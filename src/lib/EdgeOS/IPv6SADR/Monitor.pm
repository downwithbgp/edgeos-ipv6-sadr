package EdgeOS::IPv6SADR;
# SPDX-License-Identifier: GPL-2.0-only
#
# Event monitor. Netlink events only trigger reconciliation; the authoritative
# state is the active configuration plus observed kernel state. A periodic full
# resynchronization covers lost notifications and monitor restarts.
#
# Load EdgeOS::IPv6SADR and EdgeOS::IPv6SADR::Reconcile first.

use strict;
use warnings;
use POSIX qw(:sys_wait_h);
use IO::Select;
use Errno qw(EAGAIN EINTR);
use Time::HiRes qw(time sleep);

sub _monitor_spawn {
    my ($self, $m) = @_;
    pipe(my $rh, my $wh) or die "pipe: $!\n";
    my $pid = fork;
    die "fork: $!\n" unless defined $pid;
    if ($pid == 0) {
        close $rh;
        open STDOUT, '>&', $wh or POSIX::_exit(127);
        open STDERR, '>&', $wh or POSIX::_exit(127);
        close $wh;
        exec($self->{ip}, @{ $m->{args} }) or POSIX::_exit(127);
    }
    close $wh;
    $m->{fh} = $rh;
    $m->{pid} = $pid;
    $m->{backoff} = 1;
    $m->{restart} = 0;
    return $rh;
}

sub _monitor_drain {
    my ($self, $m) = @_;
    for my $name (keys %$m) {
        my $mon = $m->{$name};
        next unless $mon->{fh};
        while (1) {
            my $n = sysread($mon->{fh}, my $buf, 65536);
            last unless defined $n && $n > 0;
            $mon->{buf} = '';
        }
    }
}

sub monitor {
    my ($self, %o) = @_;
    my $resync   = $o{resync}   // 300;
    my $debounce = $o{debounce} // 0.4;
    my $running  = 1;
    local $SIG{TERM} = sub { $running = 0; };
    local $SIG{INT}  = sub { $running = 0; };

    my %m = (
        route => { args => ['-6', 'monitor', 'route'], buf => '' },
        rule  => { args => ['-6', 'monitor', 'rule'],  buf => '' },
    );
    my $sel = IO::Select->new();
    for my $name (sort keys %m) {
        my $mon = $m{$name};
        my $fh = eval { $self->_monitor_spawn($mon) };
        if ($fh) {
            $sel->add($fh);
        } else {
            my $err = $@;
            $err =~ s/\s+$//;
            $mon->{restart} = time + 1;
            $mon->{backoff} = 1;
            $self->logmsg("monitor: cannot start $name monitor: $err");
        }
    }

    # Startup reconciliation: the first state after boot is never assumed.
    eval { $self->reconcile('active') };
    if ($@) {
        my $err = $@;
        $err =~ s/\s+$//;
        $self->logmsg("monitor: startup reconciliation failed: $err");
    }

    my $next_resync = time + $resync;
    my $suppress_until = time + 1.0;
    my $pending = 0;
    my $last_event = 0;

    while ($running) {
        my $now = time;
        my $restart_in = 1e9;
        for my $mon (values %m) {
            next if $mon->{fh};
            $restart_in = $mon->{restart} - $now if $mon->{restart} < $restart_in;
        }
        my $timeout = 0.5;
        $timeout = $next_resync - $now if $next_resync - $now < $timeout;
        $timeout = $restart_in if $restart_in < $timeout;
        $timeout = 0.05 if $timeout < 0.05;

        my @ready = $sel->can_read($timeout);
        for my $fh (@ready) {
            my ($name) = grep {
                $m{$_}{fh} && fileno($m{$_}{fh}) == fileno($fh)
            } keys %m;
            next unless $name;
            my $mon = $m{$name};
            my $n = sysread($fh, my $buf, 65536);
            if (!defined $n) {
                next if $! == EAGAIN || $! == EINTR;
                $n = 0;
            }
            if ($n == 0) {
                $sel->remove($fh);
                close $fh;
                $mon->{fh} = undef;
                my $pid = delete $mon->{pid};
                waitpid($pid, WNOHANG) if $pid;
                my $delay = $mon->{backoff};
                $mon->{backoff} = $delay * 2 > 60 ? 60 : $delay * 2;
                $mon->{restart} = time + $delay;
                $self->logmsg("monitor: $name monitor exited; restart in ${delay}s");
                next;
            }
            $mon->{buf} .= $buf;
            $mon->{buf} = substr($mon->{buf}, -8192) if length $mon->{buf} > 65536;
            if (time >= $suppress_until) {
                $pending = 1;
                $last_event = time;
            }
        }

        for my $name (sort keys %m) {
            my $mon = $m{$name};
            next if $mon->{fh} || $mon->{restart} > time;
            my $fh = eval { $self->_monitor_spawn($mon) };
            if ($fh) {
                $sel->add($fh);
                $self->logmsg("monitor: $name monitor restarted");
            } else {
                my $err = $@;
                $err =~ s/\s+$//;
                my $delay = $mon->{backoff};
                $mon->{backoff} = $delay * 2 > 60 ? 60 : $delay * 2;
                $mon->{restart} = time + $delay;
                $self->logmsg("monitor: $name monitor restart failed: $err");
            }
        }

        if ($pending && time - $last_event >= $debounce) {
            $pending = 0;
            $self->_monitor_drain(\%m);
            eval { $self->reconcile('active') };
            if ($@) {
                my $err = $@;
                $err =~ s/\s+$//;
                $self->logmsg("monitor: reconciliation failed: $err");
            }
            $suppress_until = time + 1.0;
            $last_event = time;
            $self->_monitor_drain(\%m);
        }

        if (time >= $next_resync) {
            eval { $self->reconcile('active') };
            if ($@) {
                my $err = $@;
                $err =~ s/\s+$//;
                $self->logmsg("monitor: periodic reconciliation failed: $err");
            }
            $next_resync = time + $resync;
            $suppress_until = time + 1.0;
            $pending = 0;
            $self->_monitor_drain(\%m);
        }
    }

    for my $mon (values %m) {
        close $mon->{fh} if $mon->{fh};
    }
    for my $mon (values %m) {
        next unless $mon->{pid};
        kill 'TERM', $mon->{pid};
    }
    for my $mon (values %m) {
        next unless $mon->{pid};
        my $pid = $mon->{pid};
        my $deadline = time + 2;
        while (time < $deadline) {
            my $r = waitpid($pid, WNOHANG);
            last if $r == $pid || $r == -1;
            sleep 0.05;
        }
        kill 'KILL', $pid;
        waitpid($pid, 0);
    }
    $self->logmsg('monitor: stopped');
    return 1;
}

1;
