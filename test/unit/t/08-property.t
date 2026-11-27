#!/usr/bin/perl
# SPDX-License-Identifier: GPL-2.0-only
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Storable qw(dclone);
use JSON::PP;

use EdgeOS::IPv6SADR;
use EdgeOS::IPv6SADR::Reconcile;
use SADRTest qw(base_state obs_from_state);

my $s = EdgeOS::IPv6SADR->new(state_dir => tempdir(CLEANUP => 1), no_sudo => 1);

sub rkey { return EdgeOS::IPv6SADR::_route_key($_[0]) }
sub ukey { return EdgeOS::IPv6SADR::_rule_key($_[0]) }

sub route {
    my ($table, $prefix, $type, %rest) = @_;
    return { table => $table, prefix => $prefix, type => $type // 'unicast', %rest };
}

sub rule {
    my ($pref, $from, $action, %rest) = @_;
    return { pref => $pref, from => $from, action => $action, %rest };
}

my $seed = 20261127;
sub rnd {
    $seed = (1103515245 * $seed + 12345) % 2147483648;
    return $seed;
}

my @pool = qw(
    2001:db8:a000::/56 2001:db8:a000:1::/64 2001:db8:a000:2::/64
    2001:db8:b000::/56 2001:db8:b000:1::/64 2001:db8:c000::/48
    2001:db8:c000:1::/64 2001:db8:c000:1:1::/80 2001:db8:d000::/52
    2001:db8:d000:1::/64
);

sub clone_state_with_eth1 {
    my $state = dclone(base_state());
    push @{ $state->{links} }, { ifname => 'eth1', ifindex => 13, flags => ['UP'], operstate => 'UP' };
    push @{ $state->{tables}{main} }, {
        prefix => '2001:db8:bb00::/64', type => 'unicast', dev => 'eth1',
        metric => 256, proto => 2,
    };
    return $state;
}

sub policy_set {
    my $count = 1 + rnd() % 3;
    my @policies;
    my $offset = rnd() % scalar(@pool);
    for my $i (0 .. $count - 1) {
        my $sources = 1 + rnd() % 2;
        my @src;
        for (1 .. $sources) {
            push @src, $pool[$offset++ % scalar(@pool)];
        }
        my $if = $i % 2 ? 'eth1' : 'eth0';
        push @policies, {
            name => "p$i",
            source_prefixes => \@src,
            next_hop => $if eq 'eth1' ? '2001:db8:bb00::1' : '2001:db8:aa00::1',
            interface => $if,
            table => 10001 + $i,
            disabled => (rnd() % 7 == 0) ? 1 : 0,
        };
    }
    return \@policies;
}

for my $iteration (1 .. 40) {
    my $policies = policy_set();
    my $exceptions = (rnd() % 3 == 0) ? ['2001:db8:100::/64'] : [];
    my $desired = $s->validate_desired({
        internal_interfaces => ['switch0.10'],
        destination_exceptions => $exceptions,
        policies => $policies,
    });
    my $obs = obs_from_state(clone_state_with_eth1(), $desired);
    my $exp = $s->build_expected($desired, $obs);
    my @violations = (@{ $exp->{conflicts} }, @{ $exp->{deps} });

    my %routes = map { rkey($_) => $_ } values %{ $exp->{routes} };
    my %rules  = map { ukey($_) => $_ } values %{ $exp->{rules} };

    for my $p (@{ $desired->{policies} }) {
        for my $src (@{ $p->{source_prefixes} }) {
            my ($len) = $src =~ m{/(\d+)$};
            my $base = 20000 + (128 - $len) * 8;
            push @violations, "missing terminal guard $src"
                unless $rules{ ukey(rule($base + 6, $src, 'unreachable')) };
            push @violations, "missing internal lookup $src"
                unless $rules{ ukey(rule($base, $src, 'lookup', table => 10000)) };
            push @violations, "missing provider lookup $src"
                unless $rules{ ukey(rule($base + 1, $src, 'lookup', table => $p->{table})) };
        }
        my $default = grep {
            $_->{table} == $p->{table} && $_->{prefix} eq 'default' && $_->{type} eq 'unicast'
        } values %{ $exp->{routes} };
        push @violations, "provider default presence wrong for $p->{name}"
            if (!!$default) == ($p->{disabled} ? 1 : 0);
    }

    for my $prefix (@{ $exp->{internal} }) {
        for my $p (@{ $desired->{policies} }) {
            push @violations, "missing internal guard $prefix in $p->{table}"
                unless $routes{ rkey(route($p->{table}, $prefix, 'unreachable')) };
            push @violations, "internal destination reachable via provider $p->{name}: $prefix"
                if $routes{ rkey(route($p->{table}, $prefix)) };
        }
    }

    my @sources;
    for my $p (@{ $desired->{policies} }) {
        push @sources, @{ $p->{source_prefixes} };
    }
    for my $i (0 .. $#sources) {
        for my $j (0 .. $#sources) {
            next if $i == $j;
            my ($li) = $sources[$i] =~ m{/(\d+)$};
            my ($lj) = $sources[$j] =~ m{/(\d+)$};
            next unless $li > $lj;
            my $pi = 20000 + (128 - $li) * 8;
            my $pj = 20000 + (128 - $lj) * 8;
            push @violations, "priority order violated: $sources[$i] vs $sources[$j]"
                unless $pi < $pj;
        }
    }

    ok(!@violations, "iteration $iteration structural invariants")
        or diag(join("\n", @violations));

    my $owned = { tables => {}, routes => [], rules => [] };
    my $plan1 = $s->plan($desired, $obs, $owned, $exp);
    my $plan2 = $s->plan($desired, $obs, $owned, $exp);
    is(JSON::PP->new->canonical->encode($plan1), JSON::PP->new->canonical->encode($plan2),
        "iteration $iteration planning deterministic");

    my %applied_tables;
    for my $r (values %{ $exp->{routes} }) {
        push @{ $applied_tables{ $r->{table} } }, $r;
    }
    my $applied = {
        rules => [values %{ $exp->{rules} }],
        tables => { map { $_ => { table => $_, exists => 1, routes => $applied_tables{$_} } }
            keys %applied_tables },
        main => $obs->{main},
        links => $obs->{links},
        exact => $obs->{exact},
    };
    my $idempotent = $s->plan($desired, $applied, $owned, $exp);
    is_deeply($idempotent, [], "iteration $iteration plan is idempotent");

    # Removing one policy deletes only its objects; the remaining policies stay.
    my @remaining = @{ $desired->{policies} };
    my $removed = pop @remaining;
    my $desired2 = $s->validate_desired({
        internal_interfaces => $desired->{internal_interfaces},
        destination_exceptions => $desired->{destination_exceptions},
        policies => \@remaining,
    });
    my $exp2 = $s->build_expected($desired2, $obs);
    my $manifest = EdgeOS::IPv6SADR::_manifest_from_expected($exp, $desired->{generation});
    my $transition = $s->plan($desired2, $applied, $manifest, $exp2);
    my @rule_dels = grep { $_->{op} eq 'rule_del' } @$transition;
    my %kept = map { $_ => 1 } map { @{ $_->{source_prefixes} } } @remaining;
    my @bad = grep { $kept{ $_->{rule}{from} } } @rule_dels;
    is_deeply(\@bad, [], "iteration $iteration removal does not delete surviving rules");
    ok(scalar(grep { $_->{rule}{from} eq $removed->{source_prefixes}[0]
        && $_->{rule}{action} eq 'unreachable' } @rule_dels),
        "iteration $iteration removed policy terminal guard is deleted");

    my $foreign = dclone($applied);
    my $first_table = $desired->{policies}[0]{table};
    push @{ $foreign->{tables}{$first_table}{routes} },
        route($first_table, '2001:db8:dead::/64', 'unicast',
            dev => 'eth0', metric => 1024, proto => 4);
    my $accepted = eval { $s->check_ownership($desired, $foreign, $owned, $exp); 1 };
    ok(!$accepted, "iteration $iteration foreign route refused");
}

done_testing();
