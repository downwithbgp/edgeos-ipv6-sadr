package EdgeOS::IPv6SADR;
# SPDX-License-Identifier: GPL-2.0-only
#
# Operational health. Intent, kernel realization, policy effectiveness and
# reachability are separate fields; a structurally correct policy is never
# reported as proof that a provider is reachable. Health never mutates state.
#
# Load EdgeOS::IPv6SADR and EdgeOS::IPv6SADR::Reconcile before this module.

use strict;
use warnings;

my %SEVERITY = (
    effective                => 0,
    incomplete               => 1,
    protected                => 2,
    'dependency-unavailable' => 3,
    shadowed                 => 4,
    'orphaned-guard'         => 5,
    conflict                 => 6,
    failed                   => 7,
);

my %EXIT_CODE = (
    effective                => 0,
    incomplete               => 2,
    'dependency-unavailable' => 3,
    protected                => 4,
    shadowed                 => 5,
    conflict                 => 6,
    failed                   => 7,
    disabled                 => 8,
    'orphaned-guard'         => 9,
);

sub health_exit_code {
    my ($self, $state) = @_;
    return $EXIT_CODE{$state} // 7;
}

sub _health_maps {
    my ($self, $obs) = @_;
    my (%routes, %rules);
    for my $t (values %{ $obs->{tables} // {} }) {
        $routes{_route_key($_)} = $_ for @{ $t->{routes} // [] };
    }
    $rules{_rule_key($_)} = $_ for grep {
        $_->{pref} >= RULE_BASE() && $_->{pref} <= RULE_MAX()
    } @{ $obs->{rules} // [] };
    return (\%routes, \%rules);
}

sub _health_shadowed {
    my ($self, $desired, $obs, $exp) = @_;
    my (@shadow, %seen);
    for my $src (sort keys %{ $exp->{sources} // {} }) {
        my $base = $exp->{sources}{$src}{base};
        my $s = eval { $self->parse_prefix($src) };
        next unless $s;
        for my $r (@{ $obs->{rules} // [] }) {
            next if $r->{pref} >= $base;
            next if $r->{pref} >= RULE_BASE() && $r->{pref} <= RULE_MAX();
            # The kernel's pref-0 local-table rule does not shadow forwarded
            # traffic; other pre-policy rules can divert or block a source.
            next if $r->{pref} == 0 && ($r->{table} // '') eq 'local';
            next unless ($r->{action} // '') =~ /^(?:lookup|blackhole|unreachable|prohibit)$/;
            my $matches = 0;
            if (($r->{from} // '') eq 'all') {
                $matches = 1;
            } else {
                my $f = eval { $self->rule_from_prefix($r->{from}) };
                $matches = 1 if $f && $self->prefix_overlaps($f, $s);
            }
            next unless $matches;
            my $raw = $r->{raw} // '';
            next if $seen{$raw}++;
            my $target = defined $r->{table} ? " lookup $r->{table}" : " $r->{action}";
            push @shadow, {
                source => $src,
                pref   => 0 + $r->{pref},
                from   => $r->{from},
                action => $r->{action},
                raw    => $raw,
                detail => "rule $r->{pref} from $r->{from}$target precedes the policy lookup for $src",
            };
        }
    }
    return \@shadow;
}

sub _health_orphan_guards {
    my ($self, $desired, $obs) = @_;
    my %wanted;
    for my $p (@{ $desired->{policies} // [] }) {
        $wanted{$_} = 1 for @{ $p->{source_prefixes} // [] };
    }
    my $intent = eval { $self->read_boot_intent() } || { guards => [] };
    my %rules = map { _rule_key($_) => $_ } @{ $obs->{rules} // [] };
    my @orphans;
    for my $g (@{ $intent->{guards} // [] }) {
        next if $wanted{ $g->{from} // '' };
        my $copy = { pref => $g->{pref}, from => $g->{from},
                     action => $g->{action} // 'unreachable' };
        my $key = _rule_key($copy);
        next unless $rules{$key};
        push @orphans, { %$copy, raw => $rules{$key}{raw} };
    }
    return \@orphans;
}

sub _health_missing {
    my ($self, $exp, $obs_routes, $obs_rules) = @_;
    my (@routes, @rules);
    for my $k (sort keys %{ $exp->{routes} // {} }) {
        push @routes, $k
            unless $obs_routes->{$k} && _route_equal($obs_routes->{$k}, $exp->{routes}{$k});
    }
    for my $k (sort keys %{ $exp->{rules} // {} }) {
        push @rules, $k unless $obs_rules->{$k};
    }
    return (\@routes, \@rules);
}

sub health {
    my ($self, $desired, $obs, $owned, $exp) = @_;

    my @policies_in = @{ $desired->{policies} // [] };
    my $intent = @policies_in ? 'configured' : 'unconfigured';

    my @conflicts;
    my $ownership_err = '';
    eval { $self->check_ownership($desired, $obs, $owned, $exp); 1 } or do {
        $ownership_err = $@;
        $ownership_err =~ s/\s+$//;
        push @conflicts, $ownership_err if length $ownership_err;
    };
    push @conflicts, @{ $exp->{conflicts} // [] };
    my @deps   = @{ $exp->{deps} // [] };
    my $shadow = $self->_health_shadowed($desired, $obs, $exp);
    my $orphans = $self->_health_orphan_guards($desired, $obs);
    my ($obs_routes, $obs_rules) = $self->_health_maps($obs);
    my ($missing_routes, $missing_rules) = $self->_health_missing($exp, $obs_routes, $obs_rules);

    my @internal_expected = grep { ($_->{table} // 0) == INTERNAL_TABLE() }
        values %{ $exp->{routes} // {} };
    my $internal_blocked = 0;
    for my $r (@internal_expected) {
        my $k = _route_key($r);
        $internal_blocked = 1
            unless $obs_routes->{$k} && _route_equal($obs_routes->{$k}, $r);
    }

    my %shadow_src = map { $_->{source} => 1 } @$shadow;
    my @policies;
    for my $p (sort { $a->{name} cmp $b->{name} } @policies_in) {
        my $name  = $p->{name};
        my $table = $p->{table};
        my @src   = @{ $p->{source_prefixes} // [] };
        my (@reasons, $state);

        my $has_conflict = $ownership_err ? 1 : 0;
        for my $c (@conflicts) {
            $has_conflict = 1 if $c =~ /\Q$name\E/ || $c =~ /\btable\s+\Q$table\E\b/;
            for my $s (@src) {
                $has_conflict = 1 if $c =~ /\Q$s\E/;
            }
        }
        my $has_dep = 0;
        for my $d (@deps) {
            $has_dep = 1 if $d =~ /\Q$name\E/ || $d =~ /\btable\s+\Q$table\E\b/;
            for my $s (@src) {
                $has_dep = 1 if $d =~ /\Q$s\E/;
            }
        }
        my $has_shadow = grep { $shadow_src{$_} } @src;
        my $has_missing = 0;
        for my $k (@$missing_rules) {
            for my $s (@src) {
                $has_missing = 1 if $k =~ /\|\Q$s\E\|/;
            }
        }
        for my $k (@$missing_routes) {
            $has_missing = 1 if $k =~ /^\Q$table\E\|/;
        }

        if ($has_conflict) {
            $state = 'conflict';
            push @reasons, 'ownership or structural conflict';
        } elsif ($has_shadow) {
            $state = 'shadowed';
            push @reasons, 'a pre-policy rule can match the source';
        } elsif ($has_dep) {
            $state = 'dependency-unavailable';
            push @reasons, 'a required interface or route is unavailable';
        } elsif ($p->{disabled}) {
            $state = 'disabled';
            push @reasons, 'policy is disabled';
        } elsif ($internal_blocked) {
            $state = 'protected';
            push @reasons, 'internal destinations are blocked rather than provider-routed';
        } elsif ($has_missing) {
            $state = 'incomplete';
            push @reasons, 'expected kernel objects are missing';
        } else {
            $state = 'effective';
        }
        push @reasons, @deps if $has_dep;
        push @reasons, @conflicts if $has_conflict;

        push @policies, {
            name         => $name,
            table        => 0 + $table,
            disabled     => $p->{disabled} ? 1 : 0,
            source_prefixes => [@src],
            state        => $state,
            reasons      => \@reasons,
            reachability => 'unverified',
        };
    }

    my @candidates;
    for my $p (@policies) {
        push @candidates, $p->{state} unless $p->{state} eq 'disabled';
    }
    push @candidates, 'conflict' if @conflicts;
    push @candidates, 'orphaned-guard' if @$orphans;
    push @candidates, 'shadowed' if @$shadow;
    push @candidates, 'dependency-unavailable' if @deps;
    my @missing_noninternal = grep { $_ !~ /^10000\|/ } @$missing_routes;
    push @candidates, 'incomplete' if @missing_noninternal || @$missing_rules;

    my $state = 'effective';
    for my $c (@candidates) {
        $state = $c if ($SEVERITY{$c} // 0) > ($SEVERITY{$state} // 0);
    }
    $state = 'disabled' if @policies && !@candidates;

    my @terminal;
    for my $src (sort keys %{ $exp->{sources} // {} }) {
        my $guard = { pref => $exp->{sources}{$src}{base} + TERMINAL_SLOT(),
                      from => $src, action => 'unreachable' };
        push @terminal, {
            from    => $src,
            pref    => 0 + $guard->{pref},
            present => $obs_rules->{ _rule_key($guard) } ? 1 : 0,
        };
    }

    my $effectiveness = 'effective';
    $effectiveness = 'conflict' if @conflicts;
    $effectiveness = 'orphaned-guard' if @$orphans && $effectiveness eq 'effective';
    $effectiveness = 'shadowed' if @$shadow && $effectiveness eq 'effective';
    $effectiveness = 'dependency-unavailable' if @deps && $effectiveness eq 'effective';

    return {
        schema        => 1,
        state         => $state,
        intent        => $intent,
        realization   => (@$missing_routes || @$missing_rules) ? 'incomplete' : 'realized',
        effectiveness => $effectiveness,
        reachability  => 'unverified',
        generation    => $desired->{generation} // '',
        policies      => \@policies,
        checks        => {
            conflicts       => \@conflicts,
            dependencies    => \@deps,
            shadowed        => $shadow,
            orphaned_guards => $orphans,
            missing_routes  => $missing_routes,
            missing_rules   => $missing_rules,
            terminal_guards => \@terminal,
            internal_blocked => $internal_blocked ? 1 : 0,
        },
    };
}

sub current_health {
    my ($self, %o) = @_;
    my $mode = $o{mode} // 'active';
    my $desired = eval { $self->read_desired($mode) };
    if (!$desired) {
        my $err = $@;
        $err =~ s/\s+$//;
        return {
            schema => 1, state => 'dependency-unavailable', intent => 'unreadable',
            realization => 'unknown', effectiveness => 'unknown',
            reachability => 'unverified', generation => '', policies => [],
            error => $err,
            checks => {
                conflicts => [$err], dependencies => [], shadowed => [],
                orphaned_guards => [], missing_routes => [], missing_rules => [],
                terminal_guards => [], internal_blocked => 0,
            },
        };
    }
    my $owned = eval { $self->owned_state() }
        || { schema => 1, tables => {}, routes => [], rules => [] };
    my $obs = eval { $self->observe($desired, $owned) };
    if (!$obs) {
        my $err = $@;
        $err =~ s/\s+$//;
        return {
            schema => 1, state => 'failed', intent => 'configured',
            realization => 'unknown', effectiveness => 'unknown',
            reachability => 'unverified', generation => $desired->{generation} // '',
            policies => [], error => $err,
            checks => {
                conflicts => [$err], dependencies => [], shadowed => [],
                orphaned_guards => [], missing_routes => [], missing_rules => [],
                terminal_guards => [], internal_blocked => 0,
            },
        };
    }
    my $exp = $self->build_expected($desired, $obs);
    my $health = $self->health($desired, $obs, $owned, $exp);

    my $status = eval { _read_json("$self->{state_dir}/status.json") };
    if ($status && ($status->{state} // '') eq 'failed'
        && ($status->{generation} // '') eq ($desired->{generation} // '')) {
        $health->{last_failed} = $status->{error} // 'reconciliation failed';
        $health->{state} = 'failed';
    }
    return $health;
}

1;
