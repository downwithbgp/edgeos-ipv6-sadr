# Architecture-phase design and experiment plan

**Status:** pre-decision, revised after independent planning review. This document records the
candidate mechanisms, the routing contract they must satisfy and the experiments that will decide
between them. The final decision and its evidence belong in
`docs/architecture/ADR-0001-routing-model.md`.

## 1. Decision to be made

Select the mechanism that best satisfies the requirements while remaining native, minimal,
observable and safe on EdgeOS 3.0.1. The decision is **not** "reproduce the current runtime
commands"; the existing manual RPDB configuration is an input and a baseline, not the target.

The leading hypothesis is:

> Use the Linux IPv6 RPDB with two kinds of extension-owned tables:
>
> * a **global internal whitelist table** containing only connected routes and explicitly configured
>   internal destinations, each with a terminal per-prefix `unreachable` guard;
> * one **provider table per policy**, containing the provider default and a terminal
>   `unreachable default` guard.
>
> Each configured source prefix gets two rules: `from S lookup internal`, then
> `from S lookup provider_table`. Rules are ordered longest-source-prefix first. A temporary
> terminal guard rule blocks a previously unconstrained source while its first policy is being
> installed; it is removed only after the permanent rules and table guards are verified. The
> extension owns only its tables, rules, routes and one route protocol identifier, and reconciles
> them idempotently from native EdgeOS configuration.

The internal-whitelist choice is deliberate. A `main`-lookup exception with
`suppress_prefixlength 0` still accepts **any** more-specific main-table route under the exception,
including an external BGP route through another provider. RPDB rules cannot filter by route
protocol. A separate whitelist table containing only the exact internal prefixes avoids that leak
and makes the operator's internal set explicit.

The hypothesis is accepted only if experiments E-2 through E-12 pass. Candidate B (source-specific
FIB) is tested seriously; if it proves equally strict and simpler on the target, it wins.

## 2. Candidate architectures

### A. RPDB with internal and provider tables

**Mechanics (hypothesis):**

For a policy with source prefix `S`, provider egress `NH`/`IF`, provider table `T`:

```text
internal table I (global, one per router):
    <exact internal/connected prefix> [via ...] dev ... metric 1024 proto 194
    unreachable <exact internal/connected prefix> metric 4096 proto 194
    # no default route

provider table T:
    default via NH dev IF metric 1024 proto 194
    unreachable default metric 4096 proto 194
    [connected route covering NH, dev IF, proto 194]   # if NH is global

RPDB for S:
    from S lookup I        pref p_internal
    from S lookup T        pref p_provider

temporary first-application guard:
    from S unreachable     pref p_temp   # installed before the first policy, removed after verify
```

* The internal whitelist table contains **only** the exact prefixes the operator has declared
  internal, plus connected routes. A more-specific external route in `main` is not copied and cannot
  capture a constrained source. A per-prefix unreachable guard at high metric catches the loss of
  the real internal route.
* The provider table contains the provider default and a terminal unreachable default. A lookup
  that reaches `T` cannot continue to `main` if the provider route disappears.
* The internal lookup is tried first. If the destination is not in the whitelist, the lookup falls
  through to the provider table. If it is in the whitelist but the real route is missing, the
  per-prefix guard returns unreachable and the packet is blocked, not sent to a provider.
* The source prefix is constrained only by its rules. A source with no configured policy uses
  native routing. The contract does not claim to constrain unconfigured sources.
* The global internal table is shared by all policies. This matches the reference deployment, where
  all internal destinations must be reachable regardless of source. Per-policy internal tables are
  a possible future extension, not v0.1.0.
* A policy's provider table is exclusively extension-owned. A foreign route in it is a conflict.
* A `disable` keeps the policy's internal rule and terminal provider guard but withdraws the
  provider route: internal traffic continues; external traffic is blocked. Deleting the policy is
  the explicit way to restore native routing.

**Strengths:** strict no-leak semantics even with external more-specific routes; fail-closed inside
both tables; explicit internal whitelist; no `main` mutation; works for forwarded and source-bound
local traffic; no new kernel feature; no routing-daemon modification; explicit ownership and
diagnostics.

**Weaknesses:** explicit internal-route maintenance; two tables and two rules per source prefix;
route mirroring for internal destinations; rule/table collision management; source address
selection for unbound local traffic remains an RFC 6724 problem.

