#!/usr/bin/perl
# SPDX-License-Identifier: GPL-2.0-only
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Path qw(make_path remove_tree);

use SADRTest qw(temp_env reset_fixture run_cli read_json write_json mutations
    state_rule state_route base_state);

sub status_state {
    my ($f) = @_;
    my $r = run_cli($f, 'status', '--json');
    my $h = eval { JSON::PP->new->decode($r->{out}) } || {};
    return ($r, $h);
}

# Establish the mutation sequence for the base configuration.
my $baseline = temp_env();
my $r = run_cli($baseline, 'reconcile-working');
is($r->{rc}, 0, 'baseline reconciliation') or diag($r->{err});
my $sequence = mutations($baseline);
my $count = scalar @$sequence;
cmp_ok($count, '>', 6, 'baseline produced a meaningful mutation sequence');

my $first = $sequence->[0];
is($first->[1], 'rule', 'first mutation is a rule operation');
is($first->[2], 'add', 'first mutation installs');
is($first->[5], 'unreachable', 'first mutation is the terminal guard');
is($first->[7], 20582, 'first mutation uses the terminal priority');

# Fail at every mutation boundary, then prove recovery from that state.
for my $n (1 .. $count) {
    my $f = temp_env();
    reset_fixture($f);
    $f->{env}{FAKE_IP_FAIL_AT} = $n;
    $r = run_cli($f, 'reconcile-working');
    is($r->{rc}, 7, "failure injected at mutation $n is reported");
    ok(-f "$f->{dir}/state/journal.json", "journal retained after failure at mutation $n");
    my $state = read_json("$f->{dir}/state.json");
    is(state_route($state, 'main', '2001:db8:10::/64')->{dev}, 'switch0.10',
        "base main route preserved after failure at mutation $n");
    if ($n >= 2) {
        ok(state_rule($state, 20582, '2001:db8:a000::/56', 'unreachable'),
            "terminal guard present after failure at mutation $n");
    }

    delete $f->{env}{FAKE_IP_FAIL_AT};
    $r = run_cli($f, 'reconcile-working');
    is($r->{rc}, 0, "recovery succeeds after failure at mutation $n") or diag($r->{err});
    my ($sr, $health) = status_state($f);
    is($sr->{rc}, 0, "recovered state is effective after failure at mutation $n");
    is($health->{state}, 'effective', "health effective after failure at mutation $n");
    my $after = read_json("$f->{dir}/state.json");
    my @guards = grep {
        $_->{from} eq '2001:db8:a000::/56' && $_->{action} eq 'unreachable'
    } @{ $after->{rules} };
    is(scalar @guards, 1, "exactly one terminal guard after recovery from mutation $n");
}

# Kill the reconciler at representative applied boundaries.
my @kill_points = (1, 2, int($count / 2), $count);
my %seen_kill;
for my $n (@kill_points) {
    next if $seen_kill{$n}++;
    my $f = temp_env();
    reset_fixture($f);
    $f->{env}{FAKE_IP_KILL_AT} = $n;
    $r = run_cli($f, 'reconcile-working');
    is($r->{signal}, 9, "reconciler killed at mutation $n");
    ok(-f "$f->{dir}/state/journal.json", "journal retained after kill at mutation $n");
    delete $f->{env}{FAKE_IP_KILL_AT};
    $r = run_cli($f, 'reconcile-working');
    is($r->{rc}, 0, "recovery succeeds after kill at mutation $n") or diag($r->{err});
    my ($sr, $health) = status_state($f);
    is($health->{state}, 'effective', "health effective after kill at mutation $n");
}

# A persistence failure leaves the journal for the next reconciliation.
my $pf = temp_env();
reset_fixture($pf);
make_path("$pf->{dir}/state/manifest.json");
$r = run_cli($pf, 'reconcile-working');
is($r->{rc}, 7, 'manifest persistence failure is reported');
ok(-f "$pf->{dir}/state/journal.json", 'journal retained after persistence failure');
remove_tree("$pf->{dir}/state/manifest.json");
$r = run_cli($pf, 'reconcile-working');
is($r->{rc}, 0, 'recovery after persistence failure') or diag($r->{err});
my (undef, $pf_health) = status_state($pf);
is($pf_health->{state}, 'effective', 'health effective after persistence recovery');

# Foreign state is preserved even when a failure is injected nearby.
my $ff = temp_env();
reset_fixture($ff);
$r = run_cli($ff, 'reconcile-working');
is($r->{rc}, 0, 'foreign fixture baseline');
my $state = read_json("$ff->{dir}/state.json");
push @{ $state->{tables}{10001} }, {
    prefix => '2001:db8:dead::/64', type => 'unicast', dev => 'eth0',
    metric => 1024, proto => 4, table => '10001',
};
write_json("$ff->{dir}/state.json", $state);
$ff->{env}{FAKE_IP_FAIL_AT} = 1;
$r = run_cli($ff, 'reconcile-working');
is($r->{rc}, 7, 'foreign state plus injected failure refused');
ok(state_route(read_json("$ff->{dir}/state.json"), 10001, '2001:db8:dead::/64'),
    'foreign route survives injected failure');

done_testing();
