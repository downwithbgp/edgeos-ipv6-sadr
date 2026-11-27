#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# R1 canary adapter: one authorized `unreachable` rule on the target IPv6 RPDB.
#
# Runs on the controller as root/CAP_NET_ADMIN for --baseline/--execute.
# --plan contacts nothing. --preflight is read-only.
#
# Stages:
#   0 controller preparation: namespaces, macvlans, synthetic addresses,
#     route selections, packet generators and captures.
#   1 read-only target preflight: identity, RPDB, containment, privilege and
#     production invariants.
#   2 A1 baseline: matching + control probes through the production router.
#
# The result is written atomically to $OUT/adapter-result.json. Stdout is not
# the authoritative result: SSH banners and incidental command output are kept
# in separate logs and can never corrupt the structured result.
# shellcheck disable=SC2317 # fail()/err_trap() terminate; shellcheck marks fallback paths unreachable
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=/dev/null
. "$ROOT/qualification/lib/identity.sh"
# shellcheck source=/dev/null
. "$ROOT/qualification/lib/controller.sh"

SELECTOR=${SADR_QUAL_SELECTOR:-fd42:901::a1}
PREF=${SADR_QUAL_PRIORITY:-21031}
PORT=${SADR_QUAL_PORT:-54321}
MATCH_N=${SADR_QUAL_MATCH_PROBES:-20}
CONTROL_N=${SADR_QUAL_CONTROL_PROBES:-10}
INTERVAL=${SADR_QUAL_INTERVAL:-0.5}
HOPLIMIT=${SADR_QUAL_HOPLIMIT:-64}
MIN_MEM_MB=${SADR_QUAL_MIN_AVAILABLE_MB:-32}
ROUTER=${SADR_QUAL_ROUTER:-}
TEST_ID=${SADR_QUAL_TEST_ID:-}
SCOPE=${SADR_QUAL_APPROVED_SCOPE:-}
NOT_AFTER=${SADR_QUAL_NOT_AFTER:-}
MAXDUR=${SADR_QUAL_MAX_DURATION:-}
FINGERPRINT=${SADR_QUAL_DEVICE_FINGERPRINT:-}
DEVICE_ID=${SADR_QUAL_DEVICE_ID:-}
ADAPTER_SHA=${SADR_QUAL_ADAPTER_SHA256:-}
CLEANUP_PATH=${SADR_QUAL_CLEANUP_PATH:-}
CLEANUP_SHA=${SADR_QUAL_CLEANUP_SHA256:-}
INSTALL_PATH=${SADR_QUAL_INSTALL_PATH:-}
INSTALL_SHA=${SADR_QUAL_INSTALL_SHA256:-}
SSH_KEY=${SADR_QUAL_SSH_KEY:-$HOME/.ssh/id_ed25519}
MODE=plan
OUT=${SADR_QUAL_OUT:-}
SSH_OPTS=(-q -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=yes -o UserKnownHostsFile="${SADR_QUAL_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}")

usage() {
    cat >&2 <<'EOF'
usage: r1-canary.sh --plan|--preflight|--baseline|--execute --out DIR
Harness environment: SADR_QUAL_ROUTER, SADR_QUAL_TEST_ID, SADR_QUAL_APPROVED_SCOPE,
SADR_QUAL_NOT_AFTER, SADR_QUAL_MAX_DURATION, SADR_QUAL_DEVICE_FINGERPRINT,
SADR_QUAL_DEVICE_ID, SADR_QUAL_ADAPTER_SHA256, SADR_QUAL_CLEANUP_PATH,
SADR_QUAL_CLEANUP_SHA256, SADR_QUAL_INSTALL_PATH, SADR_QUAL_INSTALL_SHA256.
--baseline runs Stages 0-2 only and never deploys device runtime files, arms a
device timer or changes the target RPDB.
EOF
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --plan) MODE=plan; shift ;;
        --preflight) MODE=preflight; shift ;;
        --baseline) MODE=baseline; shift ;;
        --execute) MODE=execute; shift ;;
        --out) [ $# -ge 2 ] || usage; OUT=$2; shift 2 ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done
[ -n "$OUT" ] || usage
mkdir -p "$OUT"

RESULT_FILE="$OUT/adapter-result.json"
STAGES_FILE="$OUT/stages.jsonl"
DIAG_FILE="$OUT/diagnostics.jsonl"
SSHLOG="$OUT/ssh.stderr.log"
SUBLOG="$OUT/subprocess.log"
CTRLERR="$OUT/controller.err"
: >"$STAGES_FILE"
: >"$DIAG_FILE"
: >"$SSHLOG"
: >"$SUBLOG"
: >"$CTRLERR"

utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

if [ "$MODE" = "plan" ]; then
    cat <<EOF
R1 plan (no device contact, no local change):
  selector:    $SELECTOR/128 (synthetic ULA, verified unused)
  priority:    $PREF, action unreachable, no table/route/interface change
  destination/control: derived from the controller's on-link /64 at execute time
  phases:      A1 $MATCH_N matching + $CONTROL_N control; B same with the rule;
               A2 same after exact deletion
  forwarding:  E1 C/128 + D/128 via the router; redirects/RA disabled; hop limit
               $HOPLIMIT -> $((HOPLIMIT-1)); L2 MAC + ingress-aware lookups must
               prove the router path
  baseline:    --baseline runs Stages 0-2 and cleans controller resources; no
               device runtime file, timer, RPDB rule or configuration change
  cleanup:     root-owned /run runtime dir; timer AccuracySec=1s armed before the
               rule; install and cleanup share a lock and a closed marker;
               exact deletion and verification; foreign rule refused
  limits:      max ${MAXDUR:-<unset>}s, not_after ${NOT_AFTER:-<unset>}
EOF
    exit 0
fi

STARTED_UTC=$(utc)
CURRENT_STAGE=startup
RESULT_STATUS=running
RESULT_CLASS=""
RESULT_MESSAGE=""
FAILURE_STAGE=""
FAILING_COMMAND=""
FAILING_STATUS=""
FAILING_SOURCE=""

# Controller resources, all uniquely tagged by this run.
RUN_TAG=""
NS_E1=""
NS_E2=""
MV1=""
MV2=""
IF=""
GW6=""
V6=""
PREFIX=""
D=""
C=""
PREFIX_IF=""
ROUTER_MAC=""
E1_MAC=""
E2_MAC=""
LISTEN_LOG=""
LISTENER_PID=""
E1_PCAP=""
E2_PCAP=""
ICMP_PCAP=""
RUNDIR=""
DEADLINE=0
DEADLINE_EPOCH=0
TIMER_ARMED=0
BOUNDARY=0
BOUNDARY_UTC=""
LOCAL_CLEANED=0
LOCAL_CLEANUP_STATUS=not_attempted
LOCAL_CLEANUP_DETAIL=""
DEVICE_CLEANED=0
DEVICE_CLEANUP_STATUS=not_attempted
DEVICE_CLEANUP_DETAIL=""
VERSION=""
KERNEL=""
TIMER_ACCURACY=""
RULES_BEFORE=""
PROTECTED_BEFORE=""
T41913_BEFORE=0
BGP_BEFORE=""
DEFAULTS_BEFORE=""
MEM_AVAIL_BEFORE=""
A1_MATCH=0
A1_CONTROL=0
B_MATCH=0
B_CONTROL=0
A2_MATCH=0
A2_CONTROL=0
OFFLINK=0
ICMP_COUNT=0

json_append() { # file event stage status detail [command] [exit_status] [source]
    python3 - "$@" <<'PY'
import datetime, json, sys
path, event, stage, status, detail = sys.argv[1:6]
command = sys.argv[6] if len(sys.argv) > 6 else ""
exit_status = sys.argv[7] if len(sys.argv) > 7 else ""
source = sys.argv[8] if len(sys.argv) > 8 else ""
record = {
    "event": event,
    "stage": stage,
    "status": status,
    "detail": detail,
    "utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
if command:
    record["command"] = command
if exit_status:
    record["exit_status"] = int(exit_status) if exit_status.lstrip("-").isdigit() else exit_status
if source:
    record["source"] = source
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(record, sort_keys=True) + "\n")
PY
}

stage_enter() { # stage detail
    CURRENT_STAGE=$1
    json_append "$STAGES_FILE" enter "$1" running "$2"
    say "stage $1: $2"
}

stage_done() { # stage status detail
    local event="done"
    json_append "$STAGES_FILE" "$event" "$1" "$2" "$3"
    say "stage $1: $2"
}

diag() { # detail [command] [exit_status] [source]
    json_append "$DIAG_FILE" diag "$CURRENT_STAGE" info "$1" "${2:-}" "${3:-}" "${4:-}"
}

class_for_stage() {
    case "$1" in
        privilege) echo controller_prerequisite ;;
        stage0) echo controller_preparation ;;
        stage1) echo target_preflight ;;
        stage2) echo dataplane_baseline ;;
        boundary|deploy|b|a2) echo device_mutation ;;
        cleanup|device_cleanup|controller_cleanup|exit_cleanup) echo cleanup ;;
        *) echo harness ;;
    esac
}

