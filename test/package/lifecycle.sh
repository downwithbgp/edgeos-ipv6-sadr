#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Exercise package maintainer scripts without root, a router or systemd.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/sadr-package.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

run_expect() { # <desc> <expected-rc> <command...>
    local desc=$1 expected=$2 rc
    shift 2
    set +e
    "$@" >"$TMP/out" 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq "$expected" ]; then
        ok "$desc (rc=$rc)"
    else
        bad "$desc (rc=$rc expected=$expected)"
        sed -n '1,8p' "$TMP/out" >&2 || true
    fi
}

printf 'EdgeRouter.ER-e50.v3.0.1.5862409.abcdef\n' >"$TMP/version-good"
printf 'EdgeRouter.ER-X.v2.0.9.0000000.abcdef\n' >"$TMP/version-bad"

cat >"$TMP/ip" <<'EOF'
#!/bin/sh
case "$*" in
    "-6 rule show")
        if [ "${FAKE_MANAGED_RULE:-0}" = "1" ]; then
            echo "20576: from 2001:db8:a000::/56 lookup 10000"
        fi
        exit 0
        ;;
    "-6 route show table all")
        if [ "${FAKE_MANAGED_ROUTE:-0}" = "1" ]; then
            echo "unreachable 2001:db8::/64 table 10001 proto 194 metric 4096"
        fi
        exit 0
        ;;
    "-6 route show table main")
        exit 0
        ;;
esac
exit 0
EOF
chmod 0755 "$TMP/ip"

PREINST="$ROOT/debian/preinst"
PRERM="$ROOT/debian/prerm"
POSTINST="$ROOT/debian/postinst"
POSTRM="$ROOT/debian/postrm"
COMMON_ENV=(EDGEOS_IPV6_SADR_IP="$TMP/ip" EDGEOS_IPV6_SADR_API="$TMP/no-api")

run_expect "preinst refuses an unsupported firmware" 1 \
    env "${COMMON_ENV[@]}" EDGEOS_IPV6_SADR_VERSION_FILE="$TMP/version-bad" \
    EDGEOS_IPV6_SADR_KERNEL=4.14.54-UBNT "$PREINST" install
run_expect "preinst refuses an unsupported kernel" 1 \
    env "${COMMON_ENV[@]}" EDGEOS_IPV6_SADR_VERSION_FILE="$TMP/version-good" \
    EDGEOS_IPV6_SADR_KERNEL=5.10.0-generic "$PREINST" install
run_expect "preinst refuses a missing firmware file" 1 \
    env "${COMMON_ENV[@]}" EDGEOS_IPV6_SADR_VERSION_FILE="$TMP/missing" \
    EDGEOS_IPV6_SADR_KERNEL=4.14.54-UBNT "$PREINST" install
run_expect "preinst accepts the supported platform" 0 \
    env "${COMMON_ENV[@]}" EDGEOS_IPV6_SADR_VERSION_FILE="$TMP/version-good" \
    EDGEOS_IPV6_SADR_KERNEL=4.14.54-UBNT "$PREINST" install
run_expect "preinst test escape hatch is explicit" 0 \
    env EDGEOS_IPV6_SADR_SKIP_PLATFORM_CHECK=1 "$PREINST" install

printf 'protocols { ipv6-sadr { policy p { source-prefix 2001:db8::/56 } } }\n' \
    >"$TMP/configured.boot"
: >"$TMP/empty.boot"

run_expect "prerm allows removal without SADR state" 0 \
    env "${COMMON_ENV[@]}" EDGEOS_IPV6_SADR_CONFIG_BOOT="$TMP/empty.boot" "$PRERM" remove
run_expect "prerm refuses saved SADR configuration" 1 \
    env "${COMMON_ENV[@]}" EDGEOS_IPV6_SADR_CONFIG_BOOT="$TMP/configured.boot" "$PRERM" remove
run_expect "prerm refuses live managed rules" 1 \
    env "${COMMON_ENV[@]}" EDGEOS_IPV6_SADR_CONFIG_BOOT="$TMP/empty.boot" \
    FAKE_MANAGED_RULE=1 "$PRERM" remove
run_expect "prerm refuses live owned routes" 1 \
    env "${COMMON_ENV[@]}" EDGEOS_IPV6_SADR_CONFIG_BOOT="$TMP/empty.boot" \
    FAKE_MANAGED_ROUTE=1 "$PRERM" remove
run_expect "prerm allows upgrade with saved configuration" 0 \
    env "${COMMON_ENV[@]}" EDGEOS_IPV6_SADR_CONFIG_BOOT="$TMP/configured.boot" "$PRERM" upgrade

run_expect "postinst configure is safe without systemd" 0 \
    env EDGEOS_IPV6_SADR_SYSTEMCTL=/bin/false "$POSTINST" configure

mkdir -p "$TMP/state"
printf 'state\n' >"$TMP/state/status.json"
run_expect "postrm purge removes runtime state" 0 \
    env EDGEOS_IPV6_SADR_SYSTEMCTL=/bin/false \
    EDGEOS_IPV6_SADR_STATE_DIR="$TMP/state" "$POSTRM" purge
if [ ! -e "$TMP/state" ]; then
    ok "postrm purge leaves no runtime state directory"
else
    bad "postrm purge left the runtime state directory"
fi

echo
if [ "$FAIL" -ne 0 ]; then
    echo "package lifecycle: pass=$PASS fail=$FAIL"
    exit 1
fi
echo "package lifecycle: pass=$PASS fail=0"
