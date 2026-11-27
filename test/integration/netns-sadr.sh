#!/bin/bash
# Generic-Linux proof of concept for IPv6 source-address-dependent routing.
#
# This is NOT an EdgeOS test. It exercises the Linux RPDB/table mechanisms the
# architecture proposes on a modern kernel. Results are labelled
# "Verified (generic Linux)" only.
#
# Topology (all addresses are documentation space):
#
#   InternetA --- PA --- ER --- PB --- InternetB
#                         |
#                    +----+----+
#                    |         |
#                    IR        CL (dual-prefix client)
#
# ER is the system under test. PA and PB validate the source prefix and expose
# capture points. IR provides a connected internal destination and a
# configured (non-connected) internal prefix. CL carries provider A and
# provider B source addresses.
#
# Requires root/CAP_NET_ADMIN, iproute2, ping, tcpdump and python3. Set
# REQUIRE_NETNS_TEST=1 to turn a missing-capability skip into a failure.
set -euo pipefail

REQUIRE=${REQUIRE_NETNS_TEST:-0}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ECHO="$ROOT/test/integration/echo6.py"
CAP=${SADR_CAPDIR:-/tmp/sadr-netns.$$}
CAP_DRAIN=${CAP_DRAIN:-1.0}
CAP_SETTLE=${CAP_SETTLE:-1.0}
mkdir -p "$CAP"

PASS=0
FAIL=0
PIDS=()
CAP_PID=""
PROBE_N=0

# ---------------------------------------------------------------- addressing
PA_PFX=2001:db8:a000::/56
PA64_PFX=2001:db8:a000:1::/64
PA56_SRC=2001:db8:a000:2::2
PA64_SRC=2001:db8:a000:1::2
PB_PFX=2001:db8:b000::/56
PB_SRC=2001:db8:b000:1::2
PA_XFER=2001:db8:aa00::/64
PB_XFER=2001:db8:bb00::/64
PA_NH=2001:db8:aa00::1
PB_NH=2001:db8:bb00::1
EXT_A=2001:db8:aaaa::/64
EXT_A_HOST=2001:db8:aaaa::2
EXT_B=2001:db8:bbbb::/64
EXT_B_HOST=2001:db8:bbbb::2
INT_CONNECTED=2001:db8:100::/64
INT_CONNECTED_HOST=2001:db8:100::1
INT_CFG=2001:db8:200::/56
INT_CFG_HOST=2001:db8:200:2::80
INT_LEAK=2001:db8:200:2::/64
LAN=2001:db8:1::/64

# Provider transfer prefixes are deliberately NOT in the internal whitelist.
# A connected route on a policy egress/next-hop interface is not internal: a
# constrained source must not cross to the other provider's on-link subnet.
INTERNAL_PREFIXES=(
    "$LAN dev er_cl"
    "$INT_CONNECTED dev er_ir"
    "$INT_CFG via $INT_CONNECTED_HOST dev er_ir"
    "2001:db8:a000:1::/64 dev er_cl"
    "2001:db8:a000:2::/64 dev er_cl"
    "2001:db8:b000:1::/64 dev er_cl"
)

