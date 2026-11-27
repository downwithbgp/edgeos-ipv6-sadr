#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP="${TMPDIR:-/tmp}/sadr-profile-test.$$"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/out"

DEV_MODEL="Ubiquiti EdgeRouter ER-X-TEST"
DEV_MAC="aa:bb:cc:dd:ee:ff"
DEV_FP=$(printf '%s\n%s\n' "$DEV_MODEL" "$DEV_MAC" | sha256sum | awk '{print $1}')

# A fake ssh on PATH proves which paths contact a router at all. It never
# reaches a network; each test replaces it as needed.
cat >"$TMP/bin/ssh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_SSH_LOG"
exit 1
SH
chmod +x "$TMP/bin/ssh"
export FAKE_SSH_LOG="$TMP/ssh.log"
: >"$FAKE_SSH_LOG"
export PATH="$TMP/bin:$PATH"

# The executable adapter and cleanup script the authorization must bind.
ADAPTER="$TMP/adapter.sh"
CLEANUP_SCRIPT="$TMP/cleanup.sh"
cat >"$ADAPTER" <<'SH'
#!/bin/bash
case "${1:-}" in
    fail) printf '{"ok": false, "probes": 0, "wrong_provider": 0}\n' ;;
    slow) touch "$2"; sleep 10 ;;
    *) printf '{"ok": true, "probes": 12, "wrong_provider": 0}\n' ;;
esac
SH
# shellcheck disable=SC2016 # the written script intentionally contains "$1"
printf '#!/bin/bash\ntouch "$1"\n' >"$CLEANUP_SCRIPT"
INSTALL_SCRIPT="$TMP/install.sh"
printf '#!/bin/bash\nexit 0\n' >"$INSTALL_SCRIPT"
chmod +x "$ADAPTER" "$CLEANUP_SCRIPT" "$INSTALL_SCRIPT"
ADAPTER_SHA=$(sha256sum "$ADAPTER" | awk '{print $1}')
CLEANUP_SHA=$(sha256sum "$CLEANUP_SCRIPT" | awk '{print $1}')
INSTALL_SHA=$(sha256sum "$INSTALL_SCRIPT" | awk '{print $1}')

run_plan() { # profile expected-step
    local profile=$1 expected=$2 out="$TMP/$1"
    bash "$ROOT/qualification/profile.sh" --profile "$profile" --plan --out "$out" >/dev/null
    python3 - "$out/results.json" "$profile" "$expected" <<'PY'
import json,sys
data=json.load(open(sys.argv[1])); profile=sys.argv[2]; expected=sys.argv[3]
assert data["mode"] == "plan", data["mode"]
assert data["profile"] == profile, data.get("profile")
ids={s["id"] for s in data["steps"]}
assert expected in ids, (expected, sorted(ids))
assert all(s["status"] == "planned" for s in data["steps"])
print(f"PASS: {profile} plan contains {expected}")
PY
}

expect_fail() { # description command...
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then
        echo "FAIL: $desc" >&2
        exit 1
    fi
    echo "PASS: $desc"
}

