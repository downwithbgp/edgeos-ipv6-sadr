#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Production-aware qualification profiles. Default is Plan; no router contact.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
. "$ROOT/qualification/lib/identity.sh"
PROFILE=plan
MODE=plan
PREFLIGHT=0
ROUTER=""
DEVICE_ID=""
FIRMWARE=""
ARTIFACT=""
CONFIG=""
AUTH_FILE=""
TEST_ID=""
ADAPTER=""
CLEANUP=""
INSTALL=""
DEVICE_FP=""
NOT_AFTER=""
OUT=""
AUTHORIZED=0
MAXDUR=0
CLEANUP_TIMEOUT=30
MUTATION_STARTED=0
CLEANED=0
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -o UserKnownHostsFile="${SADR_QUAL_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}" -i "${SADR_QUAL_SSH_KEY:-$HOME/.ssh/id_ed25519}")

usage() {
    cat >&2 <<'EOF'
usage: qualification/profile.sh --profile plan|observe|canary|maintenance|isolated --out DIR [options]

  --plan                      render the profile plan (default)
  --execute                   execute an authorized profile
  --preflight                 read-only preflight through the real execution path
  --authorize                 acknowledge explicit scoped authorization
  --profile NAME              plan|observe|canary|maintenance|isolated
  --test-id ID                exact authorized test id (canary/maintenance)
  --router USER@HOST          management endpoint
  --device-id ID              exact expected device identity
  --firmware VERSION          exact expected /etc/version
  --artifact PATH             package under test (isolated)
  --config PATH               configuration command file (isolated)
  --authorization PATH        scoped authorization JSON (canary/maintenance/isolated)
  --device-fingerprint HEX    expected stable device fingerprint (mutating profiles)
  --adapter PATH              executable R1 adapter bound by the authorization (canary/maintenance)
  --cleanup PATH              device-local cleanup script bound by the authorization
  --install PATH              device-local install wrapper bound by the authorization
  --out DIR                   results directory

Default profile is Plan, which never contacts a router. Observe is read-only and
takes no authorization file. Canary/maintenance require --test-id plus an
authorization file with a not_after deadline; isolated also needs
SADR_QUAL_ISOLATED=1. No generic production-safety bypass exists.
EOF
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --plan) MODE=plan; shift ;;
        --execute) MODE=execute; shift ;;
        --preflight) PREFLIGHT=1; shift ;;
        --authorize) AUTHORIZED=1; shift ;;
        --profile) [ $# -ge 2 ] || usage; PROFILE=$2; shift 2 ;;
        --test-id) [ $# -ge 2 ] || usage; TEST_ID=$2; shift 2 ;;
        --router) [ $# -ge 2 ] || usage; ROUTER=$2; shift 2 ;;
        --device-id) [ $# -ge 2 ] || usage; DEVICE_ID=$2; shift 2 ;;
        --firmware) [ $# -ge 2 ] || usage; FIRMWARE=$2; shift 2 ;;
        --artifact) [ $# -ge 2 ] || usage; ARTIFACT=$2; shift 2 ;;
        --config) [ $# -ge 2 ] || usage; CONFIG=$2; shift 2 ;;
        --authorization) [ $# -ge 2 ] || usage; AUTH_FILE=$2; shift 2 ;;
        --device-fingerprint) [ $# -ge 2 ] || usage; DEVICE_FP=$2; shift 2 ;;
        --adapter) [ $# -ge 2 ] || usage; ADAPTER=$2; shift 2 ;;
        --cleanup) [ $# -ge 2 ] || usage; CLEANUP=$2; shift 2 ;;
        --install) [ $# -ge 2 ] || usage; INSTALL=$2; shift 2 ;;
        --out) [ $# -ge 2 ] || usage; OUT=$2; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done
case "$PROFILE" in plan|observe|canary|maintenance|isolated) ;; *) usage ;; esac
[ -n "$OUT" ] || usage
mkdir -p "$OUT"
TSV="$OUT/results.tsv"
: >"$TSV"

record() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" \
    "$(printf '%s' "$4" | tr '\t\n' '  ')" "$(printf '%s' "$5" | tr '\t\n' '  ')" >>"$TSV"; }

report() {
    local mode=$1
    python3 "$ROOT/qualification/report.py" --mode "$mode" --profile "$PROFILE" \
        --tsv "$TSV" --out "$OUT" --router "$ROUTER" --artifact "$ARTIFACT" \
        --firmware "$FIRMWARE"
}