say() { printf '%s %s\n' "$(utc)" "$*" | tee -a "$OUT/adapter.log" >&2; }

fail() { # class message [exit_status]
    local class=$1 msg=$2 status=${3:-1}
    RESULT_STATUS=fail
    RESULT_CLASS=$class
    RESULT_MESSAGE=$msg
    FAILURE_STAGE=$CURRENT_STAGE
    FAILING_COMMAND=${4:-}
    FAILING_STATUS=$status
    FAILING_SOURCE=${BASH_LINENO[0]:-}
    say "FAIL: $msg"
    stage_done "$CURRENT_STAGE" fail "$msg"
    diag "$msg" "${4:-}" "$status" "${BASH_LINENO[0]:-}"
    exit "$status"
}

IN_ERR=0
err_trap() { # status command source-line
    local rc=$1 cmd=$2 line=$3
    [ "$IN_ERR" -eq 1 ] && return 0
    IN_ERR=1
    trap - ERR
    set +e
    RESULT_STATUS=fail
    RESULT_CLASS=$(class_for_stage "$CURRENT_STAGE")
    RESULT_MESSAGE="uncaught command failed (exit $rc): $cmd"
    FAILURE_STAGE=$CURRENT_STAGE
    FAILING_COMMAND=$cmd
    FAILING_STATUS=$rc
    FAILING_SOURCE=$line
    say "FAIL: $RESULT_MESSAGE"
    stage_done "$CURRENT_STAGE" fail "$RESULT_MESSAGE"
    diag "$RESULT_MESSAGE" "$cmd" "$rc" "$line"
    exit "$rc"
}
trap 'err_trap $? "$BASH_COMMAND" "${BASH_LINENO[0]}"' ERR

# A controller-side failure is a prerequisite/preparation failure, never a
# target-platform failure. Use the recorded stderr to distinguish EPERM.
controller_fail() { # message
    if grep -qiE 'operation not permitted|permission denied' "$CTRLERR" 2>/dev/null; then
        fail controller_prerequisite "$1 (controller privilege)"
    else
        fail controller_preparation "$1"
    fi
}

rssh() { ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" "$ROUTER" "$@" 2>>"$SSHLOG"; }
rssh_err() { ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" "$ROUTER" "$@" 2>&1; }
rsudo() { rssh "sudo -n $*"; }
rsudo_err() { rssh_err "sudo -n $*"; }

rule_at() {
    local out
    out=$(rssh "ip -6 rule show") || return 1
    printf '%s\n' "$out" | awk -F'\t' -v p="${PREF}:" '$1 == p {print $2}'
}
rule_count() {
    local out
    out=$(rssh "ip -6 rule show") || return 1
    printf '%s\n' "$out" | awk -F'\t' -v p="${PREF}:" '$1 == p {n++} END {print n+0}'
}
table41913_count() {
    local out
    out=$(rssh "ip -6 route show table 41913") || return 1
    printf '%s\n' "$out" | grep -c . || true
}
bgp_counts() {
    local out neighbors established
    out=$(rssh "vtysh -c 'show ip bgp summary' 2>/dev/null") || return 1
    neighbors=$(printf '%s\n' "$out" | awk '/^Total number of neighbors / {print $NF; exit}')
    established=$(printf '%s\n' "$out" | awk '/^Total number of Established sessions / {print $NF; exit}')
    if [ -z "$neighbors" ] || [ -z "$established" ]; then
        return 1
    fi
    printf '%s %s\n' "$neighbors" "$established"
}
defaults_now() {
    rssh "ip -4 route show default; ip -6 route show default" |
        sed -E 's/ expires [0-9]+sec//g; s/[[:space:]]+/ /g; s/^ //; s/ $//'
}

cleanup_local() {
    [ "$LOCAL_CLEANED" -eq 1 ] && return 0
    local had_e=0 rc=0 ns pid
    case $- in *e*) had_e=1 ;; esac
    set +e
    for pid in "$LISTENER_PID" "$E1_PCAP" "$E2_PCAP" "$ICMP_PCAP"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
    done
    wait 2>/dev/null
    for ns in "$NS_E1" "$NS_E2"; do
        [ -n "$ns" ] || continue
        ip netns del "$ns" 2>"$CTRLERR"
        if ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$ns"; then
            rc=1
        fi
    done
    for pid in "$LISTENER_PID" "$E1_PCAP" "$E2_PCAP" "$ICMP_PCAP"; do
        [ -n "$pid" ] || continue
        if kill -0 "$pid" 2>/dev/null; then
            rc=1
        fi
    done
    if [ -z "$NS_E1" ] && [ -z "$NS_E2" ]; then
        LOCAL_CLEANUP_STATUS=pass
        LOCAL_CLEANUP_DETAIL="no controller resources were created"
    elif [ "$rc" -eq 0 ]; then
        LOCAL_CLEANUP_STATUS=pass
        LOCAL_CLEANUP_DETAIL="namespaces $NS_E1/$NS_E2 absent; capture/listener processes stopped"
    else
        LOCAL_CLEANUP_STATUS=fail
        LOCAL_CLEANUP_DETAIL="residual controller namespace or process"
    fi
    [ "$rc" -eq 0 ] && LOCAL_CLEANED=1
    [ "$had_e" -eq 1 ] && set -e
    return "$rc"
}

cleanup_device() {
    [ "$DEVICE_CLEANED" -eq 1 ] && return 0
    local had_e=0 rc=0 count timer_active timer_out timer_rc test_rc cleanup_rc=0
    case $- in *e*) had_e=1 ;; esac
    set +e
    if [ -z "$RUNDIR" ]; then
        DEVICE_CLEANUP_STATUS=not_needed
        DEVICE_CLEANUP_DETAIL="no device runtime directory was deployed"
        DEVICE_CLEANED=1
        [ "$had_e" -eq 1 ] && set -e
        return 0
    fi
    say "cleanup: exact rule deletion and verification"
    rsudo "sh '$RUNDIR/r1-cleanup.sh' '$SELECTOR' '$PREF' '$RUNDIR/cleanup.log' '$RUNDIR'" >/dev/null 2>&1 || cleanup_rc=$?
    if ! count=$(rule_count); then
        DEVICE_CLEANUP_STATUS=fail
        DEVICE_CLEANUP_DETAIL="rule read failed; device timer left armed"
        rc=1
    elif [ "$count" -ne 0 ]; then
        DEVICE_CLEANUP_STATUS=fail
        DEVICE_CLEANUP_DETAIL="cleanup_rc=$cleanup_rc; priority $PREF still present; device timer left armed"
        rc=1
    else
        rsudo "systemctl stop sadr-r1-cleanup.timer" >/dev/null 2>&1
        rsudo "systemctl reset-failed sadr-r1-cleanup.service" >/dev/null 2>&1
        rsudo "cat '$RUNDIR/cleanup.log'" >"$OUT/device-cleanup.log" 2>/dev/null
        rsudo "rm -f '$RUNDIR/r1-install.sh' '$RUNDIR/r1-cleanup.sh' '$RUNDIR/cleanup.log' '$RUNDIR/lock' '$RUNDIR/closed'; rmdir '$RUNDIR'" >/dev/null 2>&1
        timer_out=$(rssh "systemctl show sadr-r1-cleanup.timer -p ActiveState --value" 2>/dev/null)
        timer_rc=$?
        if [ "$timer_rc" -ne 0 ]; then
            DEVICE_CLEANUP_STATUS=fail
            DEVICE_CLEANUP_DETAIL="cannot verify the cleanup timer state"
            rc=1
        else
            timer_active=$timer_out
            if [ "$timer_active" = "active" ]; then
                DEVICE_CLEANUP_STATUS=fail
                DEVICE_CLEANUP_DETAIL="cleanup timer is still active"
                rc=1
            elif rsudo "test -e '$RUNDIR'"; then
                DEVICE_CLEANUP_STATUS=fail
                DEVICE_CLEANUP_DETAIL="device runtime directory $RUNDIR remains"
                rc=1
            else
                test_rc=$?
                if [ "$test_rc" -eq 255 ]; then
                    DEVICE_CLEANUP_STATUS=fail
                    DEVICE_CLEANUP_DETAIL="cannot verify that the device runtime directory was removed"
                    rc=1
                else
                    DEVICE_CLEANUP_STATUS=pass
                    DEVICE_CLEANUP_DETAIL="cleanup_rc=$cleanup_rc; rule absent; timer not active; runtime directory removed"
                    DEVICE_CLEANED=1
                fi
            fi
        fi
    fi
    [ "$had_e" -eq 1 ] && set -e
    return "$rc"
}