write_auth() { # file profile target_class [overrides as JSON object]
    local file=$1 profile=$2 target=$3 overrides=${4:-}
    python3 - "$file" "$profile" "$target" "$overrides" "$DEV_FP" "$ADAPTER_SHA" "$CLEANUP_SHA" "$INSTALL_SHA" <<'PY'
import json, sys
file, profile, target, overrides, fp, adapter, cleanup, install = sys.argv[1:9]
doc = {
    "device_id": "ER-X-TEST",
    "device_fingerprint": fp,
    "profile": profile,
    "target_class": target,
    "test_ids": ["R1-guard-only"],
    "max_duration_seconds": 120,
    "approved_mutation_scope": "one unreachable rule at priority 21031",
    "recovery": "exact rule delete plus watchdog",
    "not_after": "2099-01-01T00:00:00Z",
    "artifact_sha256": "",
}
if profile in ("canary", "maintenance"):
    doc["adapter_sha256"] = adapter
    doc["cleanup_sha256"] = cleanup
    doc["install_sha256"] = install
doc.update(json.loads(overrides) if overrides else {})
with open(file, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
}

CANARY_ARGS=(--adapter "$ADAPTER" --cleanup "$CLEANUP_SCRIPT" --install "$INSTALL_SCRIPT" --device-fingerprint "$DEV_FP")

run_plan observe observe
run_plan canary canary
run_plan maintenance maintenance
run_plan isolated install

AUTH="$TMP/auth.json"
write_auth "$AUTH" canary production

# The default profile and every mutating path must be unreachable without an
# explicit acknowledgement and the exact authorization file.
expect_fail "plan profile cannot execute" \
    bash "$ROOT/qualification/profile.sh" --profile plan --execute --authorize --out "$TMP/out" \
        --router admin@router.invalid --device-id ER-X-TEST --authorization "$AUTH" \
        --test-id R1-guard-only "${CANARY_ARGS[@]}"
expect_fail "execute requires --authorize" \
    bash "$ROOT/qualification/profile.sh" --profile canary --execute --out "$TMP/out" \
        --router admin@router.invalid --device-id ER-X-TEST --authorization "$AUTH" \
        --test-id R1-guard-only "${CANARY_ARGS[@]}"
expect_fail "canary requires --authorization" \
    bash "$ROOT/qualification/profile.sh" --profile canary --execute --authorize --out "$TMP/out" \
        --router admin@router.invalid --device-id ER-X-TEST --test-id R1-guard-only "${CANARY_ARGS[@]}"
expect_fail "canary requires --test-id" \
    bash "$ROOT/qualification/profile.sh" --profile canary --execute --authorize --out "$TMP/out" \
        --router admin@router.invalid --device-id ER-X-TEST --authorization "$AUTH" "${CANARY_ARGS[@]}"
expect_fail "canary requires --device-fingerprint" \
    bash "$ROOT/qualification/profile.sh" --profile canary --execute --authorize --out "$TMP/out" \
        --router admin@router.invalid --device-id ER-X-TEST --authorization "$AUTH" \
        --test-id R1-guard-only --adapter "$ADAPTER" --cleanup "$CLEANUP_SCRIPT"
expect_fail "canary requires --adapter" \
    bash "$ROOT/qualification/profile.sh" --profile canary --execute --authorize --out "$TMP/out" \
        --router admin@router.invalid --device-id ER-X-TEST --authorization "$AUTH" \
        --test-id R1-guard-only --cleanup "$CLEANUP_SCRIPT" --device-fingerprint "$DEV_FP"
expect_fail "canary requires --cleanup" \
    bash "$ROOT/qualification/profile.sh" --profile canary --execute --authorize --out "$TMP/out" \
        --router admin@router.invalid --device-id ER-X-TEST --authorization "$AUTH" \
        --test-id R1-guard-only --adapter "$ADAPTER" --device-fingerprint "$DEV_FP"
expect_fail "canary requires --install" \
    bash "$ROOT/qualification/profile.sh" --profile canary --execute --authorize --out "$TMP/out" \
        --router admin@router.invalid --device-id ER-X-TEST --authorization "$AUTH" \
        --test-id R1-guard-only --adapter "$ADAPTER" --cleanup "$CLEANUP_SCRIPT" --device-fingerprint "$DEV_FP"
expect_fail "canary command must reference the bound adapter" \
    env SADR_QUAL_CANARY_CMD='bash /tmp/not-the-bound-adapter.sh' \
    bash "$ROOT/qualification/profile.sh" --profile canary --execute --authorize --out "$TMP/out" \
        --router admin@router.invalid --device-id ER-X-TEST --authorization "$AUTH" \
        --test-id R1-guard-only "${CANARY_ARGS[@]}"

# The isolated gate must fail before any contact when SADR_QUAL_ISOLATED is unset.
ARTIFACT="$TMP/artifact.deb"
printf 'not a real package\n' >"$ARTIFACT"
ARTIFACT_SHA=$(sha256sum "$ARTIFACT" | awk '{print $1}')
ISO_AUTH="$TMP/isolated.json"
write_auth "$ISO_AUTH" isolated isolated "{\"artifact_sha256\": \"$ARTIFACT_SHA\"}"
expect_fail "isolated requires SADR_QUAL_ISOLATED=1" \
    env -u SADR_QUAL_ISOLATED bash "$ROOT/qualification/profile.sh" --profile isolated --execute --authorize \
        --out "$TMP/out" --router admin@router.invalid --device-id ER-X-TEST \
        --authorization "$ISO_AUTH" --artifact "$ARTIFACT" --config /dev/null \
        --device-fingerprint "$DEV_FP"
if [ -s "$FAKE_SSH_LOG" ]; then
    echo "FAIL: a rejected profile contacted the router" >&2
    cat "$FAKE_SSH_LOG" >&2
    exit 1
fi
echo "PASS: rejected profiles never contact a router"

# The authorization binding must fail closed on a mismatched dependency or device.
MISMATCH_ADAPTER="$TMP/mismatch-adapter.json"
write_auth "$MISMATCH_ADAPTER" canary production '{"adapter_sha256": "0000000000000000000000000000000000000000000000000000000000000000"}'
expect_fail "profile rejects an adapter hash mismatch" \
    bash "$ROOT/qualification/profile.sh" --profile canary --execute --authorize --out "$TMP/out" \
        --router admin@router.invalid --device-id ER-X-TEST --authorization "$MISMATCH_ADAPTER" \
        --test-id R1-guard-only "${CANARY_ARGS[@]}"
MISMATCH_CLEANUP="$TMP/mismatch-cleanup.json"
write_auth "$MISMATCH_CLEANUP" canary production '{"cleanup_sha256": "0000000000000000000000000000000000000000000000000000000000000000"}'
expect_fail "profile rejects a cleanup hash mismatch" \
    bash "$ROOT/qualification/profile.sh" --profile canary --execute --authorize --out "$TMP/out" \
        --router admin@router.invalid --device-id ER-X-TEST --authorization "$MISMATCH_CLEANUP" \
        --test-id R1-guard-only "${CANARY_ARGS[@]}"
MISMATCH_FP="$TMP/mismatch-fp.json"
write_auth "$MISMATCH_FP" canary production '{"device_fingerprint": "0000000000000000000000000000000000000000000000000000000000000000"}'
expect_fail "profile rejects a device fingerprint mismatch" \
    bash "$ROOT/qualification/profile.sh" --profile canary --execute --authorize --out "$TMP/out" \
        --router admin@router.invalid --device-id ER-X-TEST --authorization "$MISMATCH_FP" \
        --test-id R1-guard-only "${CANARY_ARGS[@]}"

# Option injection must be refused before it can be interpreted as an ssh option.
: >"$FAKE_SSH_LOG"
if out=$(bash "$ROOT/qualification/profile.sh" --profile observe --execute --authorize --out "$TMP/out" \
    --router '-oProxyCommand=id' 2>&1); then
    echo "FAIL: router with an ssh option was accepted" >&2
    exit 1
fi
case "$out" in
    *"unsupported characters"*) ;;
    *) echo "FAIL: router injection failed for the wrong reason: $out" >&2; exit 1 ;;