# ---------------------------------------------------------------- utilities
say() { printf '%s\n' "$*"; }
ok() { PASS=$((PASS + 1)); say "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); say "FAIL: $*"; }

cleanup() {
    local pid
    for pid in "${PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
    if [ "${SADR_KEEP:-0}" = "1" ]; then
        say "SADR_KEEP=1: captures retained at $CAP"
        return
    fi
    for ns in pa pb ia ib er cl ir; do
        ip netns del "sadr-$ns" 2>/dev/null || true
    done
    rm -rf "$CAP"
}
trap cleanup EXIT INT TERM

run() {
    local ns=$1
    shift
    ip netns exec "sadr-$ns" "$@"
}

runsh() {
    local ns=$1
    shift
    ip netns exec "sadr-$ns" bash -c "$*"
}

need() {
    if ! command -v "$1" >/dev/null 2>&1; then
        if [ "$REQUIRE" = "1" ]; then
            echo "FAIL: required command not found: $1" >&2
            exit 1
        fi
        echo "SKIP: required command not found: $1 (set REQUIRE_NETNS_TEST=1 to fail)" >&2
        exit 0
    fi
}

require_environment() {
    need ip
    need ping
    need tcpdump
    need python3
    if [ "$(id -u)" -ne 0 ]; then
        if [ "$REQUIRE" = "1" ]; then
            echo "FAIL: root/CAP_NET_ADMIN required" >&2
            exit 1
        fi
        echo "SKIP: root/CAP_NET_ADMIN required (set REQUIRE_NETNS_TEST=1 to fail)" >&2
        exit 0
    fi
    if ! ip netns add sadr-probe 2>/dev/null; then
        if [ "$REQUIRE" = "1" ]; then
            echo "FAIL: network namespaces are not available" >&2
            exit 1
        fi
        echo "SKIP: network namespaces are not available" >&2
        exit 0
    fi
    ip netns del sadr-probe
}

veth() { # veth <local> <peer> <local-ns> <peer-ns>
    ip link add "$1" type veth peer name "$2"
    ip link set "$1" netns "sadr-$3"
    ip link set "$2" netns "sadr-$4"
}

addr6() { # addr6 <ns> <addr/prefixlen> <dev>
    run "$1" ip -6 addr add "$2" dev "$3" nodad
}

route6() { # route6 <ns> <args...>
    local ns=$1
    shift
    run "$ns" ip -6 route add "$@"
}

up() { run "$1" ip link set "$2" up; }

sysctl6() {
    run "$1" sysctl -qw "net.ipv6.conf.all.forwarding=$2"
    run "$1" sysctl -qw "net.ipv6.conf.all.accept_ra=0"
    run "$1" sysctl -qw "net.ipv6.conf.all.accept_dad=0"
}

# ---------------------------------------------------------------- capture
cap_start() { # cap_start <ns> <if> <file>; sets CAP_PID
    local ns=$1 if=$2 file=$3
    ip netns exec "sadr-$ns" tcpdump -U -n -i "$if" -s 0 -w "$file" >/dev/null 2>&1 &
    CAP_PID=$!
    PIDS+=("$CAP_PID")
    sleep 0.2
    if ! kill -0 "$CAP_PID" 2>/dev/null; then
        bad "tcpdump failed to start on $ns $if"
        CAP_PID=""
        return 1
    fi
}

cap_stop() { # cap_stop <pid>
    local pid=$1
    [ -n "$pid" ] || return 0
    kill -INT "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
}

cap_count() { # cap_count <file> <src> <dst>
    tcpdump -nn -r "$1" "src host $2 and dst host $3" 2>/dev/null | wc -l | tr -d ' '
}

ping6() { # ping6 <ns> <src> <dst>
    run "$1" ping -6 -c 1 -W 1 -q -I "$2" "$3" >/dev/null 2>&1
}

ping6_unbound() { # ping6_unbound <ns> <dst>
    run "$1" ping -6 -c 1 -W 1 -q "$2" >/dev/null 2>&1
}

# probe <desc> <ns> <src> <dst> <expect_ok 0|1> <min_pa> <max_pa> <min_pb> <max_pb> <cmd...>
# The command is executed in the source namespace. Counts are for packets from
# <src> to <dst> captured on the PA/PB ER-facing interfaces.
probe() {
    local desc=$1 ns=$2 src=$3 dst=$4 expect_ok=$5 min_pa=$6 max_pa=$7 min_pb=$8 max_pb=$9
    shift 9
    PROBE_N=$((PROBE_N + 1))
    local pa="$CAP/pa-$PROBE_N.pcap" pb="$CAP/pb-$PROBE_N.pcap" ir="$CAP/ir-$PROBE_N.pcap"
    local pa_pid pb_pid ir_pid rc=0 want_rc
    if [ "$expect_ok" = "1" ]; then want_rc=0; else want_rc=1; fi
    rm -f "$pa" "$pb" "$ir"
    cap_start pa pa_er "$pa" || return 0
    pa_pid=$CAP_PID
    cap_start pb pb_er "$pb" || { cap_stop "$pa_pid"; return 0; }
    pb_pid=$CAP_PID
    cap_start er er_ir "$ir" || { cap_stop "$pa_pid"; cap_stop "$pb_pid"; return 0; }
    ir_pid=$CAP_PID
    sleep "$CAP_SETTLE"
    if ! "$@"; then
        rc=1
    fi
    # A successful ping returns before tcpdump has necessarily drained the
    # packet from the kernel capture buffer. Let the capture settle before
    # stopping it; a failed probe already spent its timeout.
    sleep "$CAP_DRAIN"
    cap_stop "$pa_pid"
    cap_stop "$pb_pid"
    cap_stop "$ir_pid"
    local pa_n pb_n ir_n
    pa_n=$(cap_count "$pa" "$src" "$dst")
    pb_n=$(cap_count "$pb" "$src" "$dst")
    ir_n=$(cap_count "$ir" "$src" "$dst")
    local verdict=1
    [ "$rc" -eq "$want_rc" ] || verdict=0
    if [ "$min_pa" -ge 0 ] && [ "$pa_n" -lt "$min_pa" ]; then verdict=0; fi
    if [ "$max_pa" -ge 0 ] && [ "$pa_n" -gt "$max_pa" ]; then verdict=0; fi
    if [ "$min_pb" -ge 0 ] && [ "$pb_n" -lt "$min_pb" ]; then verdict=0; fi
    if [ "$max_pb" -ge 0 ] && [ "$pb_n" -gt "$max_pb" ]; then verdict=0; fi
    if [ "$verdict" -eq 1 ]; then
        ok "probe $PROBE_N: $desc (rc=$rc pa=$pa_n pb=$pb_n ir=$ir_n)"
    else
        bad "probe $PROBE_N: $desc (rc=$rc want_rc=$want_rc pa=$pa_n want_pa=$min_pa..$max_pa pb=$pb_n want_pb=$min_pb..$max_pb ir=$ir_n)"
    fi
}

record_probe() { # record_probe <desc> <ns> <src> <dst> <cmd...>
    local desc=$1 ns=$2 src=$3 dst=$4
    shift 4
    PROBE_N=$((PROBE_N + 1))
    local pa="$CAP/pa-$PROBE_N.pcap" pb="$CAP/pb-$PROBE_N.pcap"
    local pa_pid pb_pid rc=0
    rm -f "$pa" "$pb"
    cap_start pa pa_er "$pa" || return 0
    pa_pid=$CAP_PID
    cap_start pb pb_er "$pb" || { cap_stop "$pa_pid"; return 0; }
    pb_pid=$CAP_PID
    sleep "$CAP_SETTLE"
    "$@" || rc=$?
    sleep "$CAP_DRAIN"
    cap_stop "$pa_pid"
    cap_stop "$pb_pid"
    local pa_n pb_n rg
    pa_n=$(cap_count "$pa" "$src" "$dst")
    pb_n=$(cap_count "$pb" "$src" "$dst")
    rg=$(run er ip -6 route get "$dst" from "$src" 2>&1 || true)
    say "RECORD probe $PROBE_N: $desc (rc=$rc pa=$pa_n pb=$pb_n)"
    say "RECORD route get: $rg"
}

# ---------------------------------------------------------------- health
table_owned() { # table_owned <table> <allowed-substring>...
    local table=$1
    shift
    local -a allowed=("$@")
    local line pat found
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        found=0
        for pat in "${allowed[@]}"; do
            if [[ "$line" == *"$pat"* ]]; then
                found=1
                break
            fi
        done
        if [ "$found" -eq 0 ]; then
            echo "unexpected route in table $table: $line" >&2
            return 1
        fi
        if [[ "$line" != *"proto 194"* ]]; then
            echo "foreign protocol in table $table: $line" >&2
            return 1
        fi
    done < <(run er ip -6 route show table "$table")
    return 0
}

table_owned_for() { # table_owned_for <table>
    local table=$1 spec
    local -a internal=()
    case "$table" in
        10000)
            for spec in "${INTERNAL_PREFIXES[@]}"; do
                internal+=("${spec%% *}")
            done
            table_owned 10000 "${internal[@]}"
            ;;
        10001) table_owned 10001 "default via" "unreachable default" "$PA_XFER" ;;
        10002) table_owned 10002 "default via" "unreachable default" "$PB_XFER" ;;
        10003) table_owned 10003 "unreachable default" ;;
        11001) table_owned 11001 "default via" "$PA_XFER" ;;
        11002) table_owned 11002 "default via" "$PB_XFER" ;;
        *) return 0 ;;
    esac
}

