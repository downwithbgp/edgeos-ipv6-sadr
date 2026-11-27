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
    SADR_QUAL_NOT_AFTER=2099-01-01T00:00:00Z SADR_QUAL_MAX_DURATION=120 \
    SADR_QUAL_DEVICE_FINGERPRINT="$(printf x | sha256sum | awk '{print $1}')" \
    SADR_QUAL_ADAPTER_SHA256="$1" SADR_QUAL_CLEANUP_PATH="$2" \
    SADR_QUAL_CLEANUP_SHA256="$3" \
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
if [ "$cand_adapter" = "$adapter_sha" ] && [ "$cand_cleanup" = "$cleanup_sha" ]; then
    echo "PASS: authorization candidate hashes match the executable files"; pass=$((pass + 1))
else
    echo "FAIL: authorization candidate hashes drifted from the executable files" >&2
    fail=$((fail + 1))
fi

echo "cleanup tests: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
