# R1 canary — execution-ready proposal

**Status:** proposal only. **No production mutation is authorized by this document.** It contains
everything needed for the maintainer to approve the first canary without another preparation cycle.
Table `41913` and rules `10410–10414` remain protected foreign state; the product package is unchanged.

## 1. Target identity and corrected offload inventory

| Item | Value | Evidence |
|---|---|---|
| Device | ER-X / ER-e50, EdgeOS `3.0.1.5862409.250924.1407`, kernel `4.14.54-UBNT` | Verified (target), read-only |
| Stable fingerprint | `0896090dabbf415be33b51fe09e1edad5605e65febb95db9293bbe6b2d667440` | SHA-256 of board model + management MAC |
| Management | key-based SSH to the router's IPv4 address on the server VLAN | Verified (target) |
| HWNAT | configured `system offload { hwnat enable }`; `show ubnt offload` reports the HWNAT module loaded | Verified (target) |
| Acceleration demonstration | `show ubnt offload statistics` is not available on this platform; no flow is demonstrated as accelerated | Verified (target) |
| iproute2 | `iproute2-ss171113`; `from … unreachable pref` is already used by the protected rules | Verified (target) |
| Cleanup utilities | `systemd-run` 232 with `--on-active`, passwordless sudo, `/tmp` writable; no `atd`, `timeout`, `tcpdump` or `python3` | Verified (target) |

The ethtool `hw-tc-offload` flag is **not** the acceleration state. R1 therefore qualifies the
software forwarding path only; it does not claim accelerated-path correctness.

## 2. Exact synthetic addressing

- **Rule selector S:** `fd42:901::a1/128`, a synthetic ULA verified absent from the router's
  addresses, routes, rules and neighbours and from the controller. This is the exact selector.
- **Destination D:** derived at run time from the controller's on-link server-VLAN `/64` with
  interface identifier `a2`; the exact value is recorded in the run metadata and kept out of the
  repository. D is on-link, unused, and DAD-verified at setup.
- **Nonmatching control source C:** the same `/64` with interface identifier `a3`, assigned to the
  sender namespace and DAD-verified. Exact value kept out of the repository.
- **Containment:** `ip -6 route get <D> from <S>` on the router selects the on-link VLAN interface,
  not the provider default. A ULA destination would select the provider default and is therefore
  never used. E2 has no default route and a blackhole for `fd42:901::/64`; its listener never
  replies.

## 3. Ingress and egress paths

```
E1 namespace (macvlan, private) --server VLAN--> router (software forward, RPDB lookup)
                                               --> server VLAN --> E2 namespace (macvlan, private)
```

E1 and E2 are separate network namespaces on the controller, each with a macvlan in `private` mode
on the server-VLAN NIC; no router or switch topology change is required. The router forwards a
hairpin on the same interface. This is a genuine IPv6 forwarding/RPDB test but **not** a two-interface
physical-transit test and **not** a hardware-accelerated-path test.

## 4. RPDB evaluation sequence (verified read-only)

```
0:      from all lookup local                     (D is not local; no match, continue)
10410:  from <Route64 /56> lookup main …          (S does not match)
10411:  from <Route64 /56> lookup 41913            (S does not match)
10412:  from <Route64 /56> unreachable             (S does not match)
10413:  from <Route64 VXLAN address> lookup 41913  (S does not match)
10414:  from <Route64 VXLAN address> unreachable   (S does not match)
21031:  from fd42:901::a1 unreachable              (the only rule this experiment owns)
32766:  from all lookup main
32767:  from all lookup default
```

Priority `21031` was free at observation. `ip -6 route get <D> from <S>` selects the on-link VLAN
interface before the rule and returns `unreachable` after it. The flow therefore reaches `21031`
rather than being resolved by an earlier production rule.

## 5. A/B/A probes

Each phase sends **20 matching** datagrams from S and **10 control** datagrams from C to D on
UDP/54321 at 0.5 s intervals; E2 runs a non-replying UDP listener and both namespaces capture.

