# ADR-0001 — IPv6 SADR routing model

**Status:** proposed for architecture review. Implementation and hardware qualification are pending.
**Date:** 2026-11-27
**Target:** Ubiquiti EdgeRouter X / ER-e50, EdgeOS 3.0.1 build 5862409, Linux 4.14.54-UBNT, mipsel.

## 1. Context

The site has two IPv6 providers and provider-assigned address space. Source addresses from each
provider must use an egress that provider accepts. Destination-only routing can send a provider-B
source through provider A, where ingress source-address validation may drop it, or silently violate
the site's policy. Internal destinations must remain reachable regardless of source. No NAT66 or
NPTv6 is allowed.

The current runtime proof of concept uses `ip -6 rule` with `main suppress_prefixlength 0`, a
dedicated table, and a terminal rule. It works for its narrow reference case but is not persistent,
not configuration-owned, and leaks when a more-specific external route exists in `main`.

The target has `CONFIG_IPV6_SUBTREES=y` and `CONFIG_IPV6_MULTIPLE_TABLES=y`; source-specific FIB
routes are available in the kernel (Verified (target source)); their suitability is rejected below.
Native EdgeOS has IPv6 static routes and IPv4-oriented fwmark policy tables, but no source-prefix
rule template, no terminal guard and no table-route lifecycle repair.

## 2. Decision

Adopt **RPDB with a global internal whitelist table and per-policy provider tables**:

* The internal whitelist table contains connected routes on explicitly declared internal
  interfaces plus exact configured internal prefixes, each with a terminal per-prefix
  `unreachable` guard. It has no default. Unknown interfaces are not trusted; provider-facing
  interfaces are excluded.
* Each policy has an extension-owned provider table containing the provider route and a terminal
  `unreachable default` guard.
* Each source prefix gets two lookup rules (`from S lookup internal`, then
  `from S lookup provider_table`) plus a permanent terminal source guard (`from S unreachable`)
  after them. A source that matches no policy uses native routing.
* Source rules are ordered longest-prefix-first. A policy may have multiple source prefixes; they
  share the provider table.
* The extension owns only its tables, exact rules, exact routes and a route protocol marker. It never
  flushes a table or the RPDB and never writes unrelated `main` routes.
* A small event-driven reconciler uses the active EdgeOS configuration as desired state, verifies
  kernel realization and repairs extension-owned routes after netdevice recreation. A committed
  snapshot is used only by the early boot guard.

The internal whitelist is the central decision. A `main` lookup with `suppress_prefixlength 0` is
not a whitelist: any more-specific route under an exception, including an external BGP route through
another provider, can be selected. The whitelist table contains only the exact prefixes the operator
declared internal and their guards.

## 3. Evidence and rationale

* **Generic Linux packet-path experiments:** the broad suppressor model leaked in all tested
  more-specific-route cases. The internal-whitelist model passed the architecture-phase suite:
  65 assertions (42 packet-path probes, 15 state/ownership checks, 8 health checks) plus two
  non-asserting recorded candidate-B observations, covering no cross-provider egress, internal
  preservation, nested source precedence, provider/internal route loss, UDP/TCP, local bound
  sources, ownership, shadowing, disable and interface recreation. See
  [`../investigation/2026-11-27-experiments.md`](../investigation/2026-11-27-experiments.md).
* **Guard behaviour:** a unicast default and an `unreachable` default coexist in one table; the
  unicast route wins while present, and removing it makes the lookup fail closed. Per-prefix guards
  behave the same way.
* **Source-specific FIB:** candidate B is rejected for v0.1.0. A more-specific main route captured
  the constrained source. For a destination with no more-specific route, the source-specific
  `unreachable` guard did block forwarded traffic, so the rejection rests on the more-specific
  capture, the unverified target parser and the additional mechanism needed to eliminate the
  capture.
* **Target capability:** exact kernel source confirms the required IPv6 FIB/RPDB features; the target
  `ip` supports the RPDB operations used by the model. Target `ip -j` is unreliable for route/rule
  objects, so diagnostics use text or the helper's own JSON.
* **Target configuration:** native table routes are installed by leaf actions; there is no native
  source-prefix rule template. Verified (target/templates).
* **Target lifecycle (Strongly indicated):** native table routes are not repaired after netdevice
  recreation; no link-event repair hook was found. Extension ownership is required for the lifecycle
  guarantee.

## 4. Detailed design

### 4.1 Tables, rules and markers

Tentative values, to be re-validated by target collision analysis and the v0.1.0 hardware gate:

