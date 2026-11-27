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

sub desired {
    my (%o) = @_;
    return $s->validate_desired({
        internal_interfaces => $o{internal} // ['switch0.10'],
        destination_exceptions => $o{exceptions} // ['2001:db8:100::/64'],
        policies => $o{policies} // [{
            name => 'provider-a',
            source_prefixes => ['2001:db8:a000::/56'],
            next_hop => '2001:db8:aa00::1',
            interface => 'eth0',
            table => '10001',
        }],
    });
}

sub by_key {
    my ($list) = @_;
    return { map { rkey($_) => $_ } @$list };
}

sub rule_map {
    my ($list) = @_;
    return { map { ukey($_) => $_ } @$list };
}

my $d = desired();
my $obs = obs_from_state(base_state(), $d);
my $exp = $s->build_expected($d, $obs);
is_deeply($exp->{conflicts}, [], 'no structural conflicts');
is_deeply($exp->{deps}, [], 'no dependency findings');

my $routes = by_key([values %{ $exp->{routes} }]);
my $rules = rule_map([values %{ $exp->{rules} }]);
my $src = '2001:db8:a000::/56';
my $base = 20000 + (128 - 56) * 8;

ok($routes->{ rkey(route(10000, '2001:db8:10::/64')) }, 'connected internal route mirrored');
is($routes->{ rkey(route(10000, '2001:db8:10::/64')) }{dev}, 'switch0.10', 'connected route uses internal interface');
is($routes->{ rkey(route(10000, '2001:db8:10::/64', 'unreachable')) }{metric}, 4096,
    'internal route has an unreachable guard');
is($routes->{ rkey(route(10000, '2001:db8:100::/64')) }{via}, '2001:db8:10::5',
    'exception route mirrored exactly');
ok($routes->{ rkey(route(10000, '2001:db8:100::/64', 'unreachable')) }, 'exception guard present');

ok($rules->{ ukey(rule($base, $src, 'lookup', table => 10000)) }, 'internal lookup rule');
ok($rules->{ ukey(rule($base + 1, $src, 'lookup', table => 10001)) }, 'provider lookup rule');
ok($rules->{ ukey(rule($base + 6, $src, 'unreachable')) }, 'terminal source guard');
is($rules->{ ukey(rule($base + 6, $src, 'unreachable')) }{pref}, 20582, 'terminal priority formula');

my $p = by_key([values %{ $exp->{routes} }]);
is($routes->{ rkey(route(10001, 'default')) }{via}, '2001:db8:aa00::1', 'provider default via next hop');
is($routes->{ rkey(route(10001, 'default')) }{dev}, 'eth0', 'provider default on interface');
is($routes->{ rkey(route(10001, 'default', 'unreachable')) }{metric}, 4096,
    'provider table has a terminal default guard');
ok($routes->{ rkey(route(10001, '2001:db8:10::/64', 'unreachable')) },
    'provider table guards internal destination');
ok(!$routes->{ rkey(route(10001, '2001:db8:10::/64')) },
    'provider table has no unicast internal route');
ok($routes->{ rkey(route(10001, '2001:db8:aa00::/64')) },
    'provider table resolves the next-hop connected route');

# Longest source prefix gets the lower priority number.
my $nested = desired(policies => [
    { name => 'provider-a', source_prefixes => ['2001:db8:a000::/56'],
      next_hop => '2001:db8:aa00::1', interface => 'eth0', table => '10001' },
    { name => 'provider-b', source_prefixes => ['2001:db8:b000:1::/64'],
      next_hop => '2001:db8:bb00::1', interface => 'eth1', table => '10002' },
]);
my $nested_state = dclone(base_state());
push @{ $nested_state->{links} }, { ifname => 'eth1', ifindex => 13, flags => ['UP'], operstate => 'UP' };
push @{ $nested_state->{tables}{main} }, { prefix => '2001:db8:bb00::/64', type => 'unicast',
    dev => 'eth1', metric => 256, proto => 2 };