write_result() {
    local -a envs=()
    add_env() { envs+=("$1=$2"); }
    add_env RESULT_MODE "$MODE"
    add_env RESULT_STATUS "$RESULT_STATUS"
    add_env RESULT_STARTED_UTC "$STARTED_UTC"
    add_env RESULT_FINISHED_UTC "$(utc)"
    add_env RESULT_CLASS "$RESULT_CLASS"
    add_env RESULT_MESSAGE "$RESULT_MESSAGE"
    add_env RESULT_FAILURE_STAGE "$FAILURE_STAGE"
    add_env RESULT_CURRENT_STAGE "$CURRENT_STAGE"
    add_env RESULT_FAILING_COMMAND "$FAILING_COMMAND"
    add_env RESULT_FAILING_STATUS "${FAILING_STATUS:-1}"
    add_env RESULT_FAILING_SOURCE "$FAILING_SOURCE"
    add_env RESULT_BOUNDARY "$BOUNDARY"
    add_env RESULT_BOUNDARY_UTC "$BOUNDARY_UTC"
    add_env RESULT_LOCAL_CLEANUP_STATUS "$LOCAL_CLEANUP_STATUS"
    add_env RESULT_LOCAL_CLEANUP_DETAIL "$LOCAL_CLEANUP_DETAIL"
    add_env RESULT_DEVICE_CLEANUP_STATUS "$DEVICE_CLEANUP_STATUS"
    add_env RESULT_DEVICE_CLEANUP_DETAIL "$DEVICE_CLEANUP_DETAIL"
    add_env RESULT_NS_E1 "$NS_E1"
    add_env RESULT_NS_E2 "$NS_E2"
    add_env RESULT_MV1 "$MV1"
    add_env RESULT_MV2 "$MV2"
    add_env RESULT_RUN_TAG "$RUN_TAG"
    add_env RESULT_RUNDIR "$RUNDIR"
    add_env RESULT_LISTENER_PID "$LISTENER_PID"
    add_env RESULT_E1_PCAP_PID "$E1_PCAP"
    add_env RESULT_E2_PCAP_PID "$E2_PCAP"
    add_env RESULT_ICMP_PCAP_PID "$ICMP_PCAP"
    add_env RESULT_A1_MATCH "$A1_MATCH"
    add_env RESULT_A1_CONTROL "$A1_CONTROL"
    add_env RESULT_B_MATCH "$B_MATCH"
    add_env RESULT_B_CONTROL "$B_CONTROL"
    add_env RESULT_A2_MATCH "$A2_MATCH"
    add_env RESULT_A2_CONTROL "$A2_CONTROL"
    add_env RESULT_OFFLINK "$OFFLINK"
    add_env RESULT_ICMP6 "$ICMP_COUNT"
    add_env RESULT_WRONG_PROVIDER 0
    add_env RESULT_VERSION "$VERSION"
    add_env RESULT_KERNEL "$KERNEL"
    add_env RESULT_FINGERPRINT "$FINGERPRINT"
    add_env RESULT_SELECTOR "$SELECTOR"
    add_env RESULT_PRIORITY "$PREF"
    add_env RESULT_DESTINATION "$D"
    add_env RESULT_CONTROL "$C"
    add_env RESULT_PREFIX "$PREFIX"
    add_env RESULT_GATEWAY "$GW6"
    add_env RESULT_INTERFACE "$IF"
    add_env RESULT_PREFIX_IF "$PREFIX_IF"
    add_env RESULT_ROUTER_MAC "$ROUTER_MAC"
    add_env RESULT_E1_MAC "$E1_MAC"
    add_env RESULT_E2_MAC "$E2_MAC"
    add_env RESULT_HOPLIMIT "$HOPLIMIT"
    add_env RESULT_DEADLINE "$DEADLINE"
    add_env RESULT_TIMER_ACCURACY "$TIMER_ACCURACY"
    add_env RESULT_ADAPTER_SHA "$ADAPTER_SHA"
    add_env RESULT_OUT "$OUT"
    env "${envs[@]}" python3 - "$RESULT_FILE" "$STAGES_FILE" <<'PY'
import json
import os
import pathlib
import sys

out, stages_path = sys.argv[1:3]
events = []
try:
    with open(stages_path, encoding="utf-8") as fh:
        events = [json.loads(line) for line in fh if line.strip()]
except OSError:
    events = []

order = []
stages = {}
for event in events:
    name = event.get("stage", "")
    if not name:
        continue
    if name not in stages:
        order.append(name)
        stages[name] = {"stage": name, "status": "running", "started_utc": "",
                        "finished_utc": "", "detail": ""}
    if event.get("event") == "enter":
        stages[name]["started_utc"] = event.get("utc", "")
        stages[name]["detail"] = event.get("detail", stages[name]["detail"])
    elif event.get("event") == "done":
        stages[name]["status"] = event.get("status", "unknown")
        stages[name]["finished_utc"] = event.get("utc", "")
        stages[name]["detail"] = event.get("detail", stages[name]["detail"])


def env(name, default=""):
    return os.environ.get(name, default)


def env_int(name, default=0):
    try:
        return int(os.environ.get(name, ""))
    except ValueError:
        return default


status = env("RESULT_STATUS", "fail")
if status not in ("pass", "fail"):
    status = "fail"
result = {
    "schema": 2,
    "mode": env("RESULT_MODE", "unknown"),
    "status": status,
    "ok": status == "pass",
    "started_utc": env("RESULT_STARTED_UTC"),
    "finished_utc": env("RESULT_FINISHED_UTC"),
    "failure": None,
    "stages": [stages[name] for name in order],
    "probes": {
        "a1_matching": env_int("RESULT_A1_MATCH"),
        "a1_control": env_int("RESULT_A1_CONTROL"),
        "b_matching": env_int("RESULT_B_MATCH"),
        "b_control": env_int("RESULT_B_CONTROL"),
        "a2_matching": env_int("RESULT_A2_MATCH"),
        "a2_control": env_int("RESULT_A2_CONTROL"),
        "offlink": env_int("RESULT_OFFLINK"),
        "icmp6": env_int("RESULT_ICMP6"),
    },
    "wrong_provider": env_int("RESULT_WRONG_PROVIDER"),
    "mutation_boundary_crossed": env("RESULT_BOUNDARY") == "1",
    "mutation_boundary_utc": env("RESULT_BOUNDARY_UTC") or None,
    "resources": {
        "namespaces": [x for x in (env("RESULT_NS_E1"), env("RESULT_NS_E2")) if x],
        "macvlans": [x for x in (env("RESULT_MV1"), env("RESULT_MV2")) if x],
        "run_tag": env("RESULT_RUN_TAG"),
        "device_runtime_dir": env("RESULT_RUNDIR"),
        "pids": {
            "listener": env("RESULT_LISTENER_PID"),
            "e1_capture": env("RESULT_E1_PCAP_PID"),
            "e2_capture": env("RESULT_E2_PCAP_PID"),
            "icmp_capture": env("RESULT_ICMP_PCAP_PID"),
        },
    },
    "cleanup": {
        "local": {"status": env("RESULT_LOCAL_CLEANUP_STATUS", "not_attempted"),
                  "detail": env("RESULT_LOCAL_CLEANUP_DETAIL")},
        "device": {"status": env("RESULT_DEVICE_CLEANUP_STATUS", "not_attempted"),
                   "detail": env("RESULT_DEVICE_CLEANUP_DETAIL")},
    },
    "evidence": {
        "version": env("RESULT_VERSION"),
        "kernel": env("RESULT_KERNEL"),
        "fingerprint": env("RESULT_FINGERPRINT"),
        "selector": env("RESULT_SELECTOR"),
        "priority": env("RESULT_PRIORITY"),
        "destination": env("RESULT_DESTINATION"),
        "control_source": env("RESULT_CONTROL"),
        "prefix": env("RESULT_PREFIX"),
        "gateway": env("RESULT_GATEWAY"),
        "controller_interface": env("RESULT_INTERFACE"),
        "target_egress_interface": env("RESULT_PREFIX_IF"),
        "router_mac": env("RESULT_ROUTER_MAC"),
        "e1_mac": env("RESULT_E1_MAC"),
        "e2_mac": env("RESULT_E2_MAC"),
        "hoplimit": env_int("RESULT_HOPLIMIT"),
        "deadline_seconds": env_int("RESULT_DEADLINE"),
        "timer_accuracy": env("RESULT_TIMER_ACCURACY"),
        "adapter_sha256": env("RESULT_ADAPTER_SHA"),
        "captures": {
            "e1": os.path.join(env("RESULT_OUT"), "e1.pcap"),
            "e2": os.path.join(env("RESULT_OUT"), "e2.pcap"),
            "icmp": os.path.join(env("RESULT_OUT"), "icmp.pcap"),
        },
        "logs": {
            "adapter": os.path.join(env("RESULT_OUT"), "adapter.log"),
            "ssh_stderr": os.path.join(env("RESULT_OUT"), "ssh.stderr.log"),
            "subprocess": os.path.join(env("RESULT_OUT"), "subprocess.log"),
            "controller_errors": os.path.join(env("RESULT_OUT"), "controller.err"),
            "stages": stages_path,
        },
    },
    "notes": env("RESULT_MESSAGE"),
}
if status == "fail":
    result["failure"] = {
        "class": env("RESULT_CLASS", "harness"),
        "stage": env("RESULT_FAILURE_STAGE", env("RESULT_CURRENT_STAGE", "")),
        "message": env("RESULT_MESSAGE", ""),
        "command": env("RESULT_FAILING_COMMAND", ""),
        "exit_status": env_int("RESULT_FAILING_STATUS", 1),
        "source": env("RESULT_FAILING_SOURCE", ""),
    }
path = pathlib.Path(out)
tmp = path.with_name(path.name + ".tmp." + str(os.getpid()))
tmp.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
os.replace(tmp, path)
print(json.dumps({"status": status, "ok": result["ok"], "result": str(path)},
                 sort_keys=True))
PY
}

