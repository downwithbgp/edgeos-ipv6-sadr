#!/bin/bash
# shellcheck shell=bash
# Production reconciler phase, sourced by netns-sadr.sh.
#
# Generic-Linux evidence only. The config API is a local JSON fixture; the
# kernel, RPDB, tables, rules, interfaces and packet paths are real.
# shellcheck disable=SC2154

PROD_STATE="$CAP/prod-state"
PROD_CONFIG="$CAP/prod-config.json"
PROD_BOOT="$CAP/prod-config.boot"
PROD_MON_PID=""

prod_run() {
    run er env \
        PERL5LIB="$ROOT/src/lib" \
        IPV6_SADR_API="$ROOT/test/unit/fake/fake_api.py" \
        IPV6_SADR_IP=ip \
        IPV6_SADR_STATE_DIR="$PROD_STATE" \
        IPV6_SADR_NO_SUDO=1 \
        FAKE_CONFIG="$PROD_CONFIG" \
        perl "$ROOT/src/vyatta-ipv6-sadr" "$@"
}

prod_reconcile_expect() { # prod_reconcile_expect <desc> [expected-rc]
    local desc=$1 expected=${2:-0} rc
    if prod_run reconcile-working >"$CAP/prod-reconcile.log" 2>&1; then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -eq "$expected" ]; then
        ok "$desc (rc=$rc)"
    else
        bad "$desc (rc=$rc expected=$expected)"
        sed -n '1,12p' "$CAP/prod-reconcile.log" >&2 || true
    fi
}

prod_write_config() {
    cat >"$PROD_CONFIG" <<EOF
{
  "protocols": {
    "ipv6-sadr": {
      "internal-interface": ["er_ir", "er_cl"],
      "destination-exception": ["$INT_CFG"],
      "policy": {
        "provider-a": {
          "source-prefix": ["$PA_PFX"],
          "next-hop": "$PA_NH",
          "interface": "er_pa",
          "table": "10001"
        },
        "provider-b": {
          "source-prefix": ["$PB_PFX"],
          "next-hop": "$PB_NH",
          "interface": "er_pb",
          "table": "10002"
        },
        "provider-a64": {
          "source-prefix": ["$PA64_PFX"],
          "interface": "er_pa",
          "table": "10003",
          "disable": ""
        }
      }
    }
  }
}
EOF
}

prod_write_boot_config() {
    cat >"$PROD_BOOT" <<EOF
protocols {
    ipv6-sadr {
        policy provider-a {
            source-prefix $PA_PFX
        }
        policy provider-b {
            source-prefix $PB_PFX
        }
        policy provider-a64 {
            source-prefix $PA64_PFX
        }
    }
}
EOF
}

prod_config_disable_a() {
    python3 - "$PROD_CONFIG" <<'PY'
import json
import sys
path = sys.argv[1]
cfg = json.load(open(path))
cfg["protocols"]["ipv6-sadr"]["policy"]["provider-a"]["disable"] = ""
json.dump(cfg, open(path, "w"), indent=2)
PY
}

prod_config_remove_b() {
    python3 - "$PROD_CONFIG" <<'PY'
import json
import sys
path = sys.argv[1]
cfg = json.load(open(path))
del cfg["protocols"]["ipv6-sadr"]["policy"]["provider-b"]
json.dump(cfg, open(path, "w"), indent=2)
PY
}

prod_config_add_pb64() {
    python3 - "$PROD_CONFIG" <<'PY'
import json
import sys
path = sys.argv[1]
prefix = "2001:db8:b000:2::/64"
cfg = json.load(open(path))
policy = cfg["protocols"]["ipv6-sadr"]["policy"]["provider-b"]
sources = policy.setdefault("source-prefix", [])
if prefix not in sources:
    sources.append(prefix)
json.dump(cfg, open(path, "w"), indent=2)
PY
}

prod_rule_present() { # prod_rule_present <src> <lookup|unreachable> <table-or-empty> <pref>
    local src=$1 action=$2 table=$3 pref=$4
    if [ "$action" = "lookup" ]; then
        run er ip -6 rule show \
            | grep -E "^${pref}:[[:space:]]+from ${src} lookup ${table}[[:space:]]*$" >/dev/null 2>&1
    else
        run er ip -6 rule show \
            | grep -E "^${pref}:[[:space:]]+from ${src} unreachable[[:space:]]*$" >/dev/null 2>&1
    fi
}

prod_rule_expect() { # prod_rule_expect <desc> <src> <lookup|unreachable> <table-or-empty> <pref>
    local desc=$1
    shift
    if prod_rule_present "$@"; then
        ok "$desc"
    else
        bad "$desc"
    fi
}

