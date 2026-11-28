# Phase VI-B — hardware-offload correctness acceptance criteria

**Status:** acceptance criteria and failure disposition. No target experiment is authorized by this
document; the criteria apply to the qualification plan (`qualification-plan.md`).

**Source basis:** `hnat-analysis.md` (exact vendor tree, read-only target facts). The key structural
facts are: HNAT binds in the Ethernet driver after the first packets traverse routing/RPDB and
netfilter; bound flows are then forwarded by the PPE without re-entering the stack; there is no
route/RPDB-change notification or automatic invalidation; the bind timestamp is written once; no
per-prefix/per-interface exclusion exists in this build; the only runtime control is the global
`/proc/mt7621/hw_nat` / `system offload hwnat` switch.

## 1. Definitions

- **Offloaded flow:** a flow whose packets are forwarded from a PPE FOE entry rather than by the
  Linux stack. "Offload enabled" is not evidence that a given flow is offloaded; each acceptance
  test must establish offload state for the flows it claims to test.
- **Software path:** forwarding through the Linux stack (route lookup, RPDB, netfilter).
- **Transition:** any change of routes, rules, tables, interfaces, tunnels or configuration that can
  alter the intended egress.

## 2. Acceptance criteria

| ID | Criterion | Pass condition | Evidence |
|---|---|---|---|
| AC-1 | Offload state is established per flow | For each tested workload, record whether the flow created/used a FOE entry (dump/counters, bind logs where available) and its state over time | FOE counters/dump, dmesg if available, independent captures |
| AC-2 | Steady-state egress correctness | For PA-sourced external traffic, every captured packet leaves the PA egress; PB→PB; internal destinations use the internal path. Zero wrong-provider packets for TCP and UDP, bidirectional and unidirectional, single and concurrent flows, below and above the binding threshold | Simultaneous independent captures at both provider egresses and the internal link |
| AC-3 | Transition correctness | During and after provider route withdrawal/restoration, RPDB insert/remove/replace, tunnel failure/recovery, internal route change, repeated churn, commit/rollback: zero unauthorized egress. Offloaded flows must be shown correct or invalidated; correctness must not rely on the ageout | Captures on a single timeline, route/rule state, FOE state |
| AC-4 | No unbounded stale egress | A mid-flow RPDB/route change must not leave an active flow on the old egress beyond a declared, measured bound. Measure long-lived flows with continuous traffic (does the entry stay alive indefinitely?) and idle flows. If any active flow can remain on an unauthorized egress, the platform fails this criterion unless the guarded traffic is excluded from offload | Long-lived TCP/UDP with mid-flow changes; captures; FOE state; time-stamped timeline |
| AC-5 | Fail-closed can be enforced with offload | With a source-prefix guard/terminal unreachable rule in place, no external packet from the constrained source leaves any provider, including flows that were bound before the guard. If bound flows bypass the guard, the test must show it and the design must not rely on the guard for those flows | Counter deltas, captures, FOE state, rule/table state |
| AC-6 | Local vs forwarded behaviour | Forwarded traffic follows the invariants; locally originated traffic is documented (never bound; source rules apply) and does not create hidden offload state | Local-origin probes, FOE state, captures |
| AC-7 | Exclusion mechanism is demonstrable | The only available exclusion is the global HNAT switch. Demonstrate that disabling it (in the authorized environment) stops binding and forwarding from FOE entries, and that re-enabling does not resurrect stale policy | `/proc/mt7621/hw_nat` read-only before/after (write only if authorized), FOE state, captures |
| AC-8 | Performance is measured, not inferred | Real TCP/UDP throughput, packets per second, CPU utilization, concurrent flows, loss and convergence for software vs offload forwarding. ICMP echo/traceroute latency alone is not accepted | Load generator, CPU counters, captures, recorded environment |
| AC-9 | Boot/module lifecycle | With `CONFIG_IPV6=m`, verify rules/tables cannot exist before `ipv6` loads, whether module reload drops RPDB/FOE state, and that the early guard ordering leaves no unguarded forwarding window | Boot trace, state snapshots, captures |
| AC-10 | Evidence quality | Independent packet capture at both provider egresses; raw data outside the repository; evidence label per claim; explicit pass/fail per criterion; stop conditions obeyed | Run record and review |