esac
if [ -s "$FAKE_SSH_LOG" ]; then
    echo "FAIL: an injected router value reached ssh" >&2
    cat "$FAKE_SSH_LOG" >&2
    exit 1
fi
echo "PASS: router with an ssh option is rejected before ssh"

python3 "$ROOT/qualification/authorization.py" --file "$AUTH" --profile canary \
    --device ER-X-TEST --test-id R1-guard-only >/dev/null
expect_fail "authorization rejects an unlisted test id" \
    python3 "$ROOT/qualification/authorization.py" --file "$AUTH" --profile canary \
        --device ER-X-TEST --test-id R9-unlisted
echo "PASS: authorization is bound to listed test ids"

expect_fail "authorization rejects wrong device" \
    python3 "$ROOT/qualification/authorization.py" --file "$AUTH" --profile canary \
        --device WRONG --test-id R1-guard-only
expect_fail "authorization rejects wrong profile" \
    python3 "$ROOT/qualification/authorization.py" --file "$AUTH" --profile isolated \
        --device ER-X-TEST --test-id R1-guard-only
NO_ADAPTER="$TMP/no-adapter.json"
write_auth "$NO_ADAPTER" canary production
python3 - "$NO_ADAPTER" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1])); del doc["adapter_sha256"]
json.dump(doc, open(sys.argv[1], "w"))
PY
expect_fail "authorization requires an adapter hash" \
    python3 "$ROOT/qualification/authorization.py" --file "$NO_ADAPTER" --profile canary \
        --device ER-X-TEST --test-id R1-guard-only

