#!/usr/bin/perl
# SPDX-License-Identifier: GPL-2.0-only
use strict;
use warnings;
use Test::More;
use JSON::PP;

use EdgeOS::IPv6SADR;
use EdgeOS::IPv6SADR::Reconcile;
use SADRTest qw(temp_env reset_fixture run_cli read_json write_json mutations
    state_rule state_route base_config base_state);

sub status_json {
    my ($r) = @_;
    return JSON::PP->new->decode($r->{out});
}

my $f = temp_env();
my $r = run_cli($f, 'reconcile-working');
is($r->{rc}, 0, 'initial reconciliation succeeds') or diag($r->{err});
my $state = read_json("$f->{dir}/state.json");
ok(state_rule($state, 20576, '2001:db8:a000::/56', 'lookup', '10000'), 'internal lookup installed');
ok(state_rule($state, 20577, '2001:db8:a000::/56', 'lookup', '10001'), 'provider lookup installed');
ok(state_rule($state, 20582, '2001:db8:a000::/56', 'unreachable'), 'terminal guard installed');
ok(state_route($state, 10000, '2001:db8:10::/64'), 'internal connected route mirrored');
ok(state_route($state, 10000, '2001:db8:100::/64'), 'internal exception mirrored');
ok(state_route($state, 10001, 'default'), 'provider default installed');
ok(state_route($state, 10001, '2001:db8:10::/64', 'unreachable'),
    'provider internal guard installed');
ok(-f "$f->{dir}/state/manifest.json", 'manifest written');
ok(!-f "$f->{dir}/state/journal.json", 'journal removed after success');
my $h = status_json(run_cli($f, 'status', '--json'));
is($h->{state}, 'effective', 'health effective');
is($h->{reachability}, 'unverified', 'reachability unverified');

# Idempotency: a second run must not mutate the kernel.
my $before = scalar @{ mutations($f) };
$r = run_cli($f, 'reconcile-working', '--dry-run');
is($r->{rc}, 0, 'idempotent dry-run succeeds');
is(scalar @{ mutations($f) }, $before, 'idempotent dry-run makes no kernel mutations');

# A managed table disappearing is repaired.
$state = read_json("$f->{dir}/state.json");
delete $state->{tables}{10000};
write_json("$f->{dir}/state.json", $state);
$r = run_cli($f, 'reconcile-working');
is($r->{rc}, 0, 'table disappearance repaired') or diag($r->{err});
ok(state_route(read_json("$f->{dir}/state.json"), 10000, '2001:db8:10::/64'),
    'internal table recreated');

# A missing provider terminal default is repaired.
$state = read_json("$f->{dir}/state.json");
@{ $state->{tables}{10001} } = grep {
    !($_->{type} eq 'unreachable' && $_->{prefix} eq 'default')
} @{ $state->{tables}{10001} };
write_json("$f->{dir}/state.json", $state);
$r = run_cli($f, 'reconcile-working');
is($r->{rc}, 0, 'missing terminal default repaired') or diag($r->{err});
ok(state_route(read_json("$f->{dir}/state.json"), 10001, 'default', 'unreachable'),
    'provider default guard restored');

# Disable: provider route withdrawn, guards and lookups retained.
my $cfg = read_json("$f->{dir}/config.json");
$cfg->{protocols}{'ipv6-sadr'}{policy}{'provider-a'}{disable} = '';
write_json("$f->{dir}/config.json", $cfg);
$r = run_cli($f, 'reconcile-working');
is($r->{rc}, 0, 'disable reconciliation succeeds') or diag($r->{err});
$state = read_json("$f->{dir}/state.json");
ok(!state_route($state, 10001, 'default'), 'disabled policy has no provider route');
ok(state_rule($state, 20577, '2001:db8:a000::/56', 'lookup', '10001'), 'disabled policy keeps provider lookup');
ok(state_rule($state, 20582, '2001:db8:a000::/56', 'unreachable'), 'disabled policy keeps terminal guard');
$r = run_cli($f, 'status', '--json');
is($r->{rc}, 8, 'disabled health exit code');
is(status_json($r)->{state}, 'disabled', 'disabled health state');

