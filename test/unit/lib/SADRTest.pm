package SADRTest;
# SPDX-License-Identifier: GPL-2.0-only
#
# Shared helpers for unprivileged unit tests. The fake API and fake ip scripts
# keep all state in a temporary directory; no kernel or router access occurs.

use strict;
use warnings;
use Exporter 'import';
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Spec;
use Cwd qw(abs_path);
use IPC::Open3;
use Symbol qw(gensym);

our @EXPORT_OK = qw(
    $ROOT temp_env run_cli read_json write_json base_state base_config
    reset_fixture mutations obs_from_state state_rule state_route
);

our $ROOT = abs_path(File::Spec->catdir(dirname(__FILE__), '..', '..', '..'));

sub _json { return JSON::PP->new->canonical }

sub read_json {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    open my $fh, '<', $path or die "cannot read $path: $!\n";
    local $/;
    my $text = <$fh>;
    close $fh;
    return _json()->decode($text);
}

sub write_json {
    my ($path, $data) = @_;
    my (undef, $dir) = File::Spec->splitpath($path);
    make_path($dir) if length $dir && !-d $dir;
    open my $fh, '>', $path or die "cannot write $path: $!\n";
    print {$fh} _json()->encode($data);
    close $fh;
}

sub base_config {
    return {
        protocols => {
            'ipv6-sadr' => {
                'internal-interface' => ['switch0.10'],
                'destination-exception' => ['2001:db8:100::/64'],
                policy => {
                    'provider-a' => {
                        'source-prefix' => ['2001:db8:a000::/56'],
                        'next-hop' => '2001:db8:aa00::1',
                        interface => 'eth0',
                        table => '10001',
                    },
                },
            },
        },
    };
}

sub base_state {
    return {
        links => [
            { ifname => 'lo', ifindex => 1, flags => ['UP', 'LOOPBACK'], operstate => 'UNKNOWN' },
            { ifname => 'switch0.10', ifindex => 10, flags => ['UP'], operstate => 'UP' },
            { ifname => 'eth0', ifindex => 11, flags => ['UP'], operstate => 'UP' },
            { ifname => 'eth0.100', ifindex => 12, flags => ['UP'], operstate => 'UP', master => 'eth0' },
        ],
        rules => [
            { pref => 0, from => 'all', action => 'lookup', table => 'local' },
            { pref => 32766, from => 'all', action => 'lookup', table => 'main' },
            { pref => 32767, from => 'all', action => 'lookup', table => 'default' },
        ],
        tables => {
            main => [
                { prefix => '2001:db8:10::/64', type => 'unicast', dev => 'switch0.10', metric => 256, proto => 2 },
                { prefix => '2001:db8:aa00::/64', type => 'unicast', dev => 'eth0', metric => 256, proto => 2 },
                { prefix => '2001:db8:bb00::/64', type => 'unicast', dev => 'eth0.100', metric => 256, proto => 2 },
                { prefix => '2001:db8:100::/64', type => 'unicast', via => '2001:db8:10::5', dev => 'switch0.10', metric => 1024, proto => 4 },
            ],
        },
    };
}