| Object | Value | Purpose |
|---|---|---|
| Internal table | `10000` | Connected routes on declared internal interfaces + exact internal routes and per-prefix guards |
| Provider tables | `10001–19999` | One table per policy; auto-allocated or explicit |
| Rule priorities | `20000–21031` | Source rules below `main` (32766) |
| Route protocol marker | `194` | Extension ownership aid, not a security boundary |

Provider table allocation: a stable hash of the policy name into the range, with collision refusal;
the operator may set `table` explicitly. Rule priority:
`20000 + (128 - prefix_length) * 8 + slot`. Slots `0/1` and `2/3` are the active and standby
internal/provider pairs; slot `6` is the permanent terminal source guard (`from S unreachable`);
slot `7` is reserved. The stride is 8, so every more-specific prefix's rules precede every
less-specific prefix's rules. Same-length prefixes are disjoint and may share slots; exact duplicate
source prefixes across policies are rejected.

The terminal guard is installed before a source is constrained and remains for the policy lifetime.
It protects against complete provider-table disappearance, a missing table default, partial rule
installation and interruption. It does not protect against arbitrary privileged deletion of all
rules/tables or malicious foreign state; that is an explicit limit.

On update, install the new table/guards/route, then the free pair, perform a structural/ownership/table
check, then remove the old pair. If the free pair is lower priority it takes effect after the new
table is verified; if higher, the old pair remains until removal. The terminal guard stays throughout.
Post-swap safety rests on the new table guard and the terminal source guard.

Native `protocols static table` uses `1–200`; the manual proof of concept uses table `41913` and
rules `10410–10414`. The extension does not use or modify those objects. A rule in the managed range
is a conflict and is refused. A pre-range rule that can match the source shadows the policy; health
reports `shadowed`, the extension may install its owned objects so migration can proceed, and it must
not claim enforcement or delete the foreign rule.

### 4.2 Internal whitelist

For every declared internal prefix and every connected route on an interface listed in
`internal-interface` (and not used by any policy):

```text
table 10000:
    <prefix> [via ...] dev ... metric 1024 proto 194
    unreachable <prefix> metric 4096 proto 194
```

* Connected routes are refreshed on link/address events. Unknown interfaces are not trusted;
  only `internal-interface` declarations create auto-whitelisting.
* A provider-facing transfer link is never auto-whitelisted. An interface referenced by any policy
  is excluded; declaring it as an internal interface is a configuration error. A connected route on
  a policy egress/next-hop interface must be declared explicitly if it is truly internal; otherwise
  a constrained source could cross to the other provider's on-link subnet.
* A configured internal prefix is mirrored from the **exact** main-table route. More-specific routes
  under it are not copied. If the exact route is missing or ambiguous/ECMP, v0.1.0 reports the
  condition and installs only the guard; the operator can declare a more specific prefix or a single
  route.
* A mirrored `via` route requires the covering route for its gateway in table 10000. The reconciler
  mirrors that covering connected/internal route as well, or rejects the exception. The
  provider-facing exclusion wins: if the covering route is on a policy egress/next-hop interface,
  the exception is rejected; a provider-facing transfer link is never auto-mirrored into the
  internal table.
* The table has no default. A destination outside the whitelist falls through to the provider table.
* A whitelisted prefix whose real route disappears matches its guard and is blocked; it does not fall
  through to a provider.

The operator owns the internal list. The extension does not infer that every non-default main route
is internal.

### 4.3 Provider tables and egress

```text
table T:
    default via <next-hop> dev <interface> metric 1024 proto 194
    unreachable default metric 4096 proto 194
    <connected route covering a global next-hop> dev <interface> metric 1024 proto 194  # when needed
```

Supported forms:

* global-unicast next hop with interface (connected mirror derived when needed);
* interface-scoped link-local next hop (no connected mirror);
* interface-only/point-to-point route where the kernel permits it.

Link-local next hops require an interface. Interface-only routes are validated for installation and
qualified on hardware for forwarding. v0.1.0 supports one next hop per policy; no multipath.

### 4.4 Rule layout and precedence

For each source prefix `S` in a policy with provider table `T`:

```text
from S lookup 10000   pref p_internal
from S lookup T       pref p_provider
from S unreachable    pref p_terminal
```

A source with no matching policy reaches the native `main` rule. A more-specific source policy is
placed before every less-specific policy. The terminal guard is after the policy's lookups and
before `main`; it remains when the source rules/tables are partially lost. Destination exceptions are
global in v0.1.0; per-policy exception tables are a future extension.

### 4.5 Failure and mutation ordering

The invariant once a source is covered by an effective policy:

