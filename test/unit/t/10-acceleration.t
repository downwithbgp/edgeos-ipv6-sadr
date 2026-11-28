#!/usr/bin/perl
# SPDX-License-Identifier: GPL-2.0-only
# Off-device tests for the conservative acceleration compatibility boundary.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;

use EdgeOS::IPv6SADR::Acceleration;
use SADRTest qw(temp_env run_cli);

my $dir = tempdir(CLEANUP => 1);

sub put {
    my ($name, $text) = @_;
    my $path = "$dir/$name";
    open my $fh, '>', $path or die "cannot write $path: $!\n";
    print {$fh} $text;
    close $fh;
    return $path;
}

sub detect {
    my ($proc, $cfg) = @_;
    return EdgeOS::IPv6SADR::Acceleration->new(
        hw_nat_proc => $proc,
        config_boot => $cfg,
    )->detect();
}

sub put_in {
    my ($path, $text) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!\n";
    print {$fh} $text;
    close $fh;
    return $path;
}

my $cfg_off  = put('off.boot',  "system {\n    offload {\n        hwnat disable\n    }\n}\n");
my $cfg_on   = put('on.boot',   "system {\n    offload {\n        hwnat enable\n    }\n}\n");
my $cfg_none = put('none.boot', "system {\n    host-name erx\n}\n");
my $cfg_odd  = put('odd.boot',  "system {\n    offload {\n        hwnat\n    }\n}\n");
my $proc_on  = put('proc_on',   "1\n");
my $proc_off = put('proc_off',  "0\n");
my $missing  = "$dir/missing";
mkdir "$dir/proc_dir";

my $d = detect($proc_on, $cfg_on);
is($d->{state}, 'incompatible', 'effective enabled is incompatible');
is($d->{compatible}, 0, 'enabled is not compatible');
is($d->{effective}, 'enabled', 'effective state is detected');

$d = detect($proc_off, $cfg_off);
is($d->{state}, 'compatible', 'disabled configuration and effective state are compatible');

$d = detect($proc_off, $cfg_on);
is($d->{state}, 'inconsistent', 'configured enabled but effective disabled is inconsistent');

$d = detect($missing, $cfg_off);
is($d->{state}, 'compatible', 'absent driver is compatible');
is($d->{driver}, 'absent', 'driver absence is detected');

$d = detect("$dir/proc_dir", $cfg_off);
is($d->{state}, 'indeterminate', 'unreadable effective state is indeterminate');

$d = detect($proc_off, $missing);
is($d->{state}, 'compatible', 'effective disabled with unknown configuration is compatible');
is($d->{configured}, 'unknown', 'missing configuration is unknown');

$d = detect($proc_off, $cfg_odd);
is($d->{configured}, 'unknown', 'hwnat without a value is unknown');
is($d->{state}, 'compatible', 'effective disabled keeps an unknown configuration safe');

# First activation is refused when HWNAT is enabled, with no routing mutation.
my $f = temp_env();
my $hw = put_in("$f->{dir}/hw_nat", "1\n");
$f->{env}{IPV6_SADR_HWNAT_PROC} = $hw;
my $r = run_cli($f, 'reconcile-working');
is($r->{rc}, 7, 'first activation is refused when HWNAT is enabled');
like($r->{err}, qr/hardware acceleration/i, 'refusal explains the acceleration conflict');
ok(!-s "$f->{dir}/ip.log", 'refusal performs no routing mutations');

my $f_status = temp_env();
my $hw_status = put_in("$f_status->{dir}/hw_nat", "1\n");
$f_status->{env}{IPV6_SADR_HWNAT_PROC} = $hw_status;
my $s = run_cli($f_status, 'status', '--json');
is($s->{rc}, 10, 'status exits with the unqualified code');
my $h = eval { JSON::PP->new->decode($s->{out}) };
ok($h && ref($h) eq 'HASH', 'status JSON parses');
is($h->{acceleration}{state}, 'incompatible', 'status exposes the acceleration state');
is($h->{compatibility_violation}, 1, 'status marks the compatibility violation');
is($h->{state}, 'unqualified', 'status state is unqualified');

# Existing policies keep their protection; enabling HWNAT later is reported,
# not silently undone, and does not refuse the reconcile.
my $f2 = temp_env();
my $hw2 = "$f2->{dir}/hw_nat";
put_in($hw2, "0\n");
$f2->{env}{IPV6_SADR_HWNAT_PROC} = $hw2;
my $first = run_cli($f2, 'reconcile-working');
is($first->{rc}, 0, 'reconcile succeeds with acceleration disabled');
put_in($hw2, "1\n");
my $second = run_cli($f2, 'reconcile-working');
is($second->{rc}, 0, 'existing policies are preserved when HWNAT becomes enabled');
like($second->{err}, qr/CRITICAL.*hardware acceleration/i,
    'existing-policy path logs the critical compatibility violation');

done_testing();
