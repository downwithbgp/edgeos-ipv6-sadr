# Architecture-phase requirements

**Status:** draft for review. This document defines what the architecture must satisfy; it is not a
claim that any mechanism has been selected or implemented.

**Phase:** initial engineering phase. The deliverables are evidence, an executable proof of concept
and an architecture proposal. Production packaging, live-router migration and release are gated by
an architecture review.

## 1. Context

A site uses two IPv6 providers and provider-assigned address space. Traffic sourced from provider
A's prefix must use provider A's transit; traffic sourced from provider B's prefix must use provider
B's transit. Internal destinations must remain reachable through the site's internal routing
regardless of the source prefix. No NAT66 or NPTv6 is permitted. The target is an ER-X running
EdgeOS 3.0.1 (Linux 4.14.54-UBNT, mipsel), with UBNT's `ribd`/`nsm` routing infrastructure and an
existing manual RPDB proof of concept.

The architecture must be defensible beyond the reference deployment. It must distinguish:

* source-dependent forwarding;
* host source-address selection;
* provider reachability;
* routing convergence;
* ingress/egress source-address validation;
* address lifetime and renumbering;
* actual multihoming redundancy.

A correct route in the FIB is not proof of end-to-end connectivity.

## 2. Functional requirements

### R-1 Scope and preservation

* IPv6 only for v0.1.0. IPv4 SADR, NAT66, NPTv6, general WAN load balancing, provider health
  monitoring, automated cross-provider failover, full DHCPv6-PD orchestration, DNS renumbering,
  host source-address-selection management, RA policy orchestration, routing-daemon replacement,
  BGP extensions, Babel, VRF orchestration, VXLAN management, firewall policy generation and
  Kubernetes-specific behaviour are out of scope.
* No kernel modification or additional kernel module for the initial release unless a named
  experiment proves it unavoidable and the review accepts the cost.
* No vendor file modification unless justified with provenance, compatibility bounds and a
  restoration procedure.
* End-to-end addressing is preserved. The extension must not translate addresses.

### R-2 Source-prefix policy semantics

* The configuration must support multiple static source-prefix policies, including provider
  allocations (/48, /56, /60), individual /64 networks, more-specific application prefixes and
  individual /128 addresses.
* Prefixes must be canonicalised and validated as IPv6 network prefixes. Host bits set in a prefix
  must be rejected or canonicalised only with an explicit, documented rule; silent reinterpretation
  is forbidden.
* Overlapping policies must have deterministic precedence. The preferred model is
  longest-source-prefix first. If an explicit ordered-rule model is chosen instead, precedence must
  be visible and reproducible.
* Exact duplicate source prefixes across policies are ambiguous and must be rejected unless a
  deterministic tie-break is defined and documented.
* A policy may be administratively disabled. `disable` must be explicit and fail-closed: internal
  destinations remain reachable through the internal whitelist, the provider route is withdrawn, the
  terminal guard remains, and external traffic is blocked. Deleting the policy is the explicit way
  to restore native routing. Neither operation may silently create cross-provider egress.

### R-3 Destination-aware routing

* Connected networks, local router addresses and explicitly configured internal destinations must
  remain reachable from a constrained source.
* The extension must not assume that every non-default route in `main` is internal. A more-specific
  external route must not bypass the source policy merely because it is non-default.
* The operator must be able to inspect and control which destinations may bypass a provider-specific
  default. The leading model is an extension-owned internal whitelist table containing connected
  routes and explicitly declared internal destinations, each with a terminal per-prefix guard. A
  `main` lookup with `suppress_prefixlength 0` is not a strict whitelist: a more-specific external
  route under the exception can still be selected. If it is considered, the review must address that
  case and test it.
* A more-specific external route **inside** a declared internal prefix must not capture a constrained
  source. The internal whitelist must contain only the exact internal prefixes and their guards, not
  all more-specific routes from `main`.
* Dynamic internal routes (for example BGP-learned application prefixes) must be supported when they
  are covered by an explicit exception, without implementing BGP-specific policy.
* The main routing table must not be modified by the extension except for objects it explicitly
  owns and the architecture permits. Kernel local routes and vendor/dynamic routes must not be
  touched.

### R-4 Provider-specific egress

* A policy must be able to select a provider egress by global-unicast next hop, interface-scoped
  link-local next hop, or an interface-only/point-to-point route where the platform permits.
* The architecture must not be bound to Ethernet-like interfaces. Ethernet, VLAN, tunnel, bridge and
  PPP-style Layer 3 dependencies should be equally valid where the platform supports them.
* The provider default route must be installed in an extension-owned table or otherwise isolated
  from unrelated routes, with deterministic route metrics and ownership markers.
* Multiple provider policies must coexist. The initial release does not require multipath or load
  balancing within a policy.

### R-5 Failure and fallback behaviour