### B. Source-specific IPv6 FIB

**Mechanics (hypothesis):**

```text
ip -6 route add default from S via NH dev IF metric 1024 proto 194
ip -6 route add unreachable default from S metric 4096 proto 194
```

No RPDB rules or dedicated tables. The kernel's IPv6 FIB supports source subtrees
(`CONFIG_IPV6_SUBTREES=y` on the target).

**Strengths:** smallest object set; no rule-priority or table-ID ownership; natural coexistence with
destination routes; potentially simpler lifecycle.

**Weaknesses / falsification criteria:**

* Destination lookup is longest-prefix first. A more-specific external route in `main` (for example a
  BGP route through another provider) overrides the source-specific default. If the experiment shows
  that a constrained source can egress an unauthorized provider via such a route, B fails R-3/R-5
  unless an additional guard mechanism is added.
* The target `ip` build's `route add` usage does not advertise `from` (only `route get` does). If the
  target parser rejects the operation, using it would require a custom netlink helper, increasing
  the implementation and provenance surface.
* Source-specific `unreachable` route semantics and lookup fallback must be proven on 4.14, not
  assumed from modern kernels.
* Coexistence with `ribd`/`nsm` route ownership and interface recreation must be proven.
* Candidate B would install source-qualified routes in `main`. The ownership model for A does not
  touch `main`; if B is selected, its ownership model must be amended to permit **only exact
  source-qualified routes with the extension protocol marker**, with exact-prefix checks. This is a
  deliberate decision point, not an accidental main-table mutation.

### C. Native `protocols static table` routes plus extension rules

**Mechanics:** let native EdgeOS own provider routes in `protocols static table <N> route6 ...`
(tables 1–200) and let the extension own source rules and a rule-level terminal guard.

**Findings so far:**

* Native `protocols static table` supports IPv6 next-hop, blackhole and interface routes via
  `ubnt-multi-table.pl`, which invokes `ip -6 route add table N`. Tables are restricted to 1–200.
* Native IPv6 policy routing is `fwmark`-based only (`protocols static table N mark M` installs
  `ip -6 rule pref N fwmark M table N`). There is no source-prefix rule template.
* The native leaf actions install routes at commit time. No interface lifecycle hook re-adds them
  after a netdevice is recreated (`ubnt-multi-table.pl` has no caller outside the static-table leaf
  templates).
* The native routes carry the default `ip route` protocol, not an extension marker, and have no
  terminal guard.

**Consequence:** this is a possible hybrid, but it cannot satisfy R-7 alone: after interface
recreation the native route can disappear and nothing repairs it. The extension could detect the
missing route and fail closed via its rule guard, but reachability would remain broken until a
configuration commit. Repairing a native-owned route from the extension would violate ownership.
This candidate is retained for comparison, not as the leading design.

### D. Routing-daemon integration

**Mechanics:** extend `ribd`/`nsm`/Quagga static-route configuration or install policy through the
existing routing daemon.

**Findings so far:** the target uses UBNT `ribd`/`nsm`/`imi` with Quagga protocol daemons. The
native static route6 templates call `vtysh`/zebra for main-table routes. Native table routes bypass
the daemon and use `ip` directly. No source-specific policy or RPDB rule mechanism is exposed by the
daemon configuration. Replacing the daemon is explicitly out of scope.

**Consequence:** not viable without vendor changes or a parallel control plane; reject unless a
narrow, documented integration point is found.

## 3. Evaluation criteria

| Criterion | What must be demonstrated |
|---|---|
| Correctness | Correct egress for each source prefix and destination; no unintended cross-provider egress with a more-specific external route present, including inside a declared internal prefix |
| Source precedence | Nested source prefixes choose the longest match; no less-specific policy's rule can shadow a more-specific policy |
| Failure containment | Missing provider route, missing internal route, interface down, interface recreation and process death leave the source on its effective policy or blocked, not misrouted |
| Native integration | Configuration survives commit/save/reboot/rollback; no vendor file modifications |
| Ownership | Exact object ownership; collision and shadow refusal; no flush; no unrelated state mutation |
| Coexistence | BGP/OSPF/RA/connected routes and the routing daemon are unaffected |
| Lifecycle | Idempotent reconciliation; repair after netdevice recreation; no polling; boot ordering understood |
| Observability | Configured vs effective state; actual `ip -6 route get` path; health exit codes |
| Complexity | Smallest maintainable implementation and dependency surface |
| Target support | Works on the exact 4.14.54-UBNT / iproute2 build, not only modern Linux |
| Performance | No global offload disable; a defensible qualification methodology; offload interaction identified as a correctness risk if unproven |

