# Phase VI-B — source-backed HNAT/PPE analysis

**Scope:** analysis of the exact ER-X vendor kernel tree (`/home/vadim/kernel_e50`, Linux
4.14.54-UBNT) plus read-only target inspection on 2026-11-27. No production or target mutation.

**Evidence labels:** **Verified (target source)** = established from the exact vendor tree;
**Verified (target)** = observed read-only on the device; **Strongly indicated** = source supports the
behaviour but it was not exercised; **Unverified** = requires an authorized experiment.

## 1. Build facts (exact GPL config and Makefile)

`/home/vadim/kernel_e50/.config`:

```text
CONFIG_RA_HW_NAT=y            CONFIG_HNAT_V2=y            CONFIG_RA_HW_NAT_IPV6=y
CONFIG_RA_HW_NAT_TBL_16K=y    CONFIG_PPE_MCAST=y          CONFIG_RA_HW_NAT_BINDING_THRESHOLD=30
CONFIG_RA_HW_NAT_UNB_DLTA=3   CONFIG_RA_HW_NAT_UDP_DLTA=5 CONFIG_RA_HW_NAT_TCP_DLTA=5
CONFIG_RA_HW_NAT_FIN_DLTA=5   CONFIG_RA_HW_NAT_NTU_DLTA=5 CONFIG_RA_HW_NAT_TCP_KA=1
CONFIG_RA_HW_NAT_UDP_KA=1     CONFIG_RA_HW_NAT_NTU_KA=1   CONFIG_RA_HW_NAT_HASH1=y
# CONFIG_RA_HW_NAT_WIFI is not set
# CONFIG_RA_HW_NAT_NIC_USB is not set
# CONFIG_RA_HW_NAT_PPTP_L2TP is not set
```

`net/nat/hw_nat/Makefile` links `ra_nat.o foe_fdb.o util.o hwnat_ioctl.o` and adds
`acl_policy.o/ac_policy.o/mtr_policy.o` **only when `CONFIG_HNAT_V2` is not set** — so the ACL,
accounting and metering policy stages are **not compiled in this build** (Makefile:12-16). The PPE
therefore has no classification/policy stage in front of forwarding, consistent with Phase VI-A's
reading.

## 2. Runtime target facts (Verified (target), read-only)

- `/proc/mt7621/hw_nat` exists (mode 0644) and reads `1` — the RX/TX hooks are installed.
- `/config/config.boot` has `system { offload { hwnat enable; ipsec enable } }`.
- The only configuration selector found in the firmware tree is the template
  `/opt/vyatta/share/vyatta-cfg/templates/system/offload/hwnat/node.def`; the op-mode
  `show ubnt offload` command is read-only (`docs/production-baseline.md`). No userspace
  flush/invalidation caller was found in the inspected paths.
- The driver is built in (no `hw_nat` module in `/proc/modules`); `dmesg` produced no HNAT lines
  (restricted/quiet), so no bind/ageout log evidence is available read-only.

## 3. Data path and hook order

The HNAT implementation is **not** a netfilter/route hook. It is wired into the MT7621 Ethernet
driver through exported function pointers:

- `net/nat/foe_hook/hook.c:37-41` defines/exports `ra_sw_nat_hook_rx/tx`.
- `net/nat/hw_nat/ra_nat.c:3983-3984`, `4074-4075` install `PpeRxHandler`/`PpeTxHandler`; `3964-3991`
  clears them and memsets the FOE table when `/proc/mt7621/hw_nat` is written with a value other
  than `1`.
- `drivers/net/ethernet/mediatek/mtk_eth_soc.c:1096-1118` calls `ra_sw_nat_hook_rx` in the RX path;
  the in-tree comment states return `0` means **"FWD & without netif_rx"**.
- `drivers/net/ethernet/mediatek/mtk_eth_soc.c:976-990` calls `ra_sw_nat_hook_tx` inside
  `ndo_start_xmit`, i.e. **after** the Linux stack has routed and filtered the packet.
- No netfilter symbol is referenced anywhere in `net/nat/hw_nat` (grep: no `nf_*`, no
  `netfilter`, no `ip6tables`).

Consequences:

1. The **first** packets of a flow traverse the normal stack: RX → routing/RPDB → netfilter →
   `ndo_start_xmit`.
2. The PPE marks the flow when it reaches the bind-rate threshold; `PpeTxHandler`
   (`ra_nat.c:2535-2769`) then builds the FOE entry from the routed skb (L2 rewrite, L3 addresses,
   L4 ports) and `PpeSetEntryBind` (`ra_nat.c:2451-2535`) sets state `BIND` with a timestamp.