table_has() { # table_has <table> <substring>
    run er ip -6 route show table "$1" | grep -F -- "$2" >/dev/null 2>&1
}

table_has_real() { # table_has_real <table> <prefix>
    run er ip -6 route show table "$1" | grep -F -- "$2" | grep -qv '^unreachable '
}

rule_present() { # rule_present <src> <table>
    run er ip -6 rule show | grep -E "from ${1} lookup ${2}([[:space:]]|$)" >/dev/null 2>&1
}

internal_table_ok() {
    local spec prefix
    for spec in "${INTERNAL_PREFIXES[@]}"; do
        prefix=${spec%% *}
        table_has_real 10000 "$prefix" || return 1
        table_has 10000 "unreachable $prefix" || return 1
    done
    return 0
}

shadowed() { # shadowed <src> <first_priority>
    run er ip -6 rule show | python3 "$ROOT/test/integration/shadow_check.py" "$1" "$2"
}

health_policy() { # health_policy <src> <table> <first_priority> <interface> <disabled 0|1>
    local src=$1 table=$2 first=$3 iface=$4 disabled=$5
    if shadowed "$src" "$first"; then echo shadowed; return; fi
    if ! table_owned_for "$table"; then echo conflict; return; fi
    if ! internal_table_ok; then echo incomplete; return; fi
    if ! rule_present "$src" 10000; then echo incomplete; return; fi
    if ! rule_present "$src" "$table"; then echo incomplete; return; fi
    if ! table_has "$table" "unreachable default"; then echo incomplete; return; fi
    if ! table_has "$table" "default via"; then
        if [ "$disabled" = "1" ]; then echo disabled; else echo protected; fi
        return
    fi
    if ! run er ip link show "$iface" 2>/dev/null | grep -q "state UP"; then
        echo dependency-unavailable; return
    fi
    echo effective
}

expect_health() { # expect_health <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 (want $2 got $3)"; fi
}

ensure_rule() { # ensure_rule <from> <lookup|unreachable> <table-or-empty> <pref>
    local src=$1 action=$2 table=$3 pref=$4
    if [ "$action" = "lookup" ]; then
        if ! run er ip -6 rule show | grep -E "^${pref}:[[:space:]]+from ${src} lookup ${table}[[:space:]]*$" >/dev/null 2>&1; then
            run er ip -6 rule add from "$src" lookup "$table" pref "$pref"
        fi
    else
        if ! run er ip -6 rule show | grep -E "^${pref}:[[:space:]]+from ${src} unreachable[[:space:]]*$" >/dev/null 2>&1; then
            run er ip -6 rule add from "$src" unreachable pref "$pref"
        fi
    fi
}

ensure_rule_suppress() { # ensure_rule_suppress <from> <pref>
    local src=$1 pref=$2
    if ! run er ip -6 rule show | grep -E "^${pref}:[[:space:]]+from ${src} lookup main suppress_prefixlength 0[[:space:]]*$" >/dev/null 2>&1; then
        run er ip -6 rule add from "$src" lookup main suppress_prefixlength 0 pref "$pref"
    fi
}

del_rule_suppress() { # del_rule_suppress <from> <pref>
    run er ip -6 rule del from "$1" lookup main suppress_prefixlength 0 pref "$2" 2>/dev/null || true
}

del_rule() { # del_rule <from> <lookup|unreachable> <table-or-empty> <pref>
    local src=$1 action=$2 table=$3 pref=$4
    if [ "$action" = "lookup" ]; then
        run er ip -6 rule del from "$src" lookup "$table" pref "$pref" 2>/dev/null || true
    else
        run er ip -6 rule del from "$src" unreachable pref "$pref" 2>/dev/null || true
    fi
}

ensure_table_route() { # ensure_table_route <table> <prefix> <spec...>
    local table=$1 prefix=$2
    shift 2
    run er ip -6 route replace "$prefix" "$@" table "$table" metric 1024 proto 194
}

ensure_guard() { # ensure_guard <table> <prefix>
    run er ip -6 route replace unreachable "$2" table "$1" metric 4096 proto 194
}

del_table_route() { # del_table_route <table> <prefix> <spec...>
    local table=$1 prefix=$2
    shift 2
    run er ip -6 route del "$prefix" "$@" table "$table" 2>/dev/null || true
}

