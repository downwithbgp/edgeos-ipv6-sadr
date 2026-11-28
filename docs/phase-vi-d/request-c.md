# Phase VI-D — execution-ready HWNAT maintenance-window request C

**Status:** prepared, NOT AUTHORIZED, NOT EXECUTED. This replaces the non-production-only Phase VI-B
request C. No acceleration change, reboot, package installation, migration or firewall change is
authorized by this document.

## 1. Current state (read-only, verified)

- Configuration: `system { offload { hwnat enable; ipsec enable } }`.
- Effective runtime: `/proc/mt7621/hw_nat` reads `1` (hooks installed).
- Driver: built into the kernel (no `hw_nat` module listed; `CONFIG_RA_HW_NAT=y`).
- FOE observation: no `/dev/hwnat0`, no vendor tool, op-mode statistics unavailable.
- SADR product: not installed; no SADR policies on the device.

## 2. Open questions the window must answer

1. Does the supported EdgeOS configuration path disable HWNAT immediately, or does it require a
   service restart or reboot? **Not established.** The `/proc/mt7621/hw_nat` write can detach the
   hooks and clear the FOE table at runtime (source), but it is not a supported operator interface.
   If a reboot is required, it must be named and separately approved.
2. What happens to existing FOE entries on disable (detach + memset, ageing, or undefined)?
3. What is the forwarding interruption and recovery time?
4. What are the CPU/throughput implications of software forwarding for the production profile?
5. Does the lab-VXLAN test path use hardware acceleration at all (currently UNKNOWN)?

## 3. Proposed window

| Stage | Action | Evidence | Stop condition |
|---|---|---|---|
| 0 | Read-only inventory: exact config, proc, counters, routes/rules/BGP, baseline captures | sanitized inventory | unexpected protected state |
| 1 | Operator and independent recovery present; snapshot config/routes/rules | authorization record | any gate failure |
| 2 | Baseline with current acceleration: lab-VXLAN A1/B/A2 + TCP/UDP throughput/pps/CPU/loss/convergence + connectivity probes | captures, counters, timeline | wrong-provider packet or unexplained loss |
| 3 | Disable HWNAT through the supported configuration path; commit; record interruption, proc/config, FOE state and forwarding recovery | timeline, proc/config, captures | forwarding does not recover, or protected state changes |
| 4 | Repeat the same SADR measurements with acceleration disabled | captures, throughput/pps/CPU | any invariant violation |
| 5 | Restore the exact previous configuration; verify proc/config, forwarding and performance; remove test policies | before/after comparison | restore failure (independent recovery) |
| 6 | Report; no package installation, migration or release claim | sanitized report | — |

## 4. Required evidence of effective disablement

- Configuration shows `hwnat disable` (or the exact supported equivalent).
- `/proc/mt7621/hw_nat` reads `0` (hooks detached) and remains 0.
- Forwarding works for the test and production traffic after the change.
- FOE state is recorded as available/UNKNOWN; no assumption of a clean table without evidence.
- Performance is measured, not inferred from ICMP/traceroute.

## 5. Restoration and abort

- Restore the exact previous `system offload` stanza and commit; verify proc/config and forwarding;
  compare the performance measurements.
- Maximum approved outage and abort conditions must be set by the maintainer in the authorization.
- Abort and restore on: wrong-provider packet, unexplained production loss, protected-state change,
  inability to verify effective disablement, loss of independent management, or any unauthorized
  side effect.
- Operator presence and an independent recovery path are mandatory.

## 6. Authorization required

A separate maintenance-window authorization naming the exact device, window, supported commands,
restart/reboot permission (if needed), rollback procedure, stop conditions and evidence. It must
forbid firewall changes, interface/VXLAN/BGP changes, package installation, migration and R2.
