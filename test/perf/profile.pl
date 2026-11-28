#!/usr/bin/perl
# SPDX-License-Identifier: GPL-2.0-only
# Off-device reconciliation profiler. Uses the fake API/ip harness; this is
# not a target performance claim.
use strict;
use warnings;
use Time::HiRes qw(time);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../../src/lib";
use lib "$FindBin::Bin/../../test/unit/lib";
use SADRTest qw(temp_env base_config base_state obs_from_state write_json);
use EdgeOS::IPv6SADR;
use EdgeOS::IPv6SADR::Reconcile;

sub ms { return sprintf('%.1f', $_[0] * 1000) }
sub timed {
    my ($code) = @_;
    my $start = time;
    my $value = $code->();
    return (time - $start, $value);
}

my $f = temp_env();
local %ENV = (%ENV, %{ $f->{env} });
my $s = EdgeOS::IPv6SADR->new(
    state_dir => "$f->{dir}/state",
    api => $f->{env}{IPV6_SADR_API},
    ip => $f->{env}{IPV6_SADR_IP},
    no_sudo => 1,
);

my %result = (
    environment => 'x86_64, fake config API and stateful ip harness; not EdgeOS',
    base => {},
    empty => {},
    scaling => [],
);

# Base configuration phase breakdown.
my ($read_t, $desired) = timed(sub { $s->read_desired('working') });
my ($owned_t, $owned) = timed(sub { $s->owned_state() });
my ($observe_t, $obs) = timed(sub { $s->observe($desired, $owned) });
my ($expected_t, $exp) = timed(sub { $s->build_expected($desired, $obs) });
my ($plan_t, $plan) = timed(sub { $s->plan($desired, $obs, $owned, $exp) });
$result{base} = {
    read_desired_ms => 0 + ms($read_t),
    owned_state_ms => 0 + ms($owned_t),
    observe_ms => 0 + ms($observe_t),
    build_expected_ms => 0 + ms($expected_t),
    plan_ms => 0 + ms($plan_t),
    policy_count => scalar @{ $desired->{policies} },
    internal_prefix_count => scalar @{ $exp->{internal} },
    operations => scalar @$plan,
    ip_invocations => do {
        my $n = 0;
        if (open my $fh, '<', "$f->{dir}/ip.log") {
            $n++ while <$fh>;
            close $fh;
        }
        $n;
    },
};

# Empty configuration total and phase breakdown.
my $e = temp_env(config => { protocols => { 'ipv6-sadr' => {} } });
local %ENV = (%ENV, %{ $e->{env} });
my $empty = EdgeOS::IPv6SADR->new(
    state_dir => "$e->{dir}/state",
    api => $e->{env}{IPV6_SADR_API},
    ip => $e->{env}{IPV6_SADR_IP},
    no_sudo => 1,
);
my ($empty_read_t, $empty_desired) = timed(sub { $empty->read_desired('working') });
my ($empty_owned_t, $empty_owned) = timed(sub { $empty->owned_state() });
my ($empty_observe_t, $empty_obs) = timed(sub { $empty->observe($empty_desired, $empty_owned) });
my ($empty_expected_t, $empty_exp) = timed(sub { $empty->build_expected($empty_desired, $empty_obs) });
my ($empty_plan_t, $empty_plan) = timed(sub { $empty->plan($empty_desired, $empty_obs, $empty_owned, $empty_exp) });
my ($empty_reconcile_t, $empty_ok) = timed(sub { eval { $empty->reconcile('working'); 1 } });
$result{empty} = {
    read_desired_ms => 0 + ms($empty_read_t),
    owned_state_ms => 0 + ms($empty_owned_t),
    observe_ms => 0 + ms($empty_observe_t),
    build_expected_ms => 0 + ms($empty_expected_t),
    plan_ms => 0 + ms($empty_plan_t),
    reconcile_total_ms => 0 + ms($empty_reconcile_t),
    reconcile_ok => $empty_ok ? 1 : 0,
    operations => scalar @$empty_plan,
};

# Scaling of pure planning with policy count (no kernel mutation).
for my $n (1, 10, 50, 100) {
    my @policies;
    for my $i (0 .. $n - 1) {
        my $prefix = sprintf('2001:db8:%x::/48', $i + 1);
        push @policies, {
            name => "p$i",
            source_prefixes => [$prefix],
            next_hop => '2001:db8:aa00::1',
            interface => 'eth0',
            table => 10001 + $i,
        };
    }
    my $raw = {
        internal_interfaces => ['switch0.10'],
        destination_exceptions => [],
        policies => \@policies,
    };
    my ($validate_t, $d) = timed(sub { EdgeOS::IPv6SADR->validate_desired($raw) });
    my $o = obs_from_state(base_state(), $d);
    my ($build_t, $x) = timed(sub { EdgeOS::IPv6SADR->build_expected($d, $o) });
    my $empty_owned = { tables => {}, routes => [], rules => [] };
    my ($plan_t2, $p) = timed(sub { EdgeOS::IPv6SADR->plan($d, $o, $empty_owned, $x) });
    push @{ $result{scaling} }, {
        policies => $n,
        validate_ms => 0 + ms($validate_t),
        build_expected_ms => 0 + ms($build_t),
        plan_ms => 0 + ms($plan_t2),
        operations => scalar @$p,
        conflicts => scalar @{ $x->{conflicts} },
        dependencies => scalar @{ $x->{deps} },
    };
}

my $json = JSON::PP->new->canonical->pretty->encode(\%result);
print $json;
print "\nSUMMARY\n";
printf "base: read=%.1fms observe=%.1fms build=%.1fms plan=%.1fms ops=%d ip=%d\n",
    $result{base}{read_desired_ms}, $result{base}{observe_ms},
    $result{base}{build_expected_ms}, $result{base}{plan_ms},
    $result{base}{operations}, $result{base}{ip_invocations};
printf "empty: reconcile=%.1fms read=%.1fms observe=%.1fms plan=%.1fms\n",
    $result{empty}{reconcile_total_ms}, $result{empty}{read_desired_ms},
    $result{empty}{observe_ms}, $result{empty}{plan_ms};
for my $row (@{ $result{scaling} }) {
    printf "scaling: policies=%d validate=%.1fms build=%.1fms plan=%.1fms ops=%d\n",
        $row->{policies}, $row->{validate_ms}, $row->{build_expected_ms},
        $row->{plan_ms}, $row->{operations};
}
