#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# EdgeOS IPv6 SADR hardware qualification harness.
#
# Default is --plan: no device contact, no mutation. --execute requires explicit
# authorization, an isolated-device declaration, a router, and adapters for the
# packet/transition/boot tests. It must never be pointed at the production router.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MODE=plan
ROUTER=""
ARTIFACT=""
CONFIG=""
OUT=""
DEVICE_ID=""
FIRMWARE=""
AUTHORIZED=0
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10)

usage() {
    cat >&2 <<'EOF'
usage: qualification/run.sh [--plan|--execute] --out DIR [options]

  --plan                 emit the planned qualification steps (default)
  --execute              contact the isolated router and run steps
  --authorize            acknowledge explicit hardware authorization
  --router USER@HOST     isolated router management endpoint
  --device-id ID         expected device identity string
  --firmware VERSION     expected /etc/version value
  --artifact PATH        built .deb under test
  --config PATH          configuration-mode command file for the SADR policy
  --out DIR              results directory

Execute also requires SADR_QUAL_ISOLATED=1 and the relevant adapter variables.
See qualification/README.md.
EOF
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --plan) MODE=plan ; shift ;;
        --execute) MODE=execute ; shift ;;
        --authorize) AUTHORIZED=1 ; shift ;;
        --router) ROUTER=$2 ; shift 2 ;;
        --device-id) DEVICE_ID=$2 ; shift 2 ;;
        --firmware) FIRMWARE=$2 ; shift 2 ;;
        --artifact) ARTIFACT=$2 ; shift 2 ;;
        --config) CONFIG=$2 ; shift 2 ;;
        --out) OUT=$2 ; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done
[ -n "$OUT" ] || usage
mkdir -p "$OUT"
TSV="$OUT/results.tsv"
: >"$TSV"

record() { # id description status detail command
    local id=$1 desc=$2 status=$3 detail=$4 command=$5
    detail=$(printf '%s' "$detail" | tr '\t\n' '  ')
    command=$(printf '%s' "$command" | tr '\t\n' '  ')
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$desc" "$status" "$detail" "$command" >>"$TSV"
}

plan_step() { # id description command
    [ "$MODE" = "plan" ] || return 0
    record "$1" "$2" "planned" "not executed in plan mode" "$3"
}

adapter_var() { # id description env-var [require-positive-probes]
    if [ "$MODE" = "plan" ]; then
        plan_step "$1" "$2" "set \$$3 to the adapter command"
        return 0
    fi
    local var=$3 require_packets=${4:-0}
    if [ -z "${!var:-}" ]; then
        record "$1" "$2" "blocked" "missing $var" ""
        return 0
    fi
    local out rc
    set +e
    out=$(bash -c "${!var}" 2>&1)
    rc=$?
    set -e
    local detail
    detail=$(printf '%s\n' "$out" | tail -c 600)
    if [ "$rc" -ne 0 ]; then
        record "$1" "$2" "fail" "adapter rc=$rc: $detail" "$var"
        return 0
    fi
    if ! printf '%s\n' "$out" | python3 -c '
import json,sys
require=int(sys.argv[1])
try:
    d=json.load(sys.stdin)
except Exception:
    raise SystemExit(2)
if d.get("ok") is not True:
    raise SystemExit(3)
probes=d.get("probes")
wrong=d.get("wrong_provider")
if probes is not None and (not isinstance(probes,int) or probes < 0):
    raise SystemExit(4)
if wrong is not None and wrong != 0:
    raise SystemExit(5)
if require and (not isinstance(probes,int) or probes <= 0):
    raise SystemExit(6)
if require and wrong != 0:
    raise SystemExit(7)
' "$require_packets" >/dev/null 2>&1; then
        record "$1" "$2" "fail" "adapter output invalid or not ok: $detail" "$var"
        return 0
    fi
    record "$1" "$2" "pass" "$detail" "$var"
}

# Always record the complete matrix, including in plan mode.
plan_step preflight "Verify exact EdgeOS firmware, kernel and device identity" \
    "ssh $ROUTER 'cat /etc/version; uname -r; cat /proc/device-tree/model'"
plan_step independent-management "Attest independent management connectivity" \
    "operator must set SADR_QUAL_ISOLATED=1 and verify a second management path"
plan_step backup "Back up config.boot, rules, routes and package inventory" \
    "scp/ssh snapshots to $OUT"
