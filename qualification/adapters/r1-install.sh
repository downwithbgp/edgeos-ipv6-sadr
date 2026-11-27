#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Device-local, race-free installation of the single R1 guard rule.
#
# Takes the same lock as the cleanup script, refuses to mutate after cleanup
# closed the window or after the device-side deadline, and then adds exactly
# the approved tuple. No table, route or interface is touched.
#
# usage: r1-install.sh SELECTOR PREF DEADLINE_EPOCH RUNDIR
# exit:  0 added; 2/3 lock failure; 4 window closed; 5 deadline expired;
#        6 add failed
set -u
SELECTOR=${1:?selector required}
PREF=${2:?priority required}
DEADLINE=${3:?deadline epoch required}
RUNDIR=${4:?runtime directory required}
LOG="$RUNDIR/cleanup.log"
LOCK="$RUNDIR/lock"
CLOSED="$RUNDIR/closed"
IP=${SADR_IP_BIN:-ip} # test seam for off-device tests

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"; }

exec 9>"$LOCK" || { log "install: cannot open lock"; exit 2; }
flock -w 10 9 || { log "install: lock timeout"; exit 3; }
if [ -e "$CLOSED" ]; then
    log "install: cleanup already closed the window; refusing mutation"
    exit 4
fi
now=$(date -u +%s)
if [ "$now" -ge "$DEADLINE" ]; then
    log "install: device deadline expired; refusing mutation"
    exit 5
fi
if ! "$IP" -6 rule add from "$SELECTOR" unreachable pref "$PREF" 2>>"$LOG"; then
    log "install: exact rule add failed"
    exit 6
fi
log "install: added the exact rule pref=$PREF selector=$SELECTOR"
exit 0
