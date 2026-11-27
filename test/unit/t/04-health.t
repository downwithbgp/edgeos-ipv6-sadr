#!/usr/bin/perl
# SPDX-License-Identifier: GPL-2.0-only
use strict;
use warnings;
use Test::More;
use JSON::PP;

use SADRTest qw(temp_env reset_fixture run_cli read_json write_json
    state_rule state_route);

sub hjson {
    my ($r) = @_;
    return JSON::PP->new->decode($r->{out});
}

my $f = temp_env();
my $r = run_cli($f, 'reconcile-working');
is($r->{rc}, 0, 'base reconciliation') or diag($r->{err});

$r = run_cli($f, 'status', '--json');
is($r->{rc}, 0, 'effective exit code');
my $h = hjson($r);
is($h->{state}, 'effective', 'effective state');
is($h->{intent}, 'configured', 'intent reported');
is($h->{realization}, 'realized', 'realization reported');
is($h->{effectiveness}, 'effective', 'effectiveness reported');
is($h->{reachability}, 'unverified', 'reachability never inferred from a route');

# Shadow: a pre-policy rule that matches the source.
my $state = read_json("$f->{dir}/state.json");
push @{ $state->{rules} }, {
    pref => 10410, from => 'all', extra => 'fwmark 0x1',
    action => 'lookup', table => '41913',
};
write_json("$f->{dir}/state.json", $state);
$r = run_cli($f, 'status', '--json');
is($r->{rc}, 5, 'shadowed exit code');
$h = hjson($r);
is($h->{state}, 'shadowed', 'shadowed state');
ok(grep({ $_->{pref} == 10410 } @{ $h->{checks}{shadowed} }), 'shadowing rule reported');

# Conflict: foreign state in a managed table.
$state = read_json("$f->{dir}/state.json");
@{ $state->{rules} } = grep { $_->{pref} != 10410 } @{ $state->{rules} };
push @{ $state->{tables}{10001} }, {
    prefix => '2001:db8:dead::/64', type => 'unicast', dev => 'eth0',
    metric => 1024, proto => 4, table => '10001',
};
write_json("$f->{dir}/state.json", $state);
$r = run_cli($f, 'status', '--json');
is($r->{rc}, 6, 'conflict exit code');
is(hjson($r)->{state}, 'conflict', 'conflict state');

# Protected: internal table loss blocks internal destinations.
reset_fixture($f);
run_cli($f, 'reconcile-working');
$state = read_json("$f->{dir}/state.json");
delete $state->{tables}{10000};
write_json("$f->{dir}/state.json", $state);
$r = run_cli($f, 'status', '--json');
is($r->{rc}, 4, 'protected exit code');
$h = hjson($r);
is($h->{state}, 'protected', 'protected state');
ok($h->{checks}{internal_blocked}, 'internal blocking reported');

# Dependency: an internal interface is down.
reset_fixture($f);
run_cli($f, 'reconcile-working');
$state = read_json("$f->{dir}/state.json");
for my $l (@{ $state->{links} }) {
    if ($l->{ifname} eq 'switch0.10') {
        $l->{flags} = [];
        $l->{operstate} = 'DOWN';
    }
}
write_json("$f->{dir}/state.json", $state);
$r = run_cli($f, 'status', '--json');
is($r->{rc}, 3, 'dependency exit code');
is(hjson($r)->{state}, 'dependency-unavailable', 'dependency state');

# Disabled.
reset_fixture($f);
my $cfg = read_json("$f->{dir}/config.json");
$cfg->{protocols}{'ipv6-sadr'}{policy}{'provider-a'}{disable} = '';
write_json("$f->{dir}/config.json", $cfg);
run_cli($f, 'reconcile-working');
$r = run_cli($f, 'status', '--json');
is($r->{rc}, 8, 'disabled exit code');
is(hjson($r)->{state}, 'disabled', 'disabled state');

# Orphaned boot guard: reported and then removed with intent ownership.
reset_fixture($f);
run_cli($f, 'reconcile-working');
my $orphan_src = '2001:db8:b000::/56';
write_json("$f->{dir}/state/boot-guards.json", {
    schema => 1,
    guards => [{ pref => 20582, from => $orphan_src, action => 'unreachable' }],
});
$state = read_json("$f->{dir}/state.json");
push @{ $state->{rules} }, {
    pref => 20582, from => $orphan_src, action => 'unreachable',
};
write_json("$f->{dir}/state.json", $state);
$r = run_cli($f, 'status', '--json');
is($r->{rc}, 9, 'orphaned-guard exit code');
$h = hjson($r);
is($h->{state}, 'orphaned-guard', 'orphaned-guard state');
ok(grep({ $_->{from} eq $orphan_src } @{ $h->{checks}{orphaned_guards} }),
    'orphan tuple reported');

$r = run_cli($f, 'reconcile-working');
is($r->{rc}, 0, 'orphan repaired') or diag($r->{err});
$state = read_json("$f->{dir}/state.json");
ok(!state_rule($state, 20582, $orphan_src, 'unreachable'), 'orphan guard removed');
ok(!-f "$f->{dir}/state/boot-guards.json", 'boot intent pruned after orphan removal');

# Incomplete: a managed rule is missing while guards remain.
reset_fixture($f);
run_cli($f, 'reconcile-working');
$state = read_json("$f->{dir}/state.json");
@{ $state->{rules} } = grep {
    !($_->{pref} == 20577 && $_->{from} eq '2001:db8:a000::/56')
} @{ $state->{rules} };
write_json("$f->{dir}/state.json", $state);
$r = run_cli($f, 'status', '--json');
is($r->{rc}, 2, 'incomplete exit code');
is(hjson($r)->{state}, 'incomplete', 'incomplete state');

# Failed: a failed status for the current generation dominates.
reset_fixture($f);
run_cli($f, 'reconcile-working');
my $status = read_json("$f->{dir}/state/status.json");
write_json("$f->{dir}/state/status.json", {
    schema => 1, state => 'failed', generation => $status->{generation},
    error => 'injected reconcile failure',
});
$r = run_cli($f, 'status', '--json');
is($r->{rc}, 7, 'failed exit code');
$h = hjson($r);
is($h->{state}, 'failed', 'failed state');
like($h->{last_failed}, qr/injected/, 'failure reason reported');

done_testing();