## 4. Experiments

All experiments record the environment, exact commands, observed output and commit. Generic Linux
results are labelled **Verified (generic Linux)** and never presented as EdgeOS evidence.

### E-1. Target capability and provenance

* Read-only router inspection: firmware, kernel, `ip -V`, RPDB, tables, routes, templates, routing
  daemons.
* Exact kernel source/config: `CONFIG_IPV6_SUBTREES`, `CONFIG_IPV6_MULTIPLE_TABLES`,
  `CONFIG_IP_ROUTE_MULTIPATH`, `CONFIG_NET_NS`.
* Target `ip` parser: does it accept `route add ... from`? Does `-j` work for route/rule objects?
* Target configuration engine: priority values, `end:` ordering, `my_cli_shell_api` visibility,
  scripted versus interactive context.
* Target offload: determine whether the ER-X IPv6 forwarding fast path honors multi-table RPDB
  lookup. This is a correctness question, not only performance. Hardware access is required; record
  it as a named unknown until then.
* Pass criterion: every target claim has a named source (hardware, exact firmware file, exact vendor
  source) and an evidence label.

### E-2. Netns topology and baseline

Build an isolated multihomed topology with two providers, two delegated prefixes, a multihomed edge
router, a dual-prefix client, a connected internal destination, a configured non-connected internal
destination, and external destinations behind each provider. Providers perform source-address
validation and expose capture points. Establish positive controls:

* provider A transit works for a provider A source;
* provider B transit works for a provider B source;
* both internal destinations are reachable from both sources;
* the wrong provider can be observed receiving traffic in a deliberate leak test.

Include nested source prefixes (for example a /48 policy and a /64 policy inside it) in a later
scenario so priority ordering is exercised.

### E-3. Broad RPDB (current proof of concept)

Reproduce the current model: `from S lookup main suppress_prefixlength 0`, then a dedicated table,
then a rule-level unreachable. Introduce a more-specific external route in `main` via the "wrong"
provider. Demonstrate whether a constrained source follows that route. This is expected to expose
the known limitation and is a falsification test for the broad-suppressor model.

Also test a more-specific external route **inside** an excepted destination: it demonstrates why a
`main`-lookup exception is not a strict whitelist.

### E-4. Internal whitelist and provider guards

Implement candidate A. Verify:

* provider A source uses provider A for external destinations;
* provider B source uses provider B;
* both sources reach connected and configured internal destinations through the internal table;
* a more-specific external route in `main` does not capture the constrained source;
* a more-specific external route inside a declared internal prefix does not capture it (the internal
  table contains only the exact internal route);
* removing the provider route leaves the source fail-closed (no egress on either provider);
* removing the real internal route leaves the source fail-closed for that prefix (per-prefix guard),
  not routed to a provider;
* the provider table shows both the unicast default and the unreachable default; the unreachable
  guard is selected only when the unicast route is absent;
* an unresolved next hop leaves the route selected but packets undelivered; health reports the
  dependency and does not claim reachability.

### E-5. Source-specific FIB

Implement candidate B. Verify parser support on the target, source-specific lookup, interaction with
more-specific routes, source-specific unreachable behaviour, nested source prefixes and lifecycle.
Falsify B if it cannot satisfy R-3/R-5 without reintroducing RPDB.

### E-6. Lifecycle and ownership

* Delete/recreate a provider netdevice with the same name and a new ifindex while traffic is probed.
  Verify the route disappears, the guard prevents misrouting, and reconciliation restores
  reachability.
* Delete an internal-route netdevice and verify the per-prefix guard blocks rather than leaking.
* Add a foreign route to a managed table and verify refusal, not deletion. A protocol-marker match
  without prefix-set/manifest agreement is still a conflict.
* Add a foreign rule before the extension's range and verify shadow detection, not a silent
  "effective" report.