3. **Subsequent packets of a bound flow are forwarded by the PPE from the FOE entry and never
   re-enter the stack** — no route lookup, no RPDB evaluation and no netfilter evaluation.
4. The RX hook only handles exceptions (force-to-CPU, keepalive, multicast/WiFi) and otherwise
   returns to the fast path.

## 4. Answers to the required questions

| Question | Finding | Label |
|---|---|---|
| Flow classification and eligibility | Ethernet unicast (multicast destination is flagged `is_mcast` and has dedicated CPU/mcast handling); VLAN (single/double; the triple-VLAN branch does not update the L3 parse) and PPPoE; IPv4/IPv6. IPv4 fragments are rejected. IPv6 base-header TCP/UDP → `IPV6_5T_ROUTE`; other IPv6 next-header → `IPV6_3T_ROUTE`; IPv4 carrying `IPPROTO_IPV6` → `IPV6_6RD`; IPv6 with next-header 4 (IPIP) → `IPV4_DSLITE`. Unsupported EtherTypes rejected. GRE rejected (no PPTP/L2TP build). IPv4 UDP with both ports 4500 is rejected on MT7621. Packets marked ALG-interested (FOE_ALG set by conntrack/TCP/UDP/xfrm or the skb cvm reservation; `nf_conntrack_core.c:1462`, `tcp_input.c:5383`, `udp.c:2307`, `xfrm_output.c:122`) never bind (`ra_nat.c:2539-2542`). Locally originated packets never bind (they carry no FOE magic/`FOE_AI` tag). `ra_nat.c:1151-1400`, `1714-1810`, `2535-2769`; `foe_fdb.h:398-470` | Verified (target source) |
| Initial forwarding decision and bind path | Decision is the Linux stack's on the first packets (RPDB + FIB + netfilter); the PPE signals `HIT_UNBIND_RATE_REACH`; binding happens in `ndo_start_xmit` from the routed skb's headers and egress device. The FOE entry stores the L2 rewrite (dmac/smac/VLAN/etype) and L3/L4 tuple, not a table or rule identity. | Verified (target source) |
| Flow-key composition | IPv6 5T: source address (4 words) + destination address (4 words) + source port + destination port. IPv6 3T: source + destination + protocol. Flow-label hashing is disabled (`BIT_IPV6_HASH_FLAB` commented out in `PpeSetFoeEbl`); `BIT_IPV6_HASH_GREK` is enabled. IPv6 extension headers are not walked — `nexthdr` only, so an extension-header packet falls into 3T keyed on the next-header byte. `foe_fdb.h:398-470`; `ra_nat.c:2771-2810`, `1340-1400` | Verified (target source) |
| IPv6 source participation | **Yes.** The source address is part of both 3T and 5T keys; different sources to the same destination are distinct FOE entries. | Verified (target source) |
| RPDB/FIB interaction before binding | The FOE captures the egress selected by the stack for the first packets; an RPDB rule/table difference changes which device/L2 rewrite is captured. After binding, the entry is independent of RPDB/FIB. | Verified (target source) |
| Route-change notification | None. No fib/route notifier is registered by HNAT. The only netdevice notifier is the MT7621 VLAN/ethtool/SFP callback (`mtk_eth_soc.c:1404-1470`), which does not touch FOE entries. | Verified (target source) |
| RPDB-change notification | None. No fib-rules/fib6-rules callback, netlink subscription or work item invalidates FOE entries. | Verified (target source) |
| Flow invalidation and expiration | FOE entries are removed by hardware ageing (`PPE_FOE_UNB_AGE`, `PPE_FOE_BND_AGE0/1`; deltas 3/5/5/5/5), by an explicit proc disable (memset of the FOE table), by module stop (`FoeFreeTbl`, `PpeEngStop`), or by userspace `HW_NAT_UNBIND_ENTRY` / `HW_NAT_INVALID_ENTRY` ioctls on `/dev/hwnat0` (major 220). Nothing in the kernel invalidates on a route, rule or table change. `ra_nat.c:2879-2925`, `3186-3260`, `3964-3991`; `hwnat_ioctl.h:18-22`, `hwnat_ioctl.c:66-86` | Verified (target source) |
| Can active traffic refresh stale entries indefinitely? | **Strongly indicated yes.** The bind timestamp is written once (`PpeSetEntryBind`); the driver never refreshes an entry after bind. PPE ageing is based on the entry timestamp and hardware hits are the only remaining refresh mechanism, so an active flow can keep a stale FOE entry alive; the age-out delta is an **idle** timeout, not an upper bound on stale forwarding. The 5-unit deltas are register values whose time unit is not documented in the source; the ~5 s observation is **Strongly indicated**, not proven. | Strongly indicated; requires measurement |
| Does VXLAN traffic use the hardware path? | **Not established; measure it.** There is no VXLAN handling in HNAT. The bind tags are set on physical/WiFi RX, but decapsulation passes the inner skb up without clearing `skb->cb` (where the tags live; `skb_scrub_packet` does not clear it), so an inherited tag is possible. The target terminates the lab tunnel (the outer packet is locally generated/addressed). Whether any lab-VXLAN flow is offloaded must be measured (FOE counters/dump), not assumed. `CONFIG_RA_HW_NAT_WIFI`/`NIC_USB` are unset, so `PpeSetExtIfNum` compiles to `return 0` and no interface mapping is applied at bind. | Strongly indicated; requires measurement |
| Bind threshold | `PpeSetFoeBindRate(DFL_FOE_BNDR)` programs `PPE_FOE_BNDR` with `CONFIG_RA_HW_NAT_BINDING_THRESHOLD = 30` (`frame_engine.h:437,651`; `ra_nat.c:2950-2967`, `3218`). The register's unit is not documented in the source; "30 packets per second" is **Strongly indicated**, not proven. | Verified (target source) for the value; unit Strongly indicated |
| Selective offload exclusion | No per-prefix, per-interface or per-protocol runtime exclusion exists in this build. Control is global: `/proc/mt7621/hw_nat` write toggles the hooks and clears the FOE table; the EdgeOS `system offload { hwnat enable }` toggle is the same global switch. ACL/accounting/metering policy modules are not compiled with `HNAT_V2`. Entry-level unbind/invalidate exists only through the char-device ioctls. | Verified (target source) / Verified (target) |
| Can an ip6tables source-prefix guard enforce fail-closed? | **No, not for offloaded flows.** Bound flows are forwarded by the PPE without re-entering netfilter, so an egress source-prefix guard can only prevent binding (by dropping the flow's first packets) and cannot be relied on after binding. The guard must not be assumed effective "because the rule exists". | Verified (target source) for the bypass; target experiment required for confirmation |

## 5. Consequences for correctness and qualification

1. **Offload is a correctness gate.** A bound flow's egress is frozen until the entry is removed.
   An RPDB rule/table change, provider withdrawal or terminal-guard insertion does not move an
   existing flow, and no kernel notification path exists. Fail-closed therefore has a hole whose
   size is the entry's remaining lifetime — potentially unbounded for active traffic.
2. **No independent firewall backstop.** Since offloaded packets bypass netfilter, a source-prefix
   firewall guard is not an independent enforcement mechanism for bound flows. Correctness must be
   established by the routing design plus the offload behaviour, or by not offloading the guarded
   traffic.
3. **Selective exclusion is not available.** The build offers only a global HNAT switch. If HNAT
   cannot be proven to preserve SADR invariants, the fallback is software forwarding with HNAT
   disabled (globally, on a dedicated test router or in an authorized maintenance window),
   quantified for performance — not an undocumented per-flow workaround.
4. **Environment B (lab VXLAN) cannot establish HNAT correctness.** It is strongly indicated to be
   software-forwarded; it can establish RPDB policy correctness on the production firmware but not
   the interaction with the PPE. Only Environment A (dedicated matching ER-X) can qualify offload.

## 6. Open items requiring authorized experiments

- Measure whether an active FOE entry is refreshed by hits indefinitely (long-lived TCP/UDP with a
  mid-flow RPDB change; independent captures at both egresses).
- Measure whether a rule/table change is observed at all on bound flows, and after what delay
  (0 s? ageout? never?).
- Confirm the bind threshold unit and the ageout time unit on the target.
- Confirm whether lab-VXLAN transport traffic ever creates FOE entries (FOE counters/dump), and
  whether the outer tunnel flow is accelerated.
- Confirm whether an ip6tables source-prefix guard prevents binding of new flows and whether it is
  bypassed for already-bound flows.
- Confirm the behaviour of the proc toggle and EdgeOS `hwnat` disable on existing entries (memset
  vs graceful teardown, and whether in-flight packets are dropped or software-forwarded).

Raw target output and real addresses remain outside the repository.