on_exit() {
    local rc=$?
    local failed_stage=$CURRENT_STAGE
    trap - ERR EXIT INT TERM
    set +e
    if [ "$BOUNDARY" -eq 1 ] && [ "$DEVICE_CLEANED" -eq 0 ]; then
        cleanup_device
    fi
    if [ "$TIMER_ARMED" -eq 1 ] && [ "$DEVICE_CLEANED" -eq 0 ] && [ "$BOUNDARY" -eq 0 ]; then
        rsudo "systemctl stop sadr-r1-cleanup.timer" >/dev/null 2>&1
    fi
    if [ -n "$RUNDIR" ] && [ "$DEVICE_CLEANED" -eq 0 ] && [ "$BOUNDARY" -eq 0 ]; then
        rsudo "rm -f '$RUNDIR/r1-install.sh' '$RUNDIR/r1-cleanup.sh' '$RUNDIR/cleanup.log' '$RUNDIR/lock' '$RUNDIR/closed'; rmdir '$RUNDIR'" >/dev/null 2>&1
    fi
    cleanup_local
    local cleanup_status=pass
    local cleanup_detail="device=${DEVICE_CLEANUP_STATUS}; local=${LOCAL_CLEANUP_STATUS}"
    if [ "$LOCAL_CLEANUP_STATUS" != "pass" ]; then cleanup_status=fail; fi
    if [ "$BOUNDARY" -eq 1 ] && [ "$DEVICE_CLEANUP_STATUS" != "pass" ] && [ "$DEVICE_CLEANUP_STATUS" != "not_needed" ]; then
        cleanup_status=fail
    fi
    stage_enter exit_cleanup "final cleanup audit"
    stage_done exit_cleanup "$cleanup_status" "$cleanup_detail"
    if [ "$RESULT_STATUS" = "running" ] || [ -z "$RESULT_STATUS" ]; then
        RESULT_STATUS=fail
        RESULT_CLASS=harness
        RESULT_MESSAGE="uncaught exit rc=$rc"
        FAILURE_STAGE=$failed_stage
        FAILING_STATUS=$rc
        stage_done "$failed_stage" fail "$RESULT_MESSAGE"
    fi
    if [ "$RESULT_STATUS" = "pass" ] && [ "$rc" -ne 0 ]; then
        RESULT_STATUS=fail
        RESULT_CLASS=harness
        RESULT_MESSAGE="non-zero exit rc=$rc"
        FAILURE_STAGE=$failed_stage
        FAILING_STATUS=$rc
    fi
    if [ "$RESULT_STATUS" = "pass" ] && [ "$cleanup_status" != "pass" ]; then
        RESULT_STATUS=fail
        RESULT_CLASS=cleanup
        RESULT_MESSAGE="cleanup failed: $cleanup_detail"
        FAILURE_STAGE=cleanup
        FAILING_STATUS=1
    fi
    [ "$RESULT_STATUS" = "pass" ] || [ "$rc" -ne 0 ] || rc=1
    write_result
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---- authorization and common input validation ----
if [ -z "$ROUTER" ] || [ -z "$FINGERPRINT" ]; then
    fail harness "incomplete harness identity environment"
fi
if [ "$MODE" = "execute" ]; then
    if [ -z "$TEST_ID" ] || [ -z "$NOT_AFTER" ] || [ -z "$MAXDUR" ] || [ -z "$SCOPE" ]; then
        fail harness "incomplete harness authorization environment"
    fi
else
    MAXDUR=${MAXDUR:-180}
fi
printf '%s' "$SELECTOR" | grep -Eq '^[0-9a-f:]+$' || fail harness "invalid selector: $SELECTOR"
printf '%s' "$PREF" | grep -Eq '^[0-9]+$' || fail harness "invalid priority: $PREF"
if [ "$PREF" -lt 1 ] || [ "$PREF" -gt 32767 ]; then fail harness "priority out of range: $PREF"; fi
if [ "$MAXDUR" -lt 1 ] || [ "$MAXDUR" -gt 3600 ]; then fail harness "duration out of range: $MAXDUR"; fi
printf '%s' "$FINGERPRINT" | grep -Eq '^[0-9a-f]{64}$' || fail harness "invalid device fingerprint"
if [ -n "$ADAPTER_SHA" ]; then
    [ "$(sha256sum "$0" | awk '{print $1}')" = "$ADAPTER_SHA" ] || fail harness "adapter hash mismatch"
fi
if [ "$MODE" = "execute" ]; then
    [ -n "$CLEANUP_SHA" ] || fail harness "missing cleanup hash"
    [ -n "$INSTALL_SHA" ] || fail harness "missing install hash"
    if [ -z "$CLEANUP_PATH" ] || [ ! -f "$CLEANUP_PATH" ]; then fail harness "missing cleanup script"; fi
    if [ -z "$INSTALL_PATH" ] || [ ! -f "$INSTALL_PATH" ]; then fail harness "missing install script"; fi
    [ "$(sha256sum "$CLEANUP_PATH" | awk '{print $1}')" = "$CLEANUP_SHA" ] || fail harness "cleanup hash mismatch"
    [ "$(sha256sum "$INSTALL_PATH" | awk '{print $1}')" = "$INSTALL_SHA" ] || fail harness "install hash mismatch"
    [ "$TEST_ID" = "R1-guard-only" ] || fail harness "unexpected test id: $TEST_ID"
    case "$SCOPE" in *"$SELECTOR"*"$PREF"*) ;; *) fail harness "approved scope does not name selector/priority" ;; esac
    now=$(date -u +%s)
    not_after_epoch=$(date -u -d "$NOT_AFTER" +%s 2>/dev/null) || fail harness "invalid not_after"
    remaining=$((not_after_epoch - now))
    [ "$remaining" -ge $((MAXDUR + 30)) ] || fail harness "authorization expires too soon"
    DEADLINE=$((MAXDUR - 30))
    [ "$DEADLINE" -ge 60 ] || fail harness "authorization window too small for a cleanup margin"
    if [ $((remaining - 15)) -lt "$DEADLINE" ]; then DEADLINE=$((remaining - 15)); fi
    [ "$DEADLINE" -ge 60 ] || fail harness "remaining authorization window too small"
    DEADLINE_EPOCH=$((now + DEADLINE))