- **A1 — baseline:** 20 matching + 10 control delivered to E2; E1 capture shows 20 sent.
- **B — guard:** exactly one `from S unreachable pref 21031` rule; 20 matching sent, **0 delivered**;
  10 control delivered; independent E2 capture shows no matching packet; `route get` is terminal;
  ICMPv6 errors are recorded where the target emits them.
- **A2 — restore:** exact rule deleted; 20 matching + 10 control delivered; `route get` recovers.

Pass requires exact counts, zero matching packets at E2 during B, control continuity, and no
unexpected rule/table change. A negative probe without a successful positive baseline is not
accepted; `route get` alone is control-plane evidence, not dataplane qualification.

## 6. Exact proposed mutation and cleanup

```bash
# Preflight (read-only; the adapter does this and aborts on any mismatch)
ip -6 rule show | grep -E '^21031:' && exit 1
ip -6 rule show | grep -F 'fd42:901::a1' && exit 1
ip -6 route get <D> from fd42:901::a1        # must be on-link, no "via"
cat /etc/version; uname -r
cat /proc/device-tree/model; cat /sys/class/net/eth0/address
systemd-run --help | grep -q -- --on-active
command -v ip; command -v sh; test -w /tmp

# Mutation (exactly one rule; no table, route, interface, package or configuration change)
sudo ip -6 rule add from fd42:901::a1 unreachable pref 21031
ip -6 rule show | grep -E '^21031:[[:space:]]+from fd42:901::a1 unreachable'

# Cleanup (exact; idempotent; refuses a foreign rule at the same priority)
sudo sh /tmp/sadr-r1-cleanup.sh fd42:901::a1 21031 /tmp/sadr-r1-cleanup.log
if ip -6 rule show | grep -Eq '^21031:'; then echo 'cleanup verification failed' >&2; exit 1; fi
```

## 7. Device-local deadline and cleanup mechanism

The adapter transfers `r1-cleanup.sh` to `/tmp`, verifies its SHA-256, and arms a transient timer
**before** adding the rule:

```bash
sudo systemd-run --unit=sadr-r1-cleanup --on-active=<deadline> \
  /bin/sh /tmp/sadr-r1-cleanup.sh fd42:901::a1 21031 /tmp/sadr-r1-cleanup.log
```

The timer survives SSH loss and creates a device-side execution bound (a controller timeout alone is
not a device-side bound). The cleanup script:

- deletes only the exact owned tuple `21031: from fd42:901::a1 unreachable`;
- refuses a foreign or duplicate rule at the priority and exits non-zero;
- is idempotent (absent = success), verifies the deletion and handles a concurrent delete;
- logs to `/tmp/sadr-r1-cleanup.log`.

After normal cleanup the adapter cancels the timer only after the deletion is verified; a failed
cleanup leaves the device timer armed as the retry/backstop. Cleanup failures are reported as
recovery failures, never as passes. Off-device tests cover the cleanup script's normal, absent,
foreign, duplicate, failed-delete, concurrent-delete and unreadable-table cases, the adapter's plan
and hash-refusal paths, the harness cleanup/verification gates and the generic-Linux A/B/A sequence.
The adapter's device timer, interrupt path and end-to-end run are exercised only on the target; that
is what R1 establishes.

## 8. Production invariants and abort conditions

Measured before and after (and between phases): management SSH; router IPv4/IPv6 default routes;
protected rules `10410–10414` unchanged; table `41913` route count unchanged; BGP neighbour and
established counts unchanged from the observed baseline (2 neighbours, 1 established; no requirement
that the inactive neighbour establish); available memory above 32 MiB; selector/priority free.

Abort immediately on: management loss; any unapproved rule/table/interface change; a foreign rule at
`21031`; the route lookup not being terminal in B; matching delivery in B; control-flow loss;
protected state or BGP change; memory pressure; failed/uncertain cleanup; or any need to change a
second production object. Abort runs the exact cleanup and reports a recovery failure if it cannot
verify it. Ordinary ICMP latency variation is not treated as forwarding failure.

## 9. Required operator actions

1. **Privilege:** run the harness/adapter as root (e.g. `sudo -E`) with `SADR_QUAL_SSH_KEY` pointing
   at the operator's key, or grant a narrow sudo rule for `ip netns`, `ip link`, `tcpdump` and
   `timeout` on the controller. `sudo -n` for the operator account currently requires a password.