sub temp_env {
    my (%o) = @_;
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/state");
    write_json("$dir/config.json", $o{config} // base_config());
    write_json("$dir/state.json", $o{state} // base_state());
    my %env = (
        PERL5LIB => "$ROOT/src/lib",
        IPV6_SADR_API => "$ROOT/test/unit/fake/fake_api.py",
        IPV6_SADR_IP => "$ROOT/test/unit/fake/fake_ip.py",
        IPV6_SADR_STATE_DIR => "$dir/state",
        IPV6_SADR_NO_SUDO => 1,
        IPV6_SADR_CONFIG_BOOT => "$dir/config.boot",
        IPV6_SADR_HWNAT_PROC => "$dir/hw_nat",
        FAKE_CONFIG => "$dir/config.json",
        FAKE_IP_STATE => "$dir/state.json",
        FAKE_IP_LOG => "$dir/ip.log",
        FAKE_IP_COUNT => "$dir/ip.count",
        %{ $o{env} // {} },
    );
    return { dir => $dir, env => \%env };
}

sub run_cli {
    my ($fixture, @args) = @_;
    my $err = gensym;
    my ($in, $out);
    local %ENV = (%ENV, %{ $fixture->{env} });
    my $pid = open3($in, $out, $err, $^X, "$ROOT/src/vyatta-ipv6-sadr", @args);
    close $in;
    local $/;
    my $stdout = <$out> // '';
    my $stderr = <$err> // '';
    close $out;
    close $err;
    waitpid($pid, 0);
    my $status = $?;
    return {
        rc => $status >> 8,
        signal => $status & 127,
        out => $stdout,
        err => $stderr,
        status => $status,
    };
}

sub reset_fixture {
    my ($fixture, %o) = @_;
    my $dir = $fixture->{dir};
    if (opendir(my $dh, "$dir/state")) {
        for my $f (grep { $_ ne '.' && $_ ne '..' } readdir $dh) {
            unlink "$dir/state/$f";
        }
        closedir $dh;
    }
    unlink "$dir/ip.log", "$dir/ip.count";
    write_json("$dir/config.json", $o{config} // base_config());
    write_json("$dir/state.json", $o{state} // base_state());
}

sub mutations {
    my ($fixture) = @_;
    my $path = $fixture->{dir} . '/ip.log';
    return [] unless -f $path;
    my @out;
    open my $fh, '<', $path or die "cannot read $path: $!\n";
    while (my $line = <$fh>) {
        my $argv = eval { _json()->decode($line) };
        next unless ref($argv) eq 'ARRAY' && @$argv >= 3;
        next unless $argv->[0] eq '-6';
        next unless ($argv->[1] eq 'rule' && ($argv->[2] eq 'add' || $argv->[2] eq 'del'))
            || ($argv->[1] eq 'route' && ($argv->[2] eq 'replace' || $argv->[2] eq 'del'));
        push @out, $argv;
    }
    close $fh;
    return \@out;
}

sub obs_from_state {
    my ($state, $desired) = @_;
    my %tables;
    for my $t (keys %{ $state->{tables} // {} }) {
        $tables{$t} = { table => $t, exists => 1, routes => $state->{tables}{$t} };
    }
    my %links;
    for my $l (@{ $state->{links} // [] }) {
        my @flags = @{ $l->{flags} // [] };
        my $up = (grep { $_ eq 'UP' } @flags) ? 1 : 0;
        $up = 1 if !$up && ($l->{operstate} // '') eq 'UP';
        $links{ $l->{ifname} } = { %$l, exists => 1, up => $up };
    }
    my %exact;
    for my $prefix (@{ $desired->{destination_exceptions} // [] }) {
        my @match = grep { $_->{prefix} eq $prefix }
            @{ $tables{main}{routes} // [] };
        if (@match > 1) {
            $exact{$prefix} = { ambiguous => 1, routes => \@match };
        } elsif (@match == 1) {
            $exact{$prefix} = $match[0];
        }
    }
    return {
        rules => $state->{rules} // [],
        tables => \%tables,
        main => $tables{main} // { table => 'main', exists => 1, routes => [] },
        links => \%links,
        exact => \%exact,
    };
}

sub state_rule {
    my ($state, $pref, $from, $action, $table) = @_;
    for my $r (@{ $state->{rules} // [] }) {
        next unless $r->{pref} == $pref && $r->{from} eq $from && $r->{action} eq $action;
        next if defined $table && ($r->{table} // '') ne $table;
        return $r;
    }
    return undef;
}

sub state_route {
    my ($state, $table, $prefix, $type) = @_;
    $type //= 'unicast';
    for my $r (@{ $state->{tables}{$table} // [] }) {
        return $r if $r->{prefix} eq $prefix && ($r->{type} // 'unicast') eq $type;
    }
    return undef;
}

1;