else
    DEADLINE=$MAXDUR
fi

# ---- controller privilege, before any endpoint preparation ----
if [ "$MODE" != "preflight" ]; then
    stage_enter privilege "controller privilege and tool availability"
    sadr_controller_require_root || fail controller_prerequisite "root/CAP_NET_ADMIN required on the controller for netns/macvlan/capture"
    sadr_controller_require_tools ip ssh python3 tcpdump sysctl timeout sha256sum awk sed grep ||
        fail controller_prerequisite "missing controller tool"
    stage_done privilege pass "root, netns/macvlan/capture tools available"
fi

# ---- Stage 0: controller preparation ----
derive_local_path() {
    IF=$(ip -4 route show default | awk '{print $5; exit}')
    GW6=$(ip -6 route show default | awk '/^default/ {print $3; exit}')
    V6=$(ip -6 -o addr show dev "$IF" scope global | awk '$4 ~ /\/64$/ {print $4; exit}')
    if [ -z "$IF" ] || [ -z "$GW6" ] || [ -z "$V6" ]; then
        fail controller_preparation "cannot derive the controller's on-link IPv6 path"
    fi
    read -r PREFIX D C <<<"$(python3 - "$V6" <<'PY'
import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1], strict=False)
print(net.network_address, net.network_address + 0xa2, net.network_address + 0xa3)
PY
)"
    if [ -z "$D" ] || [ -z "$C" ]; then
        fail controller_preparation "cannot derive test addresses"
    fi
}

stage0_prepare() {
    stage_enter stage0 "controller preparation"
    derive_local_path
    RUN_TAG=$(sadr_controller_unique_tag)
    printf '%s' "$RUN_TAG" | grep -Eq '^[0-9a-f]{4}$' || fail controller_preparation "cannot generate a unique run tag"
    NS_E1="sadr-e1-$RUN_TAG"
    NS_E2="sadr-e2-$RUN_TAG"
    MV1="mv1-$RUN_TAG"
    MV2="mv2-$RUN_TAG"
    if sadr_controller_ns_exists "$NS_E1" || sadr_controller_ns_exists "$NS_E2"; then
        fail controller_preparation "controller namespace collision for run tag $RUN_TAG"
    fi
    if ip link show "$MV1" >/dev/null 2>&1 || ip link show "$MV2" >/dev/null 2>&1; then
        fail controller_preparation "controller link collision for run tag $RUN_TAG"
    fi
    if ! ip netns add "$NS_E1" 2>"$CTRLERR"; then
        fail controller_prerequisite "cannot create controller namespace $NS_E1 (CAP_NET_ADMIN?)"
    fi
    if ! ip netns add "$NS_E2" 2>"$CTRLERR"; then
        fail controller_prerequisite "cannot create controller namespace $NS_E2 (CAP_NET_ADMIN?)"
    fi
    if ! ip link add "$MV1" link "$IF" type macvlan mode private 2>"$CTRLERR"; then
        controller_fail "cannot create macvlan $MV1 on $IF"
    fi
    if ! ip link add "$MV2" link "$IF" type macvlan mode private 2>"$CTRLERR"; then
        controller_fail "cannot create macvlan $MV2 on $IF"
    fi
    ip link set "$MV1" netns "$NS_E1" 2>"$CTRLERR" || controller_fail "cannot move $MV1 to $NS_E1"
    ip link set "$MV2" netns "$NS_E2" 2>"$CTRLERR" || controller_fail "cannot move $MV2 to $NS_E2"
    ip netns exec "$NS_E1" ip link set lo up 2>"$CTRLERR" || controller_fail "cannot raise lo in $NS_E1"
    ip netns exec "$NS_E1" ip link set "$MV1" up 2>"$CTRLERR" || controller_fail "cannot raise $MV1"
    ip netns exec "$NS_E2" ip link set lo up 2>"$CTRLERR" || controller_fail "cannot raise lo in $NS_E2"
    ip netns exec "$NS_E2" ip link set "$MV2" up 2>"$CTRLERR" || controller_fail "cannot raise $MV2"
    if ! ip netns exec "$NS_E1" env SADR_ROOT="$ROOT" SADR_CTRL_IF="$MV1" bash -c \
        ". \"\$SADR_ROOT/qualification/lib/controller.sh\"; sadr_controller_disable_redirects \"\$SADR_CTRL_IF\"" 2>"$CTRLERR"; then
        controller_fail "cannot disable IPv6 redirects on $MV1"
    fi
    if ! ip netns exec "$NS_E2" env SADR_ROOT="$ROOT" SADR_CTRL_IF="$MV2" bash -c \
        ". \"\$SADR_ROOT/qualification/lib/controller.sh\"; sadr_controller_disable_redirects \"\$SADR_CTRL_IF\"" 2>"$CTRLERR"; then
        controller_fail "cannot disable IPv6 redirects on $MV2"
    fi
    ip netns exec "$NS_E1" ip -6 addr add "$SELECTOR/128" dev "$MV1" nodad 2>"$CTRLERR" ||
        controller_fail "cannot assign selector to $MV1"
    # C/128 is deliberate: with C/64, D would be on-link and E1 could bypass
    # the router at Layer 2. The specific D/128 route forces the router path.
    ip netns exec "$NS_E1" ip -6 addr add "$C/128" dev "$MV1" nodad 2>"$CTRLERR" ||
        controller_fail "cannot assign control source to $MV1"
    ip netns exec "$NS_E2" ip -6 addr add "$D/128" dev "$MV2" 2>"$CTRLERR" ||
        controller_fail "cannot assign destination to $MV2"
    local dad=""
    for _ in $(seq 1 20); do
        dad=$(ip netns exec "$NS_E2" ip -6 addr show dev "$MV2" 2>"$CTRLERR")
        printf '%s' "$dad" | grep -q 'tentative' || break
        sleep 0.25
    done
    if printf '%s' "$dad" | grep -q 'tentative'; then fail controller_preparation "destination DAD did not complete"; fi
    if printf '%s' "$dad" | grep -q 'dadfailed'; then fail controller_preparation "destination DAD failed (address in use)"; fi
    ip netns exec "$NS_E1" ip -6 route add "$D/128" via "$GW6" dev "$MV1" 2>"$CTRLERR" ||
        controller_fail "cannot add the router path for D in $NS_E1"
    ip netns exec "$NS_E1" ip -6 route add default via "$GW6" dev "$MV1" 2>"$CTRLERR" ||
        controller_fail "cannot add the default route in $NS_E1"
    ip netns exec "$NS_E2" ip -6 route add unreachable fd42:901::/64 2>"$CTRLERR" ||
        controller_fail "cannot add the destination blackhole in $NS_E2"
    local e1_route
    e1_route=$(ip netns exec "$NS_E1" ip -6 route get "$D" 2>"$CTRLERR") ||
        fail controller_preparation "cannot read the E1 route to D"
    printf '%s' "$e1_route" | grep -q "via $GW6" ||
        fail controller_preparation "E1 route to D does not use the router: $e1_route"
    printf '%s' "$e1_route" | grep -q "dev $MV1" ||
        fail controller_preparation "E1 route to D does not use $MV1: $e1_route"
    E1_MAC=$(ip netns exec "$NS_E1" cat "/sys/class/net/$MV1/address" 2>"$CTRLERR") ||
        controller_fail "cannot read $MV1 MAC"
    E2_MAC=$(ip netns exec "$NS_E2" cat "/sys/class/net/$MV2/address" 2>"$CTRLERR") ||
        controller_fail "cannot read $MV2 MAC"
    printf '%s' "$E1_MAC" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || fail controller_preparation "invalid E1 MAC"
    printf '%s' "$E2_MAC" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || fail controller_preparation "invalid E2 MAC"

    cat >"$OUT/send.py" <<'PY'
import socket, sys, time
src, dst, port, count, interval, tag, hops = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5]), sys.argv[6], int(sys.argv[7])
s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_UNICAST_HOPS, hops)
s.bind((src, 0))
for i in range(count):
    s.sendto(f"r1 {tag} {i}".encode(), (dst, port))
    time.sleep(interval)
