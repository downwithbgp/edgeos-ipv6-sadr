#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# R1 canary adapter: one authorized `unreachable` rule on the target IPv6 RPDB.
#
# Runs on the controller. --plan prints the plan and contacts nothing.
# --execute requires a scoped authorization supplied through the harness
# environment and root/CAP_NET_ADMIN on the controller for the test namespaces.
#
# A (baseline): matching + control probes delivered.
# B (guard):    exactly one `from <S> unreachable pref 21031` rule; matching
#               probes must not reach the destination, control probes must.
# A (restore):  the exact rule is deleted; both flows are delivered again.
#
# Output: one JSON object on stdout (ok, probes, wrong_provider, notes).
set -euo pipefail

SELECTOR=${SADR_QUAL_SELECTOR:-fd42:901::a1}
PREF=${SADR_QUAL_PRIORITY:-21031}
PORT=${SADR_QUAL_PORT:-54321}
MATCH_N=${SADR_QUAL_MATCH_PROBES:-20}
CONTROL_N=${SADR_QUAL_CONTROL_PROBES:-10}
INTERVAL=${SADR_QUAL_INTERVAL:-0.5}
MIN_MEM_MB=${SADR_QUAL_MIN_AVAILABLE_MB:-32}
ROUTER=${SADR_QUAL_ROUTER:-}
TEST_ID=${SADR_QUAL_TEST_ID:-}
SCOPE=${SADR_QUAL_APPROVED_SCOPE:-}
NOT_AFTER=${SADR_QUAL_NOT_AFTER:-}
MAXDUR=${SADR_QUAL_MAX_DURATION:-}
FINGERPRINT=${SADR_QUAL_DEVICE_FINGERPRINT:-}
ADAPTER_SHA=${SADR_QUAL_ADAPTER_SHA256:-}
CLEANUP_PATH=${SADR_QUAL_CLEANUP_PATH:-}
CLEANUP_SHA=${SADR_QUAL_CLEANUP_SHA256:-}
SSH_KEY=${SADR_QUAL_SSH_KEY:-$HOME/.ssh/id_ed25519}
MODE=plan
OUT=${SADR_QUAL_OUT:-}
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=yes)