# Delete: managed rules are removed and terminal guards go last.
my $delete_cfg = { protocols => { 'ipv6-sadr' => {} } };
write_json("$f->{dir}/config.json", $delete_cfg);
$r = run_cli($f, 'reconcile-working');
is($r->{rc}, 0, 'delete reconciliation succeeds') or diag($r->{err});
$state = read_json("$f->{dir}/state.json");
ok(!grep({ $_->{pref} >= 20000 && $_->{pref} <= 21031 } @{ $state->{rules} }),
    'no managed rules remain after delete');
my @dels = grep { $_->[2] eq 'del' } @{ mutations($f) };
my ($pair_i) = grep { $dels[$_][3] eq 'from' && $dels[$_][4] eq '2001:db8:a000::/56'
    && $dels[$_][5] eq 'lookup' } 0 .. $#dels;
my ($guard_i) = grep { $dels[$_][3] eq 'from' && $dels[$_][4] eq '2001:db8:a000::/56'
    && $dels[$_][5] eq 'unreachable' } 0 .. $#dels;
ok(defined $pair_i && defined $guard_i && $pair_i < $guard_i,
    'terminal guard removed after lookup pairs');

# Foreign state is refused before mutation.
reset_fixture($f);
run_cli($f, 'reconcile-working');
$state = read_json("$f->{dir}/state.json");
push @{ $state->{tables}{10001} }, {
    prefix => '2001:db8:dead::/64', type => 'unicast', dev => 'eth0',
    metric => 1024, proto => 4, table => '10001',
};
write_json("$f->{dir}/state.json", $state);
my $mut_before = scalar @{ mutations($f) };
$r = run_cli($f, 'reconcile-working');
is($r->{rc}, 7, 'foreign route refused');
like($r->{err}, qr/foreign route/, 'foreign route reported');
is(scalar @{ mutations($f) }, $mut_before, 'refusal makes no mutation');
ok(state_route(read_json("$f->{dir}/state.json"), 10001, '2001:db8:dead::/64'),
    'foreign route preserved');

# A stale desired snapshot cannot overwrite a newer committed configuration.
{
    package StaleSADR;
    our @ISA = ('EdgeOS::IPv6SADR');
    sub read_desired {
        my ($self, @args) = @_;
        my $desired = $self->SUPER::read_desired(@args);
        if ($self->{swap_once}) {
            SADRTest::write_json($self->{fake_config}, $self->{next_config});
            $self->{swap_once} = 0;
        }
        return $desired;
    }
    package main;

    my $stale = temp_env();
    my $next = base_config();
    $next->{protocols}{'ipv6-sadr'}{policy} = {
        'provider-b' => {
            'source-prefix' => ['2001:db8:b000::/56'],
            'next-hop' => '2001:db8:aa00::1',
            interface => 'eth0',
            table => '10002',
        },
    };
    local %ENV = (%ENV, %{ $stale->{env} });
    my $sadr = StaleSADR->new(
        state_dir => "$stale->{dir}/state",
        api => $stale->{env}{IPV6_SADR_API},
        ip => $stale->{env}{IPV6_SADR_IP},
        no_sudo => 1,
    );
    $sadr->{fake_config} = "$stale->{dir}/config.json";
    $sadr->{next_config} = $next;
    $sadr->{swap_once} = 1;
    my $ok = eval { $sadr->reconcile('active'); 1 };
    ok($ok, 'reconciliation retries after a configuration generation change') or diag($@);
    my $after = read_json("$stale->{dir}/state.json");
    ok(state_rule($after, 20582, '2001:db8:b000::/56', 'unreachable'),
        'new generation guard installed');
    ok(!state_rule($after, 20582, '2001:db8:a000::/56', 'unreachable'),
        'stale generation guard absent');
    ok(state_rule($after, 20577, '2001:db8:b000::/56', 'lookup', '10002'),
        'new generation provider lookup installed');
}

my $api_fail = temp_env(config => {});
$api_fail->{env}{IPV6_SADR_API} = '/bin/false';
my $af = run_cli($api_fail, 'validate-working');
is($af->{rc}, 1, 'API root failure is refused');
like($af->{err}, qr/cannot prove the protocols root/, 'API failure is a hard failure');

done_testing();
