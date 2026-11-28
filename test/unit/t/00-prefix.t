#!/usr/bin/perl
# SPDX-License-Identifier: GPL-2.0-only
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

use EdgeOS::IPv6SADR;

my $s = EdgeOS::IPv6SADR->new(state_dir => tempdir(CLEANUP => 1), no_sudo => 1);

sub dies_with {
    my ($code, $re) = @_;
    my $ok = eval { $code->(); 1 };
    return 0 if $ok;
    return $@ =~ $re;
}

is($s->parse_prefix('2001:DB8:0:0::/64')->{str}, '2001:db8::/64', 'prefix canonicalized');
is($s->parse_prefix('2001:db8:a000::/56')->{len}, 56, 'prefix length');
ok(dies_with(sub { $s->parse_prefix('2001:db8::1/64') }, qr/host bits/), 'host bits rejected');
ok(dies_with(sub { $s->parse_prefix('2001:db8::/129') }, qr/invalid/), 'length > 128 rejected');
ok(dies_with(sub { $s->parse_prefix('2001:db8::') }, qr/no \/length/), 'missing length rejected');
ok(dies_with(sub { $s->parse_prefix('fe80::1%eth0/64') }, qr/zone/), 'zone index rejected');
ok(dies_with(sub { $s->parse_prefix('not-an-address/64') }, qr/invalid/), 'garbage rejected');

is($s->parse_addr('2001:DB8::1')->{str}, '2001:db8::1', 'address canonicalized');
ok(dies_with(sub { $s->parse_addr('::') }, qr/unspecified/), 'unspecified rejected');
ok(dies_with(sub { $s->parse_addr('::1') }, qr/loopback/), 'loopback rejected');
ok(dies_with(sub { $s->parse_addr('ff02::1') }, qr/multicast/), 'multicast rejected');
ok(dies_with(sub { $s->parse_addr('::ffff:192.0.2.1') }, qr/mapped/), 'v4-mapped rejected');
ok(dies_with(sub { $s->parse_addr('2001:db8::1/64') }, qr/prefix length/), 'address with length rejected');
ok($s->is_link_local('fe80::1'), 'link-local detected');
ok(!$s->is_link_local('2001:db8::1'), 'global is not link-local');

my $a = $s->parse_prefix('2001:db8:a000::/56');
my $b = $s->parse_prefix('2001:db8:a000:1::/64');
my $c = $s->parse_prefix('2001:db8:b000::/56');
ok($s->prefix_overlaps($a, $b), 'nested prefixes overlap');
ok(!$s->prefix_overlaps($a, $c), 'disjoint prefixes do not overlap');
ok($s->prefix_contains_addr($a, $s->parse_addr('2001:db8:a000:1::1')), 'contains address');
ok(!$s->prefix_contains_addr($c, $s->parse_addr('2001:db8:a000::1')), 'does not contain outside address');

is($s->rule_from_prefix('2001:db8::1')->{str}, '2001:db8::1/128', 'bare rule source becomes /128');
is($s->rule_from_prefix('2001:db8::/56')->{str}, '2001:db8::/56', 'rule source prefix preserved');

is($s->terminal_pref('2001:db8::/56'), 20582, 'terminal priority for /56');
is($s->terminal_pref('2001:db8::/64'), 20518, 'terminal priority for /64');
cmp_ok($s->terminal_pref('2001:db8::/64'), '<', $s->terminal_pref('2001:db8::/56'),
    'longer source prefix is evaluated first');

ok($s->validate_source_prefix('2001:db8:a000::/56')->{len} == 56, 'global source accepted');
ok(dies_with(sub { $s->validate_source_prefix('::/0') }, qr/::\/0/), 'default source rejected');
ok(dies_with(sub { $s->validate_source_prefix('2001::/16') }, qr/at least \/32/), 'short source rejected');
ok(dies_with(sub { $s->validate_source_prefix('ff00::/8') }, qr/multicast/), 'multicast source rejected');
ok(dies_with(sub { $s->validate_source_prefix('fe80::/10') }, qr/link-local/), 'link-local source rejected');

ok($s->validate_internal_prefix('2001:db8:10::/64')->{len} == 64, 'internal prefix accepted');
ok(dies_with(sub { $s->validate_internal_prefix('::/0') }, qr/::\/0/), 'default internal rejected');
ok(dies_with(sub { $s->validate_internal_prefix('ff00::/8') }, qr/multicast/), 'multicast internal rejected');

my $links = { by_name => {
    eth0 => { ifname => 'eth0', ifindex => 11, master => undef },
    'eth0.100' => { ifname => 'eth0.100', ifindex => 12, master => 'eth0' },
    eth1 => { ifname => 'eth1', ifindex => 13 },
    br0 => { ifname => 'br0', ifindex => 14 },
    'switch0.10' => { ifname => 'switch0.10', ifindex => 15, master => 'br0' },
} };
ok($s->links_related($links, 'eth0', 'eth0.100'), 'VLAN child related');
ok($s->links_related($links, 'br0', 'switch0.10'), 'bridge master related');
ok(!$s->links_related($links, 'eth0', 'eth1'), 'unrelated interfaces not related');
ok(!$s->links_related($links, 'eth0', 'unknown0'), 'unknown interface not related');

done_testing();