usage() {
    cat >&2 <<'EOF'
usage: r1-canary.sh --plan|--execute --out DIR
Environment (from the qualification harness): SADR_QUAL_ROUTER, SADR_QUAL_TEST_ID,
SADR_QUAL_APPROVED_SCOPE, SADR_QUAL_RECOVERY, SADR_QUAL_NOT_AFTER,
SADR_QUAL_MAX_DURATION, SADR_QUAL_DEVICE_FINGERPRINT, SADR_QUAL_ADAPTER_SHA256,
SADR_QUAL_CLEANUP_PATH, SADR_QUAL_CLEANUP_SHA256.
EOF
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --plan) MODE=plan; shift ;;
        --execute) MODE=execute; shift ;;
        --out) [ $# -ge 2 ] || usage; OUT=$2; shift 2 ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done
[ -n "$OUT" ] || usage
mkdir -p "$OUT"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$OUT/adapter.log"; }
say() { printf '%s\n' "$*" >&2; log "$*"; }
emit() { # ok probes wrong notes
    printf '{"ok": %s, "probes": %s, "wrong_provider": %s, "notes": "%s"}\n' \
        "$1" "$2" "$3" "$(printf '%s' "$4" | tr '\n' ' ' | sed 's/"/\\"/g')"
}

if [ "$MODE" = "plan" ]; then
    cat <<EOF
R1 plan (no device contact, no local change):
  selector:   $SELECTOR/128 (synthetic ULA, verified unused)
  priority:   $PREF, action unreachable, no table/route/interface change
  destination/control: derived from the controller's on-link /64 at execute time
  phases:     A $MATCH_N matching + $CONTROL_N control; B same with the rule;
              A2 same after exact deletion
  observation: E1 ingress capture, E2 post-router capture + non-replying UDP listener
  cleanup:    exact rule deletion via $CLEANUP_PATH, device timer (systemd-run --on-active),
              verification, idempotent, foreign rule refused
  limits:     max ${MAXDUR:-<unset>}s, not_after ${NOT_AFTER:-<unset>}
EOF
    exit 0
fi

fail() { say "FAIL: $*"; emit false 0 0 "$*"; exit 1; }
rssh() { ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" "$ROUTER" "$@"; }
rsudo() { rssh "sudo -n $*"; }
rule_at() {
    local out
    out=$(rssh "ip -6 rule show") || return 1
    printf '%s\n' "$out" | awk -F'\t' -v p="${PREF}:" '$1 == p {print $2}'
}
rule_count() {
    local out
    out=$(rssh "ip -6 rule show") || return 1
    printf '%s\n' "$out" | awk -F'\t' -v p="${PREF}:" '$1 == p {n++} END {print n+0}'
}
table41913_count() {
    local out
    out=$(rssh "ip -6 route show table 41913") || return 1
    printf '%s\n' "$out" | grep -c . || true
}
bgp_counts() {
    local out
    out=$(rssh "vtysh -c 'show ip bgp summary' 2>/dev/null") || return 1
    printf '%s\n' "$out" | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[ \t]/ {n++; if ($NF ~ /^[0-9]+$/) e++} END {print n+0, e+0}'
}

# Validate the authorization inputs before touching anything, and before the
# root check so a non-root test can exercise the hash refusals.
if [ -z "$ROUTER" ] || [ -z "$TEST_ID" ] || [ -z "$NOT_AFTER" ] || [ -z "$MAXDUR" ]; then
    fail "incomplete harness authorization environment"
fi
printf '%s' "$SELECTOR" | grep -Eq '^[0-9a-f:]+$' || fail "invalid selector: $SELECTOR"
printf '%s' "$PREF" | grep -Eq '^[0-9]+$' || fail "invalid priority: $PREF"
if [ "$PREF" -lt 1 ] || [ "$PREF" -gt 32767 ]; then fail "priority out of range: $PREF"; fi
if [ "$MAXDUR" -lt 1 ] || [ "$MAXDUR" -gt 3600 ]; then fail "duration out of range: $MAXDUR"; fi
[ -n "$FINGERPRINT" ] || fail "missing device fingerprint"
[ -n "$ADAPTER_SHA" ] || fail "missing adapter hash"
if [ -z "$CLEANUP_PATH" ] || [ ! -f "$CLEANUP_PATH" ]; then fail "missing cleanup script"; fi
[ -n "$CLEANUP_SHA" ] || fail "missing cleanup hash"
[ "$(sha256sum "$0" | awk '{print $1}')" = "$ADAPTER_SHA" ] || fail "adapter hash mismatch"
[ "$(sha256sum "$CLEANUP_PATH" | awk '{print $1}')" = "$CLEANUP_SHA" ] || fail "cleanup hash mismatch"
[ "$TEST_ID" = "R1-guard-only" ] || fail "unexpected test id: $TEST_ID"
case "$SCOPE" in *"$SELECTOR"*"$PREF"*) ;; *) fail "approved scope does not name selector/priority" ;; esac

[ "$(id -u)" -eq 0 ] || fail "root/CAP_NET_ADMIN required on the controller for netns/macvlan (operator action)"
for c in ip ssh python3 tcpdump sha256sum timeout; do
    command -v "$c" >/dev/null 2>&1 || fail "missing controller tool: $c"
done

# Expiry must cover the whole run with a margin; the device timer enforces the bound.
now=$(date -u +%s)
not_after=$(date -u -d "$NOT_AFTER" +%s 2>/dev/null) || fail "invalid not_after"
[ $((not_after - now)) -ge $((MAXDUR + 30)) ] || fail "authorization expires too soon"
DEADLINE=$( [ "$MAXDUR" -lt $((not_after - now - 10)) ] && echo "$MAXDUR" || echo $((not_after - now - 10)) )