plan_step artifact "Hash and inspect the .deb under test" "sha256sum $ARTIFACT"
plan_step install "Install the package on the isolated router" "scp $ARTIFACT; dpkg -i"
plan_step configure "Commit the isolated SADR policy" "run SADR_QUAL_CONFIGURE_CMD"
plan_step structural "Verify intent, guards, rules, tables and health" "run SADR_QUAL_STRUCTURAL_CMD"
plan_step packets "Continuous packet probes on all egresses; wrong-provider must be zero" "run SADR_QUAL_PACKETS_CMD"
plan_step flows "Established TCP/UDP flows during policy changes" "run SADR_QUAL_FLOWS_CMD"
plan_step transitions "Provider/internal/rule/table loss and repair" "run SADR_QUAL_TRANSITIONS_CMD"
plan_step monitor "Monitor interruption, restart and resynchronization" "run SADR_QUAL_MONITOR_CMD"
plan_step rollback "Configuration commit failure, rollback and commit-confirm" "run SADR_QUAL_ROLLBACK_CMD"
plan_step cold-boot "Cold boot/reboot and guard-before-forwarding verification" "run SADR_QUAL_BOOT_CMD"
plan_step upgrade "Upgrade and interrupted-upgrade behavior" "run SADR_QUAL_UPGRADE_CMD"
plan_step remove-refusal "Removal refusal with saved/active config and live objects" "run SADR_QUAL_REMOVE_CMD"
plan_step offload-on "Hardware offload enabled: functional policy correctness" "run SADR_QUAL_OFFLOAD_ON_CMD"
plan_step offload-off "Hardware offload disabled: functional policy correctness" "run SADR_QUAL_OFFLOAD_OFF_CMD"
plan_step source-selection "Forwarded, source-bound local and unbound router traffic" "run SADR_QUAL_SOURCE_CMD"
plan_step bgp-internal "BGP internal-route mirroring, withdrawal and ECMP" "run SADR_QUAL_BGP_CMD"
plan_step coexistence "Native firewall and edgeos-vxlan coexistence" "run SADR_QUAL_COEXIST_CMD"
plan_step resources "CPU, memory, throughput, recovery latency and boot time" "run SADR_QUAL_RESOURCES_CMD"
plan_step cleanup "Restore configuration/package state and verify no managed residue" "run SADR_QUAL_CLEANUP_CMD"

report_and_exit() {
    python3 "$ROOT/qualification/report.py" --mode execute --tsv "$TSV" --out "$OUT" \
        --router "$ROUTER" --artifact "$ARTIFACT" --firmware "$FIRMWARE" || true
    echo "qualification stopped before/at a required precondition; see $OUT/results.md" >&2
    exit 1
}

# Step ids that the harness treats as required for a complete execution.
REQUIRED="preflight independent-management backup artifact install configure structural packets flows transitions monitor rollback cold-boot upgrade remove-refusal offload-on offload-off source-selection bgp-internal coexistence resources cleanup"

if [ "$MODE" = "plan" ]; then
    python3 "$ROOT/qualification/report.py" --mode plan --tsv "$TSV" --out "$OUT" \
        --router "$ROUTER" --artifact "$ARTIFACT" --firmware "$FIRMWARE"
    echo "plan written to $OUT/results.json and $OUT/results.md"
    exit 0
fi

if [ "$AUTHORIZED" -ne 1 ] || [ "${SADR_QUAL_ISOLATED:-0}" != "1" ]; then
    echo "FAIL: --execute requires --authorize and SADR_QUAL_ISOLATED=1" >&2
    exit 2
fi
if [ -z "$ROUTER" ] || [ -z "$ARTIFACT" ] || [ -z "$CONFIG" ]; then
    echo "FAIL: --execute requires --router, --artifact and --config" >&2
    exit 2
fi
[ -f "$ARTIFACT" ] || { echo "FAIL: artifact not found: $ARTIFACT" >&2; exit 2; }
[ -f "$CONFIG" ] || { echo "FAIL: config command file not found: $CONFIG" >&2; exit 2; }
command -v ssh >/dev/null 2>&1 || { echo "FAIL: ssh required" >&2; exit 2; }
command -v scp >/dev/null 2>&1 || { echo "FAIL: scp required" >&2; exit 2; }

# Real preflight/backup/install/verify steps. Adapters cover topology-specific
# packet, transition, boot and coexistence work.
set +e
identity=$(ssh "${SSH_OPTS[@]}" "$ROUTER" 'cat /etc/version; uname -r; cat /proc/device-tree/model 2>/dev/null || true' 2>&1)
rc=$?
set -e
version=$(printf '%s\n' "$identity" | sed -n '1p')
kernel=$(printf '%s\n' "$identity" | sed -n '2p')
if [ "$rc" -eq 0 ] \
    && printf '%s' "$version" | grep -Eq '^EdgeRouter\.ER-e50\.v3\.0\.1\.5862409\.' \
    && [ "$kernel" = "4.14.54-UBNT" ] \
    && { [ -z "$FIRMWARE" ] || [ "$version" = "$FIRMWARE" ]; } \
    && { [ -z "$DEVICE_ID" ] || printf '%s' "$identity" | grep -Fq -- "$DEVICE_ID"; }; then
    record preflight "Verify exact EdgeOS firmware, kernel and device identity" pass \
        "version=$version kernel=$kernel" "ssh identity"
else
    record preflight "Verify exact EdgeOS firmware, kernel and device identity" fail \
        "unexpected: $identity" "ssh identity"
    report_and_exit
fi
if [ "${SADR_QUAL_ISOLATED:-0}" = "1" ]; then
    record independent-management "Attest independent management connectivity" pass \
        "SADR_QUAL_ISOLATED=1" "operator attestation"