prod_rule_absent() { # prod_rule_absent <desc> <src> <lookup|unreachable> <table-or-empty> <pref>
    local desc=$1
    shift
    if prod_rule_present "$@"; then
        bad "$desc"
    else
        ok "$desc"
    fi
}

prod_health_state() {
    if prod_run status --json >"$CAP/prod-health.json" 2>"$CAP/prod-health.err"; then
        :
    fi
    python3 - "$CAP/prod-health.json" <<'PY'
import json
import sys
try:
    print(json.load(open(sys.argv[1])).get("state", "invalid"))
except Exception:
    print("invalid")
PY
}

prod_health_expect() { # <desc> <expected-state>
    local desc=$1 expected=$2 actual
    actual=$(prod_health_state)
    if [ "$actual" = "$expected" ]; then
        ok "$desc (state=$actual)"
    else
        bad "$desc (state=$actual expected=$expected)"
    fi
}

prod_policy_state() { # <policy-name>
    python3 - "$CAP/prod-health.json" "$1" <<'PY'
import json
import sys
try:
    data = json.load(open(sys.argv[1]))
    for policy in data.get("policies", []):
        if policy.get("name") == sys.argv[2]:
            print(policy.get("state", "missing"))
            break
    else:
        print("absent")
except Exception:
    print("invalid")
PY
}

prod_cleanup_poc() {
    for table in 10000 10001 10002 10003 11001 11002; do
        run er ip -6 route flush table "$table" 2>/dev/null || true
    done
    if run er ip -6 rule show | grep -qE '^(2[0-9]{4}):'; then
        bad "production precheck: managed-range rules remain"
    else
        ok "production precheck: no managed-range rules remain"
    fi
    if run er ip -6 route show | grep -qE ' from 2001:db8:(a000|b000)::/56 '; then
        bad "production precheck: source-specific FIB routes remain"
    else
        ok "production precheck: no source-specific FIB routes remain"
    fi
    rm -rf "$PROD_STATE"
}

prod_flow_test() { # <desc> <client-mode> <port>
    local desc=$1 mode=$2 port=$3
    local pa="$CAP/prod-flow-pa-$mode.pcap"
    local pb="$CAP/prod-flow-pb-$mode.pcap"
    local pa_pid pb_pid flow_pid flow_rc pa_n pb_n
    rm -f "$pa" "$pb"
    cap_start pa pa_er "$pa" || return 0
    pa_pid=$CAP_PID
    cap_start pb pb_er "$pb" || { cap_stop "$pa_pid"; return 0; }
    pb_pid=$CAP_PID
    run cl python3 "$ECHO" "$mode" "$PA56_SRC" "$EXT_A_HOST" "$port" 8 0.35 \
        >"$CAP/prod-flow-$mode.log" 2>&1 &
    flow_pid=$!
    sleep 0.5
    prod_config_add_pb64
    prod_reconcile_expect "flow: concurrent provider-b update reconciles"
    if wait "$flow_pid"; then
        flow_rc=0
    else
        flow_rc=$?
    fi
    sleep "$CAP_DRAIN"
    cap_stop "$pa_pid"
    cap_stop "$pb_pid"
    pa_n=$(cap_count "$pa" "$PA56_SRC" "$EXT_A_HOST")
    pb_n=$(cap_count "$pb" "$PA56_SRC" "$EXT_A_HOST")
    if [ "$flow_rc" -eq 0 ] && grep -q stream-ok "$CAP/prod-flow-$mode.log" \
        && [ "$pa_n" -gt 0 ] && [ "$pb_n" -eq 0 ]; then
        ok "$desc (pa=$pa_n pb=$pb_n)"
    else
        bad "$desc (rc=$flow_rc pa=$pa_n pb=$pb_n)"
    fi
}

prod_monitor_start() {
    run er env \
        PERL5LIB="$ROOT/src/lib" \
        IPV6_SADR_API="$ROOT/test/unit/fake/fake_api.py" \
        IPV6_SADR_IP=ip \
        IPV6_SADR_STATE_DIR="$PROD_STATE" \
        IPV6_SADR_NO_SUDO=1 \
        FAKE_CONFIG="$PROD_CONFIG" \
        perl "$ROOT/src/vyatta-ipv6-sadr" monitor --resync 2 \
        >"$CAP/prod-monitor.log" 2>&1 &
    PROD_MON_PID=$!
    PIDS+=("$PROD_MON_PID")
    sleep 1.5
}