# ---- preflight (read-only) ----
say "preflight: identity and fingerprint"
identity=$(rssh 'cat /etc/version; uname -r; cat /proc/device-tree/model; cat /sys/class/net/eth0/address') || fail "identity read failed"
version=$(printf '%s\n' "$identity" | sed -n '1p')
kernel=$(printf '%s\n' "$identity" | sed -n '2p')
model=$(printf '%s\n' "$identity" | sed -n '3p')
mac=$(printf '%s\n' "$identity" | sed -n '4p')
case "$version" in EdgeRouter.ER-e50.v3.0.1.5862409.*) ;; *) fail "unexpected firmware: $version" ;; esac
[ "$kernel" = "4.14.54-UBNT" ] || fail "unexpected kernel: $kernel"
[ "$(printf '%s\n%s\n' "$model" "$mac" | sha256sum | awk '{print $1}')" = "$FINGERPRINT" ] || fail "device fingerprint mismatch"

say "preflight: RPDB and protected state"
rules_before=$(rssh "ip -6 rule show") || fail "rule read failed"
protected_before=$(printf '%s\n' "$rules_before" | grep -E '^(1041[0-4]):' || true)
[ "$(printf '%s\n' "$protected_before" | grep -c .)" -eq 5 ] || fail "protected rules 10410-10414 are not in the expected state"
count=$(rule_count) || fail "rule read failed"
[ "$count" -eq 0 ] || fail "priority $PREF already occupied"
if printf '%s\n' "$rules_before" | grep -Fq "$SELECTOR"; then fail "selector already present in the RPDB"; fi
addr_routes=$(rssh "ip -6 addr show; ip -6 route show table all") || fail "address/route read failed"
if printf '%s\n' "$addr_routes" | grep -Fq "$SELECTOR"; then fail "selector already present in addresses/routes"; fi
t41913_before=$(table41913_count) || fail "table 41913 read failed"
bgp_before=$(bgp_counts) || fail "BGP summary read failed"

say "preflight: cleanup mechanism and containment"
help=$(rssh 'systemd-run --help') || fail "systemd-run help read failed"
printf '%s\n' "$help" | grep -q -- '--on-active' || fail "systemd-run --on-active unsupported"
rsudo 'systemd-run --version' >/dev/null 2>&1 || fail "passwordless sudo/systemd-run unavailable"
rssh 'test -w /tmp' || fail "/tmp not writable"
timer_state=$(rssh 'systemctl show sadr-r1-cleanup.timer -p LoadState' 2>/dev/null || true)
case "$timer_state" in *"LoadState=loaded"*) fail "cleanup timer already exists" ;; esac
mem=$(rssh 'free -m') || fail "memory read failed"
mem_avail=$(printf '%s\n' "$mem" | awk '/^Mem:/ {print $7}')
if [ -z "$mem_avail" ] || [ "$mem_avail" -lt "$MIN_MEM_MB" ]; then fail "insufficient available memory"; fi

# ---- cleanup/trap installed before any local resource or mutation ----
MUTATION=0
TIMER_ARMED=0
CLEANED=0
LISTENER_PID=""
E1_PCAP=""
E2_PCAP=""
ICMP_PCAP=""
cleanup_run() {
    [ "$CLEANED" -eq 1 ] && return 0
    say "cleanup: exact rule deletion and verification"
    rssh "sudo -n sh /tmp/sadr-r1-cleanup.sh '$SELECTOR' '$PREF' /tmp/sadr-r1-cleanup.log" >/dev/null 2>&1 || true
    local count
    count=$(rule_count) || { say "RECOVERY FAILURE: rule read failed; device timer left armed"; return 1; }
    if [ "$count" -ne 0 ]; then
        say "RECOVERY FAILURE: priority $PREF still present; device timer left armed"
        return 1
    fi
    rssh "sudo -n systemctl stop sadr-r1-cleanup.timer" >/dev/null 2>&1 || true
    rssh "sudo -n systemctl reset-failed sadr-r1-cleanup.service" >/dev/null 2>&1 || true
    CLEANED=1
    return 0
}
teardown_local() {
    if [ -n "${LISTENER_PID:-}" ]; then kill "$LISTENER_PID" 2>/dev/null || true; fi
    if [ -n "${E1_PCAP:-}" ]; then kill "$E1_PCAP" 2>/dev/null || true; fi
    if [ -n "${E2_PCAP:-}" ]; then kill "$E2_PCAP" 2>/dev/null || true; fi
    if [ -n "${ICMP_PCAP:-}" ]; then kill "$ICMP_PCAP" 2>/dev/null || true; fi
    wait 2>/dev/null || true
    ip netns del sadr-r1-e1 2>/dev/null || true
    ip netns del sadr-r1-e2 2>/dev/null || true
}
on_exit() {
    local rc=$?
    if [ "$MUTATION" -eq 1 ] && [ "$CLEANED" -eq 0 ]; then
        cleanup_run || say "RECOVERY FAILURE: cleanup could not be verified; device timer left armed"
    fi
    if [ "$MUTATION" -eq 0 ] && [ "$TIMER_ARMED" -eq 1 ] && [ "$CLEANED" -eq 0 ]; then
        rssh "sudo -n systemctl stop sadr-r1-cleanup.timer" >/dev/null 2>&1 || true
    fi
    teardown_local
    exit "$rc"
}
trap on_exit EXIT INT TERM

