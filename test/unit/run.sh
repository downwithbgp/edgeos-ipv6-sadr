#!/bin/bash
# Unprivileged unit checks. These run on any developer machine.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CHECK="$ROOT/test/unit/check-doc-addresses.pl"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/sadr-unit.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

echo "== documentation address hygiene =="
perl "$CHECK" "$ROOT"

echo "== address-hygiene self-test: good fixture =="
cat >"$TMP/good.md" <<'EOF'
Source 2001:db8:a000::/56, gateway 2001:db8:aa00::1.
Management 192.0.2.10 and 198.51.100.20.
EOF
perl "$CHECK" "$TMP/good.md" >/dev/null

echo "== address-hygiene self-test: bad IPv6 must fail =="
# The marker is on this source line only; the generated fixture has no marker.
BAD6='2001:4860:4860::8888' # doc-check: ignore-line
printf '%s\n' "$BAD6" >"$TMP/bad6.md"
if perl "$CHECK" "$TMP/bad6.md" >/dev/null 2>&1; then
    echo "FAIL: checker accepted a non-documentation IPv6 literal" >&2
    exit 1
fi

echo "== address-hygiene self-test: bad IPv4 must fail =="
BAD4='8.8.8.8' # doc-check: ignore-line
printf '%s\n' "$BAD4" >"$TMP/bad4.md"
if perl "$CHECK" "$TMP/bad4.md" >/dev/null 2>&1; then
    echo "FAIL: checker accepted a non-documentation IPv4 literal" >&2
    exit 1
fi

echo "ALL UNIT TESTS PASSED"
