# Architecture-phase tasks

Each task has a verification gate. A task is complete only when its evidence is recorded and the
gate passes. The phase ends with a review; it does **not** proceed to packaging or live-router
mutation.

## T1. Repository governance and scaffolding

**Deliverables**

* `README.md`, `AGENTS.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `LICENSE`.
* `.gitignore`, `.editorconfig`, `Makefile`, `.github/workflows/ci.yml`.
* Unprivileged unit checks, including documentation-address hygiene.

**Verification**

* `make test` passes.
* No real infrastructure addresses, credentials, vendor binaries or firmware archives in the tree.
* The licensing choice is compatible with the companion project (GPL-2.0) and documented.

## T2. Spec review

**Deliverable**

* Independent review of `spec/architecture-phase/requirements.md`, `design.md` and `tasks.md`.

**Verification**

* Review findings are addressed or explicitly deferred with a reason.
* No unresolved contradiction between the requirements and the experiment plan.

## T3. Network-namespace topology and baseline

**Deliverables**

* `test/integration/netns-sadr.sh`: reproducible two-provider, dual-prefix topology.
* `test/integration/run-in-docker.sh`: privileged container runner with a loud skip/fail policy.
* Positive controls and packet-capture evidence.

**Verification**

* Provider A transit works for a provider A source.
* Provider B transit works for a provider B source.
* The internal destination is reachable from both sources.
* The wrong provider can be observed receiving traffic in a deliberate leak test.
* The suite exits non-zero on failure; CI requires it (`REQUIRE_NETNS_TEST=1`).

## T4. RPDB experiments

**Deliverables**

* Broad-suppressor experiment (`main suppress_prefixlength 0` + table + rule guard).
* Explicit-exception experiment with a table-level terminal unreachable default.
* Evidence table: source, destination, expected egress, observed egress, result.

**Verification**

* Broad model reproduces the known external-more-specific-route leak.
* Explicit-exception model sends each constrained source to its intended provider.
* Internal destinations work from both sources.
* A more-specific external route in `main` cannot capture a constrained source.
* Removing the provider route makes the source fail closed (no egress on either provider).
* `ip -6 route get` agrees with observed packet paths.

## T5. Source-specific FIB experiment

**Deliverables**

* Candidate B applied in the same topology.
* Target parser result (accepted/rejected, with command and output).
* Lookup-order and more-specific-route results.

**Verification**

* The target `ip` parser result is recorded with provenance.
* The experiment either passes the strict correctness/failure tests or records the exact falsifying
  case and the additional mechanism it would require.
* No claim is based only on modern-kernel documentation.

## T6. Lifecycle, ownership and concurrency experiments

**Deliverables**

* Interface delete/recreate test with traffic probes.
* Route-loss and guard test.
* Foreign-route and foreign-rule collision tests.
* Idempotency/no-op test.
* Interruption/kill-point analysis or fault injection.

**Verification**

* A recreated netdevice loses its routes; the guard prevents misrouting; reconciliation restores
  reachability.
* A foreign object causes refusal, not deletion.
* Repeated reconciliation converges without churn.
* An interruption cannot leave a constrained source on an unauthorized provider.
* The lock/serialization design is exercised or its absence is documented as a v0.1.0 task.

## T7. Target-specific evidence

**Deliverables**

* Read-only target record: firmware, kernel, iproute2, RPDB, tables, routes, templates, daemons.
* Exact kernel config/source findings for `CONFIG_IPV6_SUBTREES` and related options.
* Target `ip` route/rule JSON and `from` parser findings.
* Config-engine source/template findings: priorities, `end:` ordering, API visibility, scripted vs
  interactive context.
* Evidence labels and provenance.

**Verification**

* Every target claim is labelled and traceable to a command, exact file or vendor source.
* No router configuration was mutated, no package installed, no runtime restore script executed.
* Claims that require emulation or hardware are marked as such, with the resolving experiment named.

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
* The routing contract defines precedence, exceptions, failure, local/forwarded behaviour, ownership, lifecycle and explicit non-guarantees.
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

## Out of scope for this phase

* Production EdgeOS configuration templates, package build, installer, `prerm`/`postrm` logic.
* Hardware installation or migration of the manual table 41913 / rules 10410–10414.
* DHCPv6-PD tracking, dynamic exception discovery, BGP integration, host source-selection policy.
* Performance numbers on the ER-X; only the methodology and a generic-Linux sanity check.