> At every interruption point the source is on its intended provider, on the previous effective
> provider, or blocked. It is never on an unauthorized provider.

**First application for an unconstrained source:** verify ownership; install the permanent terminal
`from S unreachable` guard at slot 6; ensure the internal table/guards; install the provider table
guard and route; install the active internal/provider pair; verify. The terminal guard remains. If a
step fails, leave the guard and report `protected`/`incomplete`; if the commit is not effective and
the previous state must be restored, restore the previous state and remove only the guard installed
for this failed application after the previous state is verified. A crash is handled by
active-config reconciliation; the monitor never treats an uncommitted snapshot as authority.

**New more-specific policy under an existing broader policy:** keep the broader policy effective;
install the new terminal guard first; build the new table/guard/route; install the free pair;
perform a structural/ownership/table check. The broader policy remains valid throughout.

**Update:** the terminal guard stays. Build the new table/guard/route; install the free pair;
perform a structural/ownership/table check; remove the active pair and update the manifest. If the
free pair is lower priority it takes effect after the new table is verified; if higher, the old pair
remains until removal. If the process dies before cleanup, the old pair still handles; after cleanup
the new pair and its table guard, plus the terminal guard, handle the source.

**Delete:** remove the provider route but keep the provider table guard, source rules and terminal
guard; remove the active/standby source rules; remove the terminal guard last; then clean the table.
If interrupted, the source is blocked. Deleting a policy is the explicit way to restore native
routing.

**Disable:** keep the internal/provider rules and terminal guard; withdraw the provider route.
Internal traffic works; external is blocked; health is `disabled`. A disabled policy remains disabled
across reconciliation and interface recreation; the provider route is not restored.

**Package removal:** refuse while configured policies exist. If no policies exist, remove only
extension-owned objects. Never silently remove an active policy in a way that permits cross-provider
egress.

### 4.6 Ownership and collision handling

* Desired state for reconciliation is the **active configuration** (monitor) or the **working
  configuration** (commit action). A committed snapshot is only the early boot guard's input; a
  pending/failed snapshot is not authority.
* A managed table must be empty or contain only extension-owned routes. Destructive action requires
  agreement of table, exact prefix/type set, `proto 194` and the desired/expected set; the manifest
  alone is insufficient. A marker-only match with a wrong prefix set is a conflict.
* A foreign route in a managed table or a foreign rule in the managed priority range is a conflict
  and is refused. A foreign rule before the range that can match a configured source is reported as
  `shadowed`; the policy is not effective, and the foreign rule is never deleted. Shadow detection
  considers overlap, `from all` and rules whose match is not source-only.
* The manifest records owned tables/prefixes/active pairs but is advisory. The journal records the
  planned transaction but never authorizes deletion; recovery recomputes the plan from active config
  and observed state and re-verifies ownership.
* No `ip rule flush`, no `ip route flush table`, no unrelated `main` mutation.
* Installation never adopts the manual table 41913 or rules 10410–10414.

### 4.7 Lifecycle and reconciliation

* `reconcile-working` runs at commit priority 500. It reads the working configuration with
  `listNodes`/`returnValue`, treats API diagnostics as hard failures, validates, plans, applies,
  verifies and writes a committed snapshot only after success. It does not rely on
  `existsEffective` for the still-executing subtree.
* The monitor reads the **active configuration** with `listActiveNodes`/`returnActiveValue` outside a
  commit. A failed commit does not change active config, so a stale snapshot cannot overwrite a
  newer committed configuration. The monitor refreshes the committed snapshot from active config on
  startup and after changes; the snapshot is for the early boot guard only.
* The event source is `ip -6 monitor link addr route` (or a narrow netlink helper if target output is
  unreliable). Events are coalesced for one second. A periodic full resynchronization (60 seconds)
  covers lost notifications. A lock serializes commit and monitor mutations; the desired generation
  is re-checked immediately before apply. Self-generated events are handled by idempotent
  reconciliation and coalescing. The monitor restarts its child with bounded backoff and systemd
  restarts the monitor.
* Boot: `edgeos-ipv6-sadr-guard.service` is ordered before `vyatta-router.service` and reads the
  committed snapshot to install terminal guards only. The full reconcile follows config load. The
  ordering and snapshot freshness are mandatory qualification gates; the window before the guard
  runs remains a named non-guarantee until verified on hardware.
* An interface recreated with a new ifindex loses its routes. The terminal guard remains; the
  monitor restores provider/internal routes. A disabled policy is not a route-restoration trigger.
* A process may die between mutations. Guards live in rules/tables, not process memory; the journal
  is diagnostic and restart reconciliation converges from active config and observed state.