PY
    cat >"$OUT/listener.py" <<'PY'
import socket, sys, time
addr, port, duration, logfile = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
s.bind((addr, port))
s.settimeout(0.2)
end = time.time() + duration
with open(logfile, "a", encoding="utf-8") as fh:
    while time.time() < end:
        try:
            data, peer = s.recvfrom(2048)
            fh.write(f"SRC {peer[0]}\n")
            fh.flush()
        except socket.timeout:
            pass
PY

    LISTEN_LOG="$OUT/listener.log"
    : >"$LISTEN_LOG"
    ip netns exec "$NS_E2" timeout $((DEADLINE + 20)) python3 "$OUT/listener.py" \
        "$D" "$PORT" $((DEADLINE + 20)) "$LISTEN_LOG" >>"$SUBLOG" 2>&1 &
    LISTENER_PID=$!
    ip netns exec "$NS_E1" tcpdump -U -s 0 -i "$MV1" -n -e -v -w "$OUT/e1.pcap" \
        "ip6 and (src host $SELECTOR or src host $C)" >>"$SUBLOG" 2>&1 &
    E1_PCAP=$!
    ip netns exec "$NS_E2" tcpdump -U -s 0 -i "$MV2" -n -e -v -w "$OUT/e2.pcap" \
        "ip6 and dst host $D and udp port $PORT" >>"$SUBLOG" 2>&1 &
    E2_PCAP=$!
    ip netns exec "$NS_E1" tcpdump -U -s 0 -i "$MV1" -n -e -v -w "$OUT/icmp.pcap" \
        "icmp6 and dst host $SELECTOR" >>"$SUBLOG" 2>&1 &
    ICMP_PCAP=$!
    sleep 1
    local pair pid name
    for pair in "listener:$LISTENER_PID" "e1-capture:$E1_PCAP" "e2-capture:$E2_PCAP" "icmp-capture:$ICMP_PCAP"; do
        name=${pair%%:*}
        pid=${pair#*:}
        if ! kill -0 "$pid" 2>/dev/null; then
            if [ "$name" = "listener" ]; then
                fail controller_prerequisite "controller listener failed to start"
            else
                fail controller_prerequisite "controller packet capture $name failed to start (CAP_NET_RAW?)"
            fi
        fi
    done
    stage_done stage0 pass "namespaces $NS_E1/$NS_E2; $MV1/$MV2; selector $SELECTOR/128; C/128 and D/128 via router; generators and captures started"
}

# ---- Stage 1: read-only target preflight ----
stage1_preflight() {
    stage_enter stage1 "read-only target preflight"
    # shellcheck disable=SC2034 # consumed by the sourced identity helper
    SADR_SSH_OPTS=("${SSH_OPTS[@]}")
    # shellcheck disable=SC2034
    SADR_SSH_KEY="$SSH_KEY"
    # shellcheck disable=SC2034
    SADR_ID_STDERR="$SSHLOG"
    if ! sadr_identity_acquire "$ROUTER"; then
        fail target_preflight "identity acquisition failed (transport or malformed response)"
    fi
    if ! sadr_identity_validate "" "4.14.54-UBNT" "$FINGERPRINT" "$DEVICE_ID"; then
        fail target_preflight "identity validation/fingerprint mismatch"
    fi
    VERSION=$SADR_ID_VERSION
    KERNEL=$SADR_ID_KERNEL

    say "preflight: RPDB and protected state"
    RULES_BEFORE=$(rssh "ip -6 rule show") || fail target_preflight "rule read failed"
    PROTECTED_BEFORE=$(printf '%s\n' "$RULES_BEFORE" | grep -E '^(1041[0-4]):' || true)
    [ "$(printf '%s\n' "$PROTECTED_BEFORE" | grep -c .)" -eq 5 ] ||
        fail target_preflight "protected rules 10410-10414 are not in the expected state"
    local count
    count=$(rule_count) || fail target_preflight "rule read failed"
    [ "$count" -eq 0 ] || fail target_preflight "priority $PREF already occupied"
    if printf '%s\n' "$RULES_BEFORE" | grep -Fq "$SELECTOR"; then
        fail target_preflight "selector already present in the RPDB"
    fi
    local addr_routes
    addr_routes=$(rssh "ip -6 addr show; ip -6 route show table all") ||
        fail target_preflight "address/route read failed"
    if printf '%s\n' "$addr_routes" | grep -Fq "$SELECTOR"; then
        fail target_preflight "selector already present in addresses/routes"
    fi
    T41913_BEFORE=$(table41913_count) || fail target_preflight "table 41913 read failed"
    BGP_BEFORE=$(bgp_counts) || fail target_preflight "BGP summary read failed"
    DEFAULTS_BEFORE=$(defaults_now) || fail target_preflight "default route read failed"

    say "preflight: cleanup mechanism and containment"
    local help
    help=$(rssh 'systemd-run --help') || fail target_preflight "systemd-run help read failed"
    printf '%s\n' "$help" | grep -q -- '--on-active' || fail target_preflight "systemd-run --on-active unsupported"
    printf '%s\n' "$help" | grep -q -- '--timer-property' || fail target_preflight "systemd-run --timer-property unsupported"
    rsudo 'systemd-run --version' >/dev/null 2>&1 || fail target_preflight "passwordless sudo/systemd-run unavailable"
    rssh 'test -w /tmp' || fail target_preflight "/tmp not writable"
    local timer_state
    timer_state=$(rssh 'systemctl show sadr-r1-cleanup.timer -p LoadState' 2>/dev/null || true)
    case "$timer_state" in *"LoadState=loaded"*) fail target_preflight "cleanup timer already exists" ;; esac
    local mem
    mem=$(rssh 'free -m') || fail target_preflight "memory read failed"
    MEM_AVAIL_BEFORE=$(printf '%s\n' "$mem" | awk '/^Mem:/ {print $7}')
    if [ -z "$MEM_AVAIL_BEFORE" ] || [ "$MEM_AVAIL_BEFORE" -lt "$MIN_MEM_MB" ]; then
        fail target_preflight "insufficient available memory"
    fi
    PREFIX_IF=$(rssh "ip -6 route get $D") || fail target_preflight "cannot determine the target egress interface"
    PREFIX_IF=$(printf '%s\n' "$PREFIX_IF" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
    [ -n "$PREFIX_IF" ] || fail target_preflight "cannot determine the target egress interface for D"
    ROUTER_MAC=$(rssh "cat /sys/class/net/$PREFIX_IF/address") ||
        fail target_preflight "cannot read the target interface MAC"
    printf '%s' "$ROUTER_MAC" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' ||
        fail target_preflight "invalid target interface MAC"
    containment_check
    stage_done stage1 pass "version=$VERSION kernel=$KERNEL fingerprint=$FINGERPRINT egress_if=$PREFIX_IF protected=5 table41913=$T41913_BEFORE bgp='$BGP_BEFORE' containment=pass"
}