* Test rule-priority and table-ID collision detection.
* Test idempotent re-application and no-op reconciliation.
* Test abrupt termination between guard/route/rule mutations (simulate by ordering and kill points).
* Test a first policy application with a temporary blocking rule and a failed apply; verify the
  source is blocked or the previous effective state is restored, never routed to a new unauthorized
  provider.

### E-7. Local traffic and source selection

* Bind a local socket to each provider address and verify the selected table and egress.
* Send unbound traffic and observe the kernel's selected source; document that SADR does not control
  RFC 6724 selection.
* Verify `ip -6 route get <dst> from <src>` agrees with the observed path for forwarded and local
  traffic; note the limits of the lookup API (input interface, preferred source, cache).
* Test a local ICMP/UDP/TCP flow, not only `route get`.

### E-8. Diagnostics and effective-state verification

* Implement prototype status/health output: configured policy, internal table routes and guards,
  provider table routes and guard, rules and priorities, interface state, shadow/conflict state.
* Verify a health check exits non-zero for configured-but-incomplete, dependency-unavailable,
  protected-by-failure-policy, shadowed, ownership-conflict and reconciliation-failed states.
* Verify the diagnostic distinguishes local and forwarded lookup and does not claim end-to-end
  connectivity from route presence.

### E-9. Boot and configuration-engine ordering

* Establish from vendor source/templates where the new subtree runs relative to interfaces, addresses
  and static routes.
* Determine whether an early boot guard can be installed before WAN forwarding; if not, record the
  boot window as an explicit non-guarantee and a v0.1.0 requirement.
* Verify the configuration action reads the working configuration (not `existsEffective` of the
  still-executing subtree), and that an API error is not treated as absent.
* Verify a no-op commit, deletion of the last policy, commit-confirm rollback and a failed commit
  leave a safe effective state.

### E-10. Non-Ethernet and interface-only egress

* Verify route installation for a link-local next hop and an interface-only/point-to-point route on
  a non-Ethernet link where the kernel permits it.
* Distinguish route installation from full forwarding; hardware qualification covers the latter.

## 5. Proposed routing contract (subject to decision)

### 5.1 Source precedence

* Policies are keyed by canonical source prefix. Exact duplicate source prefixes across policies are
  invalid.
* Longest source prefix wins. Rule priorities are grouped by source-prefix length: every rule for a
  more-specific prefix has a lower priority number than every rule for a less-specific prefix.
* A policy may carry multiple source prefixes; each gets its own rule group but shares the provider
  table and egress. A more-specific prefix in the same policy is allowed and wins over a
  less-specific one.
* A source prefix that matches no policy uses native EdgeOS routing. SADR only constrains configured
  sources.
* A less-specific policy's rules must never shadow a more-specific policy's rules. The priority
  allocator and a nested-prefix experiment enforce this.

### 5.2 Destination resolution

* The internal whitelist table contains:
  * connected routes derived from the kernel (refreshed on link/address events);
  * exact routes for explicitly configured internal destinations, mirrored from the exact
    main-table route at reconciliation time;
  * for every such prefix, a terminal `unreachable` route at a higher metric.
* The internal table has no default. A destination that is not whitelisted falls through to the
  provider table.
* A whitelisted destination whose real route is missing matches its per-prefix guard and is blocked.
  It does not fall through to a provider.
* The operator owns the internal list. The extension does not infer that every non-default main
  route is internal. More-specific routes under a declared prefix are not copied unless they are
  themselves declared.
* A route mirror with multiple equal-prefix next hops (ECMP) is rejected in v0.1.0 with an explicit
  diagnostic; the operator can declare a more specific prefix or a single next hop.

### 5.3 Egress and failure

* The provider table contains the provider route and a terminal `unreachable` default. The guard is
  present before the source is constrained and remains until intentional policy deletion.
* A missing provider route, an absent interface or a failed next hop produces a fail-closed result
  for the constrained source. The system reports "protected by failure policy", not "reachable".
* No automatic fallback to `main` or another provider is implemented in v0.1.0.
* The extension cannot detect remote transit failure without provider health monitoring, which is
  out of scope. A route being present is never reported as end-to-end connectivity.

### 5.4 Local versus forwarded traffic

* RPDB rules match packets with a known source, including locally generated packets whose socket is
  bound to a configured source.
* Automatic source selection for unbound sockets remains governed by RFC 6724 and the kernel. The
  project does not modify `gai.conf`, address labels, RAs or DHCPv6 to influence it.