# ---- local topology ----
IF=$(ip -4 route show default | awk '{print $5; exit}')
GW6=$(ip -6 route show default | awk '/^default/ {print $3; exit}')
V6=$(ip -6 -o addr show dev "$IF" scope global | awk '$4 ~ /\/64$/ {print $4; exit}')
if [ -z "$IF" ] || [ -z "$GW6" ] || [ -z "$V6" ]; then fail "cannot derive the controller's on-link IPv6 path"; fi
read -r PREFIX D C <<<"$(python3 - "$V6" <<'PY'
import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1], strict=False)
print(net.network_address, net.network_address + 0xa2, net.network_address + 0xa3)
PY
)"
if [ -z "$D" ] || [ -z "$C" ]; then fail "cannot derive test addresses"; fi
route_get=$(rssh "ip -6 route get $D from $SELECTOR") || fail "route lookup failed for $D from $SELECTOR"
if printf '%s' "$route_get" | grep -q ' via '; then
    fail "destination $D is not on-link; refusing to send synthetic traffic"
fi
printf '%s' "$route_get" | grep -q ' dev ' || fail "route lookup did not select an interface: $route_get"
neigh=$(rssh "ip -6 neigh show") || fail "neighbor read failed"
if printf '%s\n' "$neigh" | grep -Fq "$D"; then fail "derived destination is in use"; fi
if printf '%s\n' "$neigh" | grep -Fq "$C"; then fail "derived control source is in use"; fi
prefix_get=$(rssh "ip -6 route get $D") || fail "egress route lookup failed"
PREFIX_IF=$(printf '%s\n' "$prefix_get" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
[ -n "$PREFIX_IF" ] || fail "cannot determine the router egress interface for $D"

ip netns del sadr-r1-e1 2>/dev/null || true
ip netns del sadr-r1-e2 2>/dev/null || true
ip netns add sadr-r1-e1
ip netns add sadr-r1-e2
ip link add mv-e1 link "$IF" type macvlan mode private
ip link add mv-e2 link "$IF" type macvlan mode private
ip link set mv-e1 netns sadr-r1-e1
ip link set mv-e2 netns sadr-r1-e2
ip netns exec sadr-r1-e1 ip link set lo up
ip netns exec sadr-r1-e1 ip link set mv-e1 up
ip netns exec sadr-r1-e2 ip link set lo up
ip netns exec sadr-r1-e2 ip link set mv-e2 up
ip netns exec sadr-r1-e1 ip -6 addr add "$SELECTOR/128" dev mv-e1 nodad
ip netns exec sadr-r1-e1 ip -6 addr add "$C/64" dev mv-e1 nodad
ip netns exec sadr-r1-e2 ip -6 addr add "$D/64" dev mv-e2
ip netns exec sadr-r1-e1 ip -6 route add default via "$GW6" dev mv-e1
ip netns exec sadr-r1-e2 ip -6 route add unreachable fd42:901::/64

for _ in $(seq 1 20); do
    dad=$(ip netns exec sadr-r1-e2 ip -6 addr show dev mv-e2 | grep -E "$(printf '%s' "$D" | sed 's/\./\\./g')")
    printf '%s' "$dad" | grep -q 'tentative' || break
    sleep 0.25
done
if printf '%s' "$dad" | grep -q 'tentative'; then fail "destination DAD did not complete"; fi
if printf '%s' "$dad" | grep -q 'dadfailed'; then fail "destination DAD failed (address in use)"; fi

cat >"$OUT/send.py" <<'PY'
import socket, sys, time
src, dst, port, count, interval, tag = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5]), sys.argv[6]
s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
s.bind((src, 0))
for i in range(count):
    s.sendto(f"r1 {tag} {i}".encode(), (dst, port))
    time.sleep(interval)
