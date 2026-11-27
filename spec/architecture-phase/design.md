# Architecture-phase design and experiment plan

**Status:** pre-decision. This document records the candidate mechanisms, the routing contract they
must satisfy and the experiments that will decide between them. The final decision and its evidence
belong in `docs/architecture/ADR-0001-routing-model.md`.

## 1. Decision to be made

Select the mechanism that best satisfies the requirements while remaining native, minimal,
observable and safe on EdgeOS 3.0.1. The decision is **not** "reproduce the current runtime
commands"; the existing manual RPDB configuration is an input and a baseline, not the target.

The leading hypothesis is:

> Use the Linux IPv6 RPDB with extension-owned routing tables and source-prefix rules. Each managed
> table contains the provider default and a terminal `unreachable` default. Explicit destination
> exceptions (plus automatically derived connected networks) look up `main` with default routes
> suppressed. Rules are ordered longest-source-prefix first. The extension owns only its tables,
> rules, routes and one route protocol identifier, and reconciles them idempotently from native
> EdgeOS configuration.

The hypothesis is accepted only if experiments E-2 through E-8 pass. Candidate B (source-specific
FIB) is tested seriously; if it proves equally strict and simpler on the target, it wins.

## 2. Candidate architectures

### A. RPDB with extension-owned tables

**Mechanics (hypothesis):**

For a policy with source prefix `S`, provider egress `NH`/`IF`, table `T` and destination
exceptions `D_i`:

```text
table T:
    default via NH dev IF metric 1024 proto 194
    unreachable default metric 4096 proto 194
    [connected route covering NH, dev IF, proto 194]   # if NH is global

RPDB:
    from S to D_i lookup main suppress_prefixlength 0  pref p_i
    from S lookup T                                    pref p_table
```

* The terminal unreachable default lives **inside the table**, so a lookup that reaches `T` cannot
  continue to `main` if the provider route disappears. This is a stronger guard than a separate
  `unreachable` rule and is independent of rule ordering.
* `suppress_prefixlength 0` on the exception lookup suppresses only `main`'s default route. A
  configured exception therefore uses a real main-table route or falls through to the provider
  table; it cannot accidentally use `main`'s default.
* Connected networks are derived as automatic exceptions; other internal destinations require an
  explicit exception. This avoids the "all non-default routes are internal" assumption.
* Longest-source-prefix precedence is implemented by rule-priority ordering. Exact duplicate source
  prefixes across policies are rejected.
* Destination exceptions are part of the policy and are therefore inspectable and testable.
* A policy's table is exclusively extension-owned. A foreign route in it is a conflict.

**Strengths:** direct expression of the required semantics on the target's known iproute2; fail-closed
inside the table; works for forwarded and source-bound local traffic; no new kernel feature; no
routing-daemon modification; explicit ownership and diagnostics.

**Weaknesses:** explicit exception maintenance for dynamic internal prefixes; more moving objects
(tables, rules, routes) than a source-specific FIB; rule/table collision management; source address
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
| Correctness | Correct egress for each source prefix and destination; no unintended cross-provider egress with a more-specific external route present |
| Failure containment | Missing provider route, interface down, interface recreation and process death leave the source blocked, not misrouted |
| Native integration | Configuration survives commit/save/reboot/rollback; no vendor file modifications |
| Ownership | Exact object ownership; collision refusal; no flush; no unrelated state mutation |
| Coexistence | BGP/OSPF/RA/connected routes and the routing daemon are unaffected |
| Lifecycle | Idempotent reconciliation; repair after netdevice recreation; no polling |
| Observability | Configured vs effective state; actual `ip -6 route get` path; health exit codes |
| Complexity | Smallest maintainable implementation and dependency surface |
| Target support | Works on the exact 4.14.54-UBNT / iproute2 build, not only modern Linux |
| Performance | No global offload disable; a defensible qualification methodology |

## 4. Experiments

All experiments record the environment, exact commands, observed output and commit. Generic Linux
results are labelled **Verified (generic Linux)** and never presented as EdgeOS evidence.

