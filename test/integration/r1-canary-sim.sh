#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Generic-Linux simulation of the R1 canary A/B/A sequence and the device-local
# cleanup script. Runs in the privileged test container; it is not EdgeOS evidence.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CLEANUP="$ROOT/qualification/adapters/r1-cleanup.sh"
SEL="fd42:901::a1"
PREF=21031
PASS=0
FAIL=0

ok() { echo "PASS: r1-sim: $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: r1-sim: $*" >&2; FAIL=$((FAIL + 1)); }

cleanup_all() {
    ip netns del r1src 2>/dev/null || true
    ip netns del r1rt 2>/dev/null || true
    ip netns del r1dst 2>/dev/null || true
}
trap cleanup_all EXIT
cleanup_all

ip netns add r1src
ip netns add r1rt
ip netns add r1dst
ip link add s0 type veth peer name r0
ip link add r1 type veth peer name d0
ip link set s0 netns r1src
ip link set r0 netns r1rt
ip link set r1 netns r1rt
ip link set d0 netns r1dst
for n in r1src r1rt r1dst; do ip netns exec "$n" ip link set lo up; done
ip netns exec r1src ip link set s0 up
ip netns exec r1rt ip link set r0 up
ip netns exec r1rt ip link set r1 up
ip netns exec r1dst ip link set d0 up
ip netns exec r1rt sysctl -qw net.ipv6.conf.all.forwarding=1
ip netns exec r1src ip -6 addr add "$SEL/128" dev s0 nodad
ip netns exec r1src ip -6 addr add 2001:db8:1::a3/64 dev s0 nodad
ip netns exec r1rt ip -6 addr add 2001:db8:1::1/64 dev r0 nodad
ip netns exec r1rt ip -6 addr add 2001:db8:2::1/64 dev r1 nodad
ip netns exec r1dst ip -6 addr add 2001:db8:2::a2/64 dev d0 nodad
ip netns exec r1src ip -6 route add default via 2001:db8:1::1

cat >/tmp/r1-send.py <<'PY'
import socket, sys
src, dst, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
s.bind((src, 0))
for _ in range(n):
    s.sendto(b"r1sim", (dst, 54321))
PY
cat >/tmp/r1-listen.py <<'PY'
import socket, sys, time
addr, duration, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
s.bind((addr, 54321))
s.settimeout(0.2)
end = time.time() + duration
with open(out, "w", encoding="utf-8") as fh:
    while time.time() < end:
        try:
            _, peer = s.recvfrom(2048)
            fh.write(peer[0] + "\n")
            fh.flush()
        except socket.timeout:
            pass
PY

listen_phase() { # outfile
    ip netns exec r1dst python3 /tmp/r1-listen.py 2001:db8:2::a2 4 "$1"
}
send_phase() {
    ip netns exec r1src python3 /tmp/r1-send.py "$SEL" 2001:db8:2::a2 3
    ip netns exec r1src python3 /tmp/r1-send.py 2001:db8:1::a3 2001:db8:2::a2 3
}

# A: baseline
listen_phase /tmp/r1a.txt & sleep 0.3
send_phase
wait
a_match=$(grep -c "^$SEL$" /tmp/r1a.txt || true)
a_control=$(grep -c '^2001:db8:1::a3$' /tmp/r1a.txt || true)
if [ "$a_match" -eq 3 ] && [ "$a_control" -eq 3 ]; then
    ok "A delivers 3 matching + 3 control"
else
    bad "A delivered matching=$a_match control=$a_control"
fi

# B: guard
ip netns exec r1rt ip -6 rule add from "$SEL" unreachable pref "$PREF"
if ip netns exec r1rt ip -6 route get 2001:db8:2::a2 from "$SEL" >/dev/null 2>&1; then
    bad "guarded route lookup unexpectedly succeeded"
else
    ok "guarded route lookup is terminal"
fi
listen_phase /tmp/r1b.txt & sleep 0.3
send_phase
wait
b_match=$(grep -c "^$SEL$" /tmp/r1b.txt || true)
b_control=$(grep -c '^2001:db8:1::a3$' /tmp/r1b.txt || true)
if [ "$b_match" -eq 0 ] && [ "$b_control" -eq 3 ]; then
    ok "B blocks matching and passes control"
else
    bad "B matching=$b_match control=$b_control"
fi

# A2: restore
ip netns exec r1rt ip -6 rule del from "$SEL" unreachable pref "$PREF"
listen_phase /tmp/r1c.txt & sleep 0.3
send_phase
wait
c_match=$(grep -c "^$SEL$" /tmp/r1c.txt || true)
c_control=$(grep -c '^2001:db8:1::a3$' /tmp/r1c.txt || true)
if [ "$c_match" -eq 3 ] && [ "$c_control" -eq 3 ]; then
    ok "A2 restores matching and control"
else
    bad "A2 matching=$c_match control=$c_control"
fi

# Cleanup script semantics inside the router namespace.
run_cleanup() { ip netns exec r1rt bash "$CLEANUP" "$SEL" "$PREF" /tmp/r1-cleanup.log; }
: >/tmp/r1-cleanup.log
ip netns exec r1rt ip -6 rule add from "$SEL" unreachable pref "$PREF"
if run_cleanup; then ok "cleanup deletes the exact owned rule"; else bad "cleanup failed on the exact rule"; fi
if ip netns exec r1rt ip -6 rule show | grep -q "^${PREF}:"; then bad "cleanup left the rule behind"; else ok "cleanup verified the deletion"; fi
if run_cleanup; then ok "cleanup is idempotent when the rule is absent"; else bad "cleanup failed when the rule was absent"; fi
ip netns exec r1rt ip -6 rule add from 2001:db8:2::dead unreachable pref "$PREF"
set +e
run_cleanup
rc=$?
set -e
if [ "$rc" -eq 3 ] && ip netns exec r1rt ip -6 rule show | grep -q "^${PREF}:"; then
    ok "cleanup refuses a foreign rule and preserves it"
else
    bad "cleanup did not refuse the foreign rule (rc=$rc)"
fi
ip netns exec r1rt ip -6 rule del from 2001:db8:2::dead unreachable pref "$PREF"

echo "r1-sim: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