containment_check() {
    local s_route c_route state
    s_route=$(rssh_err "ip -6 route get $D from $SELECTOR iif $PREFIX_IF") ||
        fail target_preflight "ingress-aware lookup failed for the matching flow: $s_route"
    if printf '%s' "$s_route" | grep -q ' via '; then
        fail target_preflight "matching flow is not on-link on the target: $s_route"
    fi
    printf '%s' "$s_route" | grep -q " dev $PREFIX_IF" ||
        fail target_preflight "matching flow does not egress $PREFIX_IF: $s_route"
    c_route=$(rssh_err "ip -6 route get $D from $C iif $PREFIX_IF") ||
        fail target_preflight "ingress-aware lookup failed for the control flow: $c_route"
    if printf '%s' "$c_route" | grep -q ' via '; then
        fail target_preflight "control flow is not on-link on the target: $c_route"
    fi
    printf '%s' "$c_route" | grep -q " dev $PREFIX_IF" ||
        fail target_preflight "control flow does not egress $PREFIX_IF: $c_route"
    state=$(rssh "ip -6 addr show; ip -6 rule show; ip -6 route show table all") ||
        fail target_preflight "containment read failed"
    if printf '%s\n' "$state" | grep -Fq "$SELECTOR"; then
        fail target_preflight "selector appeared in production state"
    fi
}

# ---- Stage 2: A1 baseline ----
count_src() { grep -c "^SRC $1$" "$LISTEN_LOG" 2>/dev/null || true; }
phase() { # tag match_n control_n
    ( ip netns exec "$NS_E1" python3 "$OUT/send.py" "$SELECTOR" "$D" "$PORT" "$2" "$INTERVAL" "m-$1" "$HOPLIMIT" ) &
    local mpid=$!
    ip netns exec "$NS_E1" python3 "$OUT/send.py" "$C" "$D" "$PORT" "$3" "$INTERVAL" "c-$1" "$HOPLIMIT"
    wait "$mpid"
    sleep 1
}
verify_forwarding() { # phase-label
    local e1_out e2_out
    e1_out=$(tcpdump -nn -e -v -r "$OUT/e1.pcap" 2>/dev/null) ||
        fail dataplane_baseline "$1: E1 capture unreadable"
    e2_out=$(tcpdump -nn -e -v -r "$OUT/e2.pcap" 2>/dev/null) ||
        fail dataplane_baseline "$1: E2 capture unreadable"
    printf '%s\n' "$e1_out" | grep -Fq "$E1_MAC > $ROUTER_MAC" ||
        fail dataplane_baseline "$1: E1 frames do not target the router MAC"
    printf '%s\n' "$e1_out" | grep -q "hlim $HOPLIMIT" ||
        fail dataplane_baseline "$1: E1 hop limit is not $HOPLIMIT"
    printf '%s\n' "$e1_out" | grep -q " > $D" ||
        fail dataplane_baseline "$1: E1 frames do not target D"
    if printf '%s\n' "$e1_out" | grep -Fq "$E1_MAC > $E2_MAC"; then
        fail dataplane_baseline "$1: direct Layer 2 frame observed (E1 -> E2)"
    fi
    printf '%s\n' "$e2_out" | grep -Fq "$ROUTER_MAC > $E2_MAC" ||
        fail dataplane_baseline "$1: E2 frames do not come from the router MAC"
    printf '%s\n' "$e2_out" | grep -q "hlim $((HOPLIMIT - 1))" ||
        fail dataplane_baseline "$1: hop limit was not decremented (flow bypassed the router?)"
    printf '%s\n' "$e2_out" | grep -Fq "$SELECTOR" ||
        fail dataplane_baseline "$1: matching flow missing from E2"
    printf '%s\n' "$e2_out" | grep -Fq "$C" ||
        fail dataplane_baseline "$1: control flow missing from E2"
}

verify_invariants() { # label class
    local label=$1 class=$2 rules_after protected_after t41913_after bgp_after defaults_after mem_after mem_avail_after
    sleep 1
    rules_after=$(rssh "ip -6 rule show") || fail "$class" "$label: rule read failed during invariants"
    protected_after=$(printf '%s\n' "$rules_after" | grep -E '^(1041[0-4]):' || true)
    [ "$protected_after" = "$PROTECTED_BEFORE" ] || fail "$class" "$label: protected rules changed"
    t41913_after=$(table41913_count) || fail "$class" "$label: table 41913 read failed"
    [ "$t41913_after" -eq "$T41913_BEFORE" ] || fail "$class" "$label: table 41913 route count changed"
    bgp_after=$(bgp_counts) || fail "$class" "$label: BGP summary read failed"
    [ "$BGP_BEFORE" = "$bgp_after" ] || fail "$class" "$label: BGP neighbor state changed ($BGP_BEFORE -> $bgp_after)"
    defaults_after=$(defaults_now) || fail "$class" "$label: default route read failed"
    [ "$DEFAULTS_BEFORE" = "$defaults_after" ] || fail "$class" "$label: default routes changed"
    mem_after=$(rssh 'free -m') || fail "$class" "$label: memory read failed"
    mem_avail_after=$(printf '%s\n' "$mem_after" | awk '/^Mem:/ {print $7}')
    if [ -z "$mem_avail_after" ] || [ "$mem_avail_after" -lt "$MIN_MEM_MB" ]; then
        fail "$class" "$label: memory below the floor after the run"
    fi
    say "invariants $label: memory available before=$MEM_AVAIL_BEFORE after=$mem_avail_after"
    if printf '%s\n' "$rules_after" | grep -q "^${PREF}:"; then
        fail "$class" "$label: guard rule residue after cleanup"
    fi
}

stage2_a1() {
    stage_enter stage2 "A1 baseline dataplane qualification"
    containment_check
    phase a1 "$MATCH_N" "$CONTROL_N"
    A1_MATCH=$(count_src "$SELECTOR")
    A1_CONTROL=$(count_src "$C")
    say "A1 matching=$A1_MATCH control=$A1_CONTROL"
    verify_invariants A1 dataplane_baseline
    diag "A1 invariants pass: protected rules, table 41913, BGP, default routes and memory unchanged"
    [ "$A1_MATCH" -eq "$MATCH_N" ] || fail dataplane_baseline "A1 matching delivery $A1_MATCH/$MATCH_N"
    [ "$A1_CONTROL" -eq "$CONTROL_N" ] || fail dataplane_baseline "A1 control delivery $A1_CONTROL/$CONTROL_N"
    verify_forwarding A1
    local e1_probes e1_to_d
    e1_probes=$(tcpdump -nn -r "$OUT/e1.pcap" 2>/dev/null "ip6 and udp and dst port $PORT" | wc -l | awk '{print $1}') ||
        fail dataplane_baseline "A1: E1 capture unreadable for the off-link check"
    e1_to_d=$(tcpdump -nn -r "$OUT/e1.pcap" 2>/dev/null "ip6 and udp and dst port $PORT and dst host $D" | wc -l | awk '{print $1}') ||
        fail dataplane_baseline "A1: E1 capture unreadable for the off-link destination check"
    OFFLINK=$((e1_probes - e1_to_d))
    [ "$OFFLINK" -eq 0 ] ||
        fail dataplane_baseline "A1: $OFFLINK synthetic packet(s) targeted a non-approved destination"
    ICMP_COUNT=$(tcpdump -nn -r "$OUT/icmp.pcap" 2>/dev/null | wc -l | awk '{print $1}') ||
        fail dataplane_baseline "A1: ICMP capture unreadable"
    stage_done stage2 pass "A1 matching=$A1_MATCH/$MATCH_N control=$A1_CONTROL/$CONTROL_N; router-MAC next hop; hlim $HOPLIMIT->$((HOPLIMIT-1)); direct-L2=absent; offlink=0; invariants=pass"
}

# ---- R1 mutation path ----
transfer() { # local remote
    local tmp="/tmp/.sadr-r1.$$.$RANDOM" remote_sha
    ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" "$ROUTER" "cat > $tmp" <"$1" 2>>"$SSHLOG" ||
        fail device_mutation "transfer of $(basename "$1") failed"
    rsudo "install -m 0755 -o root -g root $tmp '$2'" || fail device_mutation "root install of $(basename "$1") failed"
    rsudo "rm -f $tmp" >/dev/null 2>&1 || true
    remote_sha=$(rsudo "sha256sum '$2'" | awk '{print $1}') ||
        fail device_mutation "cannot verify $(basename "$1") on the device"
    [ "$remote_sha" = "$(sha256sum "$1" | awk '{print $1}')" ] ||
        fail device_mutation "transferred $(basename "$1") hash mismatch"
}

