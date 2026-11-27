#!/usr/bin/perl
# SPDX-License-Identifier: GPL-2.0-only
use strict;
use warnings;
use Test::More;
use File::Find;
use File::Spec;

use SADRTest qw($ROOT);

my @node_defs;
find(sub {
    return unless -f $_ && $_ eq 'node.def';
    push @node_defs, File::Spec->rel2abs($_);
}, "$ROOT/templates");

my $directive = qr/^[a-z][a-z0-9_-]*(?::[a-z][a-z0-9_-]*)*:(?:\s.*)?$/;
for my $file (sort @node_defs) {
    open my $fh, '<', $file or die "cannot read $file: $!\n";
    my $line_no = 0;
    my @bad;
    while (my $line = <$fh>) {
        $line_no++;
        chomp $line;
        next if $line =~ /^\s*$/ || $line =~ /^\s*#/;
        push @bad, "$line_no: $line" unless $line =~ $directive;
    }
    close $fh;
    is_deeply(\@bad, [], "$file has only directive lines");
}

my $root = "$ROOT/templates/protocols/ipv6-sadr/node.def";
open my $rfh, '<', $root or die "cannot read $root: $!\n";
my $root_text = do { local $/; <$rfh> };
close $rfh;
like($root_text, qr/^priority: 500$/m, 'ipv6-sadr subtree priority 500');
like($root_text, qr/^end: \/opt\/vyatta\/sbin\/vyatta-ipv6-sadr reconcile-working$/m,
    'commit action reconciles working configuration');
like($root_text, qr/^delete: \/opt\/vyatta\/sbin\/vyatta-ipv6-sadr reconcile-working$/m,
    'delete action reconciles removal');
like($root_text, qr/^commit:expression: exec /m, 'commit validation expression present');

for my $path (
    'templates/protocols/ipv6-sadr/internal-interface/node.def',
    'templates/protocols/ipv6-sadr/destination-exception/node.def',
    'templates/protocols/ipv6-sadr/policy/node.tag/source-prefix/node.def',
) {
    open my $fh, '<', "$ROOT/$path" or die "cannot read $path: $!\n";
    my $text = do { local $/; <$fh> };
    close $fh;
    like($text, qr/^multi:$/m, "$path is a leaf-list");
}

sub read_text {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!\n";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

my $op = "$ROOT/templates/op/show/ipv6-sadr";
like(read_text("$op/status/node.def"), qr/^run: \/opt\/vyatta\/sbin\/vyatta-ipv6-sadr status$/m,
    'status op command');
like(read_text("$op/health/node.def"), qr/^run: .* health$/m, 'health op command');
like(read_text("$op/health/json/node.def"), qr/^run: .* health --json$/m, 'health JSON op command');
like(read_text("$op/policy/node.def"), qr/^run: .* policy$/m, 'policy list op command');
like(read_text("$op/policy/node.tag/node.def"), qr/^run: .* policy --name "\$4"$/m,
    'policy name op command uses the tag argument');
my $route_run = read_text("$op/route/source/node.tag/destination/node.tag/node.def");
like($route_run, qr/^run: .* route --source "\$5" --destination "\$7"$/m,
    'route op command uses named selectors and tag arguments');
unlike(read_text("$op/route/source/node.tag/node.def"), qr/^run:/m,
    'source-only route tag cannot execute without a destination');

my $monitor = read_text("$ROOT/systemd/edgeos-ipv6-sadr-monitor.service");
like($monitor, qr/^After=vyatta-router\.service/m, 'monitor starts after the router');
like($monitor, qr/^RuntimeDirectory=edgeos-ipv6-sadr$/m, 'monitor declares runtime directory');
like($monitor, qr/^RuntimeDirectoryPreserve=yes$/m, 'monitor preserves runtime state across restarts');
like($monitor, qr/^Restart=on-failure$/m, 'monitor restarts on failure');
like($monitor, qr/^ExecStart=\/opt\/vyatta\/sbin\/vyatta-ipv6-sadr monitor$/m,
    'monitor executes the reconciler monitor');

my $guard = read_text("$ROOT/systemd/edgeos-ipv6-sadr-guard.service");
like($guard, qr/^DefaultDependencies=no$/m, 'guard has minimal boot dependencies');
like($guard, qr/^Before=.*vyatta-router\.service/m, 'guard starts before the router');
like($guard, qr/^Before=.*systemd-sysctl\.service/m, 'guard starts before forwarding sysctls');
like($guard, qr/^Before=.*network-pre\.target/m, 'guard starts before network pre-configuration');
like($guard, qr/^After=local-fs\.target/m, 'guard starts after local filesystems');
unlike($guard, qr/^ConditionPathExists=/m, 'guard does not silently skip a missing config');
like($guard, qr/^WantedBy=sysinit\.target multi-user\.target$/m, 'guard is activated in both boot targets');
like($guard, qr/^ExecStart=\/opt\/vyatta\/sbin\/vyatta-ipv6-sadr boot-guard$/m,
    'guard executes boot-guard');
like($guard, qr/^RemainAfterExit=yes$/m, 'guard remains after exit');

done_testing();
