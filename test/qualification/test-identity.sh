#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Regression tests for the shared framed identity acquisition/parsing.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP="${TMPDIR:-/tmp}/sadr-identity-test.$$"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
# shellcheck source=/dev/null
. "$ROOT/qualification/lib/identity.sh"

PASS=0
FAIL=0
ok() { echo "PASS: identity: $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: identity: $*" >&2; FAIL=$((FAIL + 1)); }

MODEL="Ubiquiti EdgeRouter ER-X-TEST"
MAC="aa:bb:cc:dd:ee:ff"
FP=$(printf '%s\n%s\n' "$MODEL" "$MAC" | sha256sum | awk '{print $1}')
FRAME="__SADR_ID_BEGIN__ 1
version=EdgeRouter.ER-e50.v3.0.1.5862409.test
kernel=4.14.54-UBNT
model=$MODEL
mac=$MAC
__SADR_ID_END__ 1"

parse_case() { # desc expected-rc input
    local desc=$1 want=$2 input=$3 rc=0
    set +e
    sadr_identity_parse <<<"$input"
    rc=$?
    set -e
    if [ "$rc" -eq "$want" ]; then ok "$desc (rc=$rc)"; else bad "$desc (rc=$rc want=$want)"; fi
}
parse_case "normal framed response" 0 "$FRAME"
parse_case "EdgeOS banner before and after the frame" 0 "Welcome to EdgeOS
$(printf '%s\n' "$FRAME")
Goodbye"
parse_case "unexpected whitespace and blank lines" 0 "  __SADR_ID_BEGIN__ 1
version=EdgeRouter.ER-e50.v3.0.1.5862409.test
 kernel=4.14.54-UBNT 
model=$MODEL
mac=$MAC
__SADR_ID_END__ 1  "
parse_case "duplicate frame markers" 4 "$FRAME
$FRAME"
parse_case "duplicate field" 2 "__SADR_ID_BEGIN__ 1
version=a
version=b
kernel=4.14.54-UBNT
model=$MODEL
mac=$MAC
__SADR_ID_END__ 1"
parse_case "missing field" 5 "__SADR_ID_BEGIN__ 1
version=a
kernel=4.14.54-UBNT
model=$MODEL
__SADR_ID_END__ 1"
parse_case "truncated response" 4 "__SADR_ID_BEGIN__ 1
version=a
kernel=4.14.54-UBNT
model=$MODEL
mac=$MAC"
parse_case "unexpected field inside the frame" 3 "__SADR_ID_BEGIN__ 1
version=a
kernel=b
model=c
mac=$MAC
extra=d
__SADR_ID_END__ 1"

set +e
sadr_identity_parse <<<"$FRAME" >/dev/null
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ "$SADR_ID_FINGERPRINT" = "$FP" ]; then
    ok "fingerprint contract"
else
    bad "fingerprint contract (rc=$rc fp=$SADR_ID_FINGERPRINT)"
fi

# Acquisition: fake ssh with exit status and banner.
cat >"$TMP/bin/ssh" <<SH
#!/bin/bash
case "\${FAKE_SSH_MODE:-ok}" in
    fail) exit 255 ;;
    banner) printf '%s\n' 'Welcome to EdgeOS'; printf '%s\n' '$FRAME'; exit 0 ;;
    *) printf '%s\n' '$FRAME'; exit 0 ;;
esac
SH
chmod +x "$TMP/bin/ssh"
export PATH="$TMP/bin:$PATH"
# shellcheck disable=SC2034 # read by the sourced helper
SADR_SSH_OPTS=(-o BatchMode=yes)
# shellcheck disable=SC2034 # read by the sourced helper
SADR_SSH_KEY=""
if sadr_identity_acquire admin@router.invalid && [ "$SADR_ID_VERSION" = "EdgeRouter.ER-e50.v3.0.1.5862409.test" ]; then
    ok "acquisition with the normal response"
else
    bad "acquisition with the normal response"
fi
if FAKE_SSH_MODE=banner sadr_identity_acquire admin@router.invalid; then
    ok "acquisition tolerates a login banner"
else
    bad "acquisition did not tolerate a login banner"
fi
if FAKE_SSH_MODE=fail sadr_identity_acquire admin@router.invalid; then
    bad "acquisition accepted an SSH transport failure"
else
    ok "acquisition fails closed on SSH transport failure"
fi
if sadr_identity_acquire admin@router.invalid && sadr_identity_validate "" "4.14.54-UBNT" "$FP" "ER-X-TEST"; then
    ok "identity validation passes for the expected device"
else
    bad "identity validation failed for the expected device"
fi
if sadr_identity_acquire admin@router.invalid && sadr_identity_validate "" "4.14.54-UBNT" "0000000000000000000000000000000000000000000000000000000000000000" ""; then
    bad "identity validation accepted a fingerprint mismatch"
else
    ok "identity validation rejects a fingerprint mismatch"
fi

echo "identity tests: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