# A deadline is part of the grant: an expired or undated file authorizes nothing.
EXPIRED="$TMP/expired.json"
write_auth "$EXPIRED" canary production '{"not_after": "2000-01-01T00:00:00Z"}'
expect_fail "authorization rejects expired grants" \
    python3 "$ROOT/qualification/authorization.py" --file "$EXPIRED" --profile canary \
        --device ER-X-TEST --test-id R1-guard-only
UNDATED="$TMP/undated.json"
write_auth "$UNDATED" canary production
python3 - "$UNDATED" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1])); del doc["not_after"]
json.dump(doc, open(sys.argv[1], "w"))
PY
expect_fail "authorization requires a deadline" \
    python3 "$ROOT/qualification/authorization.py" --file "$UNDATED" --profile canary \
        --device ER-X-TEST --test-id R1-guard-only
SOON="$TMP/soon.json"
SOON_TS=$(date -u -d '+60 seconds' +%Y-%m-%dT%H:%M:%SZ)
write_auth "$SOON" canary production "{\"not_after\": \"$SOON_TS\"}"
expect_fail "authorization rejects a deadline shorter than the run" \
    python3 "$ROOT/qualification/authorization.py" --file "$SOON" --profile canary \
        --device ER-X-TEST --test-id R1-guard-only

for duration in 0 3601; do
    dfile="$TMP/duration-$duration.json"
    write_auth "$dfile" canary production "{\"max_duration_seconds\": $duration}"
    expect_fail "authorization rejects duration $duration" \
        python3 "$ROOT/qualification/authorization.py" --file "$dfile" --profile canary \
            --device ER-X-TEST --test-id R1-guard-only
done

EMPTY="$TMP/empty.json"
write_auth "$EMPTY" canary production '{"approved_mutation_scope": "  ", "recovery": ""}'
expect_fail "authorization rejects an empty scope/recovery" \
    python3 "$ROOT/qualification/authorization.py" --file "$EMPTY" --profile canary \
        --device ER-X-TEST --test-id R1-guard-only

CLASS="$TMP/class.json"
write_auth "$CLASS" canary isolated
expect_fail "authorization rejects a target-class mismatch" \
    python3 "$ROOT/qualification/authorization.py" --file "$CLASS" --profile canary \
        --device ER-X-TEST --test-id R1-guard-only

NO_HASH="$TMP/no-hash.json"
write_auth "$NO_HASH" isolated isolated
expect_fail "isolated authorization requires an artifact hash" \
    python3 "$ROOT/qualification/authorization.py" --file "$NO_HASH" --profile isolated \
        --device ER-X-TEST

HASHED="$TMP/hashed.json"
write_auth "$HASHED" canary production '{"artifact_sha256": "0000000000000000000000000000000000000000000000000000000000000000"}'
expect_fail "authorization rejects an artifact hash mismatch" \
    python3 "$ROOT/qualification/authorization.py" --file "$HASHED" --profile canary \
        --device ER-X-TEST --test-id R1-guard-only --artifact "$ARTIFACT"

# A fake router that answers identity and accepts read-only snapshots, nothing more.
cat >"$TMP/bin/ssh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >>"\$FAKE_SSH_LOG"
case "\$*" in
    *"uname -r"*) printf '%s\n' 'EdgeRouter.ER-e50.v3.0.1.5862409.test' '4.14.54-UBNT' '$DEV_MODEL' '$DEV_MAC'; exit 0 ;;
    *) exit 0 ;;