my $nested_obs = obs_from_state($nested_state, $nested);
my $nested_exp = $s->build_expected($nested, $nested_obs);
my $nested_rules = rule_map([values %{ $nested_exp->{rules} }]);
my $short_pref = 20000 + (128 - 56) * 8;
my $long_pref  = 20000 + (128 - 64) * 8;
cmp_ok($long_pref, '<', $short_pref, 'longer source prefix has lower priority');
ok($nested_rules->{ ukey(rule($long_pref, '2001:db8:b000:1::/64', 'lookup', table => 10000)) },
    'nested policy internal rule installed');
ok($nested_rules->{ ukey(rule($long_pref + 6, '2001:db8:b000:1::/64', 'unreachable')) },
    'nested policy terminal guard installed');

# Disabled policy keeps rules/guards but has no provider route.
my $disabled = desired(policies => [{
    name => 'provider-a', source_prefixes => ['2001:db8:a000::/56'],
    next_hop => '2001:db8:aa00::1', interface => 'eth0', table => '10001', disabled => 1,
}]);
my $disabled_exp = $s->build_expected($disabled, $obs);
my $disabled_routes = by_key([values %{ $disabled_exp->{routes} }]);
ok(!$disabled_routes->{ rkey(route(10001, 'default')) }, 'disabled policy installs no provider route');
ok($disabled_routes->{ rkey(route(10001, 'default', 'unreachable')) }, 'disabled policy keeps the table guard');
my $disabled_rules = rule_map([values %{ $disabled_exp->{rules} }]);
ok($disabled_rules->{ ukey(rule($base + 1, $src, 'lookup', table => 10001)) }, 'disabled policy keeps provider lookup');
ok($disabled_rules->{ ukey(rule($base + 6, $src, 'unreachable')) }, 'disabled policy keeps terminal guard');

# Idempotency: observed state equal to expected produces no operations.
my %applied_tables;
for my $r (values %{ $exp->{routes} }) {
    push @{ $applied_tables{ $r->{table} } }, $r;
}
my $applied_obs = {
    rules => [values %{ $exp->{rules} }],
    tables => { map { $_ => { table => $_, exists => 1, routes => $applied_tables{$_} } }
        keys %applied_tables },
    main => $obs->{main},
    links => $obs->{links},
    exact => $obs->{exact},
};
my $owned = { tables => {}, routes => [], rules => [] };
my $plan = $s->plan($d, $applied_obs, $owned, $exp);
is_deeply($plan, [], 'idempotent plan is empty');
my $plan2 = $s->plan($d, $applied_obs, $owned, $exp);
is(JSON::PP->new->canonical->encode($plan), JSON::PP->new->canonical->encode($plan2),
    'planning is deterministic');

# Ownership refusals never delete foreign state.
my $foreign_obs = dclone($obs);
$foreign_obs->{tables}{10001} = { table => 10001, exists => 1, routes => [
    route(10001, '2001:db8:dead::/64', 'unicast', proto => 4, dev => 'eth0', metric => 1024),
] };
my $ok = eval { $s->check_ownership($d, $foreign_obs, $owned, $exp); 1 };
ok(!$ok && $@ =~ /foreign route/, 'foreign route refused');

my $unexpected_obs = dclone($obs);
$unexpected_obs->{tables}{10001} = { table => 10001, exists => 1, routes => [
    route(10001, '2001:db8:dead::/64', 'unicast', proto => 194, dev => 'eth0', metric => 1024),
] };
$ok = eval { $s->check_ownership($d, $unexpected_obs, $owned, $exp); 1 };
ok(!$ok && $@ =~ /unexpected route/, 'unexpected proto-194 route refused');

my $foreign_rule_obs = dclone($obs);
push @{ $foreign_rule_obs->{rules} }, rule(20578, $src, 'lookup', table => 19999);
$ok = eval { $s->check_ownership($d, $foreign_rule_obs, $owned, $exp); 1 };
ok(!$ok && $@ =~ /unexpected rule/, 'foreign managed-range rule refused');

my $owned_extra = { tables => {}, routes => [ rkey(route(10001, '2001:db8:dead::/64')) ], rules => [] };
$ok = eval { $s->check_ownership($d, $unexpected_obs, $owned_extra, $exp); 1 };
ok($ok, 'owned proto-194 route is tolerated');