* Diagnostics must state which source was actually selected and must not present the route's
  preferred-source attribute as source rewriting.

## 6. Desired-state and effective-state model

**Desired state (from native configuration):**

```text
protocols ipv6-sadr
    destination-exception <prefix>...      # global exact internal prefixes
    policy <name>
        source-prefix <prefix>...          # canonical
        next-hop <address> [interface <if>]
        interface <if>                     # for link-local or interface-only
        table <id>                         # optional; otherwise deterministic allocation
        description <text>
        disable
```

**Effective state (from kernel and netdevice state):**

```text
policy <name>
    table <id>
    rule priorities <p...>
    provider route <prefix> via <nh> dev <if> proto 194
    provider guard unreachable default proto 194
    connected mirror route (if needed)
    internal rule / provider rule present
    internal table entries for declared prefixes
    interface present/up
    next-hop resolved/unresolved
    ownership <owned|conflict>
    shadowed <yes|no>
    health <effective|incomplete|dependency-unavailable|protected|shadowed|conflict|failed|disabled>
    reason <no-route|interface-down|next-hop-unresolved|neighbour-unreachable|transit-unverified|daemon-unavailable|api-error>
```

The configuration action persists an atomic desired-state snapshot for the monitor. The kernel and
netdevice state remain authoritative for effective state. Reconciliation computes the diff, refuses
ownership conflicts, applies guarded mutations in the order below, then verifies and records the
result.

Health states are one enum with a separate reason field:

| State | Meaning |
|---|---|
| `effective` | Configured, owned objects present and verified; dependency present |
| `incomplete` | Configured, some owned objects missing or not yet applied |
| `dependency-unavailable` | Interface/address/next hop missing or down |
| `protected` | Guard active because the intended route is absent; source blocked |
| `shadowed` | A preceding foreign rule prevents this policy from matching |
| `conflict` | Foreign table/route/rule or ownership disagreement |
| `failed` | Reconciliation error; last error recorded |
| `disabled` | Policy disabled; internal rule retained, external path blocked |

`transit-unverified` is a reason, not a health state: SADR does not claim to verify remote transit.
Likewise, "link operational but remote transit unavailable" is not detectable and is an explicit
non-guarantee, not a hidden state.

## 7. Ownership model (proposed)

* **Internal table:** one global table, fixed at `10000` (tentative), exclusively extension-owned. It
  contains connected and declared internal routes plus per-prefix guards, all with proto `194`.
* **Provider tables:** `10001–19999` (tentative). Native `protocols static table` uses `1–200`; the
  manual proof of concept uses `41913`; neither is touched. An auto-allocated table that collides
  with a foreign route is a configuration error; the operator can set `table <id>` explicitly.
* **Route protocol:** numeric `194` (tentative) marks extension routes. It is a verification aid, not
  a security boundary. A destructive action requires **table + exact prefix set + proto + manifest
  agreement**. A route with the right proto but a different prefix set is a conflict and is not
  deleted.
* **Rules:** `20000–21031` (tentative), below `main` (32766) and above the manual proof-of-concept
  rules (10410–10414). The allocator is
  `priority = 20000 + (128 - prefix_length) * 8 + (stable_hash(prefix) mod 4) * 2 + slot`, where
  slot `0` is the internal-table lookup, slot `1` is the provider-table lookup and slot `7` is the
  temporary first-application guard. Every rule for a more-specific prefix therefore precedes every
  rule for a less-specific prefix; within a length, same-length prefixes are disjoint, so hash
  collisions cannot change the selected policy. A foreign rule in the range is a conflict. A foreign
  rule **before** the range that matches a configured source is a shadowing conflict; `health`
  reports `shadowed` and does not claim effectiveness.
* **Manifest:** a small state file records the allocation and last effective state. It is advisory;
  the kernel is authoritative and every destructive action is preceded by an ownership check.
* **No destructive breadth:** only exact extension-owned prefixes/tables/rules are removed. No
  `ip rule flush`, no `ip route flush table`, no `main` mutation (Candidate A).
* **Migration:** the operator creates extension policies in new tables, verifies them, then removes
  the manual table/rules. Installation never adopts table 41913 or rules 10410–10414 silently. A
  manual rule that shadows a new policy is detected and reported until it is removed.