del_guard() { # del_guard <table> <prefix>
    run er ip -6 route del unreachable "$2" table "$1" metric 4096 2>/dev/null || true
}

# ---------------------------------------------------------------- setup
require_environment

for ns in pa pb ia ib er cl ir; do
    ip netns add "sadr-$ns"
    run "$ns" ip link set lo up
    sysctl6 "$ns" 1
done
# End hosts do not forward, but forwarding is harmless and simplifies setup.
sysctl6 ia 0
sysctl6 ib 0
sysctl6 cl 0

veth pa_er er_pa pa er
veth pb_er er_pb pb er
veth pa_ia ia_pa pa ia
veth pb_ib ib_pb pb ib
veth er_ir ir_er er ir
veth er_cl cl_er er cl

addr6 pa 2001:db8:aa00::1/64 pa_er
addr6 er 2001:db8:aa00::2/64 er_pa
addr6 pb 2001:db8:bb00::1/64 pb_er
addr6 er 2001:db8:bb00::2/64 er_pb
addr6 pa 2001:db8:aaaa::1/64 pa_ia
addr6 ia 2001:db8:aaaa::2/64 ia_pa
addr6 pb 2001:db8:bbbb::1/64 pb_ib
addr6 ib 2001:db8:bbbb::2/64 ib_pb
addr6 er 2001:db8:100::2/64 er_ir
addr6 ir 2001:db8:100::1/64 ir_er
addr6 ir 2001:db8:200:2::80/64 ir_er
addr6 er 2001:db8:1::1/64 er_cl
addr6 cl 2001:db8:1::2/64 cl_er
addr6 cl 2001:db8:a000:1::2/64 cl_er
addr6 cl 2001:db8:a000:2::2/64 cl_er
addr6 cl 2001:db8:b000:1::2/64 cl_er
addr6 er 2001:db8:a000::1/128 lo
addr6 er 2001:db8:b000::1/128 lo

for spec in "pa pa_er" "pb pb_er" "pa pa_ia" "ia ia_pa" "pb pb_ib" "ib ib_pb" \
            "er er_pa" "er er_pb" "er er_ir" "ir ir_er" "er er_cl" "cl cl_er"; do
    # shellcheck disable=SC2086
    up ${spec}
done

# ER LAN link-local for the client default route.
ER_CL_LL=$(run er ip -6 -o addr show dev er_cl scope link | awk '{print $4}' | cut -d/ -f1 | head -1)
if [ -z "$ER_CL_LL" ]; then
    bad "could not determine ER LAN link-local address"
    exit 1
fi
say "ER LAN link-local: $ER_CL_LL"

# Main-table routing.
route6 er 2001:db8:a000:1::/64 dev er_cl metric 1024
route6 er 2001:db8:a000:2::/64 dev er_cl metric 1024
route6 er 2001:db8:b000:1::/64 dev er_cl metric 1024
route6 er unreachable 2001:db8:a000::/56 metric 2048
route6 er unreachable 2001:db8:b000::/56 metric 2048
route6 er default via "$PA_NH" dev er_pa
route6 er "$EXT_A" via "$PA_NH" dev er_pa
route6 er "$EXT_B" via "$PB_NH" dev er_pb
route6 er "$INT_CFG" via "$INT_CONNECTED_HOST" dev er_ir
# Deliberate more-specific external route inside the configured internal prefix.
route6 er "$INT_LEAK" via "$PB_NH" dev er_pb
route6 pa "$PA_PFX" via 2001:db8:aa00::2 dev pa_er
route6 pb "$PB_PFX" via 2001:db8:bb00::2 dev pb_er
route6 ia default via 2001:db8:aaaa::1 dev ia_pa
route6 ib default via 2001:db8:bbbb::1 dev ib_pb
route6 ir default via 2001:db8:100::2 dev ir_er
route6 ir "$PA_PFX" via 2001:db8:100::2 dev ir_er
route6 ir "$PB_PFX" via 2001:db8:100::2 dev ir_er
route6 cl default via "$ER_CL_LL" dev cl_er

# Simulated provider source-address validation. Captures remain the primary
# evidence; a missing netfilter path is only a warning.
if ! run pa ip6tables -A FORWARD -i pa_er -s "$PB_PFX" -j DROP 2>/dev/null; then
    say "WARN: could not install PA source-validation rule"
fi
if ! run pb ip6tables -A FORWARD -i pb_er -s "$PA_PFX" -j DROP 2>/dev/null; then
    say "WARN: could not install PB source-validation rule"
fi

# Echo servers.
run ia python3 "$ECHO" server-udp 9999 >"$CAP/ia-udp.log" 2>&1 & PIDS+=("$!")
run ia python3 "$ECHO" server-tcp 9998 >"$CAP/ia-tcp.log" 2>&1 & PIDS+=("$!")
run ib python3 "$ECHO" server-udp 9999 >"$CAP/ib-udp.log" 2>&1 & PIDS+=("$!")
run ib python3 "$ECHO" server-tcp 9998 >"$CAP/ib-tcp.log" 2>&1 & PIDS+=("$!")
run ir python3 "$ECHO" server-udp 9997 >"$CAP/ir-udp.log" 2>&1 & PIDS+=("$!")
sleep 0.5

say "=== topology baseline ==="
probe "PA source reaches Internet A" cl "$PA56_SRC" "$EXT_A_HOST" 1 1 999 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_A_HOST"
probe "PB source reaches Internet B" cl "$PB_SRC" "$EXT_B_HOST" 1 0 0 1 999 \
    ping6 cl "$PB_SRC" "$EXT_B_HOST"
