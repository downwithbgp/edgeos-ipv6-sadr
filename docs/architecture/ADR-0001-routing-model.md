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

* The internal whitelist table contains only connected routes and exact configured internal
  prefixes, each with a terminal per-prefix `unreachable` guard. It has no default.
* Each policy has an extension-owned provider table containing the provider route and a terminal
  `unreachable default` guard.
* Each source prefix gets two rules: `from S lookup internal`, then `from S lookup provider_table`.
  A source that matches no policy uses native routing.
* A first-application temporary terminal rule blocks a previously unconstrained source while its
  first policy is installed. It is removed only after the permanent rules and guards verify.
* Source rules are ordered longest-prefix-first. A policy may have multiple source prefixes; they
  share the provider table.
* The extension owns only its tables, exact rules, exact routes and a route protocol marker. It never
  flushes a table or the RPDB and never writes unrelated `main` routes.
* A small event-driven reconciler applies desired state from native
  `protocols ipv6-sadr` configuration, verifies effective state, and repairs extension-owned routes
  after netdevice recreation.

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
| Internal table | `10000` | Connected + exact internal routes and per-prefix guards |
| Provider tables | `10001–19999` | One table per policy; auto-allocated or explicit |
| Rule priorities | `20000–21031` | Source rules below `main` (32766) |
| Route protocol marker | `194` | Extension ownership aid, not a security boundary |

Provider table allocation: a stable hash of the policy name into the range, with collision refusal;
the operator may set `table` explicitly. Rule priority:
`20000 + (128 - prefix_length) * 8 + slot`. Slots `0/1` and `2/3` are the active and standby
internal/provider pairs; slot `7` is the temporary first-application guard. The stride is 8, so
every more-specific prefix's rules precede every less-specific prefix's rules. Same-length prefixes
are disjoint and may share slots; exact duplicate source prefixes across policies are rejected. The
standby pair is used for an update: install there, perform a structural/ownership/table check (the
standby is behind the active pair and cannot be exercised end to end), remove the active pair, and
record the new active pair. Post-swap safety rests on the new table guard.

Native `protocols static table` uses `1–200`; the manual proof of concept uses table `41913` and
rules `10410–10414`. The extension does not use or modify those objects. A rule in the managed range
is a conflict and is refused. A pre-range rule that can match the source shadows the policy; health
reports `shadowed`, the extension may install its owned objects so migration can proceed, and it must
not claim enforcement or delete the foreign rule.

### 4.2 Internal whitelist

For every declared internal prefix and every connected route on an interface that is not a
policy egress/next-hop interface:

```text
table 10000:
    <prefix> [via ...] dev ... metric 1024 proto 194
    unreachable <prefix> metric 4096 proto 194
```