* For an explicitly constrained source prefix, the default behaviour must be fail-closed: if the
  intended provider route is missing or unusable, traffic must not fall back to an unrelated
  provider.
* Fail-closed must survive process termination between mutation steps, interface loss, interface
  recreation, route loss and configuration rollback. A rule that remains after its table route has
  disappeared is not sufficient protection.
* The system must distinguish, in its operational state and diagnostics, one health enum with a
  separate reason:
  * `effective`, `incomplete`, `dependency-unavailable`, `protected`, `shadowed`, `conflict`,
    `failed`, `disabled`;
  * reasons including no matching route, interface administratively or operationally unavailable,
    next hop unresolved, neighbour unreachable, routing-daemon temporarily unavailable,
    configuration-API error and reconciliation error.
* "Link operational but remote transit unavailable" is not detectable without provider health
  monitoring, which is out of scope for v0.1.0. It is an explicit non-guarantee, not a claimed state.
* Explicit fallback may be supported only where the operator knowingly requests it and the semantics
  are defensible. It must not be the default.
* The system must not claim that a FIB entry establishes end-to-end reachability.

### R-6 Ownership and coexistence

* The extension must establish exactly which kernel routing objects it owns: tables, rules, routes
  and route protocol identifiers.
* It must never flush the complete RPDB, `main`, kernel local routes, DHCPv6-PD state, RA routes,
  vendor/dynamic routing protocol routes or another application's tables.
* Managed tables must be verified as owned before destructive reconciliation. A foreign route in a
  managed table is a conflict, not something to delete.
* Rule priorities and table identifiers must be collision-checked. A conflict must fail configuration
  application with a clear diagnostic, not overwrite unrelated state.
* Rule priority must also be checked for **shadowing**: a foreign rule that precedes the extension's
  range and matches a configured source makes the policy ineffective. The health state must report
  `shadowed`, not `effective`.
* Installing the package must not seize the operator's existing manual table or rules. A separate
  migration/adoption procedure is required.
* Ordinary SADR policy changes must not restart BGP/OSPF or disrupt the routing daemon.

### R-7 Lifecycle and reconciliation

The implementation must reason about desired state versus effective kernel state across:

* initial configuration and ordinary commits;
* policy modification and deletion;
* no-op commits;
* next-hop and interface changes;
* interface administrative disable/enable;
* interface deletion and recreation with the same name and a different ifindex;
* routing daemon restart;
* package upgrade and removal;
* boot-time configuration restoration;
* commit-confirm rollback and failed configuration transactions;
* abrupt process termination.

The design must:

* be idempotent;
* avoid broad destructive operations;
* use event-driven reconciliation where needed and justify any persistent daemon or polling;
* preserve a fail-closed guard during transitions;
* use a lock or equivalent serialization for concurrent configuration/monitor operations;
* repair extension-owned routes after netdevice recreation;
* not depend on transport-specific lifecycle callbacks from `edgeos-vxlan`.

### R-8 Native configuration model

* The operator interface must be conventional EdgeOS configuration: discovery, tab completion,
  validation, `show configuration commands`, `compare`, `commit`, `save`, deletion, rollback and
  commit-confirm.
* The configuration hierarchy must integrate naturally. A `protocols ipv6-sadr` subtree is the
  leading candidate; `policy` and other native hierarchies must be evaluated.
* The model must be capable enough to express the reference deployment without becoming an
  unrestricted routing programming language.
* It must not duplicate capabilities EdgeOS already provides without a demonstrated gap.
* The implementation must handle EdgeOS configuration API semantics correctly:
  * its own subtree is visible in the working configuration during its `end:` action;
  * `existsEffective` may not yet report nodes in the still-executing subtree;
  * API errors must not be interpreted as absent configuration;
  * scripted, interactive and boot-time sessions may differ.
* The commit action must tolerate the non-atomic EdgeOS commit engine and preserve routing safety
  even when a subtree fails or a later priority group is not applied.
* The commit action must read the **working configuration** (`exists`/`returnValue`) for its own
  still-executing subtree. `existsEffective` may report those nodes as absent during the subtree's
  `end:` action. An API error is a hard failure, never "absent".
* The action must persist an atomic desired-state snapshot for the monitor; the monitor must not
  depend on live configuration-API visibility during a commit.
* The boot window before the first reconciliation is a named non-guarantee unless an early boot
  guard service, ordered before WAN forwarding, is implemented. The design must state which applies.

### R-9 Operational diagnostics

The operator must be able to inspect:

* configured policies and their effective state;
* effective rules, tables, routes and guards;
* rule precedence and the table selected for a source;
* next hops, interfaces and missing dependencies;
* ownership conflicts;
* policies that failed reconciliation;
* the difference between configured and effective state.