### E-1. Target capability and provenance

* Read-only router inspection: firmware, kernel, `ip -V`, RPDB, tables, routes, templates, routing
  daemons.
* Exact kernel source/config: `CONFIG_IPV6_SUBTREES`, `CONFIG_IPV6_MULTIPLE_TABLES`,
  `CONFIG_IP_ROUTE_MULTIPATH`, `CONFIG_NET_NS`.
* Target `ip` parser: does it accept `route add ... from`? Does `-j` work for route/rule objects?
* Target configuration engine: priority values, `end:` ordering, `my_cli_shell_api` visibility.
* Pass criterion: every target claim has a named source (hardware, exact firmware file, exact vendor
  source) and an evidence label.

### E-2. Netns topology and baseline

Build an isolated multihomed topology with two providers, two delegated prefixes, a multihomed edge
router, a dual-prefix client, an internal destination and external destinations behind each provider.
Providers perform source-address validation and expose capture points. Establish positive controls:

* provider A transit works for a provider A source;
* provider B transit works for a provider B source;
* the internal destination is reachable from both sources;
* the wrong provider can be observed receiving traffic (so a later absence of traffic is meaningful).

### E-3. Broad RPDB (current proof of concept)

Reproduce the current model: `from S lookup main suppress_prefixlength 0`, then a dedicated table,
then a rule-level unreachable. Introduce a more-specific external route in `main` via the "wrong"
provider. Demonstrate whether a constrained source follows that route. This is expected to expose the
known limitation and is a falsification test for the broad-suppressor model.

### E-4. Explicit destination exceptions and table guard

Implement candidate A with explicit exceptions and an `unreachable default` in each managed table.
Verify:

* provider A source uses provider A for external destinations;
* provider B source uses provider B;
* both sources reach the internal destination through the exception;
* a more-specific external route in `main` does not capture the constrained source;
* removing the provider route leaves the source fail-closed (no egress on either provider);
* removing an exception makes that destination follow the provider policy (documented behaviour).

### E-5. Source-specific FIB

Implement candidate B. Verify parser support on the target, source-specific lookup, interaction with
more-specific routes, source-specific unreachable behaviour and lifecycle. Falsify B if it cannot
satisfy R-3/R-5 without reintroducing RPDB.

### E-6. Lifecycle and ownership

* Delete/recreate a provider netdevice with the same name and a new ifindex while traffic is probed.
  Verify the route disappears, the guard prevents misrouting, and reconciliation restores
  reachability.
* Delete a table route and verify fail-closed.
* Add a foreign route to a managed table and verify refusal, not deletion.
* Test rule-priority and table-ID collision detection.
* Test idempotent re-application and no-op reconciliation.
* Test abrupt termination between guard/route/rule mutations (simulate by ordering and kill points).

### E-7. Local traffic and source selection

* Bind a local socket to each provider address and verify the selected table and egress.
* Send unbound traffic and observe the kernel's selected source; document that SADR does not control
  RFC 6724 selection.
* Verify `ip -6 route get <dst> from <src>` agrees with the observed path for forwarded and local
  traffic; note the limits of the lookup API.

### E-8. Diagnostics and effective-state verification

* Implement prototype status/health output: configured policy, table, rules, provider route, guard,
  interface state, exceptions, conflict state.
* Verify a health check exits non-zero for configured-but-incomplete, dependency-unavailable,
  protected-by-failure-policy and ownership-conflict states.
* Verify the diagnostic does not claim end-to-end connectivity from route presence.

## 5. Proposed routing contract (subject to decision)

### 5.1 Source precedence

* Policies are keyed by canonical source prefix.
* Longest source prefix wins. Rule priorities are ordered accordingly.
* Exact duplicate source prefixes across policies are invalid.
* A policy may carry multiple source prefixes; each gets its own rule group but shares the table and
  egress. A more-specific prefix in the same policy is allowed and wins over a less-specific one.
* A source prefix that matches no policy uses native EdgeOS routing. SADR only constrains configured
  sources.

### 5.2 Destination resolution