execute_mutation() {
    stage_enter boundary "production mutation boundary"
    BOUNDARY=1
    BOUNDARY_UTC=$(utc)
    printf '{"crossed_utc":"%s","test_id":"%s","selector":"%s","priority":%s}\n' \
        "$BOUNDARY_UTC" "$TEST_ID" "$SELECTOR" "$PREF" >"$OUT/mutation-boundary.json.tmp"
    mv "$OUT/mutation-boundary.json.tmp" "$OUT/mutation-boundary.json"
    stage_done boundary pass "authorization consumed at $BOUNDARY_UTC; deployment begins"

    stage_enter deploy "device-local runtime deployment"
    RUNDIR="/run/sadr-r1-$(date -u +%s)-$$"
    rsudo "install -d -m 0700 -o root -g root '$RUNDIR'" ||
        fail device_mutation "cannot create the device runtime directory"
    transfer "$INSTALL_PATH" "$RUNDIR/r1-install.sh"
    transfer "$CLEANUP_PATH" "$RUNDIR/r1-cleanup.sh"
    stage_done deploy pass "runtime directory $RUNDIR; install/cleanup hash-verified"

    stage_enter b "device-local recovery, exact rule and B probes"
    local arm_out state count body guard_get e2_before_match e2_before_control e2_after_match e2_after_control
    arm_out=$(rsudo_err "systemd-run --unit=sadr-r1-cleanup --on-active=$DEADLINE --timer-property=AccuracySec=1s /bin/sh '$RUNDIR/r1-cleanup.sh' '$SELECTOR' '$PREF' '$RUNDIR/cleanup.log' '$RUNDIR'") ||
        fail device_mutation "device timer could not be armed: $arm_out"
    TIMER_ARMED=1
    state=$(rssh "systemctl show sadr-r1-cleanup.timer -p ActiveState" 2>/dev/null | cut -d= -f2 || true)
    [ "$state" = "active" ] || fail device_mutation "device cleanup timer is not active ($state)"
    TIMER_ACCURACY=$(rssh "systemctl show sadr-r1-cleanup.timer -p AccuracyUSec" 2>/dev/null | cut -d= -f2 || true)
    say "timer active accuracy=$TIMER_ACCURACY deadline=${DEADLINE}s"
    containment_check
    rsudo "sh '$RUNDIR/r1-install.sh' '$SELECTOR' '$PREF' '$DEADLINE_EPOCH' '$RUNDIR'" ||
        fail device_mutation "device-local install refused or failed"
    count=$(rule_count) || fail device_mutation "rule read failed after install"
    [ "$count" -eq 1 ] || fail device_mutation "guard rule count is $count after install"
    body=$(rule_at) || fail device_mutation "rule read failed after install"
    [ "$body" = "from $SELECTOR unreachable" ] || fail device_mutation "unexpected guard rule body: $body"
    guard_get=$(rssh_err "ip -6 route get $D from $SELECTOR iif $PREFIX_IF" || true)
    if printf '%s' "$guard_get" | grep -q ' via '; then
        fail device_mutation "guarded route lookup still resolves via a gateway: $guard_get"
    fi
    printf '%s' "$guard_get" | grep -qiE 'unreachable|No route' ||
        fail device_mutation "guarded route lookup is not terminal: $guard_get"

    e2_before_match=$(tcpdump -nn -r "$OUT/e2.pcap" 2>/dev/null | grep -c "$SELECTOR" || true)
    e2_before_control=$(tcpdump -nn -r "$OUT/e2.pcap" 2>/dev/null | grep -c "$C" || true)
    phase b "$MATCH_N" "$CONTROL_N"
    B_MATCH=$(grep -c "^SRC $SELECTOR$" "$LISTEN_LOG" 2>/dev/null || true)
    B_CONTROL=$(count_src "$C")
    B_MATCH=$((B_MATCH - A1_MATCH))
    B_CONTROL=$((B_CONTROL - A1_CONTROL))
    say "B matching=$B_MATCH control=$B_CONTROL"
    [ "$B_MATCH" -eq 0 ] || fail device_mutation "$B_MATCH matching packets reached the destination under the guard"
    [ "$B_CONTROL" -eq "$CONTROL_N" ] || fail device_mutation "control flow did not survive the guard ($B_CONTROL/$CONTROL_N)"
    e2_after_match=$(tcpdump -nn -r "$OUT/e2.pcap" 2>/dev/null | grep -c "$SELECTOR" || true)
    e2_after_control=$(tcpdump -nn -r "$OUT/e2.pcap" 2>/dev/null | grep -c "$C" || true)
    [ "$e2_after_match" -eq "$e2_before_match" ] ||
        fail device_mutation "$((e2_after_match - e2_before_match)) matching packet(s) appeared at E2 during B"
    [ "$e2_after_control" -gt "$e2_before_control" ] ||
        fail device_mutation "control flow missing from the E2 capture during B"
    stage_done b pass "matching=0 control=$B_CONTROL/$CONTROL_N; exact rule body; timer active; E2 matching delta=0"

    stage_enter device_cleanup "exact device cleanup and verification"
    if cleanup_device; then
        stage_done device_cleanup pass "$DEVICE_CLEANUP_DETAIL"
    else
        stage_done device_cleanup fail "$DEVICE_CLEANUP_DETAIL"
        fail cleanup "device cleanup failed: $DEVICE_CLEANUP_DETAIL"
    fi
    count=$(rule_count) || fail cleanup "rule read failed after cleanup"
    [ "$count" -eq 0 ] || fail cleanup "guard rule still present after cleanup"
    local restored_get
    restored_get=$(rssh_err "ip -6 route get $D from $SELECTOR iif $PREFIX_IF") ||
        fail device_mutation "route lookup failed after restore: $restored_get"
    if printf '%s' "$restored_get" | grep -q ' via '; then
        fail device_mutation "route lookup did not recover: $restored_get"
    fi
    if printf '%s' "$restored_get" | grep -qiE 'unreachable|No route'; then
        fail device_mutation "route lookup did not recover: $restored_get"
    fi
    containment_check

    stage_enter a2 "restored baseline (A2)"
    phase a2 "$MATCH_N" "$CONTROL_N"
    A2_MATCH=$(( $(count_src "$SELECTOR") - A1_MATCH ))
    A2_CONTROL=$(( $(count_src "$C") - A1_CONTROL ))
    say "A2 matching=$A2_MATCH control=$A2_CONTROL"
    [ "$A2_MATCH" -eq "$MATCH_N" ] || fail device_mutation "matching flow did not recover ($A2_MATCH/$MATCH_N)"
    [ "$A2_CONTROL" -eq $((B_CONTROL + CONTROL_N)) ] || fail device_mutation "control flow did not continue ($A2_CONTROL)"
    verify_forwarding A2
    verify_invariants A2 device_mutation
    stage_done a2 pass "matching=$A2_MATCH/$MATCH_N control=$A2_CONTROL; rule absent; route recovered; forwarding and invariants verified"
}

# ---- run the selected stage set ----
if [ "$MODE" = "preflight" ]; then
    derive_local_path
    stage1_preflight
    RESULT_STATUS=pass
    exit 0
fi

if [ "$MODE" = "baseline" ]; then
    stage0_prepare
    stage1_preflight
    stage2_a1
    stage_enter controller_cleanup "controller resource cleanup"
    if cleanup_local; then
        stage_done controller_cleanup pass "$LOCAL_CLEANUP_DETAIL"
        RESULT_STATUS=pass
        exit 0
    fi
    stage_done controller_cleanup fail "$LOCAL_CLEANUP_DETAIL"
    fail cleanup "controller cleanup failed: $LOCAL_CLEANUP_DETAIL"
fi

if [ "$MODE" = "execute" ]; then
    stage0_prepare
    stage1_preflight
    stage2_a1
    execute_mutation
    stage_enter controller_cleanup "controller resource cleanup"
    if cleanup_local; then
        stage_done controller_cleanup pass "$LOCAL_CLEANUP_DETAIL"
        RESULT_STATUS=pass
        exit 0
    fi
    stage_done controller_cleanup fail "$LOCAL_CLEANUP_DETAIL"
    fail cleanup "controller cleanup failed: $LOCAL_CLEANUP_DETAIL"
fi

fail harness "unreachable mode"