else
    record independent-management "Attest independent management connectivity" blocked \
        "SADR_QUAL_ISOLATED must be 1" ""
fi

if {
    ssh "${SSH_OPTS[@]}" "$ROUTER" 'cat /config/config.boot' >"$OUT/config.boot.before" 2>/dev/null
    ssh "${SSH_OPTS[@]}" "$ROUTER" 'ip -6 rule show' >"$OUT/rules.before" 2>/dev/null
    ssh "${SSH_OPTS[@]}" "$ROUTER" 'ip -6 route show table all' >"$OUT/routes.before" 2>/dev/null
    ssh "${SSH_OPTS[@]}" "$ROUTER" 'dpkg -l' >"$OUT/packages.before" 2>/dev/null
}; then
    record backup "Back up config.boot, rules, routes and package inventory" pass \
        "saved under $OUT" "ssh/scp snapshots"
else
    record backup "Back up config.boot, rules, routes and package inventory" fail \
        "backup command failed" "ssh/scp snapshots"
    report_and_exit
fi

hash=$(sha256sum "$ARTIFACT" | awk '{print $1}')
if [ "$hash" = "${SADR_QUAL_ARTIFACT_SHA256:-$hash}" ]; then
    record artifact "Hash and inspect the .deb under test" pass "sha256=$hash" "sha256sum"
else
    record artifact "Hash and inspect the .deb under test" fail \
        "sha256=$hash expected=$SADR_QUAL_ARTIFACT_SHA256" "sha256sum"
    report_and_exit
fi

remote_deb="/tmp/$(basename "$ARTIFACT")"
# shellcheck disable=SC2029 # the local basename is intentionally interpolated into the remote command
if scp "${SSH_OPTS[@]}" "$ARTIFACT" "$ROUTER:$remote_deb" >/dev/null 2>&1 \
    && ssh "${SSH_OPTS[@]}" "$ROUTER" "sudo dpkg -i '$remote_deb'" >"$OUT/install.log" 2>&1; then
    record install "Install the package on the isolated router" pass "dpkg -i succeeded" "scp+dpkg"
else
    record install "Install the package on the isolated router" fail "install failed" "scp+dpkg"
    report_and_exit
fi

export SADR_QUAL_CONFIG_FILE="$CONFIG"
adapter_var configure "Commit the isolated SADR policy" SADR_QUAL_CONFIGURE_CMD
adapter_var structural "Verify intent, guards, rules, tables and health" SADR_QUAL_STRUCTURAL_CMD
adapter_var packets "Continuous packet probes on all egresses; wrong-provider must be zero" SADR_QUAL_PACKETS_CMD 1
adapter_var flows "Established TCP/UDP flows during policy changes" SADR_QUAL_FLOWS_CMD 1
adapter_var transitions "Provider/internal/rule/table loss and repair" SADR_QUAL_TRANSITIONS_CMD 1
adapter_var monitor "Monitor interruption, restart and resynchronization" SADR_QUAL_MONITOR_CMD
adapter_var rollback "Configuration commit failure, rollback and commit-confirm" SADR_QUAL_ROLLBACK_CMD
adapter_var cold-boot "Cold boot/reboot and guard-before-forwarding verification" SADR_QUAL_BOOT_CMD
adapter_var upgrade "Upgrade and interrupted-upgrade behavior" SADR_QUAL_UPGRADE_CMD
adapter_var remove-refusal "Removal refusal with saved/active config and live objects" SADR_QUAL_REMOVE_CMD
adapter_var offload-on "Hardware offload enabled: functional policy correctness" SADR_QUAL_OFFLOAD_ON_CMD
adapter_var offload-off "Hardware offload disabled: functional policy correctness" SADR_QUAL_OFFLOAD_OFF_CMD
adapter_var source-selection "Forwarded, source-bound local and unbound router traffic" SADR_QUAL_SOURCE_CMD
adapter_var bgp-internal "BGP internal-route mirroring, withdrawal and ECMP" SADR_QUAL_BGP_CMD
adapter_var coexistence "Native firewall and edgeos-vxlan coexistence" SADR_QUAL_COEXIST_CMD
adapter_var resources "CPU, memory, throughput, recovery latency and boot time" SADR_QUAL_RESOURCES_CMD

# Cleanup is attempted even if earlier steps failed.
adapter_var cleanup "Restore configuration/package state and verify no managed residue" SADR_QUAL_CLEANUP_CMD

python3 "$ROOT/qualification/report.py" --mode execute --tsv "$TSV" --out "$OUT" \
    --router "$ROUTER" --artifact "$ARTIFACT" --firmware "$FIRMWARE"
python3 - "$OUT/results.json" "$REQUIRED" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]))
required=set(sys.argv[2].split())
bad=[s for s in data["steps"] if s["id"] in required and s["status"] != "pass"]
if bad:
    print("qualification incomplete/failed:", ", ".join(f'{s["id"]}={s["status"]}' for s in bad), file=sys.stderr)
    raise SystemExit(1)
PY