## 8. Mutation ordering (proposed)

The invariant, once a source prefix is covered by an **effective** policy, is:

> At every interruption point, the source is on its intended provider, on the previous effective
> provider, or blocked. It is never on an unauthorized provider.

A source that has never been constrained may use native routing until its first policy is fully
verified; during that first application a temporary terminal guard blocks it. The boot window is
covered separately in §9.

**Create a first policy for an unconstrained source:**

1. Verify table and rule-range ownership (including shadow detection).
2. Install a temporary `from S unreachable` rule at the end of the source's priority band. The source
   is now blocked.
3. Ensure the internal whitelist table and its guards exist. A missing internal route is already
   guarded; it cannot leak.
4. Install the provider table's terminal `unreachable default`.
5. Install the provider route (and connected mirror if needed). If it fails, leave the guards and the
   temporary block; report `protected`/`incomplete`. The source stays blocked.
6. Install `from S lookup internal` and `from S lookup provider` before the temporary guard.
7. Verify. Remove the temporary guard only after the permanent rules and table guards are verified.
8. If the commit fails before the policy becomes effective, restore the previous effective state
   (native routing) and remove the temporary guard; the candidate policy was never effective. If
   restoration itself fails, leave the source blocked and report `failed`.

**Create a more-specific policy under an existing broader policy:**

1. Keep the broader policy in place; it is a valid fallback.
2. Build the new provider table/guard/route.
3. Install the new source's internal/provider rules at priorities before the broader policy.
4. Verify; no temporary guard is needed because the broader policy remains effective throughout.
5. If the new policy fails, remove its partial objects; the broader policy is unchanged.

**Update an existing policy (same source, new egress/table):**

1. Build the new provider table/guard/route first; do not remove the old policy.
2. Install the new rules at a priority before the old rules. The new table is already guarded.
3. Verify the new path.
4. Remove the old rules, then the old table's routes. The new rule takes over without a fallback
   window. If the process dies before step 4, both rules exist; the new one wins and the old is
   stale but harmless. Reconciliation cleans it.

**Change a source prefix:** treat as create-new plus delete-old. Install the new prefix first. If the
new prefix is more specific, it wins immediately; if less specific, the old still applies to its
range until removed. If the new prefix is not covered by any effective policy, use the temporary
guard-first sequence.

**Delete a policy intentionally:**

1. Remove the provider route but leave the terminal guard in the table and keep the source rules.
   The source is blocked for external destinations; internal traffic still works.
2. Remove the source rules. Traffic now falls to native routing; this is the intentional
   unconstraining transition, and it is blocked while the provider route is absent.
3. Remove the table's guard and any remaining routes.
4. If the process dies after step 1, the source is blocked; if it dies after step 2, the policy is
   intentionally gone and native routing applies.

**Disable a policy:** keep the internal rule and the provider-table rule, remove the provider route,
and keep the terminal guard. Internal traffic continues; external traffic is blocked. The health
state is `disabled`. Deleting the policy is the explicit way to restore native routing.

**Package removal:** refuse while configured policies exist. If removed without policies, remove only
owned objects. Never silently delete an active policy in a way that permits cross-provider egress.

## 9. Lifecycle, boot and configuration-engine design (proposed)

* The `protocols ipv6-sadr` subtree has commit priority 500, after interfaces/addresses (default
  area) and static routes (450). Its `end:` action calls the reconciler with the working
  configuration.
* The reconciler is idempotent, takes a lock, reads **working-configuration** desired state through
  the configuration API, writes an atomic desired-state snapshot, computes the diff, applies the
  guarded sequence, verifies, and records effective state.
* During its own `end:` action, `existsEffective` may not yet report nodes in the still-executing
  subtree. The action must use `exists`/`returnValue` on the working configuration, not
  `existsEffective`. An API error is a hard failure, never "absent".
* The monitor reads the persisted desired-state snapshot, not the live configuration API, and
  reconciles on netdevice link/address events and on changes to the exact internal prefixes. It does
  not poll and does not use arbitrary sleeps beyond a short debounce.
* The monitor is started only when policies are configured and stopped when the subtree is removed,
  or runs as a lightweight always-on service that exits immediately if no policies exist. The final
  choice is a v0.1.0 implementation detail; the architecture requires that any daemon is justified
  and measurable on the ER-X.
