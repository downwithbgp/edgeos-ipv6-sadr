#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Off-device tests for the R1 device-local cleanup script and the adapter plan.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP="${TMPDIR:-/tmp}/sadr-cleanup-test.$$"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP"

cat >"$TMP/fake-ip" <<'EOF'
#!/bin/bash
# Minimal `ip -6 rule show|del` emulator over $FAKE_STATE.
state=${FAKE_STATE:?}
case "$*" in
  "-6 rule show")
    if [ "${FAKE_SHOW_MODE:-ok}" = "fail" ]; then exit 2; fi
    cat "$state" 2>/dev/null
    ;;
  "-6 rule add from "*" unreachable pref "*)
    sel=$5; pref=$8
    if [ "${FAKE_ADD_MODE:-ok}" = "fail" ]; then exit 2; fi
    printf '%s:\tfrom %s unreachable\n' "$pref" "$sel" >>"$state"
    ;;
  "-6 rule del from "*" unreachable pref "*)
    pref=$8
    case "${FAKE_DEL_MODE:-ok}" in
      fail) exit 2 ;;
      race) awk -F'\t' -v p="$pref:" '$1 != p' "$state" >"$state.tmp" && mv "$state.tmp" "$state"; exit 2 ;;
      noop) exit 0 ;;
    esac
    before=$(wc -l <"$state")
    awk -F'\t' -v p="$pref:" '$1 != p' "$state" >"$state.tmp" && mv "$state.tmp" "$state"
    after=$(wc -l <"$state")
    [ "$before" -ne "$after" ] || exit 2
    ;;
  *) exit 9 ;;
esac
EOF
chmod +x "$TMP/fake-ip"

pass=0
fail=0
check() { # desc expected-rc expected-state state-lines [del-mode]
    local desc=$1 rc=$2 want=$3 lines=$4 mode=${5:-ok} got state
    printf '%b' "$lines" >"$TMP/state"
    : >"$TMP/log"
    set +e
    SADR_IP_BIN="$TMP/fake-ip" FAKE_STATE="$TMP/state" FAKE_DEL_MODE="$mode" \
        bash "$ROOT/qualification/adapters/r1-cleanup.sh" fd42:901::a1 21031 "$TMP/log"
    got=$?
    set -e
    state=$(cat "$TMP/state")
    if [ "$got" -ne "$rc" ] || [ "$state" != "$want" ]; then
        echo "FAIL: $desc (rc=$got want=$rc state='$state')" >&2
        cat "$TMP/log" >&2 || true
        fail=$((fail + 1))
    else
        echo "PASS: cleanup: $desc"
        pass=$((pass + 1))
    fi
}

check "absent is success" 0 "" ""
check "exact rule is deleted" 0 "" "21031:\tfrom fd42:901::a1 unreachable\n"
check "foreign selector is refused" 3 "21031:	from fd42:999::a1 unreachable" "21031:\tfrom fd42:999::a1 unreachable\n"
check "foreign table rule is refused" 3 "21031:	from fd42:901::a1 lookup 41913" "21031:\tfrom fd42:901::a1 lookup 41913\n"
check "duplicate priority is refused" 3 "21031:	from fd42:901::a1 unreachable
21031:	from fd42:901::a1 unreachable" "21031:\tfrom fd42:901::a1 unreachable\n21031:\tfrom fd42:901::a1 unreachable\n"
check "delete failure is reported" 4 "21031:	from fd42:901::a1 unreachable" "21031:\tfrom fd42:901::a1 unreachable\n" fail
check "concurrent delete is success" 0 "" "21031:\tfrom fd42:901::a1 unreachable\n" race
check "unverified delete is reported" 5 "21031:	from fd42:901::a1 unreachable" "21031:\tfrom fd42:901::a1 unreachable\n" noop

# An unreadable rule table must not look like an absent rule.
printf '21031:\tfrom fd42:901::a1 unreachable\n' >"$TMP/state"
: >"$TMP/log"
set +e
SADR_IP_BIN="$TMP/fake-ip" FAKE_STATE="$TMP/state" FAKE_SHOW_MODE=fail \
    bash "$ROOT/qualification/adapters/r1-cleanup.sh" fd42:901::a1 21031 "$TMP/log"
