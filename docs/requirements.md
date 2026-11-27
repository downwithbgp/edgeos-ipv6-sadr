# Requirements and routing contract

**Status:** architecture-phase contract. The recommended mechanism is in
[`architecture/ADR-0001-routing-model.md`](architecture/ADR-0001-routing-model.md). Implementation and
hardware qualification are pending.

This document is normative for the v0.1.0 architecture. "MUST", "MUST NOT", "SHOULD" and "MAY" are
used in their usual engineering sense.

## 1. Purpose

A site uses multiple IPv6 providers with provider-assigned address space. Traffic sourced from a
provider's prefix MUST use an egress that the provider will accept. Destination-only routing is
insufficient: a packet sourced from provider B can otherwise leave through provider A and be dropped
by ingress source-address validation, or silently violate the site's routing policy.

The extension provides:

* native, persistent IPv6 source-address-dependent routing (SADR);
* preservation of internal destination routing;
* explicit, deterministic policy precedence;
* fail-closed behaviour for constrained sources;
* strict ownership of kernel routing objects;
* operational verification of configured versus effective state.

It is not a NAT66/NPTv6 project. IPv6 addresses are preserved end to end.

## 2. Definitions

* **Source prefix (S):** a canonical IPv6 prefix used to select a policy for packets with a source
  address inside it.
* **Policy:** a named mapping from one or more source prefixes to a provider egress and a provider
  table.
* **Internal whitelist table (I):** an extension-owned table containing only explicitly declared
  internal destinations and connected routes on interfaces that are not any policy's egress or
  next-hop interface, each with a terminal per-prefix guard.
* **Provider table (T):** an extension-owned table containing the provider route and a terminal
  `unreachable default` guard.
* **Destination exception:** an exact internal prefix that is copied into the internal whitelist.
* **Guard:** a route or rule that returns `unreachable` when the intended route is absent. A guard is
  a safety mechanism, not a health check.
* **Effective state:** the kernel rules, tables and routes plus the relevant netdevice state.
* **Configured state:** the EdgeOS working/active configuration for `protocols ipv6-sadr`.
* **Constrained source:** a source prefix for which an effective policy exists.
* **Source selection:** the kernel/RFC 6724 choice of source address for an unbound local socket.
  SADR routes packets with a known source; it does not control source selection.

## 3. Routing contract

### 3.1 Scope

* IPv6 only. IPv4 SADR, NAT66, NPTv6, general WAN load balancing, automatic provider health
  monitoring, automated cross-provider failover, full DHCPv6-PD orchestration, DNS renumbering, host
  source-address-selection management, RA policy orchestration, routing-daemon replacement,
  BGP-specific extensions, Babel, VRF orchestration, VXLAN management, firewall policy generation and
  Kubernetes-specific behaviour are out of scope for v0.1.0.
* No kernel modification and no additional kernel module are required for the recommended design.
* No vendor file is modified. The extension adds configuration/operational templates and
  executables.

### 3.2 Source policy and precedence

* A policy MUST have at least one canonical source prefix and exactly one egress specification.
* Source prefixes MAY be /48, /56, /60, /64, more-specific application prefixes or /128 addresses.
* Host bits set in a source prefix MUST be rejected or canonicalised only under an explicit,
  documented rule. Silent reinterpretation is forbidden.
* Longest source prefix MUST win. Every rule for a more-specific prefix MUST precede every rule for a
  less-specific prefix. Nested policies MUST be tested.
* The same source prefix MUST NOT appear in two policies. An exact duplicate is ambiguous and MUST be
  rejected.
* A policy MAY contain several source prefixes; they share the provider table and egress. Each prefix
  gets its own rule group.
* A source that matches no policy uses native EdgeOS routing. SADR only constrains configured
  sources.
* A policy MAY be disabled. `disable` MUST be fail-closed: internal destinations remain reachable
  through the internal whitelist, the provider route is withdrawn, the terminal guard remains, and
  external traffic is blocked. Deleting the policy is the explicit way to restore native routing.

