package EdgeOS::IPv6SADR::Acceleration;
# SPDX-License-Identifier: GPL-2.0-only
#
# Conservative acceleration-state detection for the SADR compatibility
# boundary. It distinguishes the configured HWNAT state, the loaded
# driver/interface state, the effective runtime state and unknown states.
# It never changes acceleration state; it only reads.
#
# Sources on the target:
#   /config/config.boot        system { offload { hwnat enable|disable } }
#   /proc/mt7621/hw_nat        1 = hooks installed, 0 = disabled
#
# Test seams (also constructor options): IPV6_SADR_CONFIG_BOOT and
# IPV6_SADR_HWNAT_PROC.

use strict;
use warnings;

sub new {
    my ($class, %o) = @_;
    return bless {
        config_boot => $o{config_boot} // $ENV{IPV6_SADR_CONFIG_BOOT} // '/config/config.boot',
        hw_nat_proc => $o{hw_nat_proc} // $ENV{IPV6_SADR_HWNAT_PROC} // '/proc/mt7621/hw_nat',
    }, $class;
}

sub _read_text {
    my ($path) = @_;
    open my $fh, '<', $path or return (undef, "$!");
    local $/;
    my $text = <$fh>;
    close $fh;
    return (defined $text ? $text : '', undef);
}

# Configured state: enabled, disabled or unknown. Absence of an hwnat stanza
# means acceleration is not configured. A stanza without enable/disable is
# unknown rather than assumed.
sub configured_state {
    my ($self) = @_;
    my ($text, $err) = _read_text($self->{config_boot});
    return ('unknown', "cannot read $self->{config_boot}: $err") unless defined $text;
    $text =~ s{/\*.*?\*/}{}gs;
    return ('disabled', 'no hwnat stanza in the configuration')
        unless $text =~ /\bhwnat\b/;
    return ('enabled', 'configuration enables hwnat')
        if $text =~ /\bhwnat\b\s+enable\b/;
    return ('disabled', 'configuration disables hwnat')
        if $text =~ /\bhwnat\b\s+disable\b/;
    return ('unknown', 'hwnat stanza without an explicit enable/disable value');
}

# Driver/interface state: present or absent.
sub driver_state {
    my ($self) = @_;
    my $path = $self->{hw_nat_proc};
    if (-e $path) {
        return ('present', "driver interface $path exists");
    }
    return ('absent', "driver interface $path is absent");
}

# Effective runtime state: enabled, disabled or unknown.
sub effective_state {
    my ($self) = @_;
    my $path = $self->{hw_nat_proc};
    my ($text, $err) = _read_text($path);
    return ('unknown', "cannot read $path: $err") unless defined $text;
    $text =~ s/\s+//g;
    return ('enabled', 'effective acceleration is enabled') if $text eq '1';
    return ('disabled', 'effective acceleration is disabled') if $text eq '0';
    return ('unknown', "unexpected value '$text' in $path");
}

# Detect and classify. Compatible only when effective acceleration is
# disabled; enabled, inconsistent (configured enabled but effective disabled)
# and unknown states are incompatible/indeterminate and must refuse activation.
sub detect {
    my ($self) = @_;
    my ($configured, $cdetail) = $self->configured_state();
    my ($driver, $ddetail) = $self->driver_state();
    my ($effective, $edetail);
    if ($driver eq 'present') {
        ($effective, $edetail) = $self->effective_state();
    } else {
        ($effective, $edetail) = ('disabled', 'acceleration driver is absent; acceleration cannot be active');
    }
    my ($state, $detail);
    if ($driver eq 'absent') {
        ($state, $detail) = ('compatible', 'no acceleration driver; effective acceleration unavailable');
    } elsif ($effective eq 'enabled') {
        ($state, $detail) = ('incompatible', 'hardware acceleration is enabled');
    } elsif ($effective eq 'unknown') {
        ($state, $detail) = ('indeterminate', "effective acceleration state is unknown: $edetail");
    } elsif ($configured eq 'enabled') {
        ($state, $detail) = ('inconsistent',
            'configuration enables hwnat but the effective state is disabled; resolve the mismatch');
    } else {
        ($state, $detail) = ('compatible', 'effective acceleration is disabled');
    }
    return {
        schema           => 1,
        state            => $state,
        compatible       => ($state eq 'compatible' ? 1 : 0),
        critical         => ($state eq 'compatible' ? 0 : 1),
        configured       => $configured,
        driver           => $driver,
        effective        => $effective,
        detail           => $detail,
        configured_detail => $cdetail,
        driver_detail    => $ddetail,
        effective_detail => $edetail,
    };
}

1;