# A run is complete only when every executed step passed. Observe uses the same
# check: a failed read-only collection must not report success.
check_complete() {
    python3 - "$OUT/results.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
bad = [s for s in d["steps"] if s["status"] != "pass"]
if bad:
    print("profile incomplete:", ", ".join(f'{s["id"]}={s["status"]}' for s in bad), file=sys.stderr)
    raise SystemExit(1)
PY
}

plan_profile() {
    case "$PROFILE" in
        observe)
            record preflight "Verify exact firmware/kernel/device" planned "not executed in plan mode" "ssh identity"
            record independent-management "Operator attests read-only access and recovery path" planned "not executed in plan mode" "operator attestation"
            record observe "Collect read-only identity/RPDB/table/interface/systemd/resource baseline" planned "not executed in plan mode" "ssh read-only inventory"
            record resources "Record CPU/memory/load baseline" planned "not executed in plan mode" "ssh resource commands"
            ;;
        canary)
            record preflight "Verify exact firmware/kernel/device" planned "not executed in plan mode" "ssh identity"
            record independent-management "Operator attests independent management and rollback path" planned "not executed in plan mode" "operator attestation"
            record backup "Snapshot rules/routes/config/packages" planned "not executed in plan mode" "ssh/scp snapshots"
            record canary "Execute the exact authorized synthetic canary only" planned "not executed in plan mode" "SADR_QUAL_CANARY_CMD"
            record cleanup "Delete only the exact authorized test objects" planned "not executed in plan mode" "SADR_QUAL_CLEANUP_CMD"
            ;;
        maintenance)
            record preflight "Verify exact firmware/kernel/device" planned "not executed in plan mode" "ssh identity"
            record independent-management "Operator attests independent management and recovery path" planned "not executed in plan mode" "operator attestation"
            record backup "Snapshot rules/routes/config/packages" planned "not executed in plan mode" "ssh/scp snapshots"
            record maintenance "Execute the exact authorized maintenance test" planned "not executed in plan mode" "SADR_QUAL_MAINTENANCE_CMD"
            record cleanup "Delete only the exact authorized test objects" planned "not executed in plan mode" "SADR_QUAL_CLEANUP_CMD"
            ;;
    esac
    report plan
    echo "plan written to $OUT/results.json and $OUT/results.md"
    exit 0
}

if [ "$MODE" = "plan" ]; then
    case "$PROFILE" in
        plan|isolated)
            SADR_QUAL_PROFILE="$PROFILE" exec "$ROOT/qualification/run.sh" --plan --out "$OUT" --router "$ROUTER" \
                --artifact "$ARTIFACT" --firmware "$FIRMWARE"
            ;;
        observe|canary|maintenance)
            plan_profile
            ;;
    esac
fi

# Everything below this line can contact the router.
[ "$AUTHORIZED" -eq 1 ] || { echo "FAIL: --execute requires --authorize" >&2; exit 2; }
[ -n "$ROUTER" ] || { echo "FAIL: --router required" >&2; exit 2; }
case "$PROFILE" in
    observe|canary|maintenance|isolated) ;;
    *) echo "FAIL: profile $PROFILE cannot execute" >&2; exit 2 ;;
esac
# Reject option injection and whitespace before the value ever reaches ssh.
case "$ROUTER" in
    -*|*[[:space:]]*|*[!A-Za-z0-9._@:%-]*)
        echo "FAIL: --router contains unsupported characters" >&2
        exit 2
        ;;
esac
command -v ssh >/dev/null 2>&1 || { echo "FAIL: ssh required" >&2; exit 2; }