esac
SH
chmod +x "$TMP/bin/ssh"
: >"$FAKE_SSH_LOG"

CLEANUP_MARK="$TMP/cleanup-ran"
SADR_QUAL_CANARY_CMD="bash $ADAPTER" \
SADR_QUAL_CLEANUP_CMD="touch $CLEANUP_MARK" \
SADR_QUAL_VERIFY_CMD="true" \
    bash "$ROOT/qualification/profile.sh" --profile canary --execute --authorize --out "$TMP/canary" \
        --router admin@router.invalid --device-id ER-X-TEST --authorization "$AUTH" \
        --test-id R1-guard-only "${CANARY_ARGS[@]}" >/dev/null
python3 - "$TMP/canary/results.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["summary"]["complete"] is True, d["summary"]
ids={s["id"] for s in d["steps"]}
assert {"preflight","independent-management","backup","canary","cleanup"} <= ids, sorted(ids)
print("PASS: an authorized canary runs and records complete evidence")
PY
if [ ! -e "$CLEANUP_MARK" ]; then
    echo "FAIL: authorized cleanup did not run" >&2
    exit 1
fi
echo "PASS: authorized cleanup runs after the canary"

# A failed canary evidence object must fail the run while still cleaning up.
rm -f "$CLEANUP_MARK"
if SADR_QUAL_CANARY_CMD="bash $ADAPTER fail" SADR_QUAL_CLEANUP_CMD="touch $CLEANUP_MARK" \
    SADR_QUAL_VERIFY_CMD="true" \
    bash "$ROOT/qualification/profile.sh" --profile canary --execute --authorize --out "$TMP/badcanary" \
        --router admin@router.invalid --device-id ER-X-TEST --authorization "$AUTH" \
        --test-id R1-guard-only "${CANARY_ARGS[@]}" >/dev/null 2>&1; then
    echo "FAIL: a failed canary evidence object exited zero" >&2
    exit 1
fi
if [ ! -e "$CLEANUP_MARK" ]; then
    echo "FAIL: cleanup did not run after a failed canary" >&2
    exit 1
fi
echo "PASS: a failed canary exits non-zero and still cleans up"

# Cleanup verification failure is a recovery failure, not a pass.
rm -f "$CLEANUP_MARK"
if SADR_QUAL_CANARY_CMD="bash $ADAPTER" SADR_QUAL_CLEANUP_CMD="touch $CLEANUP_MARK" \
    SADR_QUAL_VERIFY_CMD="false" \
    bash "$ROOT/qualification/profile.sh" --profile canary --execute --authorize --out "$TMP/verifyfail" \
        --router admin@router.invalid --device-id ER-X-TEST --authorization "$AUTH" \
        --test-id R1-guard-only "${CANARY_ARGS[@]}" >/dev/null 2>&1; then
    echo "FAIL: a failed cleanup verification exited zero" >&2
    exit 1
fi
python3 - "$TMP/verifyfail/results.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
cleanup={s["id"]:s for s in d["steps"]}["cleanup"]
assert cleanup["status"]=="fail" and "recovery failure" in cleanup["detail"], cleanup
print("PASS: a failed cleanup verification is reported as a recovery failure")
PY

# Missing verification must block before mutation.
if SADR_QUAL_CANARY_CMD="bash $ADAPTER" SADR_QUAL_CLEANUP_CMD="touch $CLEANUP_MARK" \
    bash "$ROOT/qualification/profile.sh" --profile canary --execute --authorize --out "$TMP/noverify" \
        --router admin@router.invalid --device-id ER-X-TEST --authorization "$AUTH" \
        --test-id R1-guard-only "${CANARY_ARGS[@]}" >/dev/null 2>&1; then
    echo "FAIL: a canary without a verification command exited zero" >&2
    exit 1
fi
echo "PASS: missing cleanup verification blocks the run"

