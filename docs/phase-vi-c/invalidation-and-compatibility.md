# Phase VI-C — selective FOE invalidation feasibility and HWNAT compatibility behaviour

**Status:** feasibility assessment and proposal only. No FOE write, invalidation ioctl, global flush,
register write, module reload or driver modification was performed. No compatibility enforcement is
implemented; its failure semantics require maintainer approval.

## 1. Source facts (exact vendor tree)

- The driver exposes a char device (`hwnat0`, major 220) with `HW_NAT_GET_ALL_ENTRIES`,
  `HW_NAT_DUMP_ENTRY`, `HW_NAT_DUMP_CACHE_ENTRY` (read-intended) and `HW_NAT_BIND_ENTRY`,
  `HW_NAT_UNBIND_ENTRY`, `HW_NAT_INVALID_ENTRY` (write) commands
  (`net/nat/hw_nat/hwnat_ioctl.{h,c}`, `ra_nat.c`). There is **no** source-prefix selector, no
  generation counter and no route/RPDB notifier.
- Runtime: `/dev/hwnat0` does **not** exist on the target; no vendor hwnat/FOE tool was found;
  `show ubnt offload statistics` is unavailable; `/proc/mt7621/hw_nat` only reads the global
  hook flag (`1`); dmesg carries no FOE lines. The ioctl path is therefore not reachable without
  deploying a helper, which exceeds the authorized one-rule mutation scope.
- Bind happens in `ndo_start_xmit` after the first packets traverse routing/RPDB and netfilter; the
  FOE entry stores the L2 rewrite and L3/L4 tuple. No table/rule identity is stored.
- Invalidation exists only as hardware ageing, a global proc toggle (detach hooks + memset the FOE
  table), module stop, or the write ioctls. The bind timestamp is written once; the age deltas
  (`UNB=3`, `TCP/UDP/FIN/NTU=5`) have undocumented units and hardware hit-refresh is unproven.

## 2. Feasibility assessment

| Question | Finding |
|---|---|
| Individual IPv6 entries identifiable? | Yes in principle: dump/get by 5T/3T tuple. Requires the char-device node and a userspace helper. |
| Select by source prefix? | No dedicated API. A userspace dump-and-match is possible but not atomic and races with the binder. |
| Forward and reverse entries? | Each direction binds as a separate entry; no pairing API. A helper would have to infer and coordinate both directions. |
| Can hardware bind during invalidation? | Yes. Per-entry invalidation does not stop new binds; there is no atomic policy-generation barrier. |
| Are the operations atomic? | Not established. The ioctl handler's locking versus the driver's `hwnat_mutex` was not verified to line level; there is no generation/epoch mechanism. |
| Adequate locking/synchronization? | No. The kernel has no route/RPDB-change callback; userspace cannot make invalidation atomic with a policy transition. |
| Effect on unrelated traffic? | Per-entry invalidation is targeted but unverified; the global proc toggle/flush affects all traffic and detaches the fast path. |
| Stable/supportable interface? | No: vendor char device, no device node or tool, not a documented product interface; a reliable mechanism would require vendor support or a driver change (not authorized). |
| Active-flow expiration? | The bind timestamp is written once; do not infer active-flow expiry from it. Hardware hit-refresh remains unproven; an active flow may keep a stale egress. |

**Conclusion:** mechanisms **A** (reliable exclusion of SADR-managed flows) and **B** (reliable,
synchronized invalidation preserving invariants through policy changes) are **not qualified** on this
firmware. Exclusion is global-only (no per-prefix/per-interface control); invalidation is neither
source-selective, atomic nor synchronized with RPDB/FIB changes. HWNAT-enabled SADR operation
therefore remains **unsupported** and G1 stays blocked. No enforcement mechanism is implemented.

## 3. Proposed HWNAT compatibility behaviour (not implemented)

The product must not claim SADR enforcement while acceleration is unqualified. Proposed semantics:

1. **Detect** the acceleration state from the supported configuration (`system offload { hwnat }`)
   and `/proc/mt7621/hw_nat`; treat any unknown/unreadable state as unqualified.
2. **First activation with HWNAT enabled:** refuse to activate the SADR policy with a clear
   "hardware acceleration unqualified" error; leave native routing untouched and do not install
   partial SADR state. This is a fail-closed product refusal, not a routing change.
3. **HWNAT enabled after SADR activation:** detect at the next reconcile/monitor cycle; report the
   policy as `unqualified-acceleration`; do not claim enforcement; do not silently disable HWNAT.
   Keep the RPDB rules for new software-path flows, but state that already-bound flows are outside
   the guarantee.
4. **Runtime divergence** between configured and effective acceleration: report unqualified and
   require the operator to disable HWNAT and reconcile for a supported state.
5. **Boot:** the early guard cannot control HNAT; after boot, check HNAT state before declaring a
   policy effective. If it cannot be determined, report unqualified.
6. **Explicitly not acceptable responses:** stopping the monitor, removing policies, silently
   disabling HWNAT, or claiming that an RPDB/netfilter guard protects already-bound flows.
7. **Implementation is deferred** until the maintainer approves these failure semantics; the
   supported configuration is "SADR with HWNAT disabled" until a qualified mechanism exists.
