# Phase VI-B — capability and evidence gaps

**Purpose:** explicit register of what is known, what is only indicated, and what requires an
authorized experiment. Labels: Verified (target), Verified (target source), Verified (generic Linux),
Strongly indicated, Unverified.

## 1. Verified

| Capability | Evidence |
|---|---|
| Target identity/firmware/kernel/iproute2 | ER-X / ER-e50, EdgeOS 3.0.1.5862409, 4.14.54-UBNT, iproute2-ss171113 (read-only) |
| Kernel IPv6 multiple tables / FIB rules / source subtrees | exact GPL `.config`: `IPV6_MULTIPLE_TABLES=y`, `FIB_RULES=y`, `IPV6_SUBTREES=y` |
| Kernel IPv6 as a module | `CONFIG_IPV6=m` |
| HNAT/PPE built in, IPv6 acceleration enabled | `RA_HW_NAT=y`, `HNAT_V2=y`, `RA_HW_NAT_IPV6=y`, `TBL_16K`, `PPE_MCAST` |
| Bind threshold value | `CONFIG_RA_HW_NAT_BINDING_THRESHOLD=30`, programmed into `PPE_FOE_BNDR` |
| Age/keepalive deltas | `UNB_DLTA=3`, `TCP/UDP/FIN/NTU_DLTA=5`, `TCP/UDP/NTU_KA=1` |
| HNAT control surface | `/proc/mt7621/hw_nat` (reads `1`), `system offload { hwnat enable }`, char device `hwnat0` ioctls |
| No per-prefix/per-interface exclusion | no such source path; ACL/AC/MTR modules not built with `HNAT_V2` |
| HNAT data path | driver hooks: RX fast path without `netif_rx`, TX bind in `ndo_start_xmit`; no netfilter in HNAT |
| IPv6 source in the FOE key | 5T src/dst/ports, 3T src/dst/proto; flow-label hash disabled |
| No route/RPDB notification or automatic invalidation | no notifier in HNAT; invalidation only by ageing, proc disable, module stop, ioctls |
| Lab VXLAN path without a firewall chain | `VYATTA_FW_IN_HOOK` has no `vxlan<lab>` chain; route lookup selects `vxlan<lab>` |
| RPDB model correctness (generic Linux) | netns 145/0, including the broad-model leaks, whitelist passes and candidate-B leak |
| Invariant enforcement in the reconciler | ownership, whitelist derivation, rule-priority construction, mutation phases, verification |
| R1 executable readiness (retired production-canary candidate) | execution manifest verified; adapter/cleanup/install hashes bound; qualification suites pass. The lab-VXLAN candidate is not executable until the adapter topology override and candidate regeneration are complete. |

## 2. Strongly indicated (not proven on the target)

| Claim | Why it matters | Needed evidence |
|---|---|---|
| Active flows keep FOE entries alive; ageout is an idle timeout, not a stale-egress bound | Fail-closed may be unbounded for active traffic | Environment A: long-lived flows with mid-flow changes; FOE state and captures |
| Bind threshold is ~30 packets/second | Determines when offload starts | Environment A: rate sweep with FOE state |
| Age/keepalive deltas are ~5 time units | Determines idle expiry | Environment A: idle expiry measurement |
| Lab-VXLAN traffic is software-forwarded | Environment B cannot establish G1 | Environment A/B: FOE state for the lab path |
| HNAT honours the egress selected by RPDB at bind | Core of I1 on hardware | Environment A: two sources to distinct provider egresses with FOE state |
| A source-prefix ip6tables guard is bypassed for bound flows | Guard cannot enforce fail-closed | Environment A: guard + bound flow + captures/counters |

## 3. Unverified (requires a named experiment)

| Gap | Experiment |
|---|---|
| Target `ip -6 route add ... from` parser and `proto 194` rendering | Request D (isolated netdev/table or qemu) |
| Target source-specific forwarding semantics | Request D |
| FOE bind/ageout/refresh behaviour under route/RPDB changes | Request A (G1) |
| Whether a firewall guard prevents binding and/or is bypassed after binding | Request A (AC-5) |
| IPv6 module load/boot ordering and state loss | Request E (G2) |
| Offload disabled performance (throughput, pps, CPU, flows, convergence) | Request A (AC-8) |
| EdgeOS config engine: priority, `exists`/`existsEffective`, scripted/interactive commit, rollback | Environment A maintenance tests (T15) |
| Production provider/BGP dynamics and real provider withdrawal | Environment A or a separately authorized production observation |
| Host source selection (RFC 6724) for unbound local sockets | host-side experiment; not a router guarantee |
| Provider ingress filtering (BCP 38) | outside the router; provider-side evidence |

## 4. Named non-guarantees

- No end-to-end provider health or remote transit verification.
- No RFC 6724 source-selection control for unbound local sockets.
- No zero-exposure boot window on hardware until G2 is verified.
- No automatic discovery of internal BGP prefixes; exact exceptions are operator-owned.
- No claim for untested firmware, hardware offload paths or other platforms.
- No claim that a route/guard proves connectivity.

## 5. Register maintenance

This register is updated when an experiment closes a gap; the evidence label changes only with a
recorded environment, command, date and commit. Until then, the gap remains open and the affected
release claim remains blocked.