### 3.3 Internal destinations

* The internal whitelist MUST contain only:
  * connected routes on interfaces that are **not** any policy's egress or next-hop interface;
    provider-facing transfer links are never auto-whitelisted;
  * exact routes for explicitly configured internal prefixes, mirrored from the exact main-table
    route at reconciliation time.
* A connected route on a policy egress/next-hop interface is not automatically internal. If it is
  truly an internal destination, the operator MUST declare it explicitly.
* A mirrored `via` route requires a covering route for its gateway in the internal table. The
  reconciler MUST mirror that covering connected/internal route as well, or reject the exception.
  The provider-facing exclusion wins: if the covering route is on a policy egress/next-hop
  interface, the exception MUST be rejected; a provider-facing transfer link is never mirrored.
* The internal whitelist MUST NOT contain a default route.
* Every whitelisted prefix MUST have a terminal `unreachable` guard at a higher metric. If the real
  internal route is missing, traffic for that prefix MUST be blocked, not sent to a provider.
* A destination not in the whitelist falls through to the policy's provider table. This is how
  external destinations reach the provider.
* The extension MUST NOT infer that every non-default route in `main` is internal. A more-specific
  external route under a declared internal prefix MUST NOT capture a constrained source.
* An ambiguous or ECMP exact-route mirror MUST be rejected with a diagnostic in v0.1.0; the operator
  can declare a more specific prefix or an explicit route.
* Dynamic internal routes (for example BGP-learned prefixes) are supported when covered by an exact
  exception and mirrored by the reconciler. The extension does not implement BGP-specific policy.

### 3.4 Provider egress

* The provider table MUST contain:
  * one provider route (global next hop + interface, link-local next hop + interface, or an
    interface-only/point-to-point route where the platform permits);
  * a terminal `unreachable default` at a higher metric;
  * a connected mirror covering a global next hop, when needed for resolution.
* The provider route and guard MUST carry the extension route marker; the table MUST be verified
  extension-owned before destructive reconciliation.
* Ethernet, VLAN, tunnel, bridge and PPP-style Layer 3 dependencies SHOULD be equally valid where
  the platform supports the next-hop form. The architecture MUST NOT be bound to Ethernet-like
  interfaces.
* v0.1.0 supports one next hop per policy. Multipath/load balancing is out of scope.

### 3.5 Failure and fallback

For every constrained source, at every supported interruption point, the source MUST be on its
intended provider, on the previous effective provider, or blocked. It MUST NOT be on an unauthorized
provider.

* A missing provider route, an absent interface or an unresolved next hop MUST NOT fall back to
  `main` or another provider.
* The internal-table guard and provider-table guard MUST be installed before the source is
  constrained and MUST remain until intentional deletion.
* A first-application temporary terminal rule MUST block a previously unconstrained source while
  its first policy is installed. It is removed only after the permanent rules and guards verify.
* Removing a provider route, losing an internal route, interface deletion/recreation and process
  termination MUST leave the source fail-closed.
* Explicit fallback is not part of v0.1.0. Any future fallback MUST be opt-in, documented and
  tested; it MUST NOT be the default.
* A FIB entry is not proof of end-to-end provider connectivity. Remote transit failure is not
  detectable without provider health monitoring, which is out of scope.

### 3.6 Local versus forwarded traffic

* RPDB source rules apply to packets with a known source, including locally generated packets whose
  socket is bound to a configured source.
* Automatic source selection for unbound sockets remains governed by RFC 6724 and the kernel. The
  extension MUST NOT silently modify `gai.conf`, address labels, router advertisements or DHCPv6 to
  influence source selection.
* Operational diagnostics MUST report the selected source and MUST NOT present a route's
  preferred-source attribute as source rewriting.

### 3.7 Ownership and coexistence

