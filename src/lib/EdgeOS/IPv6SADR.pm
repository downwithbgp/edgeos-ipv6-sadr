package EdgeOS::IPv6SADR;
# SPDX-License-Identifier: GPL-2.0-only
#
# Production IPv6 source-address-dependent routing reconciler.
# Perl 5.24 core modules only; route/rule state is read from the target's text
# output. Link attributes use the target-reliable `ip -j -d link` form.

use strict;
use warnings;

use JSON::PP;
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:flock);
use Socket qw(AF_INET6 inet_pton inet_ntop);
use IPC::Open3;
use Symbol qw(gensym);
use POSIX qw(strftime);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use IO::Select;
use Time::HiRes qw(time sleep);

our $VERSION = '0.1.0';

use constant {
    INTERNAL_TABLE   => 10000,
    TABLE_MIN        => 10001,
    TABLE_MAX        => 19999,
    RULE_BASE        => 20000,
    RULE_MAX         => 21031,
    TERMINAL_SLOT    => 6,
    PROTO_MARKER     => 194,
    DEFAULT_METRIC   => 1024,
    GUARD_METRIC     => 4096,
};

sub new {
    my ($class, %o) = @_;
    my $self = bless {
        state_dir => $o{state_dir} // $ENV{IPV6_SADR_STATE_DIR} // '/run/edgeos-ipv6-sadr',
        api       => $o{api}       // $ENV{IPV6_SADR_API}       // '/opt/vyatta/sbin/my_cli_shell_api',
        ip        => $o{ip}        // $ENV{IPV6_SADR_IP}        // (-x '/sbin/ip' ? '/sbin/ip' : 'ip'),
        no_sudo   => exists $o{no_sudo} ? $o{no_sudo} : ($ENV{IPV6_SADR_NO_SUDO} ? 1 : 0),
        dry_run   => $o{dry_run}   // 0,
        log_fh    => $o{log_fh},
    }, $class;
    eval { make_path($self->{state_dir}) unless -d $self->{state_dir}; };
    return $self;
}

sub logmsg {
    my ($self, $msg) = @_;
    my $line = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime) . " $msg\n";
    if ($self->{log_fh}) {
        print { $self->{log_fh} } $line;
        return;
    }
    print STDERR $line;
}

# ---------------------------------------------------------------- prefix/IPv6
sub _host_bits_zero {
    my ($packed, $len) = @_;
    for my $i (0 .. 15) {
        my $left = $len - $i * 8;
        my $byte = ord(substr($packed, $i, 1));
        next if $left >= 8;
        return 0 if $left <= 0 && $byte != 0;
        next if $left <= 0;
        my $mask = (1 << (8 - $left)) - 1;
        return 0 if ($byte & $mask) != 0;
    }
    return 1;
}

sub parse_prefix {
    my ($class, $str) = @_;
    die "empty IPv6 prefix\n" unless defined $str && length $str;
    die "IPv6 prefix has no /length: $str\n" unless $str =~ /\//;
    my ($addr, $len, @extra) = split /\//, $str;
    die "invalid IPv6 prefix: $str\n" if @extra || $len !~ /^\d+$/ || $len > 128;
    die "zone index not allowed in prefix: $str\n" if $addr =~ /%/;
    my $packed = inet_pton(AF_INET6, $addr);
    die "invalid IPv6 prefix address: $str\n" unless defined $packed;
    die "host bits set in IPv6 prefix: $str\n" unless _host_bits_zero($packed, $len);
    my $canon = lc(inet_ntop(AF_INET6, $packed)) . "/$len";
    return { str => $canon, packed => $packed, len => 0 + $len };
}

sub parse_addr {
    my ($class, $str) = @_;
    die "empty IPv6 address\n" unless defined $str && length $str;
    die "prefix length not allowed in address: $str\n" if $str =~ m{/};
    die "zone index not allowed in address: $str\n" if $str =~ /%/;
    my $packed = inet_pton(AF_INET6, $str);
    die "invalid IPv6 address: $str\n" unless defined $packed;
    my $canon = lc(inet_ntop(AF_INET6, $packed));
    die "unspecified IPv6 address not allowed: $canon\n" if $canon eq '::';
    die "loopback IPv6 address not allowed: $canon\n" if $canon eq '::1';
    die "multicast IPv6 address not allowed: $canon\n" if $canon =~ /^ff/;
    die "IPv4-mapped IPv6 address not allowed: $canon\n" if $canon =~ /^::ffff:/;
    return { str => $canon, packed => $packed, ll => $class->is_link_local($canon) };
}