### 4.8 Native configuration model

Illustrative proposed syntax (not final until the v0.1.0 template review):

```text
protocols {
    ipv6-sadr {
        internal-interface switch0.10
        internal-interface switch0.20
        destination-exception 2001:db8:1::/64
        destination-exception 2001:db8:100::/64
        destination-exception 2001:db8:200::/56

        policy provider-a {
            source-prefix 2001:db8:a000::/56
            source-prefix 2001:db8:a000:1::/64
            next-hop 2001:db8:aa00::1
            interface eth0
            table 10001
            description "Provider A transit"
        }

        policy provider-b {
            source-prefix 2001:db8:b000::/56
            next-hop 2001:db8:bb00::1
            interface eth1
            description "Provider B transit"
        }
    }
}
```

Semantics:

* `internal-interface` declares the only interfaces whose connected routes are auto-whitelisted.
  Unknown interfaces are not trusted. An interface used by a policy cannot be an internal
  interface. Provider-facing transfer links are never auto-whitelisted.
* `destination-exception` is global and exact. Its exact main-table route is mirrored; more-specific
  routes are not. A route on a policy interface, an ECMP/ambiguous exact route, or a gateway without
  a covering internal/connected route is rejected or guard-only.
* `source-prefix` is a tag child and may repeat. Exact duplicates across policies are invalid;
  overlapping prefixes are ordered longest-first.
* `next-hop` is optional for an interface-only route; `interface` is required for a link-local next
  hop and for global-next-hop resolution.
* `table` is optional; auto-allocation is deterministic and collision-checked.
* `disable` and `description` are supported. Per-policy destination exceptions are not v0.1.0.
* The subtree supports discovery, tab completion, validation, `show configuration commands`,
  `compare`, `commit`, `save`, deletion, rollback and commit-confirm through the normal engine.

### 4.9 Diagnostics and health

```text
show ipv6-sadr status
show ipv6-sadr policy [<name>]
show ipv6-sadr route <source> <destination> [iif <interface>]
show ipv6-sadr health [--json]
```

The path diagnostic uses `ip -6 route get <destination> from <source> [iif <interface>]` and explains
the selected table/rule. The target `ip -j` is unreliable for route/rule objects; the helper parses
stable text and emits its own JSON.

Health separates **intent** (configured/valid/disabled), **realization** (owned rules/tables/routes/
guards present), **effectiveness** (no shadow/conflict; guards and precedence) and **reachability**
(`unverified` by default, `next-hop-unresolved` only from neighbour state). States are `effective`,
`incomplete`, `dependency-unavailable`, `protected`, `shadowed`, `conflict`, `failed`, `disabled`;
exit codes 0/2/3/4/5/6/7/8. Route presence is never reported as end-to-end provider connectivity.

### 4.10 Implementation and source selection

Use Perl 5.24 (already present) plus the existing `ip` command; no new runtime or routing daemon. Split
responsibilities into the `EdgeOS::IPv6SADR` module and a CLI for configuration validation,
reconciliation, monitor, boot guard, status/health and route lookup. Parse text; do not depend on
target route/rule JSON. No new kernel module or vendor file change.

Forwarded traffic, explicitly source-bound local traffic and unbound router-originated traffic are
distinct. The implementation does not modify `gai.conf`, address labels, RAs or DHCPv6. Target
source-selection tests and RFC 6724/8043/8028/8678 analysis are qualification deliverables; no
automatic optimal-source claim.

### 4.11 v0.1.0 refinements

The normative v0.1.0 refinements are in [`../v0.1.0-refinements.md`](../v0.1.0-refinements.md).
They supersede conflicting text above, in particular: config.boot-derived boot guards with `/run`
intent instead of a persistent snapshot; active-config monitor authority; provider-table unreachable
guards for internal prefixes; explicit active/staging cutover; orphaned-guard health; disabled
creation/prefix shrink/exception removal ordering; and `/run` runtime state.

## 5. Alternatives considered

### A. Broad `main suppress_prefixlength 0` + table + rule guard

Rejected. It suppresses only the default route. More-specific main routes bypass the provider table,
as the experiments demonstrated for both cross-provider and internal destinations. A rule-level
terminal guard does not fix a selected more-specific route.

### B. Source-specific IPv6 FIB routes

Rejected for v0.1.0. Source-specific routes exist on the target kernel in principle, but:

* a more-specific main route captures the constrained source (generic-Linux experiment);
* for a destination with no more-specific route, the source-specific `unreachable` guard did block
  forwarded traffic; it does not solve the more-specific capture;