rc=$?
set -e
if [ "$rc" -eq 5 ] && grep -q 'rule show failed' "$TMP/log"; then
    echo "PASS: cleanup: unreadable rule table is a failure, not absent"
    pass=$((pass + 1))
else
    echo "FAIL: cleanup treated an unreadable rule table as absent (rc=$rc)" >&2
    fail=$((fail + 1))
fi

# The adapter plan must render without contacting anything.
if bash "$ROOT/qualification/adapters/r1-canary.sh" --plan --out "$TMP/plan" >"$TMP/plan.txt" 2>&1; then
    if grep -q "fd42:901::a1" "$TMP/plan.txt" && grep -q "21031" "$TMP/plan.txt"; then
        echo "PASS: adapter plan renders the selector and priority"
        pass=$((pass + 1))
    else
        echo "FAIL: adapter plan is missing the selector or priority" >&2
        fail=$((fail + 1))
    fi
else
    echo "FAIL: adapter plan exited non-zero" >&2
    fail=$((fail + 1))
fi

# The adapter must refuse a mismatched adapter or cleanup hash before contact.
adapter="$ROOT/qualification/adapters/r1-canary.sh"
cleanup="$ROOT/qualification/adapters/r1-cleanup.sh"
adapter_sha=$(sha256sum "$adapter" | awk '{print $1}')
cleanup_sha=$(sha256sum "$cleanup" | awk '{print $1}')
run_adapter_reject() { # adapter-sha cleanup-path cleanup-sha
    SADR_QUAL_ROUTER=admin@router.invalid SADR_QUAL_TEST_ID=R1-guard-only \
    SADR_QUAL_APPROVED_SCOPE='one exact terminal rule: from fd42:901::a1/128 unreachable pref 21031' \
    SADR_QUAL_NOT_AFTER=2099-01-01T00:00:00Z SADR_QUAL_MAX_DURATION=120 \
    SADR_QUAL_DEVICE_FINGERPRINT="$(printf x | sha256sum | awk '{print $1}')" \
    SADR_QUAL_ADAPTER_SHA256="$1" SADR_QUAL_CLEANUP_PATH="$2" \
    SADR_QUAL_CLEANUP_SHA256="$3" \
    SADR_QUAL_INSTALL_PATH="$ROOT/qualification/adapters/r1-install.sh" \
    SADR_QUAL_INSTALL_SHA256="$(sha256sum "$ROOT/qualification/adapters/r1-install.sh" | awk '{print $1}')" \
        bash "$adapter" --execute --out "$TMP/reject" 2>&1 || true
}
out=$(run_adapter_reject "$(printf y | sha256sum | awk '{print $1}')" "$cleanup" "$cleanup_sha")
case "$out" in
    *"adapter hash mismatch"*) echo "PASS: adapter refuses a mismatched adapter hash"; pass=$((pass + 1)) ;;
    *) echo "FAIL: adapter did not report the adapter hash mismatch: $out" >&2; fail=$((fail + 1)) ;;
esac
out=$(run_adapter_reject "$adapter_sha" "$cleanup" "$(printf z | sha256sum | awk '{print $1}')")
case "$out" in
    *"cleanup hash mismatch"*) echo "PASS: adapter refuses a mismatched cleanup hash"; pass=$((pass + 1)) ;;
    *) echo "FAIL: adapter did not report the cleanup hash mismatch: $out" >&2; fail=$((fail + 1)) ;;
esac

# The committed candidate must stay in step with the executable files.
candidate="$ROOT/docs/r1-authorization-candidate.json"
cand_adapter=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["adapter_sha256"])' "$candidate")
cand_cleanup=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cleanup_sha256"])' "$candidate")
install="$ROOT/qualification/adapters/r1-install.sh"
install_sha=$(sha256sum "$install" | awk '{print $1}')
cand_install=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["install_sha256"])' "$candidate")
manifest="$ROOT/docs/r1-execution-manifest.json"
cand_manifest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["execution_manifest_sha256"])' "$candidate")
manifest_sha=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest_sha256"])' "$manifest")
if [ "$cand_adapter" = "$adapter_sha" ] && [ "$cand_cleanup" = "$cleanup_sha" ] && \
    [ "$cand_install" = "$install_sha" ] && [ "$cand_manifest" = "$manifest_sha" ]; then
    echo "PASS: authorization candidate is bound to the executable files and manifest"; pass=$((pass + 1))