* Boot: the config engine's `end:` action runs on boot configuration load; the monitor repairs
  dependencies that come up later. Because the provider table guard is installed before the source
  rules, a later dependency failure cannot create cross-provider egress. The remaining boot window
  is before the first reconciliation: native routing may apply until the action runs. A v0.1.0
  requirement is an early boot guard service, ordered before WAN forwarding, that installs terminal
  guards from the persisted snapshot. If the platform cannot guarantee that ordering, the boot window
  is an explicit non-guarantee in the documentation and the hardware test plan, not a hidden claim.
* Abrupt termination: the guards live in tables, not in process memory. A restart reconciles. A
  previous next hop that no longer exists leaves the guard in place and is reported.
* Concurrency: a lock serializes the commit action and the monitor. If the monitor cannot acquire the
  lock, it defers and re-runs after the commit.

## 10. Diagnostic design (proposed)

```text
show ipv6-sadr status
show ipv6-sadr policy [<name>]
show ipv6-sadr route <source> <destination> [iif <interface>]
show ipv6-sadr health [--json]
```

`route` executes `ip -6 route get <destination> from <source> [iif <interface>]` and explains the
selected table/rule; it does not reimplement the FIB lookup. `health` exits `0` only when every
configured policy is effective; distinct non-zero codes indicate incomplete, protected,
dependency-unavailable, shadowed, conflict or failed. The target's `ip -j` is reliable for link
objects but not for route or rule objects; the helper parses stable text and can emit its own JSON.
A route being present is never reported as end-to-end provider connectivity.

The prototype must show both `status` (configured vs effective) and a machine-readable health object
so monitoring and regression tests can consume it.

## 11. Risks and unknowns

| Risk | Impact | Resolution |
|---|---|---|
| Target `ip` rejects `route add ... from` | Candidate B needs a custom helper or is rejected | E-1, E-5 |
| Source-specific FIB leaks via more-specific external routes | Candidate B fails strict correctness | E-3, E-5 |
| `unreachable default` inside a table does not stop RPDB fallback | Candidate A's guard is insufficient | E-4 |
| Internal exact-route mirror is stale or ambiguous | Internal destination blocked or wrong route | E-4, E-6; reject ECMP in v0.1.0 |
| Native table routes are not repaired after interface recreation | Candidate C fails lifecycle | E-6 |
| Config engine priority/visibility differs from source inspection | Action ordering or desired-state read is wrong | E-1, E-9 |
| Rule-priority or table-ID collisions on real deployments | Unsafe application | E-6; collision/shadow tests |
| A manual rule shadows the new policy during migration | Policy reports effective but is not | E-6; health `shadowed`; migration procedure |
| Dynamic internal prefixes need explicit exceptions | Operational burden or blocking if missed | Document; future automation |
| Local source selection picks an unintended source | Unbound router traffic uses the wrong path | E-7; document limitation |
| Boot window before first reconciliation | Cross-provider egress at boot | E-9; early guard service or explicit non-guarantee |
| Monitor daemon cost or process supervision | Resource/robustness concern | Prototype; justify in v0.1.0 |
| Offload path ignores multi-table lookup | Correctness/performance claim | E-1 hardware fact; qualification gate |
| Commit engine is non-atomic | Partial desired state | Guard-first ordering; idempotent reconcile; health report |

## 12. Decision rule

Candidate A is recommended only if:

* E-2 positive controls pass;
* E-4 strict no-leak (including inside declared internal prefixes), internal-preservation, guard and
  unresolved-next-hop tests pass;
* E-6 lifecycle/recreation, ownership-conflict, shadow and interruption tests pass;
* E-9 shows the configuration action can read its own subtree and the boot window is either guarded or
  explicitly non-guaranteed;
* E-1 confirms the target iproute2 and kernel support the required operations;
* no candidate is simpler while satisfying R-3, R-5, R-6 and R-7.

Candidate B replaces A only if it passes the same correctness and failure tests without additional
RPDB objects. Candidate C is accepted only if native route lifecycle is proven or a narrowly scoped,
ownership-respecting repair mechanism is designed. Candidate D is rejected unless a documented
daemon integration point exists.

If no candidate satisfies the requirements on the target, the architecture phase reports the gap and
the specific experiments or vendor changes needed; it does not ship a weaker claim.
