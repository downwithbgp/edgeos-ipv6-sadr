# ADR-0002 — SADR implementation review: RPDB vs native source-specific FIB

**Status:** Accepted (Phase VI-B maintainer decision, 2026-11-27) with the qualifications below. No
production mutation, second backend, R1 or R2 is authorized by this document. R1 is not run.
**Date:** 2026-11-27
**Target:** Ubiquiti EdgeRouter X / ER-e50, EdgeOS 3.0.1 build 5862409, Linux 4.14.54-UBNT, MT7621.
**Supersedes/extends:** ADR-0001 routing model (accepted); this review re-tests the alternative rather
than assuming the existing RPDB choice or native FIB is optimal.

**Maintainer acceptance (Phase VI-B):** RPDB is retained as the production SADR implementation with
the internal-whitelist table and per-policy provider tables; broad main-table suppression is
rejected; no second production backend is developed; all Phase V and VI-A evidence is preserved.
Native source-specific FIB is rejected for this project's requirements and this target platform, not
as a universally inferior routing architecture. Acceptance is subject to the formal invariants in
`docs/architecture/architecture-invariants.md` and the hardware-offload correctness gate in
`docs/phase-vi-b/hnat-analysis.md` and `docs/phase-vi-b/qualification-plan.md`.

## 1. Decision

**Retain RPDB with the global internal-whitelist table and per-policy provider tables.** Do not
adopt native IPv6 source-specific FIB routes as the production SADR backend. Do not implement a
second backend in this phase. The existing ADR-0001 model remains the production direction, subject
to the target gates below.

The decision is not based on prior effort. It follows from the target/kernel semantics, the isolated
packet-path comparison, ownership/lifecycle constraints and the target's configuration model.

## 2. Context and constraints

SADR (RFC 8678) requires a source-aware egress decision for provider-assigned IPv6 multihoming:
a packet with a provider-A source must not egress provider B, while internal destinations must stay
reachable and no NAT66/NPTv6 is allowed. The ER-X has two providers, local VLANs, a lab VXLAN
(`vxlan<lab>`), a Route64 VXLAN (`vxlan<route64>`) and a HE tunnel. The production firewall's
`SERVERv6_IN-30` drops server-VLAN destinations in `IPV6_LOCAL_NETS`; Phase V-C's A1 baseline
therefore failed at the firewall, not at the routing model. R1 is retired (Phase VI-B) and no
firewall exception is authorized.

## 3. Options compared

| Option | Description | Disposition |
|---|---|---|
| A | RPDB source rules + global internal whitelist + per-policy provider tables + terminal guards | **Retain** |
| B | Native IPv6 source-specific FIB routes (`route add ... from`) in `main` | **Reject** for production |
| C | Routing-daemon-managed source-specific routes | **Reject** (not exposed/supported by target daemons) |
| D | Other: native static tables, fwmark policy, source-specific mirroring, BPF/other | Reject as primary; fwmark only if a future vendor-config requirement appears |

### A — RPDB internal-whitelist (ADR-0001)

Each source prefix gets `from S lookup 10000` (internal whitelist with per-prefix unreachable
guards), `from S lookup <provider table>` (provider route + unreachable default guard), then
`from S unreachable` (permanent terminal guard). Source rules are longest-prefix-first. The
extension owns only its tables, exact rules, exact routes and a route protocol marker. The internal
whitelist is the key: a `lookup main suppress_prefixlength 0` model is **not** a whitelist, because
it suppresses only the default route; any more-specific external route in `main` can bypass the
provider table. ADR-0001 already rejected that broad model and adopted the whitelist.

**Target evidence:** the exact GPL `.config` has `CONFIG_IPV6_MULTIPLE_TABLES=y`, `FIB_RULES=y`,
`IP_ROUTE_MULTIPATH=y`; the target `ip` supports the RPDB operations used; the target currently has
7 rules (`local`, five protected at `10410–10414` — `10410` is `suppress_prefixlength`, two are
`unreachable` — and `main`), table 41913 has 2 routes and there are no source-specific routes
(`from_routes=0`). The target is verified for the RPDB operations.

