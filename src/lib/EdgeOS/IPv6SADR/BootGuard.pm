package EdgeOS::IPv6SADR;
# SPDX-License-Identifier: GPL-2.0-only
#
# Early boot guard. Parses /config/config.boot directly (the CLI API is not
# available before vyatta-router.service), records the exact terminal-guard
# tuples in /run, then installs `from S unreachable` rules. This runs before
# forwarding is allowed so a constrained source cannot fall back to native
# routing during the boot window.
#
# Load EdgeOS::IPv6SADR first.

use strict;
use warnings;

# EdgeOS configuration is line-oriented: `key {`, `}`, `key value`, `key`.
# Quoted values are single tokens; block comments are removed first.
sub _cfg_tokens {
    my ($line) = @_;
    my @t;
    while ($line =~ /\G\s*(?:"([^"]*)"|'([^']*)'|(\{|\})|(\S+))/gc) {
        push @t, defined $1 ? $1 : defined $2 ? $2 : defined $3 ? $3 : $4;
    }
    return @t;
}

sub parse_config_boot_sources {
    my ($self, $file) = @_;
    open my $fh, '<', $file or die "cannot read $file: $!\n";
    local $/;
    my $text = <$fh>;
    close $fh;
    my $generation = Digest::SHA::sha256_hex($text);
    $text =~ s{/\*.*?\*/}{}gs;

    my (@stack, %source);
    my $line_no = 0;
    for my $line (split /\n/, $text) {
        $line_no++;
        my @t = _cfg_tokens($line);
        my $i = 0;
        while ($i < @t) {
            my $token = $t[$i];
            if ($token eq '}') {
                die "unbalanced braces in $file at line $line_no\n" unless @stack;
                pop @stack;
                $i++;
                next;
            }
            if ($token eq '{') {
                die "block without a name in $file at line $line_no\n";
            }
            my @words;
            while ($i < @t && $t[$i] ne '{' && $t[$i] ne '}') {
                push @words, $t[$i];
                $i++;
            }
            if ($i < @t && $t[$i] eq '{') {
                die "anonymous block in $file at line $line_no\n" unless @words;
                push @stack, join(' ', @words);
                $i++;
                next;
            }
            my $key = shift @words;
            my $value = join(' ', @words);
            my $path = join(' ', @stack);
            if ($path =~ /^protocols ipv6-sadr policy \S+$/ && $key eq 'source-prefix') {
                my $prefix = $self->validate_source_prefix($value);
                $source{ $prefix->{str} } = 1;
            }
        }
    }
    die "unbalanced braces in $file\n" if @stack;
    return {
        config     => $file,
        generation => $generation,
        sources    => [sort keys %source],
    };
}

sub boot_guard {
    my ($self, %o) = @_;
    my $config = $o{config} // '/config/config.boot';
    my $parsed = $self->parse_config_boot_sources($config);
    my @guards = map {
        {
            pref   => $self->terminal_pref($_),
            from   => $_,
            action => 'unreachable',
        }
    } @{ $parsed->{sources} };

    # Intent is additive: a later boot-guard run must not lose ownership of
    # guards installed earlier. Only successful reconciliation prunes tuples.
    my $previous = $self->read_boot_intent();
    my (%seen, @all_guards);
    for my $guard (@{ $previous->{guards} // [] }, @guards) {
        next unless defined $guard->{pref} && defined $guard->{from};
        my $copy = { pref => $guard->{pref}, from => $guard->{from},
                     action => $guard->{action} // 'unreachable' };
        my $key = join('|', $copy->{pref}, $copy->{from}, $copy->{action});
        next if $seen{$key}++;
        push @all_guards, $copy;
    }
    $self->write_boot_intent({
        config     => $config,
        generation => $parsed->{generation},
        guards     => \@all_guards,
    });

    my $obs = $self->observe_rules();
    my %present = map { _rule_key($_) => $_ } @$obs;
    for my $guard (@guards) {
        my $key = _rule_key($guard);
        next if $present{$key};
        my @clash = grep { $_->{pref} == $guard->{pref} } @$obs;
        if (@clash) {
            die "boot guard conflict at priority $guard->{pref}: $clash[0]{raw}\n";
        }
        my ($rc, $out, $err) = $self->_ip_run($self->_rule_args($guard, 'add'));
        die "cannot install boot guard for $guard->{from} (rc=$rc): $err\n"
            if $rc != 0 && $err !~ /File exists/;
    }

    my $after = $self->observe_rules();
    my %after = map { _rule_key($_) => $_ } @$after;
    my @missing = grep { !$after{ _rule_key($_) } } @guards;
    die "boot guard verification failed: "
        . join(', ', map { $_->{from} } @missing) . "\n" if @missing;

    $self->logmsg("boot guard: " . scalar(@guards) . " terminal guard(s) verified");
    return \@guards;
}

1;