SCOPE=""
RECOVERY=""
ARTIFACT_SHA=""
ADAPTER_SHA=""
CLEANUP_SHA=""
if [ "$PROFILE" != "observe" ]; then
    [ -n "$DEVICE_ID" ] || { echo "FAIL: --device-id required" >&2; exit 2; }
    [ -n "$DEVICE_FP" ] || { echo "FAIL: --device-fingerprint required" >&2; exit 2; }
    printf '%s' "$DEVICE_FP" | grep -Eq '^[0-9a-f]{64}$' || { echo "FAIL: --device-fingerprint must be 64 lowercase hex" >&2; exit 2; }
    [ -n "$AUTH_FILE" ] || { echo "FAIL: --authorization required" >&2; exit 2; }
    [ -f "$AUTH_FILE" ] || { echo "FAIL: authorization file not found" >&2; exit 2; }
    auth_args=(--file "$AUTH_FILE" --profile "$PROFILE" --device "$DEVICE_ID")
    if [ -n "$TEST_ID" ]; then auth_args+=(--test-id "$TEST_ID"); fi
    if [ -n "$ARTIFACT" ]; then auth_args+=(--artifact "$ARTIFACT"); fi
    # The validated authorization is consumed, never discarded: duration, scope,
    # recovery, deadline, fingerprint and hashes come from it.
    if ! auth_json=$(python3 "$ROOT/qualification/authorization.py" "${auth_args[@]}"); then
        echo "FAIL: authorization rejected" >&2
        exit 2
    fi
    MAXDUR=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["max_duration_seconds"])' <<<"$auth_json")
    SCOPE=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["approved_mutation_scope"])' <<<"$auth_json")
    RECOVERY=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["recovery"])' <<<"$auth_json")
    ARTIFACT_SHA=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["artifact_sha256"])' <<<"$auth_json")
    NOT_AFTER=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["not_after"])' <<<"$auth_json")
    AUTH_FP=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["device_fingerprint"])' <<<"$auth_json")
    [ "$AUTH_FP" = "$DEVICE_FP" ] || { echo "FAIL: device fingerprint does not match the authorization" >&2; exit 2; }
    export SADR_QUAL_ROUTER="$ROUTER"
export SADR_QUAL_OUT="$OUT"
    export SADR_QUAL_TEST_ID="$TEST_ID"
    export SADR_QUAL_MAX_DURATION="$MAXDUR"
    export SADR_QUAL_NOT_AFTER="$NOT_AFTER"
    export SADR_QUAL_DEVICE_FINGERPRINT="$DEVICE_FP"
    export SADR_QUAL_APPROVED_SCOPE="$SCOPE"
    export SADR_QUAL_RECOVERY="$RECOVERY"
    if [ -n "$ARTIFACT_SHA" ]; then export SADR_QUAL_ARTIFACT_SHA256="$ARTIFACT_SHA"; fi
    if [ "$PROFILE" = "canary" ] || [ "$PROFILE" = "maintenance" ]; then
        if [ -z "$ADAPTER" ] || [ ! -f "$ADAPTER" ]; then echo "FAIL: --adapter required" >&2; exit 2; fi
        if [ -z "$CLEANUP" ] || [ ! -f "$CLEANUP" ]; then echo "FAIL: --cleanup required" >&2; exit 2; fi
        if [ -z "$INSTALL" ] || [ ! -f "$INSTALL" ]; then echo "FAIL: --install required" >&2; exit 2; fi
        ADAPTER_SHA=$(sha256sum "$ADAPTER" | awk '{print $1}')
        CLEANUP_SHA=$(sha256sum "$CLEANUP" | awk '{print $1}')
        INSTALL_SHA=$(sha256sum "$INSTALL" | awk '{print $1}')
        AUTH_ADAPTER=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["adapter_sha256"])' <<<"$auth_json")
        AUTH_CLEANUP=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["cleanup_sha256"])' <<<"$auth_json")
        AUTH_INSTALL=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["install_sha256"])' <<<"$auth_json")
        [ "$AUTH_ADAPTER" = "$ADAPTER_SHA" ] || { echo "FAIL: adapter hash mismatch" >&2; exit 2; }
        [ "$AUTH_CLEANUP" = "$CLEANUP_SHA" ] || { echo "FAIL: cleanup hash mismatch" >&2; exit 2; }
        [ "$AUTH_INSTALL" = "$INSTALL_SHA" ] || { echo "FAIL: install hash mismatch" >&2; exit 2; }
        export SADR_QUAL_ADAPTER_PATH="$ADAPTER"
        export SADR_QUAL_ADAPTER_SHA256="$ADAPTER_SHA"
        export SADR_QUAL_CLEANUP_PATH="$CLEANUP"
        export SADR_QUAL_CLEANUP_SHA256="$CLEANUP_SHA"
        export SADR_QUAL_INSTALL_PATH="$INSTALL"
        export SADR_QUAL_INSTALL_SHA256="$INSTALL_SHA"
        if [ "$PROFILE" = "maintenance" ]; then cmdvar=SADR_QUAL_MAINTENANCE_CMD; else cmdvar=SADR_QUAL_CANARY_CMD; fi
        adapter_cmd=${!cmdvar:-}
        if [ -n "$adapter_cmd" ]; then
            case "$adapter_cmd" in
                *"$ADAPTER"*) ;;
                *) echo "FAIL: the $PROFILE command does not reference the bound adapter" >&2; exit 2 ;;
            esac
        fi
    fi