**Isolated evidence:** the ADR-0001/netns suite (generic Linux) passes 145/0 including 75
packet-path probes (42 in the base lab script, 31 in the production-reconciler script plus 2
recorded controls): the broad suppressor leaks in all tested more-specific cases; the internal-whitelist model
preserves internal destinations, prevents cross-provider leakage, fails closed on provider/internal
loss, covers nested source precedence, UDP/TCP, local bound sources, ownership, shadowing, disable
and interface recreation. The current production reconciler is the strict model, not the broad
suppressor.

**Lifecycle/ownership:** tables/rules/routes are extension-owned with a protocol marker; the
reconciler repairs after netdevice recreation. The target config model has no native source-prefix
rule/guard; the extension is required. The target's native table routes are leaf-only and not
link-event repaired.

**Offload:** unverified. The target GPL source has `CONFIG_RA_HW_NAT=y`, `CONFIG_HNAT_V2=y`,
`CONFIG_RA_HW_NAT_IPV6=y`, `CONFIG_RA_HW_NAT_TBL_16K=y`, `CONFIG_PPE_MCAST=y`, with
`RA_HW_NAT_BINDING_THRESHOLD=30`. The HNAT/PPE has no policy/ACL stage in this build; a flow binds
after a rate threshold of 30 (unit not documented; observed ~30 pps) and ages out after a register
delta of 5 (unit undocumented; observed ~5 s for TCP/UDP/other); the age-out is an idle timeout, so
active flows may keep an entry alive (Strongly indicated). An already-bound flow's egress is frozen
until the entry is removed. This is a **correctness gate**, not only performance: an RPDB rule/table change may
not move an existing flow immediately. See §7.

### B — Native source-specific IPv6 FIB

The target kernel source (`/home/vadim/kernel_e50`, exact 4.14.54-UBNT) enables
`CONFIG_IPV6_SUBTREES=y`; `route.c` stores `RTA_SRC` in `rt6i_src`, and `ip6_fib.c` maintains source
subtrees. The target `ip -6 route add help` prints the generic IPv6 route usage; its only `from`
line is the `route get` synopsis (`from ADDRESS iif STRING`), so the usage text does **not** show a
route-add `from` field. The add parser is **strongly indicated** by upstream iproute2 v4.14
(`ip/iproute.c` parses `from`/`RTA_SRC` in the add path), not target-verified, and the target add was
not executed. The kernel feature is available in principle.

The Linux 4.14 lookup is **destination-first**: `fib6_lookup()` descends the destination trie and
consults the source subtree only inside a matched destination node (`ip6_fib.c:1262-1296`). Source
specificity never outranks a longer destination prefix. A more-specific main-table route (e.g., a
BGP-learned `/64` through provider B) is selected for a provider-A source before any less-specific
source-qualified default; the source-specific `unreachable` guard only applies when the lookup
reaches that node. The isolated source-FIB candidate confirmed this: a PA source to a configured
internal prefix with a more-specific PB route egressed PB; the source-specific unreachable guard
worked only for destinations with no more-specific main route.

