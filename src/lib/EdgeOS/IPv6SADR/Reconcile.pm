package EdgeOS::IPv6SADR;
# SPDX-License-Identifier: GPL-2.0-only
#
# Planning, ownership verification, mutation and reconciliation. Reopens the
# base package; load EdgeOS::IPv6SADR first.

use strict;
use warnings;
use POSIX qw(strftime);
use Fcntl qw(:flock);

# ---------------------------------------------------------------- ownership
sub _canon_prefix {
    my ($str) = @_;
    return $str unless defined $str && length $str;
    return $str if $str eq 'default';
    my $p = eval { EdgeOS::IPv6SADR->parse_prefix($str) };
    return $p ? $p->{str} : $str;
}

sub _canon_from {
    my ($from) = @_;
    return 'all' if defined $from && $from eq 'all';
    return $from unless defined $from && length $from;
    my $p = eval { EdgeOS::IPv6SADR->rule_from_prefix($from) };
    return $p ? $p->{str} : $from;
}

sub _norm_table {
    my ($table) = @_;
    return '' unless defined $table;
    return 0 + $table if $table =~ /^\d+$/;
    return $table;
}

sub _route_key {
    my ($r) = @_;
    return join('|', _norm_table($r->{table}), _canon_prefix($r->{prefix}), $r->{type} // '');
}

sub _rule_key {
    my ($r) = @_;
    my $tail = ($r->{action} // '') eq 'lookup' ? _norm_table($r->{table}) : '';
    return join('|', 0 + ($r->{pref} // 0), _canon_from($r->{from}), $r->{action} // '', $tail);
}

sub _route_equal {
    my ($a, $b) = @_;
    return 0 unless ($a->{type} // '') eq ($b->{type} // '');
    return 0 unless ($a->{prefix} // '') eq ($b->{prefix} // '');
    return 0 unless ($a->{via} // '') eq ($b->{via} // '');
    return 0 unless ($a->{dev} // '') eq ($b->{dev} // '');
    return 0 unless ($a->{metric} // 0) == ($b->{metric} // 0);
    return 1;
}

sub _add_route {
    my ($exp, $r) = @_;
    $r->{proto} = PROTO_MARKER();
    $exp->{routes}{_route_key($r)} = $r;
}

sub _is_policy_interface {
    my ($self, $desired, $if, $links) = @_;
    return 0 unless defined $if;
    $links //= { by_name => {} };
    for my $p (@{ $desired->{policies} }) {
        next unless defined $p->{interface};
        return 1 if $self->links_related($links, $if, $p->{interface});
    }
    return 0;
}

sub _is_link_scope_prefix {
    my ($self, $prefix) = @_;
    my $p = eval { $self->parse_prefix($prefix) };
    return 1 unless $p;
    my $first = ord(substr($p->{packed}, 0, 1));
    return 1 if $first == 0xff;                                    # multicast
    return 1 if $first == 0xfe && ((ord(substr($p->{packed}, 1, 1)) & 0xc0) == 0x80); # link-local
    return 0;
}

sub _internal_covers_addr {
    my ($self, $prefixes, $addr) = @_;
    my $a = eval { $self->parse_addr($addr) };
    return 0 unless $a;
    for my $pstr (@$prefixes) {
        my $p = eval { $self->parse_prefix($pstr) };
        next unless $p;
        return 1 if $self->prefix_contains_addr($p, $a);
    }
    return 0;
}

sub _choose_pair {
    my ($self, $obs, $policy, $src, $base) = @_;
    my @r = grep { ($_->{from} // '') eq $src } @{ $obs->{rules} };
    my %at;
    $at{$_->{pref}} = $_ for @r;
    my $a_int  = $at{$base}     && ($at{$base}{action} // '') eq 'lookup'     && $at{$base}{table} == INTERNAL_TABLE();
    my $a_prov = $at{$base + 1} && ($at{$base + 1}{action} // '') eq 'lookup' && $at{$base + 1}{table} == $policy->{table};
    my $b_int  = $at{$base + 2} && ($at{$base + 2}{action} // '') eq 'lookup' && $at{$base + 2}{table} == INTERNAL_TABLE();
    my $b_prov = $at{$base + 3} && ($at{$base + 3}{action} // '') eq 'lookup' && $at{$base + 3}{table} == $policy->{table};
    return 0 if $a_int && $a_prov;
    return 2 if $b_int && $b_prov;
    my $a_used = grep { $_->{pref} == $base || $_->{pref} == $base + 1 } @r;
    my $b_used = grep { $_->{pref} == $base + 2 || $_->{pref} == $base + 3 } @r;
    return 0 if !$a_used && !$b_used;
    return 0 if !$a_used;
    return 2 if !$b_used;
    return -1;
}

sub build_expected {
    my ($self, $desired, $obs) = @_;
    my $exp = { routes => {}, rules => {}, conflicts => [], deps => [], internal => [], sources => {} };
    my @policies = @{ $desired->{policies} };
    return $exp unless @policies;

    my %internal;
    my @internal_prefixes;
    for my $if (@{ $desired->{internal_interfaces} }) {
        my $link = $obs->{links}{$if};
        push @{ $exp->{deps} }, "internal interface $if is absent or down"
            unless $link && $link->{exists} && $link->{up};
        if ($self->_is_policy_interface($desired, $if, $obs->{links})) {
            push @{ $exp->{conflicts} },
                "internal interface $if is related to a policy interface";
            next;
        }
        my @conn = $self->_connected_for_if($obs, $if);
        push @{ $exp->{deps} }, "internal interface $if has no connected IPv6 prefix" unless @conn;
        for my $cr (@conn) {
            next if $self->_is_link_scope_prefix($cr->{prefix});
            my $p = eval { $self->parse_prefix($cr->{prefix}) };
            next unless $p;
            next if $internal{$p->{str}}++;
            push @internal_prefixes, $p->{str};
            _add_route($exp, { table => INTERNAL_TABLE(), prefix => $p->{str}, type => 'unicast',
                               dev => $if, metric => DEFAULT_METRIC() });
            _add_route($exp, { table => INTERNAL_TABLE(), prefix => $p->{str}, type => 'unreachable',
                               metric => GUARD_METRIC() });
        }
    }
    for my $pstr (@{ $desired->{destination_exceptions} }) {
        next if $internal{$pstr}++;
        push @internal_prefixes, $pstr;
        _add_route($exp, { table => INTERNAL_TABLE(), prefix => $pstr, type => 'unreachable',
                           metric => GUARD_METRIC() });
        my $ex = $obs->{exact}{$pstr};
        if (!$ex) {
            push @{ $exp->{deps} }, "internal exception $pstr has no exact main-table route";
            next;
        }
        if ($ex->{ambiguous}) {
            push @{ $exp->{conflicts} }, "internal exception $pstr has ambiguous/ECMP exact routes";
            next;
        }
        if (defined $ex->{dev} && $self->_is_policy_interface($desired, $ex->{dev}, $obs->{links})) {
            push @{ $exp->{conflicts} }, "internal exception $pstr is on policy interface $ex->{dev}";
            next;
        }
        if (defined $ex->{via} && !$self->_internal_covers_addr(\@internal_prefixes, $ex->{via})) {
            push @{ $exp->{conflicts} }, "internal exception $pstr gateway $ex->{via} is not covered by an internal route";
            next;
        }
        if (!defined $ex->{dev} && !defined $ex->{via}) {
            push @{ $exp->{conflicts} }, "internal exception $pstr has no usable exact route";
            next;
        }
        my $r = { table => INTERNAL_TABLE(), prefix => $pstr, type => 'unicast', metric => DEFAULT_METRIC() };
        $r->{via} = $ex->{via} if defined $ex->{via};
        $r->{dev} = $ex->{dev} if defined $ex->{dev};
        _add_route($exp, $r);
    }

    for my $policy (@policies) {
        my $table = $policy->{table};
        _add_route($exp, { table => $table, prefix => 'default', type => 'unreachable', metric => GUARD_METRIC() });
        for my $ip (@internal_prefixes) {
            _add_route($exp, { table => $table, prefix => $ip, type => 'unreachable', metric => GUARD_METRIC() });
        }
        if (!$policy->{disabled}) {
            if (defined $policy->{next_hop}) {
                _add_route($exp, { table => $table, prefix => 'default', type => 'unicast',
                                   via => $policy->{next_hop}, dev => $policy->{interface},
                                   metric => DEFAULT_METRIC() });
                if (!$self->is_link_local($policy->{next_hop})) {
                    my @conn = $self->_connected_for_if($obs, $policy->{interface});
                    my $cov = $self->_covering_route(\@conn, $policy->{next_hop});
                    if (!$cov) {
                        push @{ $exp->{deps} }, "policy $policy->{name} next-hop $policy->{next_hop} has no covering connected route";
                    } else {
                        _add_route($exp, { table => $table, prefix => $cov->{prefix}, type => 'unicast',
                                           dev => $policy->{interface}, metric => DEFAULT_METRIC() });
                    }
                }
            } elsif (defined $policy->{interface}) {
                _add_route($exp, { table => $table, prefix => 'default', type => 'unicast',
                                   dev => $policy->{interface}, metric => DEFAULT_METRIC() });
            }
        }
        for my $src (@{ $policy->{source_prefixes} }) {
            my $prefix = $self->parse_prefix($src);
            my $base = RULE_BASE() + (128 - $prefix->{len}) * 8;
            my $slot = $self->_choose_pair($obs, $policy, $src, $base);
            if ($slot < 0) {
                push @{ $exp->{conflicts} }, "policy $policy->{name} source $src has two non-matching rule pairs";
                $slot = 0;
            }
            $exp->{sources}{$src} = { policy => $policy->{name}, table => $table, base => $base, slot => $slot };
            my $guard = { pref => $base + TERMINAL_SLOT(), from => $src, action => 'unreachable' };
            my $i = { pref => $base + $slot, from => $src, action => 'lookup', table => INTERNAL_TABLE() };
            my $p = { pref => $base + $slot + 1, from => $src, action => 'lookup', table => $table };
            $exp->{rules}{_rule_key($guard)} = $guard;
            $exp->{rules}{_rule_key($i)} = $i;
            $exp->{rules}{_rule_key($p)} = $p;
        }
    }
    $exp->{internal} = \@internal_prefixes;
    return $exp;
}

sub _manifest_from_expected {
    my ($exp, $generation) = @_;
    my %tables;
    for my $r (values %{ $exp->{routes} }) {
        push @{ $tables{$r->{table}} }, $r->{prefix};
    }
    for my $t (keys %tables) {
        my %u; $u{$_} = 1 for @{ $tables{$t} };
        $tables{$t} = [sort keys %u];
    }
    return {
        schema => 1,
        generation => $generation // '',
        tables => \%tables,
        routes => [sort keys %{ $exp->{routes} }],
        rules => [sort keys %{ $exp->{rules} }],
    };
}

sub read_manifest {
    my ($self) = @_;
    return _read_json("$self->{state_dir}/manifest.json")
        // { schema => 1, tables => {}, routes => [], rules => [], generation => '' };
}

sub read_journal {
    my ($self) = @_;
    return _read_json("$self->{state_dir}/journal.json");
}

sub owned_state {
    my ($self) = @_;
    my $m = $self->read_manifest();
    my $j = $self->read_journal();
    if ($j && ref($j->{manifest}) eq 'HASH') {
        my $jm = $j->{manifest};
        for my $t (keys %{ $jm->{tables} // {} }) {
            my %u;
            $u{$_} = 1 for @{ $m->{tables}{$t} // [] }, @{ $jm->{tables}{$t} // [] };
            $m->{tables}{$t} = [sort keys %u];
        }
        my %r; $r{$_} = 1 for @{ $m->{routes} // [] }, @{ $jm->{routes} // [] };
        $m->{routes} = [sort keys %r];
        my %u; $u{$_} = 1 for @{ $m->{rules} // [] }, @{ $jm->{rules} // [] };
        $m->{rules} = [sort keys %u];
    }
    # Boot-guard intent records exact tuples installed before vyatta-router.
    # It extends ownership for orphan cleanup; it never authorizes deletion by
    # itself (the tuple must still match an observed rule).
    my $intent = eval { $self->read_boot_intent() } || { guards => [] };
    my %u = map { $_ => 1 } @{ $m->{rules} // [] };
    for my $g (@{ $intent->{guards} // [] }) {
        next unless defined $g->{pref} && defined $g->{from};
        my $copy = { pref => $g->{pref}, from => $g->{from},
                     action => $g->{action} // 'unreachable' };
        $u{_rule_key($copy)} = 1;
    }
    $m->{rules} = [sort keys %u];
    return $m;
}

sub check_ownership {
    my ($self, $desired, $obs, $owned, $exp) = @_;
    my @conflicts;
    my %tables = (INTERNAL_TABLE() => 1);
    $tables{$_->{table}} = 1 for @{ $desired->{policies} };
    $tables{$_} = 1 for keys %{ $owned->{tables} // {} };
    my %exp_routes = %{ $exp->{routes} };
    my %exp_rules  = %{ $exp->{rules} };
    my %owned_routes = map { $_ => 1 } @{ $owned->{routes} // [] };
    my %owned_rules  = map { $_ => 1 } @{ $owned->{rules} // [] };
    for my $table (sort { $a <=> $b } keys %tables) {
        my $t = $obs->{tables}{$table} or next;
        for my $r (@{ $t->{routes} }) {
            my $desc = $r->{raw} // _route_key($r);
            if (!defined $r->{proto} || $r->{proto} != PROTO_MARKER()) {
                push @conflicts, "table $table has a foreign route: $desc";
                next;
            }
            my $k = _route_key($r);
            push @conflicts, "table $table has an unexpected route: $desc"
                unless $exp_routes{$k} || $owned_routes{$k};
        }
    }
    for my $r (@{ $obs->{rules} }) {
        next unless $r->{pref} >= RULE_BASE() && $r->{pref} <= RULE_MAX();
        my $k = _rule_key($r);
        push @conflicts, "managed rule range has an unexpected rule: "
            . ($r->{raw} // _rule_key($r))
            unless $exp_rules{$k} || $owned_rules{$k};
    }
    die "ownership conflict:\n" . join("\n", map { "  $_" } @conflicts) . "\n" if @conflicts;
}

sub plan {
    my ($self, $desired, $obs, $owned, $exp) = @_;
    $self->check_ownership($desired, $obs, $owned, $exp);
    my %exp_routes = %{ $exp->{routes} };
    my %exp_rules  = %{ $exp->{rules} };
    my %obs_routes;
    my %obs_rules;
    my %tables = (INTERNAL_TABLE() => 1);
    $tables{$_->{table}} = 1 for @{ $desired->{policies} };
    $tables{$_} = 1 for keys %{ $owned->{tables} // {} };
    for my $table (keys %tables) {
        my $t = $obs->{tables}{$table} or next;
        $obs_routes{_route_key($_)} = $_ for @{ $t->{routes} };
    }
    $obs_rules{_rule_key($_)} = $_ for grep { $_->{pref} >= RULE_BASE() && $_->{pref} <= RULE_MAX() } @{ $obs->{rules} };

    my @ops;
    for my $k (keys %exp_rules) {
        my $r = $exp_rules{$k};
        next if $obs_rules{$k};
        my $phase = ($r->{pref} % 8 == TERMINAL_SLOT()) ? 1 : 4;
        push @ops, { op => 'rule_add', phase => $phase, rule => $r };
    }
    for my $k (keys %exp_routes) {
        my $r = $exp_routes{$k};
        next if $obs_routes{$k} && _route_equal($obs_routes{$k}, $r);
        push @ops, { op => 'route_replace', phase => 2, route => $r };
    }
    for my $k (keys %obs_routes) {
        next if $exp_routes{$k};
        my $r = $obs_routes{$k};
        my $phase = ($r->{type} eq 'unicast' && $r->{prefix} eq 'default') ? 3 : 7;
        push @ops, { op => 'route_del', phase => $phase, route => $r };
    }
    for my $k (keys %obs_rules) {
        next if $exp_rules{$k};
        my $r = $obs_rules{$k};
        my $phase = ($r->{pref} % 8 == TERMINAL_SLOT()) ? 6 : 5;
        push @ops, { op => 'rule_del', phase => $phase, rule => $r };
    }
    @ops = sort {
        $a->{phase} <=> $b->{phase}
        || ((($a->{route} && $a->{route}{type} eq 'unreachable') ? 1 : 0)
            <=> (($b->{route} && $b->{route}{type} eq 'unreachable') ? 1 : 0))
        || (($a->{route} && $a->{route}{table} || $a->{rule} && $a->{rule}{pref} || 0)
            <=> ($b->{route} && $b->{route}{table} || $b->{rule} && $b->{rule}{pref} || 0))
        || (($a->{route} ? _route_key($a->{route}) : _rule_key($a->{rule}))
            cmp ($b->{route} ? _route_key($b->{route}) : _rule_key($b->{rule})))
        || ($a->{op} cmp $b->{op})
    } @ops;
    return \@ops;
}

# ---------------------------------------------------------------- mutation
sub _route_args {
    my ($self, $route, $verb) = @_;
    my @a = ('-6', 'route', $verb);
    push @a, $route->{type} if $route->{type} eq 'unreachable' || $route->{type} eq 'blackhole';
    push @a, $route->{prefix};
    push @a, 'via', $route->{via} if defined $route->{via};
    push @a, 'dev', $route->{dev} if defined $route->{dev};
    push @a, 'table', $route->{table}, 'metric', $route->{metric} // 0;
    push @a, 'proto', PROTO_MARKER();
    return @a;
}

sub _rule_args {
    my ($self, $rule, $verb) = @_;
    my @a = ('-6', 'rule', $verb, 'from', $rule->{from});
    if (($rule->{action} // '') eq 'lookup') {
        push @a, 'lookup', $rule->{table};
    } else {
        push @a, $rule->{action};
    }
    push @a, 'pref', $rule->{pref};
    return @a;
}

sub apply_ops {
    my ($self, $ops) = @_;
    for my $op (@$ops) {
        my ($rc, $out, $err);
        if ($op->{op} eq 'route_replace') {
            ($rc, $out, $err) = $self->_ip_run($self->_route_args($op->{route}, 'replace'));
        } elsif ($op->{op} eq 'route_del') {
            ($rc, $out, $err) = $self->_ip_run($self->_route_args($op->{route}, 'del'));
            next if $rc != 0 && $err =~ /No such process|Cannot find device/;
        } elsif ($op->{op} eq 'rule_add') {
            ($rc, $out, $err) = $self->_ip_run($self->_rule_args($op->{rule}, 'add'));
            next if $rc != 0 && $err =~ /File exists/;
        } elsif ($op->{op} eq 'rule_del') {
            ($rc, $out, $err) = $self->_ip_run($self->_rule_args($op->{rule}, 'del'));
            next if $rc != 0 && $err =~ /No such file|No such process/;
        }
        die "$op->{op} failed (rc=$rc): $err\n" if $rc != 0;
    }
}

sub _observe_managed {
    my ($self, $desired, $owned) = @_;
    my $obs = $self->observe($desired, $owned);
    my (%routes, %rules);
    for my $t (values %{ $obs->{tables} }) {
        $routes{_route_key($_)} = $_ for @{ $t->{routes} // [] };
    }
    $rules{_rule_key($_)} = $_ for grep {
        $_->{pref} >= RULE_BASE() && $_->{pref} <= RULE_MAX()
    } @{ $obs->{rules} // [] };
    return ($obs, \%routes, \%rules);
}

sub _verify_once {
    my ($self, $desired, $owned, $exp, %o) = @_;
    my ($obs, $obs_routes, $obs_rules) = $self->_observe_managed($desired, $owned);
    my @missing;
    for my $k (keys %{ $exp->{routes} }) {
        push @missing, "route $k"
            unless $obs_routes->{$k} && _route_equal($obs_routes->{$k}, $exp->{routes}{$k});
    }
    for my $k (keys %{ $exp->{rules} }) {
        push @missing, "rule $k" unless $obs_rules->{$k};
    }
    unless ($o{allow_leftovers}) {
        for my $k (keys %$obs_routes) {
            push @missing, "leftover route $k" unless $exp->{routes}{$k};
        }
        for my $k (keys %$obs_rules) {
            push @missing, "leftover rule $k" unless $exp->{rules}{$k};
        }
    }
    die "verification failed:\n" . join("\n", map { "  $_" } @missing) . "\n" if @missing;
    return 1;
}

sub verify {
    my ($self, $desired, $owned, $exp, %o) = @_;
    my @delays = $o{retries} ? (0, 0.2, 0.5) : (0);
    my $last;
    for my $delay (@delays) {
        sleep($delay) if $delay > 0;
        my $ok = eval { $self->_verify_once($desired, $owned, $exp, %o); 1 };
        return 1 if $ok;
        $last = $@;
    }
    die $last;
}

sub write_status {
    my ($self, $status) = @_;
    my $file = "$self->{state_dir}/status.json";
    _write_json_atomic($file, { schema => 1, generated => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime), %$status });
}

sub _lock {
    my ($self) = @_;
    my $lock = "$self->{state_dir}/lock";
    open my $fh, '>>', $lock or die "cannot open lock $lock: $!\n";
    flock($fh, LOCK_EX) or die "cannot lock $lock: $!\n";
    return $fh;
}

# Boot-guard intent for still-configured sources is retained; tuples for
# sources that are no longer desired are dropped only after a successful
# apply+verify has removed them from the kernel.
sub _prune_boot_intent {
    my ($self, $desired) = @_;
    my $intent = eval { $self->read_boot_intent() };
    return unless $intent && ref($intent->{guards}) eq 'ARRAY' && @{ $intent->{guards} };
    my %keep_src;
    for my $p (@{ $desired->{policies} // [] }) {
        $keep_src{$_} = 1 for @{ $p->{source_prefixes} // [] };
    }
    my @keep = grep { $keep_src{ $_->{from} // '' } } @{ $intent->{guards} };
    if (@keep) {
        $intent->{guards} = \@keep;
        $self->write_boot_intent($intent);
    } else {
        unlink $self->boot_intent_file();
    }
}

sub _health_after_apply {
    my ($self, $desired) = @_;
    # Health is a collaborator of reconcile but not of the low-level planners;
    # load it lazily so bare `perl -c` and planner-only users do not need it.
    require EdgeOS::IPv6SADR::Health;
    my $owned = $self->owned_state();
    my $obs = $self->observe($desired, $owned);
    my $exp = $self->build_expected($desired, $obs);
    return $self->health($desired, $obs, $owned, $exp);
}

sub reconcile {
    my ($self, $arg, %o) = @_;
    my $mode = ref($arg) eq 'HASH' ? undef : ($arg // 'active');
    my $lock = $self->_lock();
    my $ok = 0;
    my $last_err = '';
    my $last_gen = '';
    eval {
        for my $attempt (1 .. 3) {
            # Desired state is re-read under the lock. A stale snapshot is
            # never the authority for a mutation.
            my $desired = ref($arg) eq 'HASH'
                ? $self->validate_desired($arg)
                : $self->read_desired($mode);
            $last_gen = $desired->{generation} // '';
            my $owned = $self->owned_state();
            my $obs = $self->observe($desired, $owned);
            my $exp = $self->build_expected($desired, $obs);
            die join("\n", @{ $exp->{conflicts} }) . "\n" if @{ $exp->{conflicts} };
            my $ops = $self->plan($desired, $obs, $owned, $exp);
            if ($self->{dry_run}) {
                $self->logmsg("PLAN $_->{phase} $_->{op}") for @$ops;
                $ok = 1;
                last;
            }
            # A concurrent configuration commit must not be overwritten by
            # this plan. Re-read immediately before mutation.
            if (defined $mode) {
                my $fresh = $self->read_desired($mode);
                if ($fresh->{generation} ne $desired->{generation}) {
                    $self->logmsg("desired state changed during reconciliation; retrying");
                    next;
                }
            }
            my $manifest = _manifest_from_expected($exp, $desired->{generation});
            _write_json_atomic("$self->{state_dir}/journal.json", {
                schema => 1, generation => $desired->{generation}, ops => $ops,
                manifest => $manifest, started => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
            });
            my @pre  = grep { $_->{phase} <= 4 } @$ops;
            my @post = grep { $_->{phase} >= 5 } @$ops;
            $self->apply_ops(\@pre);
            # The new tables, guards and staging pair must be present before the
            # previous-effective pair is removed. Extra old rules are allowed.
            $self->verify($desired, $owned, $exp, allow_leftovers => 1)
                if @pre && @post;
            $self->apply_ops(\@post);
            $self->verify($desired, $owned, $exp, retries => 1);
            _write_json_atomic("$self->{state_dir}/manifest.json", $manifest);
            unlink "$self->{state_dir}/journal.json";
            $self->_prune_boot_intent($desired);
            my $health = eval { $self->_health_after_apply($desired) };
            unless ($health) {
                my $health_err = $@;
                $health_err =~ s/\s+$//;
                $health = { state => 'failed',
                            error => "post-apply health observation failed: $health_err" };
            }
            die "post-apply health failed: " . ($health->{error} // 'unknown') . "\n"
                if ($health->{state} // '') eq 'failed';
            $self->write_status({
                state => $health->{state} // 'failed',
                generation => $desired->{generation},
                policies => scalar @{ $desired->{policies} },
                health => $health,
            });
            $ok = 1;
            last;
        }
        die "reconciliation did not converge after retries\n" unless $ok;
    };
    if ($@) {
        $last_err = $@;
        $last_err =~ s/\s+$//;
        eval { $self->write_status({ state => 'failed', generation => $last_gen, error => $last_err }); };
    }
    close $lock;
    die $last_err if length $last_err;
    return 1;
}

1;