* Connected routes are refreshed on link/address events.
* A provider-facing transfer link is never auto-whitelisted. A connected route on a policy
  egress/next-hop interface must be declared explicitly if it is truly internal; otherwise a
  constrained source could cross to the other provider's on-link subnet.
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
```

A source with no matching policy reaches the native `main` rule. A more-specific source policy is
placed before every less-specific policy. Destination exceptions are global in v0.1.0; per-policy
exception tables are a future extension.

### 4.5 Failure and mutation ordering

The invariant once a source is covered by an effective policy:

> At every interruption point the source is on its intended provider, on the previous effective
> provider, or blocked. It is never on an unauthorized provider.

**First application for an unconstrained source:** verify ownership; install a temporary
`from S unreachable` rule; ensure the internal table/guards; install the provider guard and route;
install the permanent rules; verify; remove the temporary rule. If the commit fails before the
policy is effective, restore the previous effective state and remove the temporary rule; if
restoration fails, leave the source blocked and report `failed`.

**New more-specific policy under an existing broader policy:** keep the broader policy effective;
build the new table/guard/route; install the new rules in the inactive pair; perform a
structural/ownership/table check. No temporary guard is needed because the broader policy remains
valid throughout.

**Update:** build the new table/guard/route; install the new rules in the inactive pair; perform a
structural/ownership/table check; remove the active pair and update the manifest. The old pair
remains effective until it is removed. If the process dies before cleanup, the old pair still
handles; reconciliation completes the transition. If it dies after cleanup, the new pair and its
table guard handle the source.

**Delete:** remove the provider route but keep the terminal guard and rules; remove the source rules
(intentional unconstraining); remove the table/guard. If the process dies after the provider route
removal, the source is blocked. Deleting a policy is the explicit way to restore native routing.

**Disable:** keep the internal and provider rules, withdraw the provider route, retain the terminal
guard. Internal traffic works; external is blocked; health is `disabled`. Deleting the policy is
required to restore native external routing. A disabled policy MUST remain disabled across
reconciliation and interface recreation; the provider route MUST NOT be restored.

**Package removal:** refuse while configured policies exist. If no policies exist, remove only
extension-owned objects. Never silently remove an active policy in a way that permits cross-provider
egress.

### 4.6 Ownership and collision handling

* A managed table must be empty or contain only extension-owned routes. Destructive action requires
  agreement of table, exact prefix set, `proto 194` and the manifest. A marker-only match with a
  wrong prefix set is a conflict.
* A foreign route in a managed table or a foreign rule in the managed priority range is a conflict
  and is refused. A foreign rule before the range that can match a configured source is reported as
  `shadowed`; the policy is not effective, and the foreign rule is never deleted. Shadow detection
  considers overlap, `from all` and rules whose match is not source-only.
* The manifest is advisory; the kernel is authoritative. The reconciler re-verifies before cleanup.
* No `ip rule flush`, no `ip route flush table`, no unrelated `main` mutation.
* Installation never adopts the manual table 41913 or rules 10410–10414.

### 4.7 Lifecycle and reconciliation

* `protocols ipv6-sadr` runs at commit priority 500 (recommendation), after interfaces/addresses and
  static routes. Its `end:` action reads the working configuration with `exists`/`returnValue`,
  writes an atomic desired-state snapshot, applies the guarded sequence, verifies and records
  effective state. It does not rely on `existsEffective` for the still-executing subtree.
* A small event-driven monitor reads the snapshot and reconciles on netdevice link/address events
  and on changes to the exact internal prefixes. The candidate event source is `ip -6 monitor link`
  plus `ip -6 monitor addr` (and a filtered route monitor) under a systemd service, or a narrow
  netlink helper if the target monitor output is unreliable. It does not poll. A lock serializes
  commit and monitor. Target monitor/systemd support is a named gate.
* Boot: the config engine's `end:` action runs on boot configuration load. The provider table guard is
  installed before the source rules, so later dependency failures cannot create cross-provider
  egress. The window before the first reconciliation is a named non-guarantee unless an early boot
  guard service, ordered before WAN forwarding, is implemented. Target ordering is an open gate.
* An interface recreated with a new ifindex loses its routes. The guard remains; the monitor
  restores the provider/internal routes. If a previous next hop no longer exists, the source stays
  protected and the health state reports the dependency.
* A disabled policy is not a route-restoration trigger: the provider route remains absent across
  recreation; internal reachability remains and external traffic stays blocked.
* A process may die between mutations. Guards live in tables, not process memory; restart
  reconciliation converges.

### 4.8 Native configuration model

Illustrative proposed syntax (not final until the v0.1.0 template review):

```text
protocols {
    ipv6-sadr {
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

* `destination-exception` is global and exact. Connected routes on non-policy interfaces are
  automatic; provider-facing transfer links are excluded. A connected route on a policy interface
  must be declared explicitly if it is truly internal.
* `source-prefix` is a tag child and may repeat. Exact duplicates across policies are invalid.
* `next-hop` is optional for an interface-only route; `interface` is required for a link-local next
  hop and for global-next-hop resolution.
* `table` is optional; auto-allocation is deterministic and collision-checked.
* `disable` and `description` are supported. Per-policy destination exceptions are not v0.1.0.
* The subtree supports discovery, tab completion, validation, `show configuration commands`,
  `compare`, `commit`, `save`, deletion, rollback and commit-confirm through the normal engine.

### 4.9 Diagnostics

Proposed operational commands:

```text
show ipv6-sadr status
show ipv6-sadr policy [<name>]
show ipv6-sadr route <source> <destination> [iif <interface>]
show ipv6-sadr health [--json]
```

The path diagnostic uses `ip -6 route get <destination> from <source> [iif <interface>]` and explains
the selected table/rule. The target `ip -j` is unreliable for route/rule objects; the helper parses
stable text and emits its own JSON. Health uses the enum in
[`../requirements.md`](../requirements.md) and has meaningful exit codes. Route presence is never
reported as end-to-end provider connectivity.

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