sub is_link_local {
    my ($self, $addr) = @_;
    my $packed = inet_pton(AF_INET6, $addr);
    return 0 unless defined $packed;
    return (ord(substr($packed, 0, 1)) == 0xfe
            && ((ord(substr($packed, 1, 1)) & 0xc0) == 0x80)) ? 1 : 0;
}

sub prefix_overlaps {
    my ($class, $a, $b) = @_;
    my $bits = $a->{len} < $b->{len} ? $a->{len} : $b->{len};
    for my $i (0 .. $bits - 1) {
        my $byte = int($i / 8);
        my $mask = 1 << (7 - ($i % 8));
        my $aa = ord(substr($a->{packed}, $byte, 1)) & $mask;
        my $bb = ord(substr($b->{packed}, $byte, 1)) & $mask;
        return 0 if $aa != $bb;
    }
    return 1;
}

sub prefix_contains_addr {
    my ($class, $prefix, $addr) = @_;
    my $p = $prefix->{len};
    for my $i (0 .. $p - 1) {
        my $byte = int($i / 8);
        my $mask = 1 << (7 - ($i % 8));
        my $aa = ord(substr($prefix->{packed}, $byte, 1)) & $mask;
        my $bb = ord(substr($addr->{packed}, $byte, 1)) & $mask;
        return 0 if $aa != $bb;
    }
    return 1;
}

sub _strip_quotes {
    my ($v) = @_;
    return $v unless defined $v;
    $v =~ s/^\s+|\s+$//g;
    $v =~ s/^'(.*)'$/$1/s;
    $v =~ s/^"(.*)"$/$1/s;
    return $v;
}

sub _fnv1a {
    my ($str) = @_;
    use integer;
    my $h = 2166136261;
    for my $c (unpack('C*', $str)) {
        $h ^= $c;
        $h = ($h * 16777619) & 0xffffffff;
    }
    return $h < 0 ? $h + 4294967296 : $h;
}

sub _json {
    return JSON::PP->new->canonical;
}

sub _read_json {
    my ($file) = @_;
    return undef unless -f $file;
    open my $fh, '<', $file or die "cannot read $file: $!\n";
    local $/;
    my $text = <$fh>;
    close $fh;
    return _json()->decode($text);
}

sub _write_json_atomic {
    my ($file, $data) = @_;
    my $tmp = "$file.tmp.$$";
    open my $fh, '>', $tmp or die "cannot write $tmp: $!\n";
    print {$fh} _json()->encode($data);
    close $fh or die "cannot close $tmp: $!\n";
    chmod 0640, $tmp;
    rename $tmp, $file or die "cannot rename $tmp to $file: $!\n";
}

# ---------------------------------------------------------------- config API
sub _run_capture {
    my ($self, @cmd) = @_;
    my ($in, $out, $err);
    my $errh = gensym;
    my $pid = eval { open3($in, $out, $errh, @cmd) };
    die "cannot execute @cmd: $@\n" unless $pid;
    close $in;
    local $/;
    my $stdout = <$out> // '';
    my $stderr = <$errh> // '';
    close $out;
    close $errh;
    waitpid($pid, 0);
    my $status = $?;
    my $signal = $status & 127;
    die "command @cmd terminated by signal $signal\n" if $signal;
    return ($status >> 8, $stdout, $stderr);
}

sub _api_verb {
    my ($mode, $kind) = @_;
    my %map = (
        working => { list => 'listNodes', value => 'returnValue', exists => 'exists' },
        active  => { list => 'listActiveNodes', value => 'returnActiveValue', exists => 'existsActive' },
    );
    die "invalid config mode: $mode\n" unless $map{$mode};
    return $map{$mode}{$kind};
}

