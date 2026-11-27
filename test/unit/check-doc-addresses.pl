#!/usr/bin/perl
# Reject non-documentation IPv6 literals in public repository text.
#
# The project must not publish the maintainer's real prefixes. Examples use
# 2001:db8::/32, link-local, multicast, ULA and the unspecified/loopback
# addresses. This check is deliberately conservative: a literal that is not
# in an allowed range fails the build and must be replaced or justified.
use strict;
use warnings;
use Socket qw(AF_INET6 inet_pton inet_ntop);
use File::Find;

my @roots = @ARGV ? @ARGV : ('.');
my @violations;
my $checked = 0;

sub allowed {
    my ($canon) = @_;
    return 1 if $canon eq '::' || $canon eq '::1';
    return 1 if $canon =~ /^2001:db8(?::|$)/;
    return 1 if $canon =~ /^fe80:/;
    return 1 if $canon =~ /^f[cd][0-9a-f]{2}:/;
    return 1 if $canon =~ /^ff[0-9a-f]{2}:/;
    return 0;
}

sub check_line {
    my ($path, $line_no, $line) = @_;
    # At least two colons and no whitespace inside the candidate. This is a
    # conservative lexical filter; inet_pton performs the real validation.
    while ($line =~ /(?<![0-9A-Fa-f:])([0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,})(?![0-9A-Fa-f:])/g) {
        my $candidate = $1;
        $candidate =~ s/^\[//;
        $candidate =~ s/\]$//;
        my $packed = inet_pton(AF_INET6, $candidate);
        next unless defined $packed;
        $checked++;
        my $canon = inet_ntop(AF_INET6, $packed);
        next if allowed($canon);
        push @violations, "$path:$line_no: $candidate";
    }
}

sub wanted {
    my $path = $File::Find::name;
    return unless -f $path;
    return if $path =~ m{/\.git/} || $path =~ m{^\./\.git$};
    return if $path =~ m{/build/} || $path =~ m{/node_modules/};
    # This checker contains IPv6-shaped regex and format fragments, not
    # documentation examples.
    return if $path =~ m{/test/unit/check-doc-addresses\.pl$};
    return unless -T $path;
    open my $fh, '<', $path or do {
        push @violations, "$path: cannot read: $!";
        return;
    };
    my $line_no = 0;
    while (my $line = <$fh>) {
        $line_no++;
        check_line($path, $line_no, $line);
    }
    close $fh;
}

for my $root (@roots) {
    if (-d $root) {
        find({ wanted => \&wanted, no_chdir => 1 }, $root);
    } elsif (-f $root) {
        wanted($root);
    }
}

if (@violations) {
    print STDERR "Non-documentation IPv6 literal(s) found:\n";
    print STDERR "  $_\n" for @violations;
    print STDERR "Use 2001:db8::/32 (or fe80::/10, fc00::/7, ff00::/8, ::/::1) in public text.\n";
    exit 1;
}

print "checked $checked IPv6 literal(s); all in documentation-safe ranges\n";
exit 0;