PY
cat >"$OUT/listener.py" <<'PY'
import socket, sys, time
addr, port, duration, logfile = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
s.bind((addr, port))
s.settimeout(0.2)
end = time.time() + duration
with open(logfile, "a", encoding="utf-8") as fh:
    while time.time() < end:
        try:
            data, peer = s.recvfrom(2048)
            fh.write(f"SRC {peer[0]}\n")
            fh.flush()
        except socket.timeout:
            pass
PY

LISTEN_LOG="$OUT/listener.log"
: >"$LISTEN_LOG"
ip netns exec sadr-r1-e2 timeout $((DEADLINE + 20)) python3 "$OUT/listener.py" "$D" "$PORT" $((DEADLINE + 20)) "$LISTEN_LOG" &
LISTENER_PID=$!
ip netns exec sadr-r1-e1 tcpdump -i mv-e1 -n -w "$OUT/e1.pcap" "ip6 and (src host $SELECTOR or src host $C) and dst host $D" >/dev/null 2>&1 &
E1_PCAP=$!
ip netns exec sadr-r1-e2 tcpdump -i mv-e2 -n -w "$OUT/e2.pcap" "ip6 and dst host $D and udp port $PORT" >/dev/null 2>&1 &
E2_PCAP=$!
ip netns exec sadr-r1-e1 tcpdump -i mv-e1 -n -w "$OUT/icmp.pcap" "icmp6 and dst host $SELECTOR" >/dev/null 2>&1 &
ICMP_PCAP=$!
sleep 1

count_src() { grep -c "^SRC $1$" "$LISTEN_LOG" 2>/dev/null || true; }
phase() { # tag match_n control_n
    ( ip netns exec sadr-r1-e1 python3 "$OUT/send.py" "$SELECTOR" "$D" "$PORT" "$2" "$INTERVAL" "m-$1" ) &
    local mpid=$!
    ip netns exec sadr-r1-e1 python3 "$OUT/send.py" "$C" "$D" "$PORT" "$3" "$INTERVAL" "c-$1"
    wait "$mpid"
    sleep 1
}

say "phase A1: baseline delivery"
phase a1 "$MATCH_N" "$CONTROL_N"
a1_match=$(count_src "$SELECTOR")
a1_control=$(count_src "$C")
say "A1 matching=$a1_match control=$a1_control"
if [ "$a1_match" -ne "$MATCH_N" ] || [ "$a1_control" -ne "$CONTROL_N" ]; then
    fail "baseline probes were not delivered"
fi

say "phase B: arming the device-side bound"
ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" "$ROUTER" "cat > /tmp/sadr-r1-cleanup.sh" <"$CLEANUP_PATH"
remote_sha=$(rssh "sha256sum /tmp/sadr-r1-cleanup.sh" | awk '{print $1}')
[ "$remote_sha" = "$CLEANUP_SHA" ] || fail "cleanup script transfer hash mismatch"
rssh "sudo -n chmod 0755 /tmp/sadr-r1-cleanup.sh"
rssh "sudo -n systemd-run --unit=sadr-r1-cleanup --on-active=$DEADLINE /bin/sh /tmp/sadr-r1-cleanup.sh $SELECTOR $PREF /tmp/sadr-r1-cleanup.log" >/dev/null
TIMER_ARMED=1
state=$(rssh "systemctl show sadr-r1-cleanup.timer -p ActiveState" 2>/dev/null | cut -d= -f2 || true)
[ "$state" = "active" ] || fail "device cleanup timer is not active ($state)"

say "phase B: adding the exact guard"
MUTATION=1
rssh "sudo -n ip -6 rule add from $SELECTOR unreachable pref $PREF"
count=$(rule_count)
[ "$count" -eq 1 ] || fail "guard rule count is $count after add"
body=$(rule_at)
[ "$body" = "from $SELECTOR unreachable" ] || fail "unexpected guard rule body: $body"