**A successful `ip -6 route get`, a single low-rate UDP delivery, or an "offload enabled" banner does
not establish offload correctness.** Each pass requires packet delivery evidence and offload-state
evidence for the tested flows.

## 3. Fail-closed guard analysis (netfilter vs HNAT)

Source findings:

- The bind is created in `ndo_start_xmit` after the first packets have traversed the stack, so the
  **first** packets are subject to netfilter rules.
- Bound flows are forwarded by the PPE from the FOE entry; the RX hook returns to the fast path
  without `netif_rx`, and the driver contains no netfilter reference. Bound packets are therefore
  **not** re-checked against ip6tables FORWARD/OUTPUT rules.
- A source-prefix `unreachable` RPDB rule is likewise not consulted for bound flows.

Consequences:

1. An ip6tables source-prefix guard can prevent a flow from **binding** (if it drops the flow's
   first packets) but cannot be assumed to enforce fail-closed after binding. "The rule exists" is
   not evidence for bound flows.
2. A terminal `from S unreachable` RPDB rule protects the software path and new flows; it does not
   remove existing FOE entries.
3. The design must either (a) prove that guarded traffic is never offloaded, (b) exclude it (not
   available per-prefix in this build), or (c) accept the measured stale-egress window as a
   documented platform limitation with the affected traffic not deployed. Option (c) is not a
   fail-closed guarantee.

## 4. Selective exclusion feasibility

| Mechanism | Available in this build? | Assessment |
|---|---|---|
| Per-prefix / per-interface offload exclusion | No | No such control exists in the source or config model |
| ACL/accounting/metering policy stage | No | `acl_policy.o`, `ac_policy.o`, `mtr_policy.o` are only built without `CONFIG_HNAT_V2`; this build sets `HNAT_V2=y` |
| Global HNAT enable/disable | Yes | `/proc/mt7621/hw_nat` (read `1` on the target) and `system offload { hwnat enable }`; disabling memsets the FOE table and detaches the hooks |
| Entry-level unbind/invalidate ioctls | Yes (char device `hwnat0`) | Requires an external per-flow tracker; not a policy mechanism and not integrated with RPDB |
| Disable offload only in a maintenance window | Operationally possible | Global, not selective; requires authorization and a reboot/config commitment depending on the platform path |

If HNAT cannot guarantee the invariants, the supported fallback is **software forwarding with HNAT
disabled**, measured on a dedicated test router (Environment A) or in an authorized maintenance
window — not a per-flow userspace workaround.

## 5. Performance fallback quantification

When HNAT is disabled, quantify on the dedicated test router:

- TCP and UDP throughput (both directions), packets per second, CPU utilization per core,
  concurrent-flow scaling, loss and convergence after route/rule changes;
- the same workloads with HNAT enabled where correctness permits, for comparison;
- the target's role (edge router, two providers, VLANs, one or more tunnels) and the measured
  software-forwarding headroom.

Correctness is a gate; performance is a recorded qualification result. A performance shortfall does
not justify an unproven offload path, and an offload path that violates an invariant is a release
blocker regardless of throughput.

## 6. Failure disposition

If HNAT cannot be shown to preserve I1/I2/I5/I9 for the guarded traffic:

1. Investigate supported selective exclusion. **Result for this build: none exists** (section 4).
2. Quantify software forwarding on a dedicated test router. If the required performance is met,
   qualify the product with HNAT disabled for the SADR deployment (documented configuration).
3. If neither correctness nor performance is met, classify the platform limitation explicitly in the
   release-blocker register and product documentation. Do not introduce an undocumented production
   workaround (for example, relying on the ageout, disabling the guard, or scripting entry
   invalidation without a tracking model).

## 7. Stop conditions

Any observed wrong-provider packet, any silent fail-open after a rule/route change, or any
inability to establish per-flow offload state stops the run, preserves the evidence and blocks the
SADR qualification claim until reviewed. The target qualification execution gate requires a fresh,
candidate-bound authorization; this document authorizes nothing.