2. **Approval:** set `not_after` in the authorization candidate, sign the approval record and run the
   batch. No cryptographic signing is implied; the approval is an explicit maintainer-approved
   authorization document.
3. **Recovery:** confirm the management path cannot match S (it cannot: S is a ULA absent from
   production) and that the device timer is the accepted recovery mechanism. Serial console is
   desirable, not mandatory for R1, because the rule cannot affect management return traffic.
4. **Optional:** if a physically separate endpoint is required, provide SSH access to a Linux VM on
   an internal VLAN; otherwise R1 uses the namespace pair and claims only software-path evidence.

## 10. Authorization candidate

`docs/r1-authorization-candidate.json` is populated with the device fingerprint, test id, duration,
exact scope, recovery, adapter SHA-256 and cleanup SHA-256. Only `not_after` and the approval record
are left to the maintainer. The harness invocation is:

```bash
sudo -E \
  SADR_QUAL_CANARY_CMD='bash qualification/adapters/r1-canary.sh --execute' \
  SADR_QUAL_CLEANUP_CMD='ssh <router> sudo sh /tmp/sadr-r1-cleanup.sh fd42:901::a1 21031 /tmp/sadr-r1-cleanup.log' \
  SADR_QUAL_VERIFY_CMD='ssh <router> "! ip -6 rule show | grep -q \"^21031:\""' \
  qualification/profile.sh --profile canary --execute --authorize \
    --router <user>@<router> --device-id 'Ubiquiti EdgeRouter' \
    --device-fingerprint 0896090dabbf415be33b51fe09e1edad5605e65febb95db9293bbe6b2d667440 \
    --test-id R1-guard-only --authorization docs/r1-authorization-candidate.json \
    --adapter qualification/adapters/r1-canary.sh \
    --cleanup qualification/adapters/r1-cleanup.sh \
    --out /secure/r1-run
```

## 11. Executable hashes and off-device evidence

| Artifact | SHA-256 |
|---|---|
| `qualification/adapters/r1-canary.sh` | `4645f199df73d78b80687f19bb1246aba48259ec3130d61bf1a76b313e75cca4` |
| `qualification/adapters/r1-cleanup.sh` | `a32e1d8c97bf88fe3e072ccbd23afca6d61c186170288d1922ce40a379d54843` |

Off-device evidence: qualification plan/profile/cleanup tests pass (42 + 13 assertions); the
generic-Linux A/B/A simulation passes 8/8 and the full netns suite 145/0. These are generic-Linux
results, not EdgeOS evidence; the target run is what R1 establishes.

## 12. What R1 will and will not establish

**Will establish (target):** on this exact ER-X/EdgeOS 3.0.1 target, a single IPv6 RPDB `unreachable`
rule at priority `21031` matching a synthetic ULA `/128` drops matching **forwarded** software-path
traffic before egress, leaves nonmatching traffic unaffected, can be installed and removed exactly,
and is bounded by a working device-local timer. It also establishes that the protected production
rules/table and observed BGP state are unchanged by such a rule.

**Will not establish:** HWNAT accelerated-path correctness (no statistics and no flow proof);
two-interface physical-transit behavior (hairpin topology); SADR policy/table/route behavior (R2+);
configuration-engine transactions; boot ordering; fail-closed behavior for real constrained sources;
source-selection behavior for provider-assigned prefixes; or production migration readiness.

## 13. Approval record

```text
Approved by: ____________________
Role:        ____________________
Date/time:   ____________________
not_after:   ____________________  (UTC YYYY-MM-DDTHH:MM:SSZ)
Device fingerprint: 0896090dabbf415be33b51fe09e1edad5605e65febb95db9293bbe6b2d667440
Test ID:     R1-guard-only
Scope:       one unreachable rule at priority 21031 for fd42:901::a1/128
Recovery:    device-local timer + r1-cleanup.sh exact deletion/verification
```

Until this record and the matching JSON authorization exist, R1 is **BLOCKED**.