probe "PA source reaches connected internal" cl "$PA56_SRC" "$INT_CONNECTED_HOST" 1 0 0 0 0 \
    ping6 cl "$PA56_SRC" "$INT_CONNECTED_HOST"
probe "PB source reaches connected internal" cl "$PB_SRC" "$INT_CONNECTED_HOST" 1 0 0 0 0 \
    ping6 cl "$PB_SRC" "$INT_CONNECTED_HOST"
# Deliberate leak control: without SADR, a more-specific main route sends the
# PA-sourced internal packet out PB. This proves the capture can see the wrong
# provider before we claim that a later zero is meaningful.
probe "LEAK CONTROL: PA source to configured internal goes out PB" cl "$PA56_SRC" "$INT_CFG_HOST" 0 0 0 1 999 \
    ping6 cl "$PA56_SRC" "$INT_CFG_HOST"
probe "LEAK CONTROL: PB source to Internet A goes out PA" cl "$PB_SRC" "$EXT_A_HOST" 0 1 999 0 0 \
    ping6 cl "$PB_SRC" "$EXT_A_HOST"

# ---------------------------------------------------------------- broad RPDB
broad_apply() {
    ensure_table_route 11001 default via "$PA_NH" dev er_pa
    ensure_table_route 11001 "$PA_XFER" dev er_pa
    ensure_table_route 11002 default via "$PB_NH" dev er_pb
    ensure_table_route 11002 "$PB_XFER" dev er_pb
    ensure_rule_suppress "$PA_PFX" 15000
    ensure_rule "$PA_PFX" lookup 11001 15001
    ensure_rule "$PA_PFX" unreachable "" 15002
    ensure_rule_suppress "$PB_PFX" 15010
    ensure_rule "$PB_PFX" lookup 11002 15011
    ensure_rule "$PB_PFX" unreachable "" 15012
}

broad_reset() {
    del_rule_suppress "$PA_PFX" 15000
    del_rule "$PA_PFX" lookup 11001 15001
    del_rule "$PA_PFX" unreachable "" 15002
    del_rule_suppress "$PB_PFX" 15010
    del_rule "$PB_PFX" lookup 11002 15011
    del_rule "$PB_PFX" unreachable "" 15012
}

say "=== broad main-table suppressor model (current proof of concept) ==="
broad_apply
probe "broad: PA source reaches Internet A" cl "$PA56_SRC" "$EXT_A_HOST" 1 1 999 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_A_HOST"
probe "broad: PB source reaches Internet B" cl "$PB_SRC" "$EXT_B_HOST" 1 0 0 1 999 \
    ping6 cl "$PB_SRC" "$EXT_B_HOST"
probe "broad LEAK: PA source to Internet B goes out PB" cl "$PA56_SRC" "$EXT_B_HOST" 0 0 999 1 999 \
    ping6 cl "$PA56_SRC" "$EXT_B_HOST"
probe "broad LEAK: PB source to Internet A goes out PA" cl "$PB_SRC" "$EXT_A_HOST" 0 1 999 0 999 \
    ping6 cl "$PB_SRC" "$EXT_A_HOST"
probe "broad LEAK: PA source to configured internal goes out PB" cl "$PA56_SRC" "$INT_CFG_HOST" 0 0 999 1 999 \
    ping6 cl "$PA56_SRC" "$INT_CFG_HOST"
broad_reset