guard_get=$(rssh "ip -6 route get $D from $SELECTOR" 2>&1) || true
if printf '%s' "$guard_get" | grep -q ' via '; then
    fail "guarded route lookup still resolves via a gateway: $guard_get"
fi
printf '%s' "$guard_get" | grep -qiE 'unreachable|No route' || fail "guarded route lookup is not terminal: $guard_get"

say "phase B: guarded probes"
phase b "$MATCH_N" "$CONTROL_N"
b_match=$(grep -c "^SRC $SELECTOR$" "$LISTEN_LOG" 2>/dev/null || true)
b_control=$(count_src "$C")
b_match=$((b_match - a1_match))
b_control=$((b_control - a1_control))
say "B matching=$b_match control=$b_control"
[ "$b_match" -eq 0 ] || fail "$b_match matching packets reached the destination under the guard"
[ "$b_control" -eq "$CONTROL_N" ] || fail "control flow did not survive the guard ($b_control)"

say "phase A2: exact deletion and restoration"
rssh "sudo -n ip -6 rule del from $SELECTOR unreachable pref $PREF"
MUTATION=0
count=$(rule_count) || fail "rule read failed after deletion"
[ "$count" -eq 0 ] || fail "guard rule still present after deletion"
cleanup_run || fail "cleanup verification failed"
restored_get=$(rssh "ip -6 route get $D from $SELECTOR" 2>&1) || fail "route lookup failed after restore"
if printf '%s' "$restored_get" | grep -q ' via '; then fail "route lookup did not recover: $restored_get"; fi
if printf '%s' "$restored_get" | grep -qiE 'unreachable|No route'; then fail "route lookup did not recover: $restored_get"; fi
phase a2 "$MATCH_N" "$CONTROL_N"
a2_match=$(( $(count_src "$SELECTOR") - a1_match ))
a2_control=$(( $(count_src "$C") - a1_control ))
say "A2 matching=$a2_match control=$a2_control"
[ "$a2_match" -eq "$MATCH_N" ] || fail "matching flow did not recover ($a2_match)"
[ "$a2_control" -eq $((b_control + CONTROL_N)) ] || fail "control flow did not continue ($a2_control)"

# ---- invariants ----
sleep 1
rules_after=$(rssh "ip -6 rule show") || fail "rule read failed during invariants"
protected_after=$(printf '%s\n' "$rules_after" | grep -E '^(1041[0-4]):' || true)
[ "$protected_after" = "$protected_before" ] || fail "protected rules changed"
t41913_after=$(table41913_count) || fail "table 41913 read failed"
[ "$t41913_after" -eq "$t41913_before" ] || fail "table 41913 route count changed"
bgp_after=$(bgp_counts) || fail "BGP summary read failed"
[ "$bgp_before" = "$bgp_after" ] || fail "BGP neighbour state changed ($bgp_before -> $bgp_after)"
mem_after=$(rssh 'free -m') || fail "memory read failed"
mem_avail_after=$(printf '%s\n' "$mem_after" | awk '/^Mem:/ {print $7}')
if [ -z "$mem_avail_after" ] || [ "$mem_avail_after" -lt "$MIN_MEM_MB" ]; then fail "memory below floor after the run"; fi
if printf '%s\n' "$rules_after" | grep -q "^${PREF}:"; then fail "guard rule residue after cleanup"; fi
e2_pcap_count=$(tcpdump -nn -r "$OUT/e2.pcap" 2>/dev/null | wc -l | awk '{print $1}')
icmp_count=$(tcpdump -nn -r "$OUT/icmp.pcap" 2>/dev/null | wc -l | awk '{print $1}')
say "evidence: e2_pcap=$e2_pcap_count icmp6=$icmp_count device=$version/$kernel egress_if=$PREFIX_IF"
emit true "$((a1_match + a2_match))" "$b_match" "R1 passed: selector=$SELECTOR pref=$PREF prefix=$PREFIX A1=$a1_match/$a1_control B=0/$b_control A2=$a2_match/$a2_control icmp6=$icmp_count"