* the target `ip` `route add ... from` parser is not target-verified (upstream v4.14 source supports
  it; the target usage omits it; qemu execution was blocked by the host MIPS PIE limitation);
* the fail-closed guarantee would require additional mechanisms, eroding the simplicity advantage.

If a future target experiment proves strict semantics, this decision can be revisited. The
recommended architecture does not depend on it.

### C. Native `protocols static table` routes + extension rules

Rejected as the primary architecture. Native tables are limited to 1–200, have no source-prefix
rules, install routes with the default protocol and no terminal guard, and are not repaired after
netdevice recreation. Using them would either violate ownership (extension repairing native-owned
routes) or fail the lifecycle requirement. A future hybrid can be reconsidered if the vendor adds
lifecycle hooks or an ownership marker.

### D. Routing-daemon integration

Rejected. UBNT `ribd`/`nsm` and Quagga do not expose source-specific RPDB policy or per-table source
rules. Replacing or patching the daemon is out of scope and would duplicate a control plane.

## 6. Consequences

**Guaranteed by the design, subject to implementation and hardware qualification:**

* Correct source-provider egress for tested destination classes.
* Internal whitelist preservation, with fail-closed per-prefix guards.
* No automatic cross-provider fallback after route/interface loss or recreation.
* No unrelated routing-state mutation; refusal on collisions and ownership disagreement, with
  shadowing reported as not effective.
* Idempotent reconciliation and inspectable configured/effective state.
* Native configuration and operational integration; no kernel module or vendor file change.

**Not guaranteed:**

* End-to-end provider transit or remote health.
* RFC 6724 source selection for unbound local sockets.
* Behaviour on untested firmware, hardware offload paths or other platforms.
* A zero-exposure boot window before the early guard service is implemented and verified.
* Dynamic internal prefixes not covered by an exact exception.
* Target `route add ... from` or target source-specific forwarding semantics.
* Maximum performance; hardware offload must be measured.

## 7. Known unknowns and gates

1. **Config-engine ordering:** priority 500, `exists` versus `existsEffective`, no-op/delete/rollback,
   boot ordering. Gate: emulated EdgeOS plus hardware.
2. **Target parser:** `route add ... from` and `proto 194` rendering. Gate: qemu on a compatible host
   or read-only netns probe; not required for the recommended model.
3. **Hardware offload:** does the ER-X IPv6 fast path honour multi-table RPDB lookup? Gate: hardware
   forwarded TCP/UDP with and without the extension; offload on/off only with evidence.
4. **Internal route mirroring:** exact-route selection, ECMP refusal, BGP update/withdraw handling.
   Gate: unit/mock and hardware with an isolated BGP prefix.
5. **Monitor/systemd:** target `ip -6 monitor` support, systemd service ordering, early boot guard,
   lock/concurrency and resource cost. Gate: read-only target probe, emulation and hardware.
6. **Collision landscape:** rule priorities, table IDs and shadowing on the maintainer's router.
   Gate: read-only survey and isolated migration rehearsal.
7. **Source selection:** unbound router traffic may choose a WAN transfer address and bypass the
   policy. Documented; no gai.conf/RA/DHCP modification.

## 8. v0.1.0 implementation milestones

| Milestone | Deliverable | Gate |
|---|---|---|
| M1 | Production reconciler, config/operational templates, unit/mocks, ownership manifest, health command | `make test`; mock config API |
| M2 | Emulated EdgeOS config engine validation | subtree discovery, priority 500, `exists`/`existsEffective`, delete/no-op/rollback |
| M3 | Debian `Architecture: all` package, firmware guard, safe `prerm`/`postrm`, service | reproducible build; install/uninstall on emulation |
| M4 | Hardware qualification in isolated test policies; boot, commit-confirm, recreation, collision, rollback | target hardware evidence |
| M5 | Dataplane/offload/performance qualification with real TCP/UDP | hardware; no global offload disable |
| M6 | Migration of manual table 41913/rules 10410–10414 and release readiness | documented migration; no cross-provider exposure |

## 9. References

* RFC 8043, RFC 8678, RFC 7157, RFC 6724, RFC 8028, RFC 3704.
* EdgeOS 3.0.1 exact kernel/iproute2 source and read-only target inspection:
  [`../investigation/2026-11-27-platform-investigation.md`](../investigation/2026-11-27-platform-investigation.md).
* Generic-Linux experiments:
  [`../investigation/2026-11-27-experiments.md`](../investigation/2026-11-27-experiments.md).
* `edgeos-vxlan` platform/architecture records (concepts only; no code copied).