* The extension owns only its internal table, provider tables, exact source rules, exact routes and
  the route protocol marker. It MUST NOT flush the RPDB or any table.
* It MUST NOT modify `main`, kernel local routes, DHCPv6-PD state, RA routes, vendor/dynamic routing
  protocol routes, firewall-generated policy or another application's tables.
* A managed table MUST be empty or contain only extension-owned routes. Ownership requires agreement
  of table, exact prefix set, route protocol marker and the manifest. A route with the right marker
  but a different prefix set is a conflict.
* Rule priorities and table identifiers MUST be collision-checked. A foreign object in a managed
  range MUST cause a clear failure, not an overwrite.
* A foreign object in a managed table or priority range MUST be refused. A foreign rule before the
  extension's range that can match a configured source MUST be reported as `shadowed`, not as
  effective. Shadow detection MUST consider overlap, catch-all `from all` and rules whose match is
  not source-only (for example `fwmark`, `iif`, `oif` or `tos`); a conservative false positive is
  acceptable. The extension MAY install its owned objects while shadowed so migration can proceed,
  but it MUST NOT claim enforcement or delete the foreign rule.
* Installing the extension MUST NOT seize a manually created table or rules. Migrating manual state
  is a separate, documented procedure.
* Ordinary policy changes MUST NOT restart BGP/OSPF or disrupt the routing daemon.

### 3.8 Lifecycle

The implementation MUST be idempotent and reason about desired versus effective state across:

* first configuration, ordinary commits, no-op commits and policy modification;
* policy deletion and administrative disable;
* next-hop/table/interface changes;
* interface administrative down/up, deletion and recreation with a new ifindex;
* routing-daemon restart;
* package upgrade and removal;
* boot-time configuration restoration;
* commit-confirm rollback and failed commits;
* abrupt process termination.

The event source MUST be identified and target-verified. The candidate is `ip -6 monitor link`
plus `ip -6 monitor addr` (and a filtered route monitor for exact internal prefixes) under a small
systemd service, or a narrow netlink helper if the target monitor output is unreliable. The design
MUST use event-driven reconciliation for netdevice/address and exact internal-prefix route changes,
MUST serialize commit and monitor reconciliation with a lock, and MUST avoid polling and arbitrary
sleeps. Any persistent daemon MUST be justified and measurable on the ER-X.

* A disabled policy MUST remain disabled across reconciliation and interface recreation: the
  provider route MUST NOT be restored. Internal reachability remains; external remains blocked.

### 3.9 Native configuration

* The operator interface MUST support discovery, tab completion, validation,
  `show configuration commands`, `compare`, `commit`, `save`, deletion, rollback and commit-confirm.
* The leading hierarchy is `protocols ipv6-sadr`. It MUST NOT duplicate existing EdgeOS capabilities
  without a demonstrated gap.
* During its `end:` action, the extension MUST read its own subtree from the working configuration
  (`exists`/`returnValue`), not rely on `existsEffective`, which may report the still-executing
  subtree as absent. A configuration-API error MUST be a hard failure, not "absent".
* The action MUST persist an atomic desired-state snapshot for the monitor and MUST tolerate the
  non-atomic commit engine.
* The subtree SHOULD run at priority 500, after interfaces/addresses and static routes (450). The
  exact target ordering MUST be validated by emulation and hardware.
* The boot window before first reconciliation is a named non-guarantee unless an early boot guard
  service, ordered before WAN forwarding, is implemented. The design MUST state which applies.

### 3.10 Diagnostics and health

The operator MUST be able to inspect configured policies, effective rules/tables/routes/guards,
precedence, next hops, interfaces, missing dependencies, ownership conflicts, shadowing, failed
reconciliation and configured-versus-effective differences.

The "given source S and destination D" diagnostic MUST use the kernel's actual lookup
(`ip -6 route get <destination> from <source> [iif <interface>]`), not a speculative userspace
approximation. It MUST distinguish local and forwarded lookups and MUST NOT claim end-to-end
connectivity from route presence.

