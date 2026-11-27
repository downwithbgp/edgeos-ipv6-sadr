# Phase VI-C — revised maintenance-window qualification request C

**Status:** request only; nothing is authorized or executed. Request C in Phase VI-B (non-production
only) is replaced by this staged production maintenance-window proposal. No acceleration change,
package installation, firewall change, interface/VXLAN change, BGP withdrawal or reboot is
authorized by this document.

## 1. Objective

Qualify SADR with hardware acceleration **disabled** on the production ER-X, compare observed
forwarding with the HWNAT-enabled state, and restore the exact existing acceleration configuration —
without violating the protected state (`main`, table `41913`, rules `10410–10414`) or changing the
firewall.

## 2. Open questions to resolve before execution

- Supported disable/enable operations: EdgeOS configuration commit (`system offload { hwnat ... }`)
  versus `/proc/mt7621/hw_nat`; which one is supported and whether either requires a restart/reboot.
- Effect on existing FOE entries: detach + memset, ageing only, or undefined; observed forwarding
  interruption and recovery time.
- CPU/throughput implications of software forwarding for the production traffic profile.
- Independent recovery path and operator presence.
- Whether the lab-VXLAN test path is offloaded at all (FOE state is UNKNOWN on this firmware).

## 3. Staged proposal

| Stage | Action | Evidence | Stop condition |
|---|---|---|---|
| 0 | Read-only inventory: offload config, proc flag, module state, counters, baseline captures, exact current acceleration configuration | read-only output | unexpected protected-state change |
| 1 | Authorize a bounded maintenance window with an operator and independent recovery; snapshot config/routes/rules | authorization record | any gate failure |
| 2 | Baseline: run the lab-VXLAN A1/B/A and TCP/UDP performance with the current acceleration state; record FOE availability/UNKNOWN | captures, counters, timestamps | wrong-provider packet or unexplained loss |
| 3 | Disable HWNAT through the supported configuration path; commit; record interruption, proc flag and forwarding recovery | timeline, proc/config, captures | forwarding does not recover or protected state changes |
| 4 | Run the same SADR A1/B/A and performance set with HWNAT disabled | captures, throughput/pps/CPU | any invariant violation |
| 5 | Restore the exact previous acceleration configuration; verify proc/config, forwarding and performance; remove any test policies | before/after comparison | restore failure (independent recovery) |
| 6 | Report; no SADR package installation, migration, firewall exception or release claim | sanitized report | — |

## 4. Measurements

- Forwarding correctness: A1 20/20 + control 10/10, B matching 0/20 + control 10/10, A2 restoration;
  internal destination preservation; no wrong-provider packet.
- Performance: TCP/UDP throughput, packets per second, CPU utilization, loss, convergence; real
  traffic generators, not ICMP/traceroute inference.
- Interruption: exact outage window and recovery time for the acceleration change and restore.
- Protected state before/after: rules `10410–10414`, table `41913`, BGP state, default routes,
  memory.

## 5. Authorization requirements

A separate, explicit maintenance-window authorization must name the exact device, window, operator,
acceleration commands, rollback procedure, stop conditions and the evidence to record. It must
explicitly forbid firewall changes, interface/VXLAN changes, BGP withdrawal, package installation,
migration, reboot unless separately approved, and R2. If the supported disable/restore operation
requires a reboot, that must be named and separately approved.

## 6. Relationship to the support contract

Until a qualified exclusion or synchronized invalidation mechanism exists (see
`invalidation-and-compatibility.md`), the supported SADR configuration is **HWNAT disabled**. This
request is the path to qualify that configuration on the target; it does not by itself change the
support claim.
