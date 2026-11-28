# Phase VI-B — two-environment target qualification plan

**Status:** design only. No target experiment, R1/R2, production deployment, merge or release is
authorized by this document. Each environment requires a fresh, candidate-bound authorization before
execution.

**Related:** `hnat-analysis.md`, `offload-acceptance-criteria.md`,
`../architecture/architecture-invariants.md`.

## 1. Environments

### Environment A — dedicated physical ER-X (preferred)

A dedicated ER-X / ER-e50 matching the production hardware and firmware as closely as possible:
EdgeOS 3.0.1 build 5862409, Linux 4.14.54-UBNT, MT7621, the same `system offload { hwnat enable }`
setting, and a laboratory provider topology that reproduces two providers, the internal VLANs and at
least one tunnel. It is isolated from production; it may be rebooted, reconfigured and have its
offload toggled.

**Establishes:** the full dataplane qualification — HNAT on/off and FOE state (AC-1), steady-state
and transition correctness (AC-2/AC-3), stale-entry bound (AC-4), fail-closed and the netfilter
bypass (AC-5), local-vs-forwarded (AC-6), exclusion (AC-7), performance (AC-8), boot/module lifecycle
(AC-9) and evidence quality (AC-10); invariants I1/I2/I5/I9 on the exact platform.

**Does not establish:** the production device's exact provider/BGP behaviour or the production
firewall policy; production change safety. It qualifies the platform/firmware combination, not the
specific production unit.

**Requirements:** matching firmware and hardware; two independent provider simulators or lab
transits with capture points on each provider egress and the internal link; a traffic generator able
to produce TCP/UDP, bidirectional/unidirectional and concurrent flows below and above the binding
threshold; FOE counters/dump and, where available, bind/ageout logs; serial console and an
out-of-band recovery path; no production connectivity.

### Environment B — production ER-X over the existing permitted lab VXLAN path

The production ER-X, using the existing lab VXLAN (`vxlan<lab>`) to the controller underlay and the
controller-side peer. **No firewall modification**: `VYATTA_FW_IN_HOOK` has no lab-VXLAN chain
(Verified (target), read-only). The only production mutation is one exact RPDB rule, under a fresh
candidate-bound authorization, with a device-local timer, exact deletion/verification and a
controller-side observation plan.

**Establishes:** R1 A/B/A on the production firmware; RPDB rule install/remove and terminal-guard
behaviour on the software path (if the flow is not offloaded); internal destination preservation for
the lab destination only (no internal-VLAN coverage); identity and fingerprint; containment and
cleanup; the absence of upstream escape on the lab path; the production device's rule/table lifecycle.

**Does not establish:** HNAT correctness. Lab-VXLAN traffic is **expected** to be software-forwarded,
but this is not established: HNAT has no VXLAN handling, yet decapsulation can pass the physical-RX
FOE metadata to the inner skb, and the target terminates the lab tunnel. FOE state must be measured
before any claim; if lab-VXLAN flows are offloaded, Environment B cannot be treated as a software-path
test and the run must stop. Either way it cannot satisfy AC-1/AC-4/AC-5 for offloaded flows, and it
cannot establish real provider withdrawal and restoration, production BGP dynamics, throughput/pps/
CPU, reboot/module lifecycle or commit/rollback for the SADR configuration.

**Limitations:** single permitted path (not a provider path); no firewall exception; one rule and a
bounded window; no R2; the lab path may not create FOE entries at all (to be recorded, not assumed).

## 2. Environment capability matrix

| Requirement | Environment A | Environment B |
|---|---|---|
| AC-1 per-flow offload state | Yes (FOE state) | No (software indicated) |
| AC-2 steady-state egress | Yes | Partial: lab path only |
| AC-3 transition correctness | Yes | Partial: RPDB rule insert/remove only |
| AC-4 stale-egress bound | Yes | Not applicable (no offload) |
| AC-5 fail-closed with offload | Yes | Software-path guard only |
| AC-6 local vs forwarded | Yes | Partial |
| AC-7 exclusion | Yes | No |
| AC-8 performance | Yes | No |
| AC-9 boot/module lifecycle | Yes | No |
| AC-10 evidence quality | Yes | Yes (controller-side captures) |
| I1/I2/I5/I9 (hardware) | Yes | Software path only |
| G1 offload gate | Yes | Cannot close |
| G2 boot/`IPV6=m` gate | Yes | No |

