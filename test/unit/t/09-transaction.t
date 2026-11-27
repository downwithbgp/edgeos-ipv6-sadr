#!/usr/bin/perl
# SPDX-License-Identifier: GPL-2.0-only
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

use EdgeOS::IPv6SADR;
use EdgeOS::IPv6SADR::Reconcile;
use SADRTest qw(temp_env reset_fixture run_cli read_json write_json
    state_rule state_route base_config base_state);

sub provider_b_config {
    my $cfg = base_config();
    $cfg->{protocols}{'ipv6-sadr'}{policy} = {
        'provider-b' => {
            'source-prefix' => ['2001:db8:b000::/56'],
            'next-hop' => '2001:db8:aa00::1',
            interface => 'eth0',
            table => '10002',
        },
    };
    return $cfg;
}

sub reconcile_active {
    my ($f) = @_;
    local %ENV = (%ENV, %{ $f->{env} });
    my $sadr = EdgeOS::IPv6SADR->new(
        state_dir => "$f->{dir}/state",
        api => $f->{env}{IPV6_SADR_API},
        ip => $f->{env}{IPV6_SADR_IP},
        no_sudo => 1,
    );
    return eval { $sadr->reconcile('active'); 1 };
}

sub split_env {
    my ($f, $working, $active) = @_;
    write_json("$f->{dir}/config.json", $working);
    write_json("$f->{dir}/active.json", $active);
    $f->{env}{FAKE_ACTIVE_CONFIG} = "$f->{dir}/active.json";
}

# A successful commit applies working state; an active-config reconcile must
# converge to active state if the commit later fails or is rolled back.
my $f = temp_env();
split_env($f, base_config(), provider_b_config());
my $working = run_cli($f, 'reconcile-working');
is($working->{rc}, 0, 'working commit applies') or diag($working->{err});
my $state = read_json("$f->{dir}/state.json");
ok(state_rule($state, 20582, '2001:db8:a000::/56', 'unreachable'),
    'working-config guard installed');

my $ok = reconcile_active($f);
ok($ok, 'active reconcile converges after failed/rolled-back commit') or diag($@);
$state = read_json("$f->{dir}/state.json");
ok(state_rule($state, 20582, '2001:db8:b000::/56', 'unreachable'),
    'active-config guard restored');
ok(!state_rule($state, 20582, '2001:db8:a000::/56', 'unreachable'),
    'working-config guard removed');
ok(state_rule($state, 20577, '2001:db8:b000::/56', 'lookup', '10002'),
    'active-config provider lookup restored');

# Interruption after kernel mutation but before configuration activation:
# the monitor's active reconcile must still converge to active state.
reset_fixture($f);
split_env($f, base_config(), provider_b_config());
$f->{env}{FAKE_IP_FAIL_AT} = 3;
my $failed = run_cli($f, 'reconcile-working');
is($failed->{rc}, 7, 'commit hook failure reported after mutation');
delete $f->{env}{FAKE_IP_FAIL_AT};
$ok = reconcile_active($f);
ok($ok, 'active reconcile converges after interrupted commit') or diag($@);
$state = read_json("$f->{dir}/state.json");
ok(state_rule($state, 20582, '2001:db8:b000::/56', 'unreachable'),
    'active guard present after interrupted commit');
ok(!state_rule($state, 20582, '2001:db8:a000::/56', 'unreachable'),
    'interrupted working guard removed');

# Two monitor-style reconciliations are serialized and remain idempotent.
reset_fixture($f);
split_env($f, provider_b_config(), provider_b_config());
my $child_rc = 0;
my @pids;
for (1 .. 2) {
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        my $ok_child = reconcile_active($f);
        exit($ok_child ? 0 : 1);
    }
    push @pids, $pid;
}
for my $pid (@pids) {
    waitpid($pid, 0);
    $child_rc |= ($? >> 8);
}
is($child_rc, 0, 'concurrent active reconciliations succeed under the lock');
$state = read_json("$f->{dir}/state.json");
is(scalar(grep { $_->{from} eq '2001:db8:b000::/56'
    && $_->{action} eq 'unreachable' } @{ $state->{rules} }), 1,
    'concurrent reconciliations do not duplicate the guard');

# Status in active mode reports active state while working state differs.
split_env($f, base_config(), provider_b_config());
ok(reconcile_active($f), 'active state reconciled before status');
my $active_status = run_cli($f, 'status', '--mode', 'active', '--json');
is($active_status->{rc}, 0, 'active status succeeds') or diag($active_status->{out});
like($active_status->{out}, qr/provider-b/, 'active status reads active configuration');

done_testing();