A safe native-FIB implementation would need to mirror **every BGP-learned destination route per
source prefix** (with the source's provider next-hop) and add source-specific internal overrides for
every more-specific external route under an internal prefix, plus per-source guards. That is a new
control plane with BGP update/withdraw coupling, route ownership and a route count of
`BGP prefixes × source policies`; it erodes the simplicity advantage and is not exposed by the
target daemons. The target's source-specific forwarding semantics also remain unverified beyond the
generic-Linux experiment. The two mechanisms are not equivalent: RPDB selects a **table by source**
before the destination lookup; the native FIB keeps one destination-first table and adds source
qualification inside it.

**Disposition:** reject for production. Revisit only if a target experiment proves strict
source-specific forwarding and the BGP mirroring/ownership problem is solved without a second
backend.

### C — Routing daemon

The target runs UBNT `ribd`/`nsm`/`imi` plus Quagga `bgpd`/`ospfd`/`ospf6d`; `vtysh` is a wrapper.
No inspected daemon configuration exposes source-specific RPDB policy, per-table source rules or
source-qualified routes. Replacing/patching the daemon duplicates the control plane and violates the
ownership boundary. Reject.

### D — Other implementations

- **Native static tables:** `protocols static table 1..200` plus extension rules. No source-prefix
  rule, no terminal guard, default proto, leaf-only installs and no netdevice-recreation repair.
  Reject as primary; a future hybrid only if the vendor adds lifecycle/ownership hooks.
- **fwmark policy:** the kernel supports IPv6 `fwmark` rules (`net/core/fib_rules.c:235`,
  `net/ipv6/fib6_rules.c:204-235`), but the installed EdgeOS static-table `mark` leaf is IPv4-only
  and the approach depends on a firewall/ip6tables mark. The RPDB source rule is simpler, has no
  firewall dependency and is target-verified. Reject as primary; re-evaluate only if a vendor
  config model requires fwmark.
- **Source-specific BGP mirroring:** possible but is option B with additional maintenance; reject
  as a second backend.
- **BPF/lwt/nftables:** not justified on 4.14.54-UBNT/ER-X and would add a kernel/userspace
  dependency; reject.

## 4. Comparative assessment

| Criterion | A RPDB whitelist | B Native source-FIB | C Daemon | D fwmark/native tables |
|---|---|---|---|---|
| Destination + source LPM | source rule chooses table, then destination LPM | destination-first; source only inside matched node | inherits B | fwmark chooses table |
| Internal destinations | whitelist table + guards | needs source-specific internal overrides | weak | possible, firewall-dependent |
| BGP-learned routes | provider tables; no per-source copy | per-source mirroring required | daemon limits | table copy |
| Locally originated traffic | source rules apply; RFC 6724 not guaranteed | source-specific FIB applies | same | fwmark/selection |
| Provider defaults | provider table default + guard | source-specific default, captured by more-specific | same | table default |
| Source-prefix leak | prevented by whitelist | leaks without mirroring | similar | depends on marks |
| Fail-closed | terminal source/table/per-prefix guards | source-specific unreachable (narrow) | weak | guard needed |
| Route withdrawal/restore | table default/guard, health | guard, but more-specific capture | daemon | table |
| Dynamic prefix | extension config/reconcile | extension route mirror | daemon | config |
| Ownership | exact rules/tables/routes, proto 194 | source-specific routes, per-source | daemon | tables/marks |
| Config lifecycle | extension subtree, priority 500 | extension + new source-route model | vendor/daemon | vendor template change |
| Reboot | extension/early guard | extension/early guard | daemon | extension |
| Firewall interaction | none | none | none | mark/ip6tables |
| Hardware offload | unverified multi-table | unverified source-FIB | unverified | unverified |
| Flow-cache invalidation | HNAT ageout/bind risk | same | same | same |
| Performance | target plan | target plan | target plan | target plan |
| Maintainability | existing implementation | new backend | duplicate control plane | new config path |
| Complexity | existing | high (BGP mirroring/overrides) | high | medium-high |

## 5. suppress_prefixlength and destination-precedence analysis

- The broad RPDB model `from S lookup main suppress_prefixlength 0` is unsafe: the kernel's
  `fib6_rule_suppress()` compares only the destination prefix length (`fib6_rules.c:177-202`), so a
  more-specific main route (BGP or static) is selected and can leak the source to the other
  provider. The accepted internal-whitelist model does not use a main lookup for constrained
  sources; it uses the internal/provider tables and terminal guards. The existing netns packet-path
  suite demonstrated the broad-model leaks and the whitelist pass.
- The native source-specific FIB has the equivalent, more fundamental risk: the lookup is
  destination-first; the source subtree is only consulted inside a matched destination node. A
  more-specific main route captures the source. The isolated candidate B recorded exactly this. The
  source-specific `unreachable` guard is not a substitute; it only covers destinations with no
  more-specific route. RFC 9079 §1.3 and §4 require destination-first ordering of a source-specific
  routing domain (the §4 MUST binds implementations of that Babel extension, and source-first
  ordering can create persistent loops); Linux's destination-first lookup is that ordering, so the
  behavior is the specified semantics of a source-specific table, not a Linux defect.
- The RPDB internal-whitelist is the only tested design that preserves internal destinations and
  prevents the tested cross-provider leak **without per-source route mirroring**. The whitelist is
  the central architectural decision.

## 6. Target capability matrix

| Capability | Evidence | Status |
|---|---|---|
| Kernel IPv6 source subtrees | exact `/home/vadim/kernel_e50/.config`: `CONFIG_IPV6_SUBTREES=y` | Verified (target source) |
| Kernel multiple tables/FIB rules | `CONFIG_IPV6_MULTIPLE_TABLES=y`, `CONFIG_FIB_RULES=y` | Verified (target source) |
| IPv6 stack module | `CONFIG_IPV6=m` | Verified (target source); boot/module lifecycle gate |
| Target kernel | `4.14.54-UBNT`, MIPS32r2; GPL tree `DTB_UBNT_ER=y`, `SOC_MT7621=y` | Verified (target/source) |
| Target iproute2 | `iproute2-ss171113`; route usage shows `from ADDRESS` only in the `route get` synopsis; route-add `from` parser strongly indicated (upstream 4.14), not target-verified; add not executed | Verified (target help) / add Strongly indicated |
| RPDB operations | target supports rule/table/route/suppress/unreachable; target RPDB shape 7 rules, 5 protected, 1 suppress, 2 unreachable, table 41913=2 | Verified (target) |
| Source-specific routes installed | `ip -6 route show table all` `from_routes=0` | Verified (target); feature not in use |
| Target route protocol 194 | no 194 routes; `proto 194` rendering not exercised | Unverified |
| UBNT/Quagga source-specific policy | `ribd`/`nsm`/`imi` + Quagga; no source-specific RPDB/per-table policy observed | Verified (target/investigation) |
| Native static tables | `protocols static table 1..200`; no source-prefix rule/terminal guard; leaf-only, no link-event repair | Verified (target/templates); lifecycle Strongly indicated |
| Native fwmark `mark` leaf | installed template IPv4-only; kernel IPv6 fwmark supported | Verified (target template) / kernel source |
| Lab VXLAN | target `vxlan900` to controller underlay; controller `vxlan903`; `ip -6 route get <lab-dest> from <synthetic> iif vxlan900` selects `dev vxlan900`; no `VYATTA_FW_IN_HOOK` chain for `vxlan900` | Verified (target, read-only) |
| Firewall server VLAN | `SERVERv6_IN-30` drops `IPV6_LOCAL_NETS`; counter 137 at Phase VI-A discovery | Verified (target) |
| HNAT/PPE | `CONFIG_RA_HW_NAT=y`, `CONFIG_HNAT_V2=y`, `CONFIG_RA_HW_NAT_IPV6=y`, `TBL_16K`, `PPE_MCAST`, binding threshold 30; no policy stage; 5 s ageout | Config Verified (target source); bind/ageout Strongly indicated; fast-path behavior Unverified |
| `hw-tc-offload: off [fixed]` | NIC feature only; not evidence about HNAT | Verified (target); do not confuse |
| Target IPv6 forwarding | `/proc/sys/net/ipv6/conf/all/forwarding=1` | Verified (target) |
| Target /proc/config.gz | absent | Verified; exact config from GPL source, not inferred from absence |

## 7. Hardware-offload risk and revised target qualification plan

**Risk (target source):** HNAT/PPE binds a flow after the 30-unit threshold and caches its egress;
the age-out is an idle timeout (register delta 5, unit undocumented; observed ~5 s), and active flows
may keep an entry alive (Strongly indicated). There is no policy/ACL stage in this build. A source
policy/rule/table change does not move an already-bound flow until the entry is removed; a
fail-closed guarantee therefore has an ageout-or-longer hole unless offload is disabled for the
guarded prefixes/class or the fast path is proven to re-evaluate the policy. The `hw-tc-offload` NIC
feature is not HNAT evidence. The bind path is now source-verified (bind in `ndo_start_xmit`; the FOE
entry records the L2 rewrite and L3/L4 tuple, not a table/rule identity), while fast-path behaviour
remains a target gate (`docs/phase-vi-b/hnat-analysis.md`).

**Revised target qualification plan (no production offload/configuration change in Phase VI-A):**

1. Read-only offload inventory: `show ubnt offload`/`vbash -c 'show ubnt offload'`, HNAT/PPE
   counters/proc nodes, `dmesg` for bind/ageout, active `system offload` stanza; record before/after.
2. RPDB-under-offload correctness: two source prefixes to distinct provider tables/next-hops;
   long-lived TCP/UDP per source; simultaneous captures on both egress interfaces; prove each
   source used its policy egress, not `main`, and observe HNAT binding.
3. Fail-closed under offload on/off: provider route withdrawal, terminal guard, more-specific
   external route in `main`; prove no wrong-provider packet, including the ageout window after a
   rule/table change. Offload on/off only in an authorized maintenance/isolated lab, never globally
   in production.
4. IPv6 module/boot lifecycle: `CONFIG_IPV6=m`; verify rules/tables cannot exist before `ipv6`
   loads, whether module reload drops RPDB state, and early-guard ordering (maintenance window).
5. Config engine: priority 500, `exists` vs `existsEffective`, scripted/interactive commit,
   rollback (emulation + hardware).
6. Target source-specific experiment (separate authorization): target `ip -6 route add ... from`
   in an isolated netns/table with exact containment/rollback; verify parser, proto 194, lookup
   precedence and source-specific forwarding. Not required for the retained RPDB model.
7. Performance: real TCP/UDP throughput, pps, CPU, concurrent flows, route/rule withdrawal and
   restoration; no ICMP/traceroute-only inference; no production offload change.

## 8. R1 topology reconsideration (no firewall exception)

The Phase V-C A1 block is the production server-VLAN firewall, not the SADR model. R1 is retired
(Phase VI-B); no firewall exception is authorized. Future R1 topology options, best first:

1. **Isolated lab ER-X** with the same firmware/hardware: run the actual R1 A/B/A and offload
   qualification there; no production router mutation and no firewall change. This is the preferred
   target-platform evidence path because it exercises the exact platform without production risk.
2. **Production ER-X on the existing lab VXLAN path:** the target has a lab VXLAN (`vxlan<lab>`,
   controller peer `vxlan<lab-peer>`); its `ip -6 route get <lab-dest> from <synthetic-source> iif
   vxlan<lab>` selects `dev vxlan<lab>`, and `VYATTA_FW_IN_HOOK` has no `vxlan<lab>` chain (the relevant `FORWARD`/
   post-FW policy is independent of `SERVERv6_IN-30`). This can provide A1/B/A2 dataplane evidence
   **without a firewall exception**. The single production RPDB rule remains a production mutation
   and needs a fresh, separate R1 authorization; no R1 is authorized in Phase VI-A.
3. **Dedicated test VLAN/port with an exact, separately authorized firewall exception:** only if
   options 1–2 are unavailable; justify against them; no Phase VI-A change.
4. **Controller-only generic-Linux lab:** useful for mechanism comparison, but not target-platform
   evidence; label Generic Linux.

The R1 topology must retain containment, source/destination proof, no wrong-provider/upstream
escape, production invariants and exact cleanup. The lab VXLAN option removes the server-VLAN
firewall obstacle without weakening security policy; it does not remove the production RPDB
mutation boundary.

## 9. Recommendation

1. Retain the RPDB internal-whitelist architecture and the existing production reconciler. Do not
   adopt native source-specific FIB or implement a second production backend.
2. Keep the broad `main suppress_prefixlength 0` construction rejected; do not reintroduce it.
3. Keep R1 not run and create no firewall exception (Phase VI-A recommendation; the Phase V-C
   authorization is retired in Phase VI-B). Prefer the isolated lab ER-X
   for R1; if the production ER-X is required, use the existing permitted lab VXLAN path under a
   fresh separate R1 authorization, not a firewall exception.
4. Authorize the offload/target qualification plan above; do not change production offload.
5. Revisit native FIB only if a target experiment proves strict source-specific forwarding and the
   BGP per-source mirroring/ownership model is accepted as a new control plane.

## 10. Unresolved assumptions and maintainer decisions

- Target `ip -6 route add ... from` execution, `proto 194` rendering and source-specific forwarding
  semantics (the target usage shows `from` only in the `route get` synopsis; upstream 4.14 indicates
  the add parser; add not executed).
- HNAT fast-path behaviour, whether an active flow keeps a stale entry indefinitely, and whether a
  bind freezes policy changes beyond the measured ageout (Phase VI-B analysis).
- `CONFIG_IPV6=m` boot/module-reload RPDB state and early-guard ordering.
- Config-engine priority/visibility/rollback and boot ordering.
- R1 topology choice (isolated ER-X vs production lab VXLAN vs dedicated test VLAN/firewall
  exception) and a fresh R1 authorization if the production ER-X is used.
- Whether the native FIB is ever revisited; BGP per-source mirroring ownership.
- RFC 6724 source selection for unbound local sockets; no optimal-source claim.
- Target performance and offload fast-path behavior.

**Maintainer decisions requested:** approve RPDB retention; approve the isolated-ER-X R1 preference
and the lab-VXLAN alternative (no firewall exception); authorize the target offload/qualification
experiments; confirm R1/R2/merge/release remain unauthorized until the architecture gate and a new
execution authorization are complete.

## 11. Sources

- RFC 8678, *Enterprise Multihoming Using Provider-Assigned IPv6 Addresses without Network Prefix
  Translation: Requirements and Solutions* (the SADR requirement; title verified 2026-11-27).
- RFC 6724 *Default Address Selection for IPv6* (RFC 6724 §5 default-address-selection rules) and
  RFC 3704/BCP 84 *Ingress Filtering for Multihomed Networks*, both as referenced by RFC 9079.
- RFC 9079, *Source-Specific Routing in the Babel Routing Protocol*: §1.3 shows that ordering
  source/destination prefix pairs is not tree-like and that routers must agree on destination-first
  ordering to avoid persistent loops; §4 mandates destination-first ordering ("R1 is preferred to R2
  when R1's destination prefix is more specific ... or the destination prefixes are equal and R1's
  source prefix is more specific"). This is the specified semantics of a source-specific table, not a
  Linux implementation choice; it is the direct basis for the destination-precedence risk in §5.
  (Title, §1.3 and §4 fetched from rfc-editor.org 2026-11-27.)
- Linux 4.14.54: `net/ipv6/ip6_fib.c` (`fib6_lookup_1`/`fib6_lookup`, destination-first/source
  subtree), `net/ipv6/route.c` (`RTA_SRC`/`rt6i_src`, output lookup), `net/ipv6/fib6_rules.c`
  (`fib6_rule_suppress`, source/fwmark rules); exact vendor tree `/home/vadim/kernel_e50`.
- EdgeOS 3.0.1 GPL: `/home/vadim/kernel_e50/.config` (`IPV6_SUBTREES`, `MULTIPLE_TABLES`, `IPV6=m`,
  `RA_HW_NAT`, `HNAT_V2`, `RA_HW_NAT_IPV6`, `TBL_16K`, `PPE_MCAST`, binding threshold),
  `net/nat/hw_nat`, `net/core/fib_rules.c`, `net/ipv6/fib6_rules.c`.
- Repository: ADR-0001, `docs/investigation/2026-11-27-platform-investigation.md`,
  `docs/investigation/2026-11-27-experiments.md`, `docs/production-baseline.md`,
  `docs/phase-vi-a/disposition.md`, `test/integration/netns-sadr.sh` (source-FIB candidate).
- Target read-only discovery: kernel/firmware/iproute2/RPDB/table counts, lab-VXLAN route lookup,
  firewall hook/counter and `ip -6 route add help` (raw values omitted; no mutation).