prod_monitor_stop() {
    [ -n "$PROD_MON_PID" ] || return 0
    kill "$PROD_MON_PID" 2>/dev/null || true
    wait "$PROD_MON_PID" 2>/dev/null || true
    PROD_MON_PID=""
}

prod_wait_table() { # <table> <substring>
    local table=$1 needle=$2
    for _ in $(seq 1 20); do
        if table_has "$table" "$needle"; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# ---------------------------------------------------------------- production
say "=== production reconciler (generic Linux) ==="
prod_cleanup_poc
prod_write_config
prod_write_boot_config

if prod_run boot-guard --config "$PROD_BOOT" >"$CAP/prod-boot.log" 2>&1; then
    ok "production boot guard installs terminal guards"
else
    bad "production boot guard failed"
    sed -n '1,12p' "$CAP/prod-boot.log" >&2 || true
fi
prod_rule_expect "production boot guard: PA /56 terminal guard" "$PA_PFX" unreachable "" 20582
prod_rule_expect "production boot guard: PB /56 terminal guard" "$PB_PFX" unreachable "" 20582
prod_rule_expect "production boot guard: PA /64 terminal guard" "$PA64_PFX" unreachable "" 20518
probe "production boot guard: PA source is blocked before reconcile" cl "$PA56_SRC" "$EXT_A_HOST" 0 0 0 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_A_HOST"
probe "production boot guard: internal traffic is blocked too" cl "$PA56_SRC" "$INT_CONNECTED_HOST" 0 0 0 0 0 \
    ping6 cl "$PA56_SRC" "$INT_CONNECTED_HOST"

prod_reconcile_expect "production initial reconciliation is effective"
prod_rule_expect "production: PA internal lookup" "$PA_PFX" lookup 10000 20576
prod_rule_expect "production: PA provider lookup" "$PA_PFX" lookup 10001 20577
prod_rule_expect "production: PB internal lookup" "$PB_PFX" lookup 10000 20576
prod_rule_expect "production: PB provider lookup" "$PB_PFX" lookup 10002 20577
prod_rule_expect "production: PA64 internal lookup" "$PA64_PFX" lookup 10000 20512
prod_rule_expect "production: PA64 provider lookup" "$PA64_PFX" lookup 10003 20513
prod_rule_expect "production: PA64 terminal guard" "$PA64_PFX" unreachable "" 20518
metric_count=$(run er ip -6 rule show | grep -cE '^(2[0-9]{4}):' || true)
if [ "$metric_count" -eq 9 ]; then
    ok "production: exactly nine managed rules after initial apply"
else
    bad "production: managed rule count is $metric_count (expected 9)"
fi

prod_spec_prefix() { printf '%s' "${1%% *}"; }
# Only kernel-connected routes on an internal interface are mirrored. The PoC's
# manual routes for the client source subnets are deliberately not connected.
PROD_INTERNAL_PREFIXES=(
    "$LAN dev er_cl"
    "$INT_CONNECTED dev er_ir"
    "$INT_CFG via $INT_CONNECTED_HOST dev er_ir"
)
for spec in "${PROD_INTERNAL_PREFIXES[@]}"; do
    prefix=$(prod_spec_prefix "$spec")
    if table_has_real 10000 "$prefix" && table_has 10000 "unreachable $prefix"; then
        ok "production: internal route and guard for $prefix"
    else
        bad "production: internal route/guard missing for $prefix"
    fi
done
if table_has_real 10000 "2001:db8:a000:1::/64"; then
    bad "production: non-connected manual route was mirrored"
else
    ok "production: non-connected manual route is not trusted"
fi
if table_has 10001 "default via $PA_NH" && table_has 10001 "unreachable default"; then
    ok "production: provider-a route and table guard"
else
    bad "production: provider-a route/guard missing"
fi
if table_has 10002 "default via $PB_NH" && table_has 10002 "unreachable default"; then
    ok "production: provider-b route and table guard"
else
    bad "production: provider-b route/guard missing"
fi
if table_has 10003 "unreachable default" && ! table_has 10003 "default via"; then
    ok "production: disabled PA64 table is guard-only"
else
    bad "production: PA64 table is not guard-only"
fi
if table_has 10001 "unreachable $INT_CONNECTED" \
    && ! table_has_real 10001 "$INT_CONNECTED"; then
    ok "production: provider table guards internal destinations"
else
    bad "production: provider table can route an internal destination"
fi
prod_health_expect "production: health is effective" effective
if [ "$(prod_policy_state provider-a64)" = "disabled" ]; then
    ok "production: PA64 policy is disabled"
else
    bad "production: PA64 policy is not disabled"
fi

probe "production: PA source reaches Internet A" cl "$PA56_SRC" "$EXT_A_HOST" 1 1 999 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_A_HOST"
probe "production: PB source reaches Internet B" cl "$PB_SRC" "$EXT_B_HOST" 1 0 0 1 999 \
    ping6 cl "$PB_SRC" "$EXT_B_HOST"
probe "production: PA source to Internet B does not use PB" cl "$PA56_SRC" "$EXT_B_HOST" 0 0 999 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_B_HOST"
probe "production: PB source to Internet A does not use PA" cl "$PB_SRC" "$EXT_A_HOST" 0 0 0 0 999 \
    ping6 cl "$PB_SRC" "$EXT_A_HOST"
probe "production: PA source reaches configured internal" cl "$PA56_SRC" "$INT_CFG_HOST" 1 0 0 0 0 \
    ping6 cl "$PA56_SRC" "$INT_CFG_HOST"
probe "production: PB source reaches configured internal" cl "$PB_SRC" "$INT_CFG_HOST" 1 0 0 0 0 \
    ping6 cl "$PB_SRC" "$INT_CFG_HOST"
probe "production: nested /64 source reaches connected internal" cl "$PA64_SRC" "$INT_CONNECTED_HOST" 1 0 0 0 0 \
    ping6 cl "$PA64_SRC" "$INT_CONNECTED_HOST"
probe "production: nested /64 source is blocked externally" cl "$PA64_SRC" "$EXT_A_HOST" 0 0 0 0 0 \
    ping6 cl "$PA64_SRC" "$EXT_A_HOST"
probe "production: PA source to PB transfer does not use PB" cl "$PA56_SRC" 2001:db8:bb00::1 0 0 999 0 0 \
    ping6 cl "$PA56_SRC" 2001:db8:bb00::1
probe "production: PB source to PA transfer does not use PA" cl "$PB_SRC" 2001:db8:aa00::1 0 0 0 0 999 \
    ping6 cl "$PB_SRC" 2001:db8:aa00::1
probe "production: PA source UDP to Internet A" cl "$PA56_SRC" "$EXT_A_HOST" 1 1 999 0 0 \
    run cl python3 "$ECHO" client-udp "$PA56_SRC" "$EXT_A_HOST" 9999
probe "production: PB source TCP to Internet B" cl "$PB_SRC" "$EXT_B_HOST" 1 0 0 1 999 \
    run cl python3 "$ECHO" client-tcp "$PB_SRC" "$EXT_B_HOST" 9998

prod_flow_test "production flow: established TCP survives a provider-b update" client-tcp-stream 9998
prod_flow_test "production flow: established UDP survives a provider-b update" client-udp-stream 9999

# Provider route loss is fail-closed, not a fallback to the other provider.
del_table_route 10001 default via "$PA_NH" dev er_pa
probe "production loss: PA source is fail-closed" cl "$PA56_SRC" "$EXT_A_HOST" 0 0 0 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_A_HOST"
probe "production loss: PB source still reaches Internet B" cl "$PB_SRC" "$EXT_B_HOST" 1 0 0 1 999 \
    ping6 cl "$PB_SRC" "$EXT_B_HOST"
prod_reconcile_expect "production loss: reconciliation restores the provider route"
probe "production restore: PA source reaches Internet A" cl "$PA56_SRC" "$EXT_A_HOST" 1 1 999 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_A_HOST"

# Internal route withdrawal leaves the per-prefix guard in place.
del_table_route 10000 "$INT_CFG" via "$INT_CONNECTED_HOST" dev er_ir
del_table_route 10000 "2001:db8:200:2::/64" dev er_ir
probe "production loss: internal destination is blocked" cl "$PA56_SRC" "$INT_CFG_HOST" 0 0 0 0 0 \
    ping6 cl "$PA56_SRC" "$INT_CFG_HOST"
probe "production loss: external traffic is unaffected" cl "$PA56_SRC" "$EXT_A_HOST" 1 1 999 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_A_HOST"
prod_reconcile_expect "production loss: reconciliation restores the internal route"
probe "production restore: internal destination is reachable" cl "$PA56_SRC" "$INT_CFG_HOST" 1 0 0 0 0 \
    ping6 cl "$PA56_SRC" "$INT_CFG_HOST"

# Complete managed-table disappearance is repaired.
run er ip -6 route flush table 10001 2>/dev/null || true
probe "production loss: missing provider table is fail-closed" cl "$PA56_SRC" "$EXT_A_HOST" 0 0 0 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_A_HOST"
prod_reconcile_expect "production loss: missing provider table is recreated"
probe "production restore: provider table path is back" cl "$PA56_SRC" "$EXT_A_HOST" 1 1 999 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_A_HOST"

run er ip -6 route flush table 10000 2>/dev/null || true
probe "production loss: missing internal table blocks internal destinations" cl "$PA56_SRC" "$INT_CFG_HOST" 0 0 0 0 0 \
    ping6 cl "$PA56_SRC" "$INT_CFG_HOST"
probe "production loss: external path survives internal table loss" cl "$PA56_SRC" "$EXT_A_HOST" 1 1 999 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_A_HOST"
prod_reconcile_expect "production loss: internal table is recreated"
probe "production restore: internal table path is back" cl "$PA56_SRC" "$INT_CFG_HOST" 1 0 0 0 0 \
    ping6 cl "$PA56_SRC" "$INT_CFG_HOST"

# Disable keeps internal reachability and the guards while withdrawing egress.
prod_config_disable_a
prod_reconcile_expect "production disable: reconciliation succeeds"
if table_has 10001 "default via"; then
    bad "production disable: provider route remains"
else
    ok "production disable: provider route withdrawn"
fi
probe "production disable: PA external is blocked" cl "$PA56_SRC" "$EXT_A_HOST" 0 0 0 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_A_HOST"
probe "production disable: PA internal remains reachable" cl "$PA56_SRC" "$INT_CONNECTED_HOST" 1 0 0 0 0 \
    ping6 cl "$PA56_SRC" "$INT_CONNECTED_HOST"
prod_health_expect "production disable: overall health remains effective" effective
if [ "$(prod_policy_state provider-a)" = "disabled" ]; then
    ok "production disable: provider-a reports disabled"
else
    bad "production disable: provider-a does not report disabled"
fi
prod_write_config
prod_reconcile_expect "production enable: reconciliation restores provider-a"
probe "production enable: PA external is reachable" cl "$PA56_SRC" "$EXT_A_HOST" 1 1 999 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_A_HOST"

# Foreign state in a managed table is refused and never deleted.
run er ip -6 route add 2001:db8:dead::/64 dev er_pa table 10001 proto 4
prod_reconcile_expect "production ownership: foreign route is refused" 7
if run er ip -6 route show table 10001 | grep -q '2001:db8:dead::/64'; then
    ok "production ownership: foreign route preserved"
else
    bad "production ownership: foreign route was deleted"
fi
run er ip -6 route del 2001:db8:dead::/64 dev er_pa table 10001 2>/dev/null || true
prod_reconcile_expect "production ownership: recovery after removing foreign state"

# Monitor repairs route loss and survives restart.
prod_monitor_start
del_table_route 10001 default via "$PA_NH" dev er_pa
if prod_wait_table 10001 "default via $PA_NH"; then
    ok "production monitor: provider route repaired from events"
else
    bad "production monitor: provider route was not repaired"
fi
probe "production monitor: repaired path forwards" cl "$PA56_SRC" "$EXT_A_HOST" 1 1 999 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_A_HOST"
prod_monitor_stop
del_table_route 10001 default via "$PA_NH" dev er_pa
sleep 2
if table_has 10001 "default via $PA_NH"; then
    bad "production monitor: stopped monitor still repaired state"
else
    ok "production monitor: stopped monitor leaves state unmodified"
fi
prod_monitor_start
if prod_wait_table 10001 "default via $PA_NH"; then
    ok "production monitor: restart repairs provider route"
else
    bad "production monitor: restart did not repair provider route"
fi
prod_monitor_stop

# Removing a policy removes its rules and terminal guard; native routing for
# that source is restored only after the guard is gone.
prod_config_remove_b
prod_reconcile_expect "production delete: provider-b policy removed"
prod_rule_absent "production delete: PB internal lookup removed" "$PB_PFX" lookup 10000 20576
prod_rule_absent "production delete: PB provider lookup removed" "$PB_PFX" lookup 10002 20577
prod_rule_absent "production delete: PB terminal guard removed" "$PB_PFX" unreachable "" 20582
probe "production delete: PB source falls back to native routing" cl "$PB_SRC" "$EXT_B_HOST" 1 0 0 1 999 \
    ping6 cl "$PB_SRC" "$EXT_B_HOST"
prod_write_config
prod_reconcile_expect "production restore: provider-b policy re-added"
probe "production restore: PB source is constrained again" cl "$PB_SRC" "$EXT_B_HOST" 1 0 0 1 999 \
    ping6 cl "$PB_SRC" "$EXT_B_HOST"

prod_monitor_stop
