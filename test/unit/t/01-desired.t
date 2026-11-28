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

sub raw_config {
    return {
        internal_interfaces => ['switch0.20', 'switch0.10'],
        destination_exceptions => ['2001:db8:100::/64'],
        policies => [
            {
                name => 'provider-b',
                source_prefixes => ['2001:db8:b000::/56'],
                next_hop => '2001:db8:bb00::1',
                interface => 'eth1',
            },
            {
                name => 'provider-a',
                source_prefixes => ['2001:db8:a000::/56', '2001:db8:a000:1::/64'],
                next_hop => '2001:db8:aa00::1',
                interface => 'eth0',
                table => '10001',
                description => 'provider a',
            },
        ],
    };
}

my $d = $s->validate_desired(raw_config());
is_deeply($d->{internal_interfaces}, ['switch0.10', 'switch0.20'], 'internal interfaces sorted');
is_deeply([map { $_->{name} } @{ $d->{policies} }], ['provider-a', 'provider-b'], 'policies sorted by name');
is_deeply($d->{policies}[0]{source_prefixes},
    ['2001:db8:a000:1::/64', '2001:db8:a000::/56'], 'source prefixes longest first');
is($d->{policies}[0]{table}, 10001, 'explicit table preserved');
ok($d->{policies}[1]{table} >= 10001 && $d->{policies}[1]{table} <= 19999, 'auto table in range');
ok(length $d->{generation} == 64, 'sha256 generation');

my $d2 = $s->validate_desired(raw_config());
is($d2->{generation}, $d->{generation}, 'generation deterministic');

my $reordered = raw_config();
@{$reordered->{internal_interfaces}} = reverse @{$reordered->{internal_interfaces}};
@{$reordered->{policies}} = reverse @{$reordered->{policies}};
@{$reordered->{policies}[0]{source_prefixes}} = reverse @{$reordered->{policies}[0]{source_prefixes}};
my $d3 = $s->validate_desired($reordered);
is($d3->{generation}, $d->{generation}, 'generation insensitive to declaration order');

my $changed = raw_config();
$changed->{policies}[1]{description} = 'changed';
isnt($s->validate_desired($changed)->{generation}, $d->{generation}, 'generation changes with content');

ok(dies_with(sub { $s->validate_desired({
    policies => [{ name => 'p', source_prefixes => ['2001:db8::/56'],
        next_hop => '2001:db8::1', interface => 'eth0', table => 10001 }],
    policies => [{ name => 'p', source_prefixes => ['2001:db8::/56'],
        next_hop => '2001:db8::1', interface => 'eth0', table => 10001 },
        { name => 'q', source_prefixes => ['2001:db8:1::/56'],
        next_hop => '2001:db8::1', interface => 'eth0', table => 10001 }],
}) }, qr/table .* more than one policy/), 'duplicate table rejected');

ok(dies_with(sub { $s->validate_desired({
    policies => [{ name => 'bad name', source_prefixes => ['2001:db8::/56'],
        next_hop => '2001:db8::1', interface => 'eth0' }],
}) }, qr/invalid policy name/), 'policy name rejected');

ok(dies_with(sub { $s->validate_desired({
    policies => [{ name => 'p', source_prefixes => ['2001:db8::/56'] }],
}) }, qr/requires next-hop or interface/), 'missing egress rejected');

ok(dies_with(sub { $s->validate_desired({
    policies => [{ name => 'p', source_prefixes => ['2001:db8::/56'], next_hop => '2001:db8::1' }],
}) }, qr/requires interface with next-hop/), 'next-hop without interface rejected');

ok(dies_with(sub { $s->validate_desired({
    internal_interfaces => ['eth0'],
    policies => [{ name => 'p', source_prefixes => ['2001:db8::/56'],
        next_hop => '2001:db8::1', interface => 'eth0' }],
}) }, qr/also an internal interface/), 'policy interface cannot be internal');

ok(dies_with(sub { $s->validate_desired({
    internal_interfaces => ['eth0'],
    policies => [{ name => 'p', source_prefixes => ['2001:db8::/56'],
        next_hop => '2001:db8::1', interface => 'eth0.100' }],
}) }, qr/conflicts with policy/), 'VLAN child of internal interface rejected');

ok(dies_with(sub { $s->validate_desired({
    policies => [{ name => 'p', source_prefixes => ['2001:db8::/56'],
        next_hop => '2001:db8::1', interface => 'eth0', table => 9999 }],
}) }, qr/invalid table/), 'table below range rejected');

ok(dies_with(sub { $s->validate_desired({
    policies => [{ name => 'p', source_prefixes => ['2001:db8::/56'],
        next_hop => '2001:db8::1', interface => 'eth0', table => 20000 }],
}) }, qr/invalid table/), 'table above range rejected');

ok(dies_with(sub { $s->validate_desired({
    policies => [{ name => 'p', source_prefixes => ['2001:db8::/56'],
        next_hop => '2001:db8::1', interface => 'eth0' },
        { name => 'q', source_prefixes => ['2001:db8::/56'],
        next_hop => '2001:db8::1', interface => 'eth0' }],
}) }, qr/more than one policy/), 'duplicate source prefix rejected');

ok(dies_with(sub { $s->validate_desired({
    destination_exceptions => ['2001:db8:100::/64', '2001:db8:100::/64'],
}) }, qr/duplicate destination exception/), 'duplicate exception rejected');

ok(dies_with(sub { $s->validate_desired({
    destination_exceptions => ['ff00::/8'],
}) }, qr/multicast/), 'multicast exception rejected');

ok(dies_with(sub { $s->validate_desired({
    policies => [{ name => 'p', source_prefixes => ['::/0'],
        next_hop => '2001:db8::1', interface => 'eth0' }],
}) }, qr/::\/0/), 'default source prefix rejected');

ok(dies_with(sub { $s->validate_desired({
    policies => [{ name => 'p', source_prefixes => ['fe80::/10'],
        next_hop => '2001:db8::1', interface => 'eth0' }],
}) }, qr/link-local/), 'link-local source prefix rejected');

ok(dies_with(sub { $s->validate_desired({
    internal_interfaces => ['switch0.10', 'switch0.10'],
}) }, qr/duplicate internal interface/), 'duplicate internal interface rejected');

my $disabled = raw_config();
$disabled->{policies}[1]{disabled} = 1;
my ($disabled_a) = grep { $_->{name} eq 'provider-a' }
    @{ $s->validate_desired($disabled)->{policies} };
ok($disabled_a->{disabled}, 'disabled preserved');

my $empty = $s->validate_desired({});
is_deeply($empty->{policies}, [], 'empty configuration valid');
is($empty->{internal_interfaces}[0], undef, 'empty internal list');

done_testing();
