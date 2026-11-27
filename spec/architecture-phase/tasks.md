# Architecture-phase tasks

Each task has a verification gate. A task is complete only when its evidence is recorded and the
gate passes. The phase ends with a review; it does **not** proceed to packaging or live-router
mutation.

## T1. Repository governance and scaffolding

**Deliverables**

* `README.md`, `AGENTS.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `LICENSE`.
* `.gitignore`, `.editorconfig`, `Makefile`, `.github/workflows/ci.yml`.
* Unprivileged unit checks, including IPv4/IPv6 documentation-address hygiene and its self-test.

**Verification**

* `make test` passes.
* No real infrastructure addresses, credentials, vendor binaries or firmware archives in the tree.
* The hygiene checker rejects both a non-documentation IPv6 and IPv4 fixture and accepts the
  repository scan.
* The licensing choice is compatible with the companion project (GPL-2.0) and documented.

## T2. Spec review

**Deliverable**

* Independent review of `spec/architecture-phase/requirements.md`, `design.md` and `tasks.md`.

**Verification**

* Review findings are addressed or explicitly deferred with a reason.
* No unresolved contradiction between the requirements, the proposed routing contract and the
  experiment plan. In particular: fail-closed ordering, internal-whitelist no-leak, nested source
  precedence, boot window, disable/delete semantics and health vocabulary.

## T3. Network-namespace topology and baseline

**Deliverables**

* `test/integration/netns-sadr.sh`: reproducible two-provider, dual-prefix topology.
* `test/integration/run-in-docker.sh`: privileged container runner with a loud skip/fail policy and
  `REQUIRE_NETNS_TEST=1` enforcement.
* Positive controls and packet-capture evidence.

**Verification**

* Provider A transit works for a provider A source.
* Provider B transit works for a provider B source.
* Connected and configured internal destinations are reachable from both sources.
* The wrong provider can be observed receiving traffic in a deliberate leak test.
* Nested source prefixes are present in at least one scenario.
* The suite exits non-zero on failure; an environment skip fails when `REQUIRE_NETNS_TEST=1`.
* CI sets the requirement and runs the suite.

## T4. RPDB experiments

**Deliverables**

* Broad-suppressor experiment (`main suppress_prefixlength 0` + table + rule guard).
* Internal-whitelist experiment: global internal table with exact routes and per-prefix guards;
  per-policy provider tables with a terminal `unreachable default`.
* Evidence table: source, destination, expected egress, observed egress, result.

**Verification**

* Broad model reproduces the known external-more-specific-route leak, including a more-specific
  route inside an excepted destination.
* Internal-whitelist model sends each constrained source to its intended provider.
* Connected and configured internal destinations work from both sources.
* A more-specific external route in `main`, including one inside a declared internal prefix, cannot
  capture a constrained source.
* Removing the provider route makes the source fail closed (no egress on either provider).
* Removing the real internal route makes the prefix fail closed through its per-prefix guard.
* Removing an internal exception from configuration removes its route and guard; the destination then
  follows provider policy (documented, intentional transition).
* The provider table shows both the unicast default and the unreachable guard; route selection and
  the guard are observed, not asserted.
* An unresolved next hop leaves the route selected but undelivered; health reports the dependency.
* `ip -6 route get` agrees with observed packet paths.

## T5. Source-specific FIB experiment

**Deliverables**

* Candidate B applied in the same topology, including nested source prefixes.
* Target parser result (accepted/rejected, with command and output).
* Lookup-order and more-specific-route results.

**Verification**

* The target `ip` parser result is recorded with provenance.
* The experiment either passes the strict correctness/failure tests or records the exact falsifying
  case and the additional mechanism it would require.
* No claim is based only on modern-kernel documentation.

## T6. Lifecycle, ownership, shadowing and concurrency

**Deliverables**

* Interface delete/recreate test with traffic probes.
* Internal-route loss and provider-route loss tests.
* Foreign-route and foreign-rule collision tests.
* Shadowing test: a preceding foreign rule matching a configured source.
* Protocol-marker-with-wrong-prefix-set test.
* Idempotency/no-op test.
* Interruption/kill-point analysis or fault injection, including a failed first-policy application.

**Verification**

* A recreated netdevice loses its routes; the guard prevents misrouting; reconciliation restores
  reachability.
* A foreign object causes refusal, not deletion.
* A shadowed policy is reported `shadowed`, not `effective`.
* A route with the extension protocol marker but a different prefix set is a conflict, not deleted.
* Repeated reconciliation converges without churn.
* An interruption cannot leave a constrained source on an unauthorized provider; a failed first
  application either restores the previous effective state or leaves the source blocked.
* The lock/serialization design is exercised or its absence is documented as a v0.1.0 task.

## T7. Target-specific evidence

**Deliverables**

* Read-only target record: firmware, kernel, iproute2, RPDB, tables, routes, templates, daemons.
* Exact kernel config/source findings for `CONFIG_IPV6_SUBTREES` and related options.
* Target `ip` route/rule JSON and `from` parser findings.
* Config-engine source/template findings: priorities, `end:` ordering, API visibility, scripted
  versus interactive context.
* Offload interaction finding: does the ER-X IPv6 fast path honor multi-table RPDB lookup?
* Evidence labels and provenance.

**Verification**

* Every target claim is labelled and traceable to a command, exact file or vendor source.
* No router configuration was mutated, no package installed, no runtime restore script executed.
* Claims that require emulation or hardware are marked as such, with the resolving experiment named.
* Offload is treated as a correctness risk until hardware evidence exists, not merely a performance
  note.

## T8. Architecture deliverables

**Deliverables**

* `docs/requirements.md`: durable routing contract and non-guarantees.
* `docs/investigation/2026-11-27-platform-investigation.md`: target evidence.
* `docs/investigation/2026-11-27-experiments.md`: netns and target experiments.
* `docs/architecture/ADR-0001-routing-model.md`: decision, alternatives, consequences.
* `docs/testing-strategy.md`: unit, netns, emulation, hardware layers and performance methodology.
* `docs/platform-compatibility.md`: exact supported platform and non-claims.
* `docs/prototype-results.md`: what the proof of concept proves and does not prove.
* Proposed v0.1.0 milestones and open unknowns.

**Verification**

* The ADR answers each evaluation criterion with evidence, not assertion.
* The routing contract defines precedence, internal whitelist, guards, failure, local/forwarded
  behaviour, ownership, boot/lifecycle and explicit non-guarantees.
* The health enum and reasons are consistent across requirements, ADR and prototype.
* Known unknowns have named experiments or are explicitly deferred.
* Documentation uses only documentation address ranges.

## T9. Verification, review and commit

**Deliverables**

* Green `make test`.
* A recorded netns run (including the container/kernel/iproute2 versions).
* Independent review of the full diff.
* Meaningful commits with conventional messages.
* A session handoff memory.

**Verification**

* No uncommitted work remains.
* The review verdict and any residual findings are recorded.
* No release tag, published artifact, package installation or live-router mutation occurred.
* The GitHub remote is configured only after identity verification; pushing is a separate decision.

## T10. Local traffic, source selection and lookup diagnostics

**Deliverables**

* Bound-source ICMP/UDP/TCP probes from the edge router to both providers and internal destinations.
* Unbound-source observation with the kernel-selected source recorded.
* `ip -6 route get` local and forwarded comparisons, including `iif` where supported.

**Verification**

* A socket bound to a provider source follows that provider's table and egress.
* Unbound traffic's selected source is recorded; the project does not claim to control it.
* The diagnostic agrees with the observed path and does not present preferred-source output as
  source rewriting.
* The limits of `route get` (cache, input interface, local semantics) are documented.

## T11. Health and effective-state diagnostics

**Deliverables**

* Prototype `status`/`health` output for configured vs effective state.
* Distinct exit codes and reasons for effective, incomplete, dependency-unavailable, protected,
  shadowed, conflict, failed and disabled.
* Machine-readable output where the target parser is reliable.

**Verification**

* Each state can be induced in the netns lab and is reported correctly.
* A policy with a missing provider route reports `protected`, not `effective`.
* A shadowed policy reports `shadowed`.
* A foreign table/rule reports `conflict`.
* Route presence is never reported as end-to-end provider connectivity.

## T12. Boot and configuration-engine ordering

**Deliverables**

* Source/template analysis of the `protocols` subtree priority and `end:` execution.
* A plan or prototype for an early boot guard ordered before WAN forwarding, or an explicit
  non-guarantee if the platform cannot support it.
* Tests or mocks for working-config visibility, API errors, no-op commit, last-policy deletion and
  failed commit.

**Verification**

* The action's desired-state source is unambiguous and testable.
* An API error is not interpreted as absent configuration.
* The boot window is either guarded or explicitly documented as a non-guarantee.
* The configuration-engine findings are labelled target-source, emulated or hardware, not inferred
  from Linux alone.

## T13. Non-Ethernet and interface-only route installation

**Deliverables**

* Link-local next-hop and interface-only/point-to-point route installation on a non-Ethernet link
  where the kernel permits it.
* Explicit distinction between route installation and full forwarding.

**Verification**

* The route is installed and visible with the expected next hop/device.
* Full forwarding is either exercised on a suitable link or deferred to hardware qualification with
  a named test.

## Out of scope for this phase

* Production EdgeOS configuration templates, package build, installer, `prerm`/`postrm` logic.
* Hardware installation or migration of the manual table 41913 / rules 10410–10414.
* DHCPv6-PD tracking, dynamic exception discovery, BGP integration, host source-selection policy.
* Performance numbers on the ER-X; only the methodology and a generic-Linux sanity check.