Health states are one enum:

| State | Meaning |
|---|---|
| `effective` | Configured, owned objects present and verified, dependency present |
| `incomplete` | Configured, some owned objects missing or not yet applied |
| `dependency-unavailable` | Interface/address/next hop missing or down |
| `protected` | Guard active because the intended route is absent; source blocked |
| `shadowed` | A preceding foreign rule prevents the policy from matching |
| `conflict` | Foreign table/route/rule or ownership disagreement |
| `failed` | Reconciliation error; last error recorded |
| `disabled` | Policy disabled; internal path retained, external blocked |

A separate `reason` field carries the detailed cause (`no-route`, `interface-down`,
`next-hop-unresolved`, `neighbour-unreachable`, `transit-unverified`, `daemon-unavailable`,
`api-error`, `reconciliation-error`). `transit-unverified` is a reason, not a health state.

A monitoring-oriented health command MUST have meaningful exit codes and MAY emit machine-readable
output. The target `ip -j` output for route/rule objects is not reliable; the helper MUST parse the
stable text form or emit its own JSON.

### 3.11 Packaging and removal

* The preferred package is `Architecture: all` if the implementation is scripts and templates only.
  No kernel package is required.
* The package MUST include firmware compatibility guards and the exact supported platform.
* Upgrade MUST preserve or safely reconcile extension-owned state.
* `prerm` MUST refuse removal while configured policies exist. If removal proceeds with no policies,
  only extension-owned objects are removed. Uninstall MUST NOT silently remove an active policy in a
  way that permits unintended cross-provider egress.
* The build MUST be reproducible and auditable. No release artifacts or tags are produced in the
  architecture phase.

## 4. Guarantees and non-guarantees

**Guaranteed once a policy is effective (subject to hardware qualification):**

* Correct source-provider egress for the tested destination classes.
* Internal whitelist reachability, with fail-closed guards on missing internal routes.
* No automatic fallback to another provider after route/interface loss or recreation.
* No modification of unrelated routing state.
* Explicit refusal on ownership/collision; a shadowed policy is reported as not effective.
* Idempotent reconciliation and an inspectable effective state.

**Not guaranteed:**

* End-to-end provider transit. A FIB entry can exist while remote transit is down.
* Automatic provider health monitoring or multi-WAN failover.
* Control of RFC 6724 source selection for unbound local sockets.
* Correct behaviour on untested EdgeOS firmware, kernels, hardware offload paths or non-ER-X
  platforms.
* A zero-exposure interval at boot before the first guard service runs, unless the early boot guard
  is implemented and verified.
* Correct handling of dynamic internal prefixes that are not covered by an exact destination
  exception.
* The target `ip` `route add ... from` parser and target 4.14 source-specific forwarding semantics
  until the named target/emulation/hardware checks pass.
* Hardware offload honouring multi-table RPDB lookup until measured.

## 5. Verification

The architecture phase requires the layered verification in
[`testing-strategy.md`](testing-strategy.md):

* unit and configuration tests;
* an executable Linux netns proof of concept with packet-path evidence;
* firmware emulation where useful;
* target hardware qualification before any compatibility claim.

The generic-Linux prototype result is in [`prototype-results.md`](prototype-results.md). It is not
EdgeOS evidence.

## 6. References

* RFC 8043, RFC 8678, RFC 7157, RFC 6724, RFC 8028, RFC 3704.
* RFC 9079, RFC 7368, RFC 7084, RFC 4861, RFC 4862, RFC 8200, RFC 8201 (background and terminology).
* `edgeos-vxlan` platform/architecture records, used as platform knowledge with citation; no code is
  copied.
* Exact EdgeOS kernel and iproute2 source inspected for this phase; see
  [`investigation/2026-11-27-platform-investigation.md`](investigation/2026-11-27-platform-investigation.md).