fi
if [ "$PROFILE" = "isolated" ]; then
    [ "${SADR_QUAL_ISOLATED:-0}" = "1" ] || { echo "FAIL: isolated requires SADR_QUAL_ISOLATED=1" >&2; exit 2; }
    if [ -z "$ARTIFACT" ] || [ -z "$CONFIG" ]; then
        echo "FAIL: isolated requires --artifact/--config" >&2
        exit 2
    fi
    SADR_QUAL_ISOLATED=1 SADR_QUAL_PROFILE="$PROFILE" exec "$ROOT/qualification/run.sh" --execute --authorize \
        --router "$ROUTER" --device-id "$DEVICE_ID" --firmware "$FIRMWARE" \
        --artifact "$ARTIFACT" --config "$CONFIG" --out "$OUT"
fi

preflight_step="Verify exact firmware/kernel"
if [ -n "$DEVICE_ID" ]; then preflight_step="Verify exact firmware/kernel/device"; fi
# shellcheck disable=SC2034 # consumed by the sourced identity helper
SADR_SSH_OPTS=("${SSH_OPTS[@]}")
# shellcheck disable=SC2034
SADR_SSH_KEY=${SADR_QUAL_SSH_KEY:-}
if ! sadr_identity_acquire "$ROUTER" || ! sadr_identity_validate "$FIRMWARE" "4.14.54-UBNT" "$DEVICE_FP" "$DEVICE_ID"; then
    record preflight "$preflight_step" fail "identity acquisition/validation failed" "shared framed identity"
    report execute
    exit 1
fi
version=$SADR_ID_VERSION
kernel=$SADR_ID_KERNEL
fp=$SADR_ID_FINGERPRINT
record preflight "$preflight_step" pass "version=$version kernel=$kernel fingerprint=$fp" "shared framed identity"
record independent-management "Operator attests independent management and rollback path" pass \
    "operator attestation, not independently verified: $RECOVERY" "operator attestation"

if [ "$PROFILE" = "observe" ]; then
    if {
        ssh "${SSH_OPTS[@]}" "$ROUTER" 'cat /etc/version; uname -a; ip -V; systemctl --version | head -1; ip -6 rule show; ip -6 route show table all; ip -6 addr show; ip -d link show; free -m; uptime; df -h / /config'
    } >"$OUT/observe.txt" 2>&1; then
        record observe "Collect read-only baseline" pass "saved to $OUT/observe.txt" "ssh read-only inventory"
    else
        record observe "Collect read-only baseline" fail "collection failed" "ssh read-only inventory"
    fi
    report execute
    check_complete
    exit 0
fi

# Mutating profiles: snapshot, run exactly one authorized adapter, clean up.
run_cleanup() {
    if [ "$CLEANED" -eq 1 ]; then return 0; fi
    if [ -z "${SADR_QUAL_CLEANUP_CMD:-}" ]; then return 1; fi
    timeout "$CLEANUP_TIMEOUT" bash -c "$SADR_QUAL_CLEANUP_CMD" || return 1
    CLEANED=1
    return 0
}