## 3. Dataplane test matrix

Each row is executed in Environment A; Environment B runs only the rows marked. "Captures" means
independent packet capture at both provider-facing egresses and the internal link (Environment A) or
at the controller-side lab endpoints (Environment B).

| Test | Workload | Environment | Pass condition |
|---|---|---|---|
| T1 | IPv6 TCP, bidirectional, single flow | A, B (lab) | every PA packet on PA, PB on PB; zero wrong-provider |
| T2 | IPv6 UDP, bidirectional, single flow | A, B (lab) | as T1 |
| T3 | Unidirectional TCP/UDP (one-way load) | A | as T1 |
| T4 | Concurrent flows (multiple sources/destinations) | A | as T1; no cross-flow leakage |
| T5 | Traffic below the HNAT binding threshold | A | software path correct; offload state recorded |
| T6 | Traffic above the HNAT binding threshold | A | offloaded flows correct (AC-1/AC-2) |
| T7 | Confirmed software-forwarded vs confirmed offloaded flows | A | both correct; offload state proven per flow |
| T8 | Long-lived established TCP/UDP through a route/rule change | A | no unauthorized egress; stale-egress bound measured (AC-4) |
| T9 | New flows created during a transition | A | no unauthorized egress; fail-closed where intended |
| T10 | Provider route withdrawal and restoration | A | no wrong-provider packet; fail-closed; restore correct |
| T11 | RPDB insertion, removal and replacement | A, B (single rule) | no unauthorized egress; cleanup exact |
| T12 | Tunnel failure and recovery | A | no fallback to an unauthorized provider; recovery correct |
| T13 | Internal route changes (add/remove/restore) | A | internal reachability preserved or blocked; no provider fallback |
| T14 | Repeated route/rule churn | A | no wrong-provider packet; convergence recorded |
| T15 | Configuration commit and rollback | A | no transient leakage; rollback restores the previous state |
| T16 | Reboot and `ipv6` module lifecycle (`CONFIG_IPV6=m`) | A | no unguarded window; module reload state documented |
| T17 | Throughput, pps, CPU, loss, convergence | A | measured with real TCP/UDP; no ICMP/traceroute inference |

**Universal pass condition:** zero unauthorized egress in steady state **and** during every
transition. A successful `route get` or a single low-rate UDP delivery is not evidence.

## 4. Independent observation architecture

- Environment A: a capture point on each provider-facing egress and on the internal link; timestamps
  from a single clock; the traffic generator records flow starts/stops; FOE state is sampled before,
  during and after each transition. Raw captures and real addresses remain outside the repository.
- Environment B: the controller-side lab endpoints capture both directions; the router's identity,
  rule state and cleanup are verified from the controller; the production firewall counters are
  recorded before/after (read-only) to prove no production policy change.
- Every claim is labelled with the evidence vocabulary; environment A results are target-hardware,
  environment B results are production-firmware software-path results.

## 5. Authorization gates

1. **Environment A hardware qualification:** a new authorization covering the dedicated router, its
   lab providers, the exact configuration changes and the offload toggling.
2. **Environment B R1 (lab VXLAN):** a fresh candidate-bound authorization for one RPDB rule, bounded
   duration, device-local timer, exact cleanup and controller-side observations
   (`r1-lab-vxlan-authorization-request.md`). It does not authorize R2 or a second rule.
3. **Offload maintenance experiment (only if Environment A is unavailable):** an explicitly
   authorized maintenance window on a non-production test router; never a global production offload
   change.

## 6. Evidence gaps this plan cannot close by design

- BGP-learned internal prefixes remain operator-declared; no automatic discovery.
- RFC 6724 source selection for unbound local sockets remains a host behaviour, not a router
  guarantee.
- Provider-side ingress filtering (BCP 38) behaviour is outside the router.
- The production firewall policy remains the operator's; the plan uses the permitted lab-VXLAN path
  and does not change it.