else
    echo "FAIL: authorization candidate hashes or manifest binding drifted" >&2
    fail=$((fail + 1))
fi

# Device-local install/cleanup coordination: deadline, closed window, repeat.
now=$(date -u +%s)
RUNDIR="$TMP/rundir"
mkdir -p "$RUNDIR"
: >"$RUNDIR/cleanup.log"
: >"$TMP/state"
set +e
SADR_IP_BIN="$TMP/fake-ip" FAKE_STATE="$TMP/state" \
    bash "$ROOT/qualification/adapters/r1-install.sh" fd42:901::a1 21031 $((now + 60)) "$RUNDIR"
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q '^21031:' "$TMP/state"; then
    echo "PASS: install adds the exact rule before the deadline"; pass=$((pass + 1))
else
    echo "FAIL: install did not add the rule (rc=$rc)" >&2; fail=$((fail + 1))
fi
set +e
SADR_IP_BIN="$TMP/fake-ip" FAKE_STATE="$TMP/state" \
    bash "$ROOT/qualification/adapters/r1-cleanup.sh" fd42:901::a1 21031 "$RUNDIR/cleanup.log" "$RUNDIR"
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ ! -s "$TMP/state" ] && [ -e "$RUNDIR/closed" ]; then
    echo "PASS: cleanup deletes the rule and closes the window"; pass=$((pass + 1))
else
    echo "FAIL: cleanup did not close/delete (rc=$rc)" >&2; fail=$((fail + 1))
fi
set +e
SADR_IP_BIN="$TMP/fake-ip" FAKE_STATE="$TMP/state" \
    bash "$ROOT/qualification/adapters/r1-install.sh" fd42:901::a1 21031 $((now + 60)) "$RUNDIR"
rc=$?
set -e
if [ "$rc" -eq 4 ] && [ ! -s "$TMP/state" ]; then
    echo "PASS: install refuses after the window closed"; pass=$((pass + 1))
else
    echo "FAIL: install was not refused after close (rc=$rc)" >&2; fail=$((fail + 1))
fi
RUNDIR2="$TMP/rundir2"
mkdir -p "$RUNDIR2"; : >"$RUNDIR2/cleanup.log"; : >"$TMP/state"
set +e
SADR_IP_BIN="$TMP/fake-ip" FAKE_STATE="$TMP/state" \
    bash "$ROOT/qualification/adapters/r1-install.sh" fd42:901::a1 21031 $((now - 10)) "$RUNDIR2"
rc=$?
set -e
if [ "$rc" -eq 5 ] && [ ! -s "$TMP/state" ]; then
    echo "PASS: install refuses after the device deadline"; pass=$((pass + 1))
else
    echo "FAIL: install was not refused after the deadline (rc=$rc)" >&2; fail=$((fail + 1))
fi
set +e
SADR_IP_BIN="$TMP/fake-ip" FAKE_STATE="$TMP/state" \
    bash "$ROOT/qualification/adapters/r1-cleanup.sh" fd42:901::a1 21031 "$RUNDIR2/cleanup.log" "$RUNDIR2"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    echo "PASS: repeated cleanup is idempotent"; pass=$((pass + 1))
else
    echo "FAIL: repeated cleanup failed (rc=$rc)" >&2; fail=$((fail + 1))
fi
RUNDIR3="$TMP/rundir3"
mkdir -p "$RUNDIR3"; : >"$RUNDIR3/cleanup.log"; : >"$TMP/state"
set +e
SADR_IP_BIN="$TMP/fake-ip" FAKE_STATE="$TMP/state" FAKE_ADD_MODE=fail \
    bash "$ROOT/qualification/adapters/r1-install.sh" fd42:901::a1 21031 $((now + 60)) "$RUNDIR3"
rc=$?
set -e
if [ "$rc" -eq 6 ] && [ ! -s "$TMP/state" ]; then
    echo "PASS: install partial failure is reported"; pass=$((pass + 1))
else
    echo "FAIL: install partial failure was not reported (rc=$rc)" >&2; fail=$((fail + 1))
fi

echo "cleanup tests: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