# Losing this session must not leave the authorized test objects behind. The trap
# runs only when a mutation actually started and is idempotent with the normal path.
on_exit() {
    local rc=$?
    if [ "$MUTATION_STARTED" -eq 1 ] && [ "$CLEANED" -eq 0 ]; then
        echo "WARN: interrupted after mutation; running authorized cleanup (recovery: $RECOVERY)" >&2
        if run_cleanup >"$OUT/cleanup.trap.log" 2>&1; then
            echo "WARN: trap cleanup returned 0; verify absence manually" >&2
        else
            echo "FAIL: trap cleanup failed; manual recovery required: $RECOVERY" >&2
        fi
    fi
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if {
    ssh "${SSH_OPTS[@]}" "$ROUTER" 'cat /config/config.boot' >"$OUT/config.boot.before" 2>/dev/null
    ssh "${SSH_OPTS[@]}" "$ROUTER" 'ip -6 rule show' >"$OUT/rules.before" 2>/dev/null
    ssh "${SSH_OPTS[@]}" "$ROUTER" 'ip -6 route show table all' >"$OUT/routes.before" 2>/dev/null
    ssh "${SSH_OPTS[@]}" "$ROUTER" 'dpkg -l' >"$OUT/packages.before" 2>/dev/null
}; then
    record backup "Snapshot rules/routes/config/packages" pass "saved under $OUT; scope: $SCOPE" "ssh/scp snapshots"
else
    record backup "Snapshot rules/routes/config/packages" fail "snapshot failed" "ssh/scp snapshots"
    report execute
    exit 1
fi
if [ "$PREFLIGHT" -eq 1 ]; then
    if [ -z "${SADR_QUAL_ADAPTER_PATH:-}" ]; then
        record preflight "Adapter preflight" fail "no bound adapter path" "SADR_QUAL_ADAPTER_PATH"
        report execute
        check_complete
        exit 1
    fi
    set +e
    pf_out=$(timeout "$MAXDUR" bash -c "bash '$SADR_QUAL_ADAPTER_PATH' --preflight" 2>"$OUT/preflight.stderr")
    pf_rc=$?
    set -e
    if [ "$pf_rc" -eq 0 ] && printf '%s' "$pf_out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("ok") is True' >/dev/null 2>&1; then
        record preflight "Adapter preflight" pass "read-only adapter preflight passed" "SADR_QUAL_ADAPTER_PATH --preflight"
    else
        record preflight "Adapter preflight" fail "adapter preflight failed rc=$pf_rc: $(printf '%s' "$pf_out" | tail -c 300)" "SADR_QUAL_ADAPTER_PATH --preflight"
    fi
    report execute
    check_complete
    exit 0
fi

if [ "$PROFILE" = "canary" ]; then
    var=SADR_QUAL_CANARY_CMD; id=canary
else
    var=SADR_QUAL_MAINTENANCE_CMD; id=maintenance
fi
[ -n "${!var:-}" ] || { record "$id" "Execute authorized test" blocked "missing $var" ""; report execute; exit 1; }
[ -n "${SADR_QUAL_CLEANUP_CMD:-}" ] || { record cleanup "Delete exact test objects" blocked "missing SADR_QUAL_CLEANUP_CMD" ""; report execute; exit 1; }
[ -n "${SADR_QUAL_VERIFY_CMD:-}" ] || { record cleanup "Delete exact test objects" blocked "missing SADR_QUAL_VERIFY_CMD (cleanup verification)" ""; report execute; exit 1; }
export SADR_QUAL_CONFIG_FILE="$CONFIG"
MUTATION_STARTED=1
set +e
out=$(timeout "$MAXDUR" bash -c "${!var}" 2>&1)
rc=$?
set -e
detail=$(printf '%s\n' "$out" | tail -c 600)
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d.get("ok") is True
assert isinstance(d.get("probes"),int) and d["probes"] > 0
assert d.get("wrong_provider") == 0
' >/dev/null 2>&1; then
    record "$id" "Execute authorized test" pass "$detail" "$var"
else
    record "$id" "Execute authorized test" fail "rc=$rc or invalid evidence: $detail" "$var"
fi
set +e
run_cleanup >"$OUT/cleanup.log" 2>&1
crc=$?
if [ "$crc" -eq 0 ]; then
    timeout "$CLEANUP_TIMEOUT" bash -c "$SADR_QUAL_VERIFY_CMD" >"$OUT/cleanup.verify.log" 2>&1
    vrc=$?
else
    vrc=1
fi
set -e
if [ "$crc" -eq 0 ] && [ "$vrc" -eq 0 ]; then
    record cleanup "Delete exact test objects" pass "cleanup and verification returned 0" "SADR_QUAL_CLEANUP_CMD + SADR_QUAL_VERIFY_CMD"
elif [ "$crc" -eq 0 ]; then
    record cleanup "Delete exact test objects" fail "cleanup verification failed (recovery failure); see $OUT/cleanup.verify.log" "SADR_QUAL_VERIFY_CMD"
else
    record cleanup "Delete exact test objects" fail "cleanup rc=$crc (recovery failure)" "SADR_QUAL_CLEANUP_CMD"
fi
report execute
check_complete