* Connected routes are automatic exceptions. The reconciler derives them from `main` and refreshes
  them on address/link events.
* Additional internal/dynamic destinations must be configured as explicit exceptions. The operator
  owns this list; the extension does not guess that a non-default route is internal.
* Exception lookup is `main` with `suppress_prefixlength 0`; a missing exception route falls through
  to the provider table rather than accidentally using `main`'s default.
* The destination exception set is ordered before the provider table rule for the same source.

### 5.3 Egress and failure

* The provider table contains the provider route and a terminal `unreachable` default. The guard is
  present before the source rule is installed and remains until intentional policy deletion.
* A missing provider route, an absent interface or a failed next hop produces a fail-closed result
  for the constrained source. The system reports "protected by failure policy", not "reachable".
* No automatic fallback to `main` or another provider is implemented in v0.1.0.

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
policy <name>
    source-prefix <prefix>...          # canonical
    destination-exception <prefix>... # canonical; connected routes auto-added
    next-hop <address> [interface <if>]
    interface <if>                     # for link-local or interface-only
    table <id>                         # optional; otherwise deterministic allocation
    description <text>
    disable
```

**Effective state (from kernel and netdevice state):**

```text
policy <name>
    table <id>                         # allocated
    rule priorities <p...>
    provider route <prefix> via <nh> dev <if> proto 194
    guard route unreachable default proto 194
    connected mirror route (if needed)
    source-rule present / exception-rule set
    interface present/up
    next-hop resolved/unresolved
    ownership <owned|conflict>
    health <effective|incomplete|dependency-unavailable|protected|conflict|failed>
