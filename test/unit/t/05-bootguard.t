#!/usr/bin/perl
# SPDX-License-Identifier: GPL-2.0-only
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

use EdgeOS::IPv6SADR;
use EdgeOS::IPv6SADR::BootGuard;
use SADRTest qw(temp_env reset_fixture run_cli read_json write_json
    state_rule base_config);

sub write_text {
    my ($path, $text) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!\n";
    print {$fh} $text;
    close $fh;
}

sub config_boot {
    return <<'CFG';
/* EdgeOS configuration */
protocols {
    ipv6-sadr {
        internal-interface switch0.10
        policy provider-a {
            source-prefix 2001:db8:a000::/56
            next-hop 2001:db8:aa00::1
            interface eth0
        }
        policy provider-b {
            source-prefix 2001:db8:b000::/56 /* second provider */
        }
    }
}
CFG
}

my $s = EdgeOS::IPv6SADR->new(state_dir => tempdir(CLEANUP => 1), no_sudo => 1);
my $f = temp_env();
my $cfg_path = "$f->{dir}/config.boot";
write_text($cfg_path, config_boot());

my $parsed = $s->parse_config_boot_sources($cfg_path);
is_deeply($parsed->{sources}, ['2001:db8:a000::/56', '2001:db8:b000::/56'],
    'config.boot sources parsed and canonicalized');
is(length $parsed->{generation}, 64, 'config.boot generation hash');
is($s->parse_config_boot_sources($cfg_path)->{generation}, $parsed->{generation},
    'config.boot generation stable');

my $r = run_cli($f, 'boot-guard', '--config', $cfg_path);
is($r->{rc}, 0, 'boot guard succeeds') or diag($r->{err});
my $state = read_json("$f->{dir}/state.json");
ok(state_rule($state, 20582, '2001:db8:a000::/56', 'unreachable'), 'guard A installed');
ok(state_rule($state, 20582, '2001:db8:b000::/56', 'unreachable'), 'guard B installed');
my $intent = read_json("$f->{dir}/state/boot-guards.json");
is(scalar @{ $intent->{guards} }, 2, 'intent records exact guard tuples');
is($intent->{generation}, $parsed->{generation}, 'intent records config generation');

my $before = scalar @{ $intent->{guards} };
$r = run_cli($f, 'boot-guard', '--config', $cfg_path);
is($r->{rc}, 0, 'boot guard is idempotent');
is(scalar @{ read_json("$f->{dir}/state/boot-guards.json")->{guards} }, $before,
    'intent is not duplicated');

# A later boot-guard run is additive: dropping a policy from config.boot must
# not lose ownership of the still-installed guard.
write_text($cfg_path, <<'ONE');
protocols {
    ipv6-sadr {
        policy provider-a {
            source-prefix 2001:db8:a000::/56
        }
    }
}
ONE
$r = run_cli($f, 'boot-guard', '--config', $cfg_path);
is($r->{rc}, 0, 'boot guard accepts a smaller configuration');
$intent = read_json("$f->{dir}/state/boot-guards.json");
is(scalar @{ $intent->{guards} }, 2, 'boot intent is additive across runs');
ok(state_rule(read_json("$f->{dir}/state.json"), 20582,
    '2001:db8:b000::/56', 'unreachable'), 'earlier guard remains owned');

# Intent is written before the first mutation, so a failed install is attributable.
reset_fixture($f);
write_text($cfg_path, config_boot());
$f->{env}{FAKE_IP_FAIL_AT} = 1;
$r = run_cli($f, 'boot-guard', '--config', $cfg_path);
is($r->{rc}, 7, 'failed guard install returns failure');
$intent = read_json("$f->{dir}/state/boot-guards.json");
ok($intent && @{ $intent->{guards} } == 2, 'intent survives a failed install');
delete $f->{env}{FAKE_IP_FAIL_AT};

# A conflicting rule at the guard priority is refused, not deleted.
reset_fixture($f);
$state = read_json("$f->{dir}/state.json");
push @{ $state->{rules} }, {
    pref => 20582, from => '2001:db8:c000::/56', action => 'unreachable',
};
write_json("$f->{dir}/state.json", $state);
$r = run_cli($f, 'boot-guard', '--config', $cfg_path);
is($r->{rc}, 7, 'conflicting guard priority refused');
like($r->{err}, qr/boot guard conflict/, 'conflict reported');
ok(state_rule(read_json("$f->{dir}/state.json"), 20582, '2001:db8:c000::/56', 'unreachable'),
    'conflicting rule preserved');

# Empty subtree is valid and installs no guard.
reset_fixture($f);
write_text("$f->{dir}/empty.boot", "protocols {\n    ipv6-sadr {\n    }\n}\n");
$r = run_cli($f, 'boot-guard', '--config', "$f->{dir}/empty.boot");
is($r->{rc}, 0, 'empty subtree accepted');
is(scalar @{ read_json("$f->{dir}/state/boot-guards.json")->{guards} }, 0,
    'empty subtree installs no guards');

# Malformed configuration fails closed.
write_text("$f->{dir}/unbalanced.boot", "protocols {\n  ipv6-sadr {\n    policy p {\n      source-prefix 2001:db8::/56\n");
my $ok = eval { $s->parse_config_boot_sources("$f->{dir}/unbalanced.boot"); 1 };
ok(!$ok && $@ =~ /unbalanced/, 'unbalanced configuration rejected');

$ok = eval { $s->parse_config_boot_sources("$f->{dir}/missing.boot"); 1 };
ok(!$ok && $@ =~ /cannot read/, 'missing configuration is a failure, not a skip');

write_text("$f->{dir}/badprefix.boot",
    "protocols {\n  ipv6-sadr {\n    policy p {\n      source-prefix 2001:db8::1/64\n    }\n  }\n}\n");
$ok = eval { $s->parse_config_boot_sources("$f->{dir}/badprefix.boot"); 1 };
ok(!$ok && $@ =~ /host bits/, 'invalid source prefix rejected');

done_testing();