sub _api_cmd {
    my ($self, $mode, $kind, @path) = @_;
    my $verb = _api_verb($mode, $kind);
    my ($rc, $out, $err) = $self->_run_capture($self->{api}, $verb, @path);
    if ($rc != 0) {
        if ($err =~ /\S/) {
            die "configuration API failure ($verb @path): $err\n";
        }
        if ($out =~ /\S/) {
            die "configuration API inconsistency ($verb @path): failed with output\n";
        }
        return (1, '');
    }
    return (0, $out);
}

sub _api_list {
    my ($self, $mode, @path) = @_;
    my ($rc, $out) = $self->_api_cmd($mode, 'list', @path);
    return () if $rc != 0;
    my @v;
    for my $word (split /\s+/, $out) {
        next unless length $word;
        push @v, _strip_quotes($word);
    }
    return @v;
}

sub _api_value {
    my ($self, $mode, @path) = @_;
    my ($rc, $out) = $self->_api_cmd($mode, 'value', @path);
    return undef if $rc != 0;
    $out =~ s/\s+$//;
    return _strip_quotes($out);
}

sub _api_exists {
    my ($self, $mode, @path) = @_;
    my ($rc) = $self->_api_cmd($mode, 'exists', @path);
    return $rc == 0 ? 1 : 0;
}

sub read_desired {
    my ($self, $mode) = @_;
    $mode //= 'active';
    # A dead/inconsistent API must never be mistaken for an empty policy
    # subtree: reconciling an empty desired state would remove every guard.
    my $root = $self->_api_exists($mode, 'protocols');
    my $subtree = $self->_api_exists($mode, 'protocols', 'ipv6-sadr');
    die "configuration API cannot prove the protocols root; refusing empty desired state\n"
        unless $root;
    die "configuration API inconsistency: ipv6-sadr exists without protocols\n"
        if $subtree && !$root;
    return $self->validate_desired({}) unless $subtree;
    my @internal = $self->_api_list($mode, 'protocols', 'ipv6-sadr', 'internal-interface');
    my @exceptions = $self->_api_list($mode, 'protocols', 'ipv6-sadr', 'destination-exception');
    my @policy_names = $self->_api_list($mode, 'protocols', 'ipv6-sadr', 'policy');
    my @policies;
    for my $name (sort @policy_names) {
        my @src = $self->_api_list($mode, 'protocols', 'ipv6-sadr', 'policy', $name, 'source-prefix');
        my $nh = $self->_api_value($mode, 'protocols', 'ipv6-sadr', 'policy', $name, 'next-hop');
        my $if = $self->_api_value($mode, 'protocols', 'ipv6-sadr', 'policy', $name, 'interface');
        my $table = $self->_api_value($mode, 'protocols', 'ipv6-sadr', 'policy', $name, 'table');
        my $desc = $self->_api_value($mode, 'protocols', 'ipv6-sadr', 'policy', $name, 'description');
        my $disabled = $self->_api_exists($mode, 'protocols', 'ipv6-sadr', 'policy', $name, 'disable');
        push @policies, {
            name => $name,
            source_prefixes => \@src,
            next_hop => $nh,
            interface => $if,
            table => $table,
            description => $desc,
            disabled => $disabled ? 1 : 0,
        };
    }
    return $self->validate_desired({
        internal_interfaces => \@internal,
        destination_exceptions => \@exceptions,
        policies => \@policies,
    });
}