```

Reconciliation computes the diff between desired and effective state, refuses ownership conflicts,
applies guarded mutations in the order documented below, then verifies and records the result.

## 7. Ownership model (proposed)

* **Tables:** extension range `10000–19999` (tentative; final range chosen after collision analysis).
  Native `protocols static table` uses `1–200`; the manual proof of concept uses `41913`; neither is
  touched. A managed table must be empty or contain only routes with the extension protocol marker.
* **Route protocol:** numeric `194` (tentative) marks extension routes. `proto` is used for
  verification and cleanup scoping; it is not a security boundary.
* **Rules:** extension range `20000–28999` (tentative), below `main` (32766) and above the manual
  proof-of-concept rules (10410–10414). Longest-source-prefix ordering is encoded in priorities. A
  foreign rule in the range is a conflict.
* **Manifest:** a small state file records the allocation and last effective state. It is advisory;
  the kernel is authoritative and every destructive action is preceded by an ownership check.
* **No destructive breadth:** only exact extension-owned prefixes/tables/rules are removed. No
  `ip rule flush`, no `ip route flush table`, no `main` mutation.
* **Migration:** the operator creates extension policies in new tables, verifies them, then removes
  the manual table/rules. Installation never adopts table 41913 or rules 10410–10414 silently.

## 8. Mutation ordering (proposed)

The invariant is: **at every interruption point, a constrained source is either on its intended
provider or blocked; it is never on an unauthorized provider.**

**Create a policy:**

1. Verify table and rule-range ownership.
2. Install the table's terminal `unreachable default` (guard). Until the source rule exists, it has
   no effect; if the process dies now, the source still uses native routing.
3. Install the provider route (and connected mirror if needed). If it fails, leave the guard and
   report incomplete; the source is still on native routing.
4. Install destination-exception rules (main lookup) and the provider-table rule. At this point the
   source is constrained. The guard is already present.
5. Verify effective state.

**Update a policy (same source, new egress/table):**

1. Build the new table/guard/route first; do not remove the old policy.
2. Install the new rule at a priority before the old rule. The new table is already guarded.
3. Verify the new path.
4. Remove the old rule, then the old table's routes. The new rule takes over without a fallback
   window.

**Change a source prefix:** treat as create-new plus delete-old; install the new prefix first, then
remove the old. If the new prefix is more specific, it wins immediately; if less specific, the old
still applies to its range until removed.

**Delete a policy intentionally:**

1. Remove the provider route but leave the terminal guard in the table.
2. Remove the source rule(s). Traffic now falls to native routing; this is the intentional
   unconstraining transition, and it is blocked while the provider route is absent.
3. Remove the table's guard and any remaining routes.
4. If the process dies after step 1, the source is blocked; if it dies after step 2, the policy is
   intentionally gone and native routing applies.

**Package removal:** refuse while configured policies exist. If removed without policies, remove only
owned objects. Never silently delete an active policy in a way that permits cross-provider egress.

## 9. Lifecycle design (proposed)

* The `protocols ipv6-sadr` subtree has commit priority 500, after interfaces/addresses (default
  area) and static routes (450). Its `end:` action calls the reconciler with the working
  configuration.
* The reconciler is idempotent, takes a lock, reads desired state through the configuration API,
  computes the diff, applies the guarded sequence, verifies, and records effective state.
* A small event-driven monitor observes netdevice link/address events and triggers reconciliation
  when a managed interface appears, disappears, is recreated or changes addresses. It does not poll
  and does not use arbitrary sleeps beyond a short debounce.
* The monitor is started only when policies are configured and stopped when the subtree is removed,
  or runs as a lightweight always-on service that exits immediately if no policies exist. The final
  choice is a v0.1.0 implementation detail; the architecture requires that any daemon is justified
  and measurable on the ER-X.
* Boot: the config engine's `end:` action runs on boot configuration load; the monitor repairs
  dependencies that come up later. Guards are installed first, so boot-time ordering cannot create
  cross-provider egress.
* Abrupt termination: the guard lives in the table, not in process memory. A restart reconciles.
  A previous next hop that no longer exists leaves the guard in place and is reported.
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
configured policy is effective; distinct non-zero codes indicate incomplete, protected, dependency
unavailable, conflict or failed. The target's `ip -j` is reliable for link objects but not for route
or rule objects; the helper parses stable text and can emit its own JSON. A route being present is
never reported as end-to-end provider connectivity.

## 11. Risks and unknowns

| Risk | Impact | Resolution |
|---|---|---|
| Target `ip` rejects `route add ... from` | Candidate B needs a custom helper or is rejected | E-1, E-5 |
| Source-specific FIB leaks via more-specific external routes | Candidate B fails strict correctness | E-3, E-5 |
| `unreachable default` inside a table does not stop RPDB fallback | Candidate A's guard is insufficient | E-4 |
| Native table routes are not repaired after interface recreation | Candidate C fails lifecycle | E-6 |
| Config engine priority/visibility differs from source inspection | Action ordering or desired-state read is wrong | E-1, emulation/hardware gate |
| Rule-priority or table-ID collisions on real deployments | Unsafe application | E-6, collision tests |
| Dynamic internal prefixes need explicit exceptions | Operational burden or leakage if missed | Document; future automation |
| Local source selection picks an unintended source | Unbound router traffic uses the wrong path | E-7; document limitation |
| Monitor daemon cost or process supervision | Resource/robustness concern | Prototype; justify in v0.1.0 |
| Offload path ignores multi-table lookup | Performance/correctness claim | Hardware qualification later; methodology in testing strategy |
| Commit engine is non-atomic | Partial desired state | Guard-first ordering; idempotent reconcile; health report |

## 12. Decision rule

Candidate A is recommended only if:

* E-2 positive controls pass;
* E-4 strict no-leak, internal-preservation and guard tests pass;
* E-6 lifecycle/recreation and ownership-conflict tests pass;
* E-1 confirms the target iproute2 and kernel support the required operations;
* no candidate is simpler while satisfying R-3, R-5, R-6 and R-7.

Candidate B replaces A only if it passes the same correctness and failure tests without additional
RPDB objects. Candidate C is accepted only if native route lifecycle is proven or a narrowly scoped,
ownership-respecting repair mechanism is designed. Candidate D is rejected unless a documented
daemon integration point exists.

If no candidate satisfies the requirements on the target, the architecture phase reports the gap and
the specific experiments or vendor changes needed; it does not ship a weaker claim.