# Prefix shrink (/56 -> /64): install the new guard before removing the old guard.
my $narrow = desired(policies => [{
    name => 'provider-a', source_prefixes => ['2001:db8:a000:1::/64'],
    next_hop => '2001:db8:aa00::1', interface => 'eth0', table => '10001',
}]);
my $narrow_obs = obs_from_state(base_state(), $narrow);
my $narrow_exp = $s->build_expected($narrow, $narrow_obs);
my $old56 = '2001:db8:a000::/56';
my $old56_base = 20000 + (128 - 56) * 8;
my $shrink_obs = dclone($applied_obs);
my $shrink_owned = { tables => {}, routes => [],
    rules => [ map { ukey($_) } @{ $shrink_obs->{rules} } ] };
my $shrink_plan = $s->plan($narrow, $shrink_obs, $shrink_owned, $narrow_exp);
my ($add64_i) = grep { $shrink_plan->[$_]{op} eq 'rule_add'
    && $shrink_plan->[$_]{rule}{pref} == $long_pref + 6
    && $shrink_plan->[$_]{rule}{from} eq '2001:db8:a000:1::/64' } 0 .. $#$shrink_plan;
my ($del56_i) = grep { $shrink_plan->[$_]{op} eq 'rule_del'
    && $shrink_plan->[$_]{rule}{pref} == $old56_base + 6
    && $shrink_plan->[$_]{rule}{from} eq $old56 } 0 .. $#$shrink_plan;
ok(defined $add64_i && defined $del56_i, 'shrink plans new guard and old guard removal');
cmp_ok($add64_i, '<', $del56_i, 'new terminal guard installed before old guard removal');

# Exception removal: remove the real route before its guard.
my $noexc = desired(exceptions => []);
my $noexc_exp = $s->build_expected($noexc, $obs);
my $noexc_obs = dclone($applied_obs);
my $noexc_owned = {
    tables => {},
    routes => [
        rkey(route(10000, '2001:db8:100::/64', 'unicast')),
        rkey(route(10000, '2001:db8:100::/64', 'unreachable')),
        rkey(route(10001, '2001:db8:100::/64', 'unreachable')),
    ],
    rules => [],
};
my $noexc_plan = $s->plan($noexc, $noexc_obs, $noexc_owned, $noexc_exp);
my ($uni_i) = grep { $noexc_plan->[$_]{op} eq 'route_del'
    && $noexc_plan->[$_]{route}{prefix} eq '2001:db8:100::/64'
    && $noexc_plan->[$_]{route}{type} eq 'unicast' } 0 .. $#$noexc_plan;
my ($guard_i) = grep { $noexc_plan->[$_]{op} eq 'route_del'
    && $noexc_plan->[$_]{route}{prefix} eq '2001:db8:100::/64'
    && $noexc_plan->[$_]{route}{type} eq 'unreachable' } 0 .. $#$noexc_plan;
ok(defined $uni_i && defined $guard_i, 'exception removal plans route and guard deletion');
cmp_ok($uni_i, '<', $guard_i, 'real exception route removed before guard');

# Missing managed table and missing terminal default are repaired.
my $missing_obs = dclone($obs);
delete $missing_obs->{tables}{10000};
my $missing_exp = $s->build_expected($d, $missing_obs);
my $missing_plan = $s->plan($d, $missing_obs, $owned, $missing_exp);
ok(scalar(grep { $_->{op} eq 'route_replace' && $_->{route}{table} == 10000 } @$missing_plan),
    'missing internal table is recreated');

my $no_default_obs = dclone($applied_obs);
@{ $no_default_obs->{tables}{10001}{routes} } =
    grep { !($_->{type} eq 'unreachable' && $_->{prefix} eq 'default') }
    @{ $no_default_obs->{tables}{10001}{routes} };
my $no_default_plan = $s->plan($d, $no_default_obs, $owned, $exp);
ok(scalar(grep { $_->{op} eq 'route_replace'
    && $_->{route}{table} == 10001 && $_->{route}{type} eq 'unreachable'
    && $_->{route}{prefix} eq 'default' } @$no_default_plan),
    'missing provider terminal default is repaired');

done_testing();