sub validate_desired {
    my ($self, $raw) = @_;
    die "desired state must be an object\n" unless ref($raw) eq 'HASH';
    my @internal = @{ $raw->{internal_interfaces} // [] };
    my @exceptions = @{ $raw->{destination_exceptions} // [] };
    my @policies = @{ $raw->{policies} // [] };

    my %seen_int;
    my @internals;
    for my $if (@internal) {
        $if = _strip_quotes($if);
        die "invalid internal interface name: $if\n" unless defined $if && $if =~ /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/;
        die "duplicate internal interface: $if\n" if $seen_int{$if}++;
        push @internals, $if;
    }

    my %seen_exc;
    my @exceptions_out;
    for my $p (@exceptions) {
        my $prefix = $self->validate_internal_prefix(_strip_quotes($p));
        die "duplicate destination exception: $prefix->{str}\n" if $seen_exc{$prefix->{str}}++;
        push @exceptions_out, $prefix->{str};
    }

    my %seen_source;
    my %used_tables;
    my %seen_policy;
    my @policies_out;
    for my $p (@policies) {
        die "policy must be an object\n" unless ref($p) eq 'HASH';
        my $name = _strip_quotes($p->{name});
        die "invalid policy name: $name\n" unless defined $name && $name =~ /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;
        die "duplicate policy name: $name\n" if $seen_policy{$name}++;
        my @src_raw = @{ $p->{source_prefixes} // [] };
        die "policy $name has no source-prefix\n" unless @src_raw;
        my @src;
        my %seen_src_local;
        for my $s (@src_raw) {
            my $prefix = $self->validate_source_prefix(_strip_quotes($s));
            die "duplicate source prefix in $name: $prefix->{str}\n" if $seen_src_local{$prefix->{str}}++;
            die "source prefix $prefix->{str} appears in more than one policy\n" if $seen_source{$prefix->{str}}++;
            push @src, $prefix->{str};
        }
        @src = sort {
            my ($al) = $a =~ m{/(\d+)$};
            my ($bl) = $b =~ m{/(\d+)$};
            $bl <=> $al || $a cmp $b
        } @src;

        my $nh = $p->{next_hop};
        $nh = _strip_quotes($nh) if defined $nh && length $nh;
        my $if = $p->{interface};
        $if = _strip_quotes($if) if defined $if && length $if;
        die "policy $name requires next-hop or interface\n" unless (defined $nh && length $nh) || (defined $if && length $if);
        die "policy $name requires interface with next-hop\n" if defined $nh && length $nh && !(defined $if && length $if);
        die "invalid policy interface: $if\n" if defined $if && $if !~ /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/;
        $nh = $self->parse_addr($nh)->{str} if defined $nh && length $nh;
        if (defined $if && $seen_int{$if}) {
            die "policy $name interface $if is also an internal interface\n";
        }

        my $table = $p->{table};
        $table = _strip_quotes($table) if defined $table && length $table;
        if (defined $table && length $table) {
            die "invalid table for $name: $table\n" unless $table =~ /^\d+$/ && $table >= TABLE_MIN && $table <= TABLE_MAX;
            die "table $table is used by more than one policy\n" if $used_tables{$table}++;
        } else {
            my $h = _fnv1a($name);
            $table = TABLE_MIN + ($h % (TABLE_MAX - TABLE_MIN + 1));
            die "auto table collision for $name (set table explicitly)\n" if $used_tables{$table}++;
        }
        my $disabled = $p->{disabled} ? 1 : 0;
        push @policies_out, {
            name => $name,
            source_prefixes => \@src,
            next_hop => (defined $nh && length $nh) ? $nh : undef,
            interface => (defined $if && length $if) ? $if : undef,
            table => 0 + $table,
            description => $p->{description},
            disabled => $disabled,
        };
    }

    for my $i (@internals) {
        for my $p (@policies_out) {
            my $pi = $p->{interface};
            next unless defined $pi && length $pi;
            next unless $i eq $pi
                || $pi =~ /^\Q$i\E\.\d+$/
                || $i =~ /^\Q$pi\E\.\d+$/;
            die "internal interface $i conflicts with policy $p->{name} interface $pi\n";
        }
    }

    my $desired = {
        schema => 1,
        internal_interfaces => [sort @internals],
        destination_exceptions => [sort @exceptions_out],
        policies => [sort { $a->{name} cmp $b->{name} } @policies_out],
    };
    my $canon = _json()->encode($desired);
    $desired->{generation} = sha256_hex($canon);
    return $desired;
}

# ---------------------------------------------------------------- kernel
sub _ip_cmd {
    my ($self, @args) = @_;
    my @cmd = ($self->{ip}, @args);
    unshift @cmd, 'sudo', '-n' if !$self->{no_sudo} && $< != 0;
    return @cmd;
}

sub _ip_run {
    my ($self, @args) = @_;
    my ($rc, $out, $err) = $self->_run_capture($self->_ip_cmd(@args));
    return ($rc, $out, $err);
}

sub _ip_ok {
    my ($self, @args) = @_;
    my ($rc, $out, $err) = $self->_ip_run(@args);
    die "ip @args failed (rc=$rc): $err\n" if $rc != 0;
    return $out;
}

sub _proto_num {
    my ($rest) = @_;
    return 194 if $rest =~ /\bproto\s+194\b/;
    return 2   if $rest =~ /\bproto\s+kernel\b/;
    return 4   if $rest =~ /\bproto\s+static\b/;
    return 3   if $rest =~ /\bproto\s+boot\b/;
    return 11  if $rest =~ /\bproto\s+zebra\b/;
    return 9   if $rest =~ /\bproto\s+ra\b/;
    return 0 + $1 if $rest =~ /\bproto\s+(\d+)\b/;
    return undef;
}

sub _parse_route_line {
    my ($self, $table, $line) = @_;
    $line =~ s/^\s+|\s+$//g;
    return undef unless length $line;
    my ($prefix, $rest);
    if ($line =~ /^unreachable\s+(\S+)\s+(.*)$/) {
        ($prefix, $rest) = ($1, $2);
        my $metric = $rest =~ /\bmetric\s+(\d+)/ ? $1 : 0;
        return { table => $table, prefix => $prefix, type => 'unreachable',
                 metric => 0 + $metric, proto => _proto_num($rest), raw => $line };
    }
    if ($line =~ /^blackhole\s+(\S+)\s+(.*)$/) {
        ($prefix, $rest) = ($1, $2);
        my $metric = $rest =~ /\bmetric\s+(\d+)/ ? $1 : 0;
        return { table => $table, prefix => $prefix, type => 'blackhole',
                 metric => 0 + $metric, proto => _proto_num($rest), raw => $line };
    }
    return undef unless $line =~ /^(\S+)\s+(.*)$/;
    ($prefix, $rest) = ($1, $2);
    my $metric = $rest =~ /\bmetric\s+(\d+)/ ? $1 : 0;
    my $r = { table => $table, prefix => $prefix, type => 'unicast',
              metric => 0 + $metric, proto => _proto_num($rest), raw => $line };
    $r->{ambiguous} = 1 if $rest =~ /\bnexthop\b/;
    if ($rest =~ /\bvia\s+(\S+)\s+dev\s+(\S+)/) {
        $r->{via} = $1; $r->{dev} = $2;
    } elsif ($rest =~ /\bdev\s+(\S+)/) {
        $r->{dev} = $1;
    }
    return $r;
}

sub observe_table {
    my ($self, $table) = @_;
    my ($rc, $out, $err) = $self->_ip_run('-6', 'route', 'show', 'table', $table);
    if ($rc != 0) {
        return { table => $table, exists => 0, routes => [] } if $err =~ /FIB table does not exist/;
        die "cannot read IPv6 table $table (rc=$rc): $err\n";
    }
    my @routes;
    for my $line (split /\n/, $out) {
        my $r = $self->_parse_route_line($table, $line);
        push @routes, $r if $r;
    }
    return { table => $table, exists => 1, routes => \@routes };
}

sub observe_rules {
    my ($self) = @_;
    my $out = $self->_ip_ok('-6', 'rule', 'show');
    my @rules;
    for my $line (split /\n/, $out) {
        next unless $line =~ /^\s*(\d+):\s+from\s+(\S+)\s+(.*)$/;
        my ($pref, $from, $rest) = ($1, $2, $3);
        my $r = { pref => 0 + $pref, from => $from, raw => $line };
        if ($rest =~ /\blookup\s+(\S+)/) {
            $r->{action} = 'lookup';
            $r->{table} = $1;
        } elsif ($rest =~ /\bunreachable\b/) {
            $r->{action} = 'unreachable';
        } elsif ($rest =~ /\bblackhole\b/) {
            $r->{action} = 'blackhole';
        } elsif ($rest =~ /\bprohibit\b/) {
            $r->{action} = 'prohibit';
        } else {
            $r->{action} = 'other';
        }
        push @rules, $r;
    }
    return \@rules;
}

sub observe_exact {
    my ($self, $prefix) = @_;
    my ($rc, $out, $err) = $self->_ip_run('-6', 'route', 'show', 'exact', $prefix, 'table', 'main');
    die "cannot read exact main route $prefix: $err\n" if $rc != 0;
    my @r;
    for my $line (split /\n/, $out) {
        my $route = $self->_parse_route_line('main', $line);
        push @r, $route if $route;
    }
    return undef unless @r;
    return { ambiguous => 1, routes => \@r } if @r > 1 || grep { $_->{ambiguous} } @r;
    return $r[0];
}

# One snapshot for every interface. `ip -j -d link` is used for link attributes
# only; route/rule state stays on the stable text output.
sub observe_links {
    my ($self) = @_;
    my ($rc, $out) = $self->_ip_run('-j', '-d', 'link', 'show');
    my (%by_name, %by_index);
    if ($rc == 0) {
        my $data = eval { _json()->decode($out) };
        if (ref($data) eq 'ARRAY') {
            for my $d (@$data) {
                my $name = $d->{ifname};
                next unless defined $name && length $name;
                my @flags = ref($d->{flags}) eq 'ARRAY' ? @{ $d->{flags} } : ();
                my $up = (grep { $_ eq 'UP' } @flags) ? 1 : 0;
                $up = 1 if !$up && defined $d->{operstate} && $d->{operstate} eq 'UP';
                my $rec = { exists => 1, up => $up, operstate => $d->{operstate} // '',
                            ifindex => $d->{ifindex}, master => $d->{master} };
                $by_name{$name} = $rec;
                $by_index{$d->{ifindex}} = $rec if defined $d->{ifindex};
            }
            # iproute2 reports the bridge master either by name or by ifindex.
            for my $rec (values %by_name) {
                my $m = $rec->{master};
                next unless defined $m;
                if (!exists $by_name{$m} && $m =~ /^\d+$/ && $by_index{$m}) {
                    $rec->{master} = $by_index{$m}{ifname}
                        // (grep { $by_index{$m} == $by_name{$_} } keys %by_name)[0];
                }
            }
        }
    }
    return { by_name => \%by_name, by_index => \%by_index };
}

sub observe_link {
    my ($self, $if, $links) = @_;
    $links //= $self->observe_links();
    my $rec = $links->{by_name}{$if};
    return { exists => 0, up => 0 } unless $rec;
    return { %$rec };
}

# A policy-facing interface includes its VLAN children and bridge members (and
# the bridge itself). Unknown names are unrelated, never implicitly trusted.
sub links_related {
    my ($self, $links, $a, $b) = @_;
    return 0 unless defined $a && defined $b && length $a && length $b;
    return 1 if $a eq $b;
    return 1 if $b =~ /^\Q$a\E\.\d+$/ || $a =~ /^\Q$b\E\.\d+$/;
    my $ra = $links->{by_name}{$a};
    my $rb = $links->{by_name}{$b};
    return 0 unless $ra && $rb;
    return 1 if defined $ra->{master} && $ra->{master} eq $b;
    return 1 if defined $rb->{master} && $rb->{master} eq $a;
    return 0;
}

sub observe {
    my ($self, $desired, $manifest) = @_;
    my $obs = { rules => $self->observe_rules(), tables => {}, exact => {}, links => {}, main => undef };
    my $links = $self->observe_links();
    $obs->{links} = $links->{by_name};
    my %tables = (INTERNAL_TABLE() => 1);
    $tables{$_->{table}} = 1 for @{ $desired->{policies} };
    $tables{$_} = 1 for keys %{ ($manifest->{tables} // {}) };
    for my $table (sort { $a <=> $b } keys %tables) {
        $obs->{tables}{$table} = $self->observe_table($table);
    }
    $obs->{main} = $self->observe_table('main');
    for my $p (@{ $desired->{destination_exceptions} }) {
        $obs->{exact}{$p} = $self->observe_exact($p);
    }
    return $obs;
}

sub _connected_for_if {
    my ($self, $obs, $if) = @_;
    my @r;
    for my $route (@{ $obs->{main}{routes} }) {
        next unless $route->{type} eq 'unicast';
        next unless defined $route->{dev} && $route->{dev} eq $if;
        next unless defined $route->{proto} && $route->{proto} == 2; # kernel
        push @r, $route;
    }
    return @r;
}

sub _covering_route {
    my ($self, $routes, $addr) = @_;
    my $a = $self->parse_addr($addr);
    for my $r (@$routes) {
        my $p = eval { $self->parse_prefix($r->{prefix}) };
        next unless $p;
        return $r if $self->prefix_contains_addr($p, $a);
    }
    return undef;
}

# A rule `from` may be printed with or without an explicit /length.
sub rule_from_prefix {
    my ($self, $from) = @_;
    return undef unless defined $from && length $from && $from ne 'all';
    return $self->parse_prefix($from) if $from =~ m{/};
    my $a = $self->parse_addr($from);
    return { str => "$a->{str}/128", packed => $a->{packed}, len => 128 };
}

sub terminal_pref {
    my ($self, $prefix) = @_;
    my $p = ref($prefix) eq 'HASH' ? $prefix : $self->parse_prefix($prefix);
    return RULE_BASE() + (128 - $p->{len}) * 8 + TERMINAL_SLOT();
}

sub boot_intent_file {
    my ($self) = @_;
    return "$self->{state_dir}/boot-guards.json";
}

sub read_boot_intent {
    my ($self) = @_;
    return _read_json($self->boot_intent_file())
        // { schema => 1, guards => [] };
}

sub write_boot_intent {
    my ($self, $intent) = @_;
    _write_json_atomic($self->boot_intent_file(), {
        schema => 1,
        written => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
        %$intent,
    });
}

# Diagnostic route lookup. `ip route get` shows the path selected by the RPDB;
# `table` is only printed when it differs from main, so callers must not treat
# an absent table field as "main" without checking the expected route.
sub route_lookup {
    my ($self, $src, $dst) = @_;
    my $res = { source => $src, destination => $dst, reachable => 0, raw => '' };
    my ($rc, $out, $err) = $self->_ip_run('-6', 'route', 'get', $dst, 'from', $src);
    $res->{raw} = $out;
    if ($rc != 0) {
        $res->{error} = $err =~ /\S/ ? $err : 'route lookup failed';
        $res->{unreachable} = 1 if $err =~ /unreachable|Network is unreachable/i;
        return $res;
    }
    $res->{reachable} = 1;
    my ($line) = grep { /\S/ } split /\n/, $out;
    $line //= '';
    $res->{table} = 0 + $1 if $line =~ /\btable\s+(\d+)/;
    $res->{via} = $1 if $line =~ /\bvia\s+(\S+)/;
    $res->{dev} = $1 if $line =~ /\bdev\s+(\S+)/;
    $res->{unreachable} = 1 if $line =~ /^\s*unreachable\b/;
    return $res;
}

# Source prefixes are constrained traffic selectors; garbage that would capture
# unrelated or non-global traffic is rejected at commit time.
sub validate_source_prefix {
    my ($self, $p) = @_;
    my $prefix = ref($p) eq 'HASH' ? $p : $self->parse_prefix($p);
    my $first = ord(substr($prefix->{packed}, 0, 1));
    die "source prefix must not be multicast: $prefix->{str}\n"
        if ($first & 0xff) == 0xff;
    die "source prefix must not be link-local: $prefix->{str}\n"
        if $first == 0xfe && ((ord(substr($prefix->{packed}, 1, 1)) & 0xc0) == 0x80);
    die "source prefix must not be ::/0: $prefix->{str}\n" if $prefix->{len} == 0;
    die "source prefix must be at least /32: $prefix->{str}\n" if $prefix->{len} < 32;
    return $prefix;
}

sub validate_internal_prefix {
    my ($self, $p) = @_;
    my $prefix = ref($p) eq 'HASH' ? $p : $self->parse_prefix($p);
    die "internal prefix must not be ::/0: $prefix->{str}\n" if $prefix->{len} == 0;
    my $first = ord(substr($prefix->{packed}, 0, 1));
    die "internal prefix must not be multicast: $prefix->{str}\n" if $first == 0xff;
    return $prefix;
}

1;