The diagnostic must answer "given source S and destination D, which path will the kernel select,
and why?" using the kernel's actual lookup (`ip -6 route get <destination> from <source>`), not a
speculative userspace approximation. It must distinguish local and forwarded lookups and must not
mistake a preferred-source attribute for source rewriting.

The target's route/rule JSON is unreliable (`ip -j -6 route` and `ip -j -6 rule` emit text on the
supported build). Diagnostics must use stable text parsing or a scoped helper, and may emit their
own machine-readable output.

Health states must be one enum: `effective`, `incomplete`, `dependency-unavailable`, `protected`,
`shadowed`, `conflict`, `failed` and `disabled`, with a separate reason field for the detailed cause.
A health check suitable for monitoring must have meaningful exit codes.

### R-10 Testing and evidence

* Unit tests must cover prefix/next-hop/interface/table/priority validation, overlapping policies,
  canonicalisation, duplicate detection, collision detection, ownership determination,
  desired-state generation, idempotency, partial application, rollback/recovery and configuration
  API error handling.
* A Linux network-namespace test must construct a reproducible multihomed topology with two
  providers, distinct allocations, a multihomed edge router, internal destinations and external
  destinations. It must verify actual packets on provider interfaces, not only route lookup.
* Tests must include positive controls so that absence of traffic is not mistaken for correct
  enforcement, and continuous negative probes during transitions to detect wrong-provider egress.
* The test strategy must distinguish generic Linux, emulated EdgeOS and hardware evidence.
* No hardware qualification claim may be made without a target-hardware run.

### R-11 Packaging (deferred to v0.1.0 implementation)

The architecture must leave a defensible path to a Debian package:

* `Architecture: all` if the implementation is scripts and templates only;
* firmware compatibility guards;
* no kernel package merely for symmetry;
* safe upgrade and removal;
* no silent removal of active policies that could permit cross-provider egress;
* reproducible builds and auditable artifacts.

No package is produced in the architecture phase.

### R-12 Security and performance

* The extension must not create a new security exposure by making a constrained source reachable
  through an unauthorized provider.
* It must not disable hardware offload globally without evidence.
* The design must include a performance-qualification methodology using real forwarded TCP/UDP
  traffic, not only ICMP echo or traceroute timing.
* The resource cost on the ER-X must be justified: no unnecessary daemons, polling or sleeps.

## 3. Architecture-phase acceptance criteria

The phase is complete when:

* **A-1** the architecture-phase spec has been independently reviewed;
* **A-2** target capabilities are recorded with provenance: kernel config, IPv6 FIB/RPDB,
  iproute2 operations, configuration templates, commit ordering and routing daemon;
* **A-3** an executable netns proof of concept demonstrates source-dependent egress, connected and
  configured internal destination preservation, no unintended cross-provider fallback (including a
  more-specific external route inside a declared internal prefix), fail-closed guard behaviour,
  source-prefix precedence including nested prefixes, locally originated traffic and interface
  recreation recovery, with actual packet-path evidence;
* **A-4** the source-specific FIB alternative is experimentally evaluated, including whether the
  target iproute2 and kernel support the required operation and whether nested source prefixes and
  more-specific routes behave as required;
* **A-5** a decision record compares the alternatives and recommends an architecture with evidence,
  failure modes and known unknowns;
* **A-6** routing semantics, ownership, desired/effective state, lifecycle reconciliation and
  diagnostics are specified;
* **A-7** repository scaffolding, CI and test foundations exist; no live router mutation, package
  installation, release tag or published artifact has occurred;
* **A-8** the diff is reviewed and committed in meaningful units.

## 4. Open questions to resolve by experiment

1. Does the target `ip` binary accept `ip -6 route add ... from <source>`? Does the target kernel
   apply source-specific FIB routes with the expected lookup order, including nested source prefixes?
2. Does an `unreachable default` route inside a dedicated table stop RPDB fallback to `main`? Does a
   per-prefix `unreachable` route inside the internal table stop fallback to a provider table?
3. Can the internal whitelist mirror exact routes from `main` without accepting more-specific
   external routes under the same prefix, and what should happen with ECMP/ambiguous matches?
4. Can the extension repair its provider and internal routes after netdevice recreation without a
   persistent daemon, and what is the minimum event-driven component?
5. What rule-priority and table-ID ranges are safe on the supported firmware, and how are collisions
   and shadowing detected deterministically during migration?
6. How does the target configuration engine execute a new `protocols` subtree relative to
   interfaces, addresses and static routes? What does `my_cli_shell_api` report during its `end:`
   action, and can an early boot guard be ordered before WAN forwarding?
7. What are the local source-selection and socket-caching behaviours that SADR cannot fix?
8. Does the ER-X IPv6 forwarding/offload path honor multi-table RPDB lookup? If not, the architecture
   has a correctness problem, not only a performance problem.
