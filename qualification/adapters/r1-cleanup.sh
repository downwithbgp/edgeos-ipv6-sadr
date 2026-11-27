#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Device-local cleanup for the R1 RPDB canary.
#
# Deletes only the exact rule this experiment owns:
#   <PREF>: from <SELECTOR> unreachable
# It never deletes a foreign rule, even when the priority matches. It is
# idempotent (an absent rule is success) and verifies the deletion. An
# unreadable rule table is a failure, not an absent rule.
#
# usage: r1-cleanup.sh SELECTOR PREF [LOG] [RUNDIR]
# exit:  0 deleted or already absent; 2 lock/closed failure; 3 foreign/ambiguous
#        rule; 4 delete failed; 5 the rule table could not be read or verified;
#        7 cleanup lock timeout
set -u
SELECTOR=${1:?selector required}
PREF=${2:?priority required}
LOG=${3:-/tmp/sadr-r1-cleanup.log}
RUNDIR=${4:-}
IP=${SADR_IP_BIN:-ip} # test seam: a fake ip can be substituted off-device

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"; }

# Close the device-local window under the same lock the installer uses, so no
# mutation can be added after cleanup has run.
if [ -n "$RUNDIR" ]; then
    exec 9>"$RUNDIR/lock" || { log "cleanup: cannot open lock"; exit 2; }
    flock -w 10 9 || { log "cleanup: lock timeout"; exit 7; }
    : >"$RUNDIR/closed" || { log "cleanup: cannot close the window"; exit 2; }
fi

# Capture the rule table; an unreadable table is exit 5, never "absent".
read_rules() {
    "$IP" -6 rule show 2>>"$LOG"
}

count_at() {
    printf '%s\n' "$1" |
        awk -F'\t' -v p="${PREF}:" '$1 == p {n++} END {print n+0}'
}

rules=$(read_rules) || { log "ip -6 rule show failed; refusing to assume the rule is absent"; exit 5; }
count=$(count_at "$rules")
if [ "$count" -eq 0 ]; then
    log "pref=$PREF absent; nothing to delete"
    exit 0
fi
if [ "$count" -ne 1 ]; then
    log "pref=$PREF has $count rules; refusing to guess which one to delete"
    exit 3
fi
body=$(printf '%s\n' "$rules" |
    awk -F'\t' -v p="${PREF}:" '$1 == p {print $2}' |
    sed 's/[[:space:]]*$//')
if [ "$body" != "from $SELECTOR unreachable" ]; then
    log "FOREIGN rule at pref=$PREF (body='$body'); refusing to delete"
    exit 3
fi

if ! "$IP" -6 rule del from "$SELECTOR" unreachable pref "$PREF" 2>>"$LOG"; then
    # A concurrent cleanup may have deleted it between the check and the delete.
    rules=$(read_rules) || { log "rule read failed after a failed delete"; exit 5; }
    if [ "$(count_at "$rules")" -eq 0 ]; then
        log "pref=$PREF already deleted by a concurrent cleanup"
        exit 0
    fi
    log "delete failed for pref=$PREF selector=$SELECTOR"
    exit 4
fi
rules=$(read_rules) || { log "verification read failed for pref=$PREF"; exit 5; }
if [ "$(count_at "$rules")" -ne 0 ]; then
    log "delete verification failed: pref=$PREF still present"
    exit 5
fi
log "deleted exact rule pref=$PREF selector=$SELECTOR"
exit 0
