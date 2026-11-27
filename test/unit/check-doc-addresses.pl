#!/usr/bin/perl
# Reject non-documentation IPv6 and IPv4 literals in public repository text.
#
# Examples must use 2001:db8::/32, the IPv4 TEST-NET ranges, loopback,
# link-local, multicast or ULA space. This check is deliberately conservative:
# a literal outside those ranges fails the build and must be replaced or
# explicitly justified.
use strict;
use warnings;
use Socket qw(AF_INET AF_INET6 inet_pton inet_ntop);

my @roots = @ARGV ? @ARGV : ('.');
my @violations;
my $checked = 0;

sub allowed_v6 {
    my ($canon) = @_;
    return 1 if $canon eq '::' || $canon eq '::1';
    return 1 if $canon =~ /^2001:db8(?::|$)/;
    return 1 if $canon =~ /^fe80:/;
    return 1 if $canon =~ /^f[cd][0-9a-f]{2}:/;
    return 1 if $canon =~ /^ff[0-9a-f]{2}:/;
    return 0;
}

sub allowed_v4 {
    my ($canon) = @_;
    return 1 if $canon eq '0.0.0.0' || $canon eq '255.255.255.255';
    return 1 if $canon =~ /^127\./;
    return 1 if $canon =~ /^192\.0\.2\./;
    return 1 if $canon =~ /^198\.51\.100\./;
    return 1 if $canon =~ /^203\.0\.113\./;
    return 0;
}

sub check_line {
    my ($display_path, $line_no, $line) = @_;

    # Explicit, reviewable escape hatch for the checker's own negative
    # fixtures. Do not use it for prose examples.
    return if $line =~ /doc-check:\s*ignore-line/;

    # IPv6: at least two colons. This lexical filter is intentionally broad;
    # inet_pton performs the real validation.
    while ($line =~ /(?<![0-9A-Fa-f:])([0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,})(?![0-9A-Fa-f:])/g) {
        my $candidate = $1;
        $candidate =~ s/^\[//;
        $candidate =~ s/\]$//;
        my $packed = inet_pton(AF_INET6, $candidate);
        next unless defined $packed;
        $checked++;
        my $canon = inet_ntop(AF_INET6, $packed);
        next if allowed_v6($canon);
        push @violations, "$display_path:$line_no: IPv6 $candidate";
    }

    # IPv4: four dotted decimal octets. Version strings such as 1.2.3.4 are
    # also caught; use a TEST-NET range in documentation.
    while ($line =~ /(?<![\d.])((?:\d{1,3}\.){3}\d{1,3})(?![\d.])/g) {
        my $candidate = $1;
        my $packed = inet_pton(AF_INET, $candidate);
        next unless defined $packed;
        $checked++;
        my $canon = inet_ntop(AF_INET, $packed);
        next if allowed_v4($canon);
        push @violations, "$display_path:$line_no: IPv4 $candidate";
    }
}

sub check_file {
    my ($path, $display_path) = @_;
    return unless -f $path;
    return unless -T $path;

    # Only scan prose, shell and data files. Perl sources contain regex
    # fragments such as Cwd::abs_path that look like IPv6 literals.
    my $base = $path;
    $base =~ s{.*/}{};
    my $scannable =
        ($base =~ /\.(?:md|txt|sh|bash|yml|yaml|json|conf|def|template)$/) ||
        ($base =~ /^(?:README|AGENTS|CONTRIBUTING|CHANGELOG)$/);
    return unless $scannable;

    open my $fh, '<', $path or do {
        push @violations, "$display_path: cannot read: $!";
        return;
    };
    my $line_no = 0;
    while (my $line = <$fh>) {
        $line_no++;
        check_line($display_path, $line_no, $line);
    }
    close $fh;
}

sub walk {
    my ($dir) = @_;
    opendir my $dh, $dir or do {
        push @violations, "$dir: cannot read directory: $!";
        return;
    };
    my @entries = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    for my $entry (@entries) {
        my $path = "$dir/$entry";
        if (-d $path) {
            next if $entry eq '.git' || $entry eq 'build' || $entry eq 'node_modules';
            walk($path);
        } elsif (-f $path) {
            check_file($path, $path);
        }
    }
}

for my $root (@roots) {
    if (-d $root) {
        walk($root);
    } elsif (-f $root) {
        check_file($root, $root);
    }
}

if (@violations) {
    print STDERR "Non-documentation IP literal(s) found:\n";
    print STDERR "  $_\n" for @violations;
    print STDERR "Use 2001:db8::/32, 192.0.2.0/24, 198.51.100.0/24 or 203.0.113.0/24 in public text.\n";
    exit 1;
}

print "checked $checked IP literal(s); all in documentation-safe ranges\n";
exit 0;