# Interrupting the orchestration session must trigger the authorized cleanup.
rm -f "$CLEANUP_MARK" "$TMP/mutation-started"
set -m # background job gets its own process group so the signal reaches the whole tree
SADR_QUAL_CANARY_CMD="bash $ADAPTER slow $TMP/mutation-started" \
SADR_QUAL_CLEANUP_CMD="touch $CLEANUP_MARK" \
SADR_QUAL_VERIFY_CMD="true" \
    bash "$ROOT/qualification/profile.sh" --profile canary --execute --authorize --out "$TMP/interrupted" \
        --router admin@router.invalid --device-id ER-X-TEST --authorization "$AUTH" \
        --test-id R1-guard-only "${CANARY_ARGS[@]}" >/dev/null 2>&1 &
pid=$!
set +m
for _ in $(seq 1 100); do [ -e "$TMP/mutation-started" ] && break; sleep 0.1; done
if [ ! -e "$TMP/mutation-started" ]; then
    echo "FAIL: canary never started" >&2
    kill -TERM -"$pid" 2>/dev/null || true
    exit 1
fi
kill -TERM -"$pid" 2>/dev/null || true
set +e
wait "$pid"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    echo "FAIL: an interrupted canary exited zero" >&2
    exit 1
fi
if [ ! -e "$CLEANUP_MARK" ]; then
    echo "FAIL: an interrupted canary did not run cleanup" >&2
    exit 1
fi
if [ ! -e "$TMP/interrupted/cleanup.trap.log" ]; then
    echo "FAIL: the interrupt path did not use the trap cleanup" >&2
    exit 1
fi
echo "PASS: an interrupted canary exits non-zero and runs trap cleanup"

# run.sh must refuse an unbound or mismatched artifact before installation.
CONFIG_FILE="$TMP/config.txt"
printf 'set system name sadr-test\n' >"$CONFIG_FILE"
if env -u SADR_QUAL_ARTIFACT_SHA256 SADR_QUAL_ISOLATED=1 \
    bash "$ROOT/qualification/run.sh" --execute --authorize --out "$TMP/runsh-unbound" \
        --router admin@router.invalid --device-id ER-X-TEST --firmware '' \
        --artifact "$ARTIFACT" --config "$CONFIG_FILE" >/dev/null 2>&1; then
    echo "FAIL: run.sh accepted an unbound artifact" >&2
    exit 1
fi
python3 - "$TMP/runsh-unbound/results.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); step={s["id"]:s for s in d["steps"]}["artifact"]
assert step["status"]=="fail" and "not set" in step["detail"], step
PY
echo "PASS: run.sh refuses an unbound artifact"

if SADR_QUAL_ARTIFACT_SHA256="0000000000000000000000000000000000000000000000000000000000000000" \
    SADR_QUAL_ISOLATED=1 \
    bash "$ROOT/qualification/run.sh" --execute --authorize --out "$TMP/runsh-mismatch" \
        --router admin@router.invalid --device-id ER-X-TEST --firmware '' \
        --artifact "$ARTIFACT" --config "$CONFIG_FILE" >/dev/null 2>&1; then
    echo "FAIL: run.sh accepted a mismatched artifact hash" >&2
    exit 1
fi
python3 - "$TMP/runsh-mismatch/results.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); step={s["id"]:s for s in d["steps"]}["artifact"]
assert step["status"]=="fail" and "expected=" in step["detail"], step
PY
echo "PASS: run.sh refuses a mismatched artifact hash"

# A failed observe collection must exit non-zero, not report success.
cat >"$TMP/bin/ssh" <<SH
#!/bin/bash
case "\$*" in
    *"uname -r"*) printf '%s\n' 'EdgeRouter.ER-e50.v3.0.1.5862409.test' '4.14.54-UBNT' '$DEV_MODEL' '$DEV_MAC'; exit 0 ;;
    *) exit 1 ;;
esac
SH
chmod +x "$TMP/bin/ssh"
if bash "$ROOT/qualification/profile.sh" --profile observe --execute \
    --authorize --out "$TMP/observe" --router admin@router.invalid >/dev/null 2>&1; then
    echo "FAIL: a failed observe collection exited zero" >&2
    exit 1
fi
echo "PASS: a failed observe collection exits non-zero"

echo "PASS: profile plans, authorization binding and execution gates"
