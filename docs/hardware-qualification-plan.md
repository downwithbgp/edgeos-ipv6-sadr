# Hardware qualification plan

**Status:** plan only. **Not executed.** Hardware access, installation on the production router and
migration are separately authorized activities. This document defines the evidence required before a
compatibility claim or release publication.

## 1. Purpose and authorization

The objective is to qualify the off-device v0.1.0 implementation on the exact target:

```text
Device:       Ubiquiti EdgeRouter X / ER-e50
EdgeOS:       3.0.1
Firmware:     EdgeRouter.ER-e50.v3.0.1.5862409.*
Kernel:       4.14.54-UBNT
Architecture: mipsel
```

A successful hardware session produces **Verified (target)** evidence for the tested firmware and
hardware only. Other models, firmware builds and kernels remain unsupported. Execution requires
explicit authorization; the plan itself does not authorize router mutation.

## 2. Artifacts and preconditions

- Package built reproducibly from a named commit; record `.deb` SHA-256, source commit and package
  version.
- Exact firmware file, kernel string, `ip` version and installed package inventory.
- Configuration backup (`/config/config.boot`), kernel rule/table snapshot, the operator's manual
  restore script and an independent management path (console or a separate management interface).
- Maintenance window and an explicit abort/rollback owner.
- Capture points on the provider-facing links and a packet generator/validator independent of the
  router.
- The existing manual table `41913` and rules `10410–10414` are treated as production state. They
  are not modified during qualification unless a separately authorized migration step says so.

## 3. Safety rules

1. Do not globally disable hardware offload, change the production firewall or alter unrelated
   routing objects without approval.
2. Never flush the RPDB or a table; only extension-owned objects may be removed by the reconciler.
3. A failed check is reported as a failure. A routing safety failure and a reachability failure are
   distinct outcomes.
4. Capture continuous packet evidence during every transition. Final-state checks alone are
   insufficient.
5. Stop and roll back on any wrong-provider packet, loss of independent management or unclassified
   foreign-state mutation.

## 4. Qualification matrix

| ID | Area | Required checks | Evidence | Pass criteria |
|---|---|---|---|---|
| H1 | Install/platform | Preinst firmware/kernel guard; package contents; service enablement; no vendor-file modification | command output, package hash | Exact supported platform; guard refuses others; only extension paths changed |
| H2 | Configuration engine/transactions | Subtree discovery/tab completion; priority 500 ordering vs interfaces/static; working vs active reads; failed commit after the end hook; commit/commit-confirm/rollback; simultaneous interface+SADR; monitor during commit; save/reboot persistence | CLI transcripts, `show configuration commands`, compare, kernel state and captures | Active configuration wins after failure/rollback; no stale authority or foreign deletion; convergence observed |
| H3 | Boot ordering/failure propagation | Guard before sysctl/network-pre/router; monitor after router; missing/malformed/unreadable config; guard conflict and `ip` failure; native config commit/rollback; upgrade/reboot; boot-window capture | boot trace, journal, captures, service status | No constrained-source leak; guard failure and management connectivity characterized; unavoidable exposure documented |
| H4 | RPDB/kernel 4.14 | Rule/table/guard creation; longest-source-prefix order; table disappearance; missing terminal default; partial rule install; process kill at mutation boundaries; monitor restart | `ip rule/route` output, injected failures | Source on intended/previous provider or blocked; never unauthorized provider |
| H5 | Interfaces | Provider/internal up/down; delete/recreate; VLAN/bridge; PPP/PPPoE or interface-only; MTU/PMTUD; ICMPv6 error/control traffic | interface events, captures, `ping`/`traceroute` | Routes repaired after recreation; no provider fallback; MTU/PMTUD behavior documented |
| H6 | Dataplane | Real TCP/UDP; established flows during policy changes; wrong-provider zero-packet checks; packet captures | capture files, flow logs | No wrong-provider packets; fail-closed behavior observed |
| H7 | Offload | Hardware offload enabled and disabled; functional correctness first, then CPU/throughput | captures, counters, CPU | Offload does not bypass RPDB policy; any offload defect blocks the claim |
| H8 | Source selection | Forwarded, source-bound local and unbound router traffic; RFC 6724/8043/8028/8678 analysis | `ip route get`, captures, application tests | Separate cases reported; no automatic optimal-source claim |
| H9 | Internal/BGP | Connected routes on internal interfaces; configured exceptions; withdrawal; dynamically learned internal routes; ECMP/ambiguous next hops; interface rename/recreate | routing tables, captures | Internal destinations do not fall to a provider; unknown interfaces are not trusted |
| H10 | Interaction | Native firewall and `edgeos-vxlan`; manual table/rules shadowing; no foreign mutation | before/after snapshots, diffs | Only extension-owned objects change; manual state untouched unless authorized |
| H11 | Resources | Boot time; CPU/memory of monitor/reconcile; event storms; coalescing; log volume | `ps`, systemd accounting, timing | Bounded on ER-X; no runaway restart/event loop |

## 5. Execution sequence

1. Inventory and backup; verify independent management; record baseline snapshots.
2. Install the exact package; verify preinst acceptance and service files. Do not configure policies
   yet.
3. Add a minimal single-policy configuration on a non-production source or maintenance window;
   verify guards/tables/rules, then packet paths.
4. Expand to all constrained sources; verify coverage while the manual rules still take precedence.
5. Exercise H4–H9 transitions with continuous captures.
6. Reboot and repeat the boot/guard checks.
7. Record evidence, package hash, timestamps, commands and any deviation.

## 6. Abort and rollback

Abort on wrong-provider traffic, unclassified rule/table changes, loss of management or a failed
guard. Roll back by restoring the backed-up configuration and the manual routing state, then verify
connectivity and absence of extension-owned objects. Table `41913` and rules `10410–10414` are
restored from the recorded snapshot only if a migration step changed them.

## 7. Exit criteria

Hardware qualification is complete only when H1–H11 have recorded evidence, independent review has
accepted it, and the operator explicitly authorizes a compatibility claim. Package build success,
off-device tests or a successful install alone are not qualification.

## 8. Non-guarantees

- No claim for other hardware, firmware or kernels.
- No claim that the boot window is closed until H3 passes.
- No claim that unbound local applications select an optimal source address.
- No claim of provider health, failover or end-to-end reachability from route presence.
