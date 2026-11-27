#!/bin/bash
# Generic-Linux iproute2 operation parity probe.
# This does not emulate EdgeOS or its 4.14 kernel; it verifies the operations
# and text forms the reconciler depends on on the current kernel.
set -euo pipefail

NS=${SADR_PARITY_NS:-sadr-parity-$$}
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
run() { ip netns exec "$NS" "$@"; }
cleanup() {
    ip netns del "$NS" 2>/dev/null || true
}
trap cleanup EXIT

if [ "$(id -u)" -ne 0 ]; then
    echo "SKIP: root/CAP_NET_ADMIN required" >&2
    exit 0
fi
ip netns add "$NS"
run ip link set lo up

# Rule actions, priorities and source selectors.
run ip -6 rule add from 2001:db8:a000::/56 unreachable pref 20582
if run ip -6 rule show | grep -qE '^20582:[[:space:]]+from 2001:db8:a000::/56 unreachable$'; then
    ok "rule add/show: terminal unreachable rule"
else
    bad "rule add/show: terminal unreachable rule"
fi
run ip -6 rule add from 2001:db8:a000::/56 lookup 10001 pref 20576
if run ip -6 rule show | grep -qE '^20576:[[:space:]]+from 2001:db8:a000::/56 lookup 10001$'; then
    ok "rule add/show: source lookup with explicit priority"
else
    bad "rule add/show: source lookup with explicit priority"
fi

# Route protocol marker, metric, table selection and unreachable routes.
run ip -6 route replace unreachable 2001:db8::/64 table 10001 metric 4096 proto 194
run ip -6 route replace 2001:db8:aa00::/64 dev lo table 10001 metric 1024 proto 194
table=$(run ip -6 route show table 10001)
if printf '%s\n' "$table" | grep -qE '^unreachable 2001:db8::/64 .*proto 194 .*metric 4096'; then
    ok "route show table: unreachable prefix, proto 194, metric"
else
    bad "route show table: unreachable prefix, proto 194, metric"
fi
if printf '%s\n' "$table" | grep -qE '^2001:db8:aa00::/64 dev lo proto 194'; then
    ok "route show table: unicast prefix and protocol marker"
else
    bad "route show table: unicast prefix and protocol marker"
fi
if run ip -6 route show exact 2001:db8:aa00::/64 table 10001 | grep -q '2001:db8:aa00::/64'; then
    ok "route show exact: exact prefix lookup"
else
    bad "route show exact: exact prefix lookup"
fi

# Missing FIB table is a distinct, recognizable condition.
set +e
missing=$(run ip -6 route show table 19999 2>&1)
missing_rc=$?
set -e
if [ "$missing_rc" -ne 0 ] && printf '%s\n' "$missing" | grep -q 'FIB table does not exist'; then
    ok "route show table: missing-table error is distinguishable"
else
    bad "route show table: missing-table error is distinguishable (rc=$missing_rc)"
fi

# Link JSON used only for attributes.
if run ip -j -d link show lo | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[0]["ifname"] == "lo"'; then
    ok "link JSON: ifname is machine-readable"
else
    bad "link JSON: ifname is machine-readable"
fi

# Ownership cleanup operations.
run ip -6 rule del from 2001:db8:a000::/56 unreachable pref 20582
run ip -6 rule del from 2001:db8:a000::/56 lookup 10001 pref 20576
run ip -6 route del unreachable 2001:db8::/64 table 10001 metric 4096 proto 194
run ip -6 route del 2001:db8:aa00::/64 dev lo table 10001 metric 1024 proto 194
if ! run ip -6 rule show | grep -qE '^(20576|20582):'; then
    ok "rule deletion removes managed selectors"
else
    bad "rule deletion removes managed selectors"
fi
if ! run ip -6 route show table 10001 | grep -q 'proto 194'; then
    ok "route deletion removes managed routes"
else
    bad "route deletion removes managed routes"
fi

echo
if [ "$FAIL" -ne 0 ]; then
    echo "iproute2 parity: pass=$PASS fail=$FAIL"
    exit 1
fi
echo "iproute2 parity: pass=$PASS fail=0"