# ---------------------------------------------------------------- strict model
strict_tables() {
    local spec prefix rest
    for spec in "${INTERNAL_PREFIXES[@]}"; do
        prefix=${spec%% *}
        rest=${spec#* }
        # shellcheck disable=SC2086
        ensure_table_route 10000 "$prefix" $rest
        ensure_guard 10000 "$prefix"
    done
    ensure_guard 10001 default
    ensure_table_route 10001 default via "$PA_NH" dev er_pa
    ensure_table_route 10001 "$PA_XFER" dev er_pa
    ensure_guard 10002 default
    ensure_table_route 10002 default via "$PB_NH" dev er_pb
    ensure_table_route 10002 "$PB_XFER" dev er_pb
    ensure_guard 10003 default
}

strict_rules() {
    ensure_rule "$PA_PFX" lookup 10000 20510
    ensure_rule "$PA_PFX" lookup 10001 20511
    ensure_rule "$PB_PFX" lookup 10000 20520
    ensure_rule "$PB_PFX" lookup 10002 20521
    ensure_rule "$PA64_PFX" lookup 10000 20500
    ensure_rule "$PA64_PFX" lookup 10003 20501
}

strict_apply() {
    # First-application blocking guard: a previously unconstrained source is
    # blocked while its policy is installed.
    ensure_rule "$PA_PFX" unreachable "" 20507
    ensure_rule "$PB_PFX" unreachable "" 20517
    strict_tables
    strict_rules
    del_rule "$PA_PFX" unreachable "" 20507
    del_rule "$PB_PFX" unreachable "" 20517
}

strict_reset() {
    del_rule "$PA_PFX" lookup 10000 20510
    del_rule "$PA_PFX" lookup 10001 20511
    del_rule "$PB_PFX" lookup 10000 20520
    del_rule "$PB_PFX" lookup 10002 20521
    del_rule "$PA64_PFX" lookup 10000 20500
    del_rule "$PA64_PFX" lookup 10003 20501
    del_rule "$PA_PFX" unreachable "" 20507
    del_rule "$PB_PFX" unreachable "" 20517
}

say "=== internal-whitelist model ==="
# Demonstrate the first-application guard before the permanent rules exist.
ensure_rule "$PA_PFX" unreachable "" 20507
probe "create: PA source is blocked by the first-action guard" cl "$PA56_SRC" "$EXT_A_HOST" 0 0 0 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_A_HOST"
del_rule "$PA_PFX" unreachable "" 20507

strict_apply
probe "strict: PA source reaches Internet A" cl "$PA56_SRC" "$EXT_A_HOST" 1 1 999 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_A_HOST"
probe "strict: PB source reaches Internet B" cl "$PB_SRC" "$EXT_B_HOST" 1 0 0 1 999 \
    ping6 cl "$PB_SRC" "$EXT_B_HOST"
probe "strict: PA source to Internet B does not use PB" cl "$PA56_SRC" "$EXT_B_HOST" 0 0 999 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_B_HOST"
probe "strict: PB source to Internet A does not use PA" cl "$PB_SRC" "$EXT_A_HOST" 0 0 0 0 999 \
    ping6 cl "$PB_SRC" "$EXT_A_HOST"
probe "strict: PA source reaches configured internal via IR" cl "$PA56_SRC" "$INT_CFG_HOST" 1 0 0 0 0 \
    ping6 cl "$PA56_SRC" "$INT_CFG_HOST"
probe "strict: PB source reaches configured internal via IR" cl "$PB_SRC" "$INT_CFG_HOST" 1 0 0 0 0 \
    ping6 cl "$PB_SRC" "$INT_CFG_HOST"
probe "strict: nested /64 source is blocked for external (precedence)" cl "$PA64_SRC" "$EXT_A_HOST" 0 0 0 0 0 \
    ping6 cl "$PA64_SRC" "$EXT_A_HOST"
probe "strict: nested /64 source still reaches internal" cl "$PA64_SRC" "$INT_CONNECTED_HOST" 1 0 0 0 0 \
    ping6 cl "$PA64_SRC" "$INT_CONNECTED_HOST"
# Provider-facing connected routes are not internal. A PB source must not
# reach PA's on-link transfer address through PA.
probe "strict: PB source to PA transfer address does not use PA" cl "$PB_SRC" 2001:db8:aa00::1 0 0 0 0 999 \
    ping6 cl "$PB_SRC" 2001:db8:aa00::1
probe "strict: PA source to PB transfer address does not use PB" cl "$PA56_SRC" 2001:db8:bb00::1 0 0 999 0 0 \
    ping6 cl "$PA56_SRC" 2001:db8:bb00::1

# UDP and TCP through the source policies.
probe "strict: PA source UDP to Internet A" cl "$PA56_SRC" "$EXT_A_HOST" 1 1 999 0 0 \
    run cl python3 "$ECHO" client-udp "$PA56_SRC" "$EXT_A_HOST" 9999
probe "strict: PB source TCP to Internet B" cl "$PB_SRC" "$EXT_B_HOST" 1 0 0 1 999 \
    run cl python3 "$ECHO" client-tcp "$PB_SRC" "$EXT_B_HOST" 9998
probe "strict: PA source UDP to internal" cl "$PA56_SRC" "$INT_CFG_HOST" 1 0 0 0 0 \
    run cl python3 "$ECHO" client-udp "$PA56_SRC" "$INT_CFG_HOST" 9997
probe "strict: PA source UDP to Internet B does not use PB" cl "$PA56_SRC" "$EXT_B_HOST" 0 0 999 0 0 \
    run cl python3 "$ECHO" client-udp "$PA56_SRC" "$EXT_B_HOST" 9999

# Locally originated traffic with an explicit source.
probe "local: PA loopback source reaches Internet A" er 2001:db8:a000::1 "$EXT_A_HOST" 1 1 999 0 0 \
    ping6 er 2001:db8:a000::1 "$EXT_A_HOST"
probe "local: PB loopback source reaches Internet B" er 2001:db8:b000::1 "$EXT_B_HOST" 1 0 0 1 999 \
    ping6 er 2001:db8:b000::1 "$EXT_B_HOST"
probe "local: PA loopback source to Internet B does not use PB" er 2001:db8:a000::1 "$EXT_B_HOST" 0 0 999 0 0 \
    ping6 er 2001:db8:a000::1 "$EXT_B_HOST"

# Route lookup diagnostics.
say "=== route lookup diagnostics ==="
if run er ip -6 route get "$EXT_B_HOST" from "$PA56_SRC" | grep -q "dev er_pa"; then
    ok "route get: PA source to Internet B selects PA table"
else
    bad "route get: PA source to Internet B did not select PA table"
fi
if run er ip -6 route get "$EXT_A_HOST" from "$PB_SRC" | grep -q "dev er_pb"; then
    ok "route get: PB source to Internet A selects PB table"
else
    bad "route get: PB source to Internet A did not select PB table"
fi
if run er ip -6 route get "$INT_CFG_HOST" from "$PA56_SRC" | grep -q "dev er_ir"; then
    ok "route get: PA source to configured internal selects IR"
else
    bad "route get: PA source to configured internal did not select IR"
fi
if run er ip -6 route get "$EXT_A_HOST" from "$PA64_SRC" >/dev/null 2>&1; then
    bad "route get: nested /64 source unexpectedly has an external route"
else
    ok "route get: nested /64 source is fail-closed for external"
fi

# Health states.
say "=== health states ==="
expect_health "health: PA policy effective" effective "$(health_policy "$PA_PFX" 10001 20510 er_pa 0)"
expect_health "health: PB policy effective" effective "$(health_policy "$PB_PFX" 10002 20520 er_pb 0)"
expect_health "health: nested /64 guard-only policy protected" protected "$(health_policy "$PA64_PFX" 10003 20500 er_pa 0)"

# Provider route loss is fail-closed, not a fallback.
del_table_route 10001 default via "$PA_NH" dev er_pa
probe "loss: PA provider route removed, source is fail-closed" cl "$PA56_SRC" "$EXT_A_HOST" 0 0 0 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_A_HOST"
expect_health "health: PA policy protected after route loss" protected "$(health_policy "$PA_PFX" 10001 20510 er_pa 0)"
ensure_table_route 10001 default via "$PA_NH" dev er_pa
probe "restore: PA source reaches Internet A again" cl "$PA56_SRC" "$EXT_A_HOST" 1 1 999 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_A_HOST"

# Internal route loss is also fail-closed.
del_table_route 10000 "$INT_CFG" via "$INT_CONNECTED_HOST" dev er_ir
probe "loss: internal route removed, source is fail-closed for that prefix" cl "$PA56_SRC" "$INT_CFG_HOST" 0 0 0 0 0 \
    ping6 cl "$PA56_SRC" "$INT_CFG_HOST"
expect_health "health: internal route loss reports incomplete" incomplete "$(health_policy "$PA_PFX" 10001 20510 er_pa 0)"
ensure_table_route 10000 "$INT_CFG" via "$INT_CONNECTED_HOST" dev er_ir
probe "restore: internal route restored" cl "$PA56_SRC" "$INT_CFG_HOST" 1 0 0 0 0 \
    ping6 cl "$PA56_SRC" "$INT_CFG_HOST"
expect_health "health: internal route restored reports effective" effective "$(health_policy "$PA_PFX" 10001 20510 er_pa 0)"

# Ownership conflicts are refused, not deleted.
say "=== ownership and shadowing ==="
run er ip -6 route add 2001:db8:dead::/64 dev er_pa table 10001
if table_owned_for 10001; then
    bad "ownership: foreign route in managed table was not detected"
else
    ok "ownership: foreign route in managed table detected"
fi
run er ip -6 route del 2001:db8:dead::/64 dev er_pa table 10001 2>/dev/null || true
if table_owned_for 10001; then
    ok "ownership: valid table is clean after removing foreign route"
else
    bad "ownership: valid table still reports a conflict"
fi
run er ip -6 route add 2001:db8:dead::/64 dev er_pa table 10001 proto 194
if table_owned_for 10001; then
    bad "ownership: proto-only match without prefix agreement was not detected"
else
    ok "ownership: proto-only match without prefix agreement detected"
fi
run er ip -6 route del 2001:db8:dead::/64 dev er_pa table 10001 2>/dev/null || true

run er ip -6 rule add from "$PB_PFX" lookup main pref 15000
if shadowed "$PB_PFX" 20520; then
    ok "shadow: preceding foreign rule is detected"
else
    bad "shadow: preceding foreign rule was not detected"
fi
expect_health "health: shadowed policy is not reported effective" shadowed "$(health_policy "$PB_PFX" 10002 20520 er_pb 0)"
run er ip -6 rule del from "$PB_PFX" lookup main pref 15000 2>/dev/null || true

run er ip -6 rule add from "$PA64_PFX" lookup main pref 15000
if shadowed "$PA_PFX" 20510; then
    ok "shadow: more-specific foreign rule is detected for the broader policy"
else
    bad "shadow: more-specific foreign rule was not detected"
fi
run er ip -6 rule del from "$PA64_PFX" lookup main pref 15000 2>/dev/null || true

run er ip -6 rule add from all unreachable pref 15000
if shadowed "$PA_PFX" 20510; then
    ok "shadow: catch-all foreign rule is detected"
else
    bad "shadow: catch-all foreign rule was not detected"
fi
run er ip -6 rule del from all unreachable pref 15000 2>/dev/null || true

# Idempotent re-application must not duplicate rules/routes.
say "=== idempotency ==="
before_rules=$(run er ip -6 rule show | grep -cE '^(20500|20501|20510|20511|20520|20521):' || true)
strict_apply
after_rules=$(run er ip -6 rule show | grep -cE '^(20500|20501|20510|20511|20520|20521):' || true)
if [ "$before_rules" = "$after_rules" ]; then
    ok "idempotency: rule count unchanged ($after_rules)"
else
    bad "idempotency: rule count changed $before_rules -> $after_rules"
fi

# Disable semantics: internal reachability remains, external is blocked.
say "=== disable semantics ==="
del_table_route 10002 default via "$PB_NH" dev er_pb
probe "disable: PB external is blocked" cl "$PB_SRC" "$EXT_B_HOST" 0 0 0 0 0 \
    ping6 cl "$PB_SRC" "$EXT_B_HOST"
probe "disable: PB internal remains reachable" cl "$PB_SRC" "$INT_CONNECTED_HOST" 1 0 0 0 0 \
    ping6 cl "$PB_SRC" "$INT_CONNECTED_HOST"
expect_health "health: PB policy disabled" disabled "$(health_policy "$PB_PFX" 10002 20520 er_pb 1)"
ensure_table_route 10002 default via "$PB_NH" dev er_pb
probe "restore: PB external reachable again" cl "$PB_SRC" "$EXT_B_HOST" 1 0 0 1 999 \
    ping6 cl "$PB_SRC" "$EXT_B_HOST"

# Interface recreation: routes disappear with the old netdevice. The table
# guard must keep the source blocked until reconciliation restores them.
say "=== interface recreation ==="
recreate_cap_pa="$CAP/recreate-pa.pcap"
rm -f "$recreate_cap_pa"
cap_start pa pa_er "$recreate_cap_pa" || exit 1
pa_pid=$CAP_PID
(
    for _ in $(seq 1 12); do
        if ping6 cl "$PB_SRC" "$EXT_B_HOST"; then echo up; else echo down; fi
        sleep 0.25
    done
) >"$CAP/recreate-loop.txt" 2>&1 &
loop_pid=$!
PIDS+=("$loop_pid")
sleep 0.6
run er ip link del er_pb
sleep 1
if run er ip -6 route show table 10002 | grep -q '^unreachable default'; then
    ok "recreation: provider guard remains while the interface is absent"
else
    bad "recreation: provider guard disappeared during interface loss"
fi
# Recreate the veth pair and re-apply the PB dependencies.
veth pb_er er_pb pb er
addr6 pb 2001:db8:bb00::1/64 pb_er
addr6 er 2001:db8:bb00::2/64 er_pb
up pb pb_er
up er er_pb
route6 pb "$PB_PFX" via 2001:db8:bb00::2 dev pb_er
route6 er "$EXT_B" via "$PB_NH" dev er_pb
route6 er "$INT_LEAK" via "$PB_NH" dev er_pb
ensure_table_route 10002 "$PB_XFER" dev er_pb
ensure_table_route 10002 default via "$PB_NH" dev er_pb
sleep 1
wait "$loop_pid" 2>/dev/null || true
cap_stop "$pa_pid"
downs=$(grep -c '^down$' "$CAP/recreate-loop.txt" || true)
ups=$(grep -c '^up$' "$CAP/recreate-loop.txt" || true)
wrong=$(cap_count "$recreate_cap_pa" "$PB_SRC" "$EXT_B_HOST")
if [ "$downs" -ge 1 ] && [ "$ups" -ge 2 ]; then
    ok "recreation: traffic failed during the gap and recovered (down=$downs up=$ups)"
else
    bad "recreation: expected both failure and recovery (down=$downs up=$ups)"
fi
if [ "$wrong" -eq 0 ]; then
    ok "recreation: no PB-sourced packet used PA during the gap"
else
    bad "recreation: PB-sourced packet leaked to PA ($wrong)"
fi
probe "recreation: PB path recovers after reconciliation" cl "$PB_SRC" "$EXT_B_HOST" 1 0 0 1 999 \
    ping6 cl "$PB_SRC" "$EXT_B_HOST"

# Cleanup of the strict rules, then native routing is restored intentionally.
strict_reset

# ---------------------------------------------------------------- candidate B
# Source-specific IPv6 FIB routes in main. This is a generic-Linux experiment;
# whether the target iproute2 accepts the add syntax is a separate target probe.
say "=== source-specific FIB candidate (generic Linux) ==="
if run er ip -6 rule show | grep -qE '^(20500|20501|20510|20511|20520|20521):'; then
    bad "candidate B precheck: strict rules still present"
else
    ok "candidate B precheck: strict rules removed"
fi
say "--- candidate B routes before add ---"
run er ip -6 route show | grep -E 'from |default' || true
run er ip -6 route add default from "$PA_PFX" via "$PA_NH" dev er_pa metric 1024 proto 194
run er ip -6 route add unreachable default from "$PA_PFX" metric 4096 proto 194
run er ip -6 route add default from "$PB_PFX" via "$PB_NH" dev er_pb metric 1024 proto 194
run er ip -6 route add unreachable default from "$PB_PFX" metric 4096 proto 194
say "--- candidate B routes after add ---"
run er ip -6 route show | grep -E 'from |default' || true
probe "source-FIB: PA source reaches Internet A" cl "$PA56_SRC" "$EXT_A_HOST" 1 1 999 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_A_HOST"
probe "source-FIB: PB source reaches Internet B" cl "$PB_SRC" "$EXT_B_HOST" 1 0 0 1 999 \
    ping6 cl "$PB_SRC" "$EXT_B_HOST"
probe "source-FIB LEAK: PA source to configured internal uses the more-specific PB route" cl "$PA56_SRC" "$INT_CFG_HOST" 0 0 999 1 999 \
    ping6 cl "$PA56_SRC" "$INT_CFG_HOST"
probe "source-FIB: PA source reaches connected internal" cl "$PA56_SRC" "$INT_CONNECTED_HOST" 1 0 0 0 0 \
    ping6 cl "$PA56_SRC" "$INT_CONNECTED_HOST"
record_probe "source-FIB control: PA source to a destination with no specific route uses the source default" cl "$PA56_SRC" 2001:db8:cccc::2 \
    ping6 cl "$PA56_SRC" 2001:db8:cccc::2
run er ip -6 route del default from "$PA_PFX" via "$PA_NH" dev er_pa metric 1024 proto 194
say "--- candidate B routes after PA default removal ---"
run er ip -6 route show | grep -E 'from |default' || true
# A more-specific route still captures the source. That is already a
# falsification of candidate B. Separately record whether the source-specific
# unreachable default stops forwarded fallback for a destination that has no
# more-specific route.
probe "source-FIB: more-specific route still captures PA source after provider default removal" cl "$PA56_SRC" "$EXT_A_HOST" 1 1 999 0 0 \
    ping6 cl "$PA56_SRC" "$EXT_A_HOST"
record_probe "source-FIB guard: PA source to a destination with no specific route after provider default removal" cl "$PA56_SRC" 2001:db8:cccc::2 \
    ping6 cl "$PA56_SRC" 2001:db8:cccc::2
say "See RECORD lines for the candidate B guard result; candidate B is rejected on the more-specific-route capture regardless."
run er ip -6 route del unreachable default from "$PA_PFX" metric 4096 proto 194 2>/dev/null || true
run er ip -6 route del default from "$PB_PFX" via "$PB_NH" dev er_pb metric 1024 proto 194 2>/dev/null || true
run er ip -6 route del unreachable default from "$PB_PFX" metric 4096 proto 194 2>/dev/null || true

say ""
say "netns: pass=$PASS fail=$FAIL"
say "captures and logs: $CAP"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
