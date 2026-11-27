# Documentation index

| Document | Purpose |
|---|---|
| [`requirements.md`](requirements.md) | Normative routing contract, health enum, guarantees and non-guarantees |
| [`architecture/ADR-0001-routing-model.md`](architecture/ADR-0001-routing-model.md) | Proposed architecture, alternatives, consequences, v0.1.0 milestones |
| [`architecture/ADR-0002-sadr-implementation-review.md`](architecture/ADR-0002-sadr-implementation-review.md) | Phase VI-A review: RPDB vs native source-specific FIB, target capability, offload risk, recommendation; no second backend |
| [`architecture/architecture-invariants.md`](architecture/architecture-invariants.md) | I1–I9 testable product contracts, offload gate G1, mechanism findings and verification mapping |
| [`phase-vi-a/README.md`](phase-vi-a/README.md) | Phase VI-A deliverable index, recommendation and maintainer decisions |
| [`phase-vi-b/README.md`](phase-vi-b/README.md) | Phase VI-B deliverable index: accepted decisions, HNAT analysis, invariants, offload criteria, qualification plan and R1 request |
| [`investigation/2026-11-27-platform-investigation.md`](investigation/2026-11-27-platform-investigation.md) | Read-only EdgeOS 3.0.1 / ER-X platform evidence |
| [`investigation/2026-11-27-experiments.md`](investigation/2026-11-27-experiments.md) | Generic-Linux packet-path experiments and candidate-B falsification |
| [`testing-strategy.md`](testing-strategy.md) | Unit, netns, emulated EdgeOS and hardware qualification layers |
| [`operations.md`](operations.md) | Proposed configuration, diagnostics, migration and removal |
| [`security-invariants.md`](security-invariants.md) | Safety invariant, mutation ordering and failure matrix |
| [`platform-compatibility.md`](platform-compatibility.md) | Exact supported platform, reserved ranges and non-claims |
| [`prototype-results.md`](prototype-results.md) | PoC and production-phase results (145 assertions, generic Linux) |
| [`v0.1.0-evidence.md`](v0.1.0-evidence.md) | v0.1.0 test, package, resource evidence and remaining gates |
| [`ci-evidence.md`](ci-evidence.md) | Actual GitHub Actions runs, package hash comparison and reproducibility scope |
| [`boot-safety-review.md`](boot-safety-review.md) | Early-boot ordering, activation and failure-propagation findings |
| [`target-emulation-investigation.md`](target-emulation-investigation.md) | Emulation blockers and generic-Linux iproute2 parity evidence |
| [`performance-characterization.md`](performance-characterization.md) | Phase breakdown, scaling, monitor resources and proposed target budgets |
| [`package-safety-review.md`](package-safety-review.md) | Maintainer-script trust boundary, lifecycle behavior and residual test seams |
| [`hardware-execution-authorization-request.md`](hardware-execution-authorization-request.md) | Deferred isolated-hardware authorization request; full-matrix scope |
| [`shared-qualification-infrastructure.md`](shared-qualification-infrastructure.md) | Shared qualification/infrastructure proposal; no shared runtime |
| [`configuration-transactions.md`](configuration-transactions.md) | Working/active commit, rollback, interruption and concurrency simulation results |
| [`hardware-qualification-plan.md`](hardware-qualification-plan.md) | Plan only; target qualification is separately authorized |
| [`migration-plan.md`](migration-plan.md) | Plan only; coverage-first cutover and bounded rollback |
| [`phase-iv-off-device.md`](phase-iv-off-device.md) | Phase IV off-device status, emulation options and boot-safety alternatives |
| [`production-baseline.md`](production-baseline.md) | Sanitized read-only production ER-X baseline and inferred behavior |
| [`production-synthetic-design.md`](production-synthetic-design.md) | Collision assessment and non-disruptive synthetic experiment design |
| [`production-observability.md`](production-observability.md) | Pre/during/post experiment health checks, probes and stop conditions |
| [`production-rollback.md`](production-rollback.md) | Backup inventory, exact rollback and watchdog design |
| [`production-installation-plan.md`](production-installation-plan.md) | Plan only; staged install without activation, side effects and gates |
| [`production-maintenance-plan.md`](production-maintenance-plan.md) | Plan only; maintenance-window tests and deferred tests |
| [`production-migration-plan.md`](production-migration-plan.md) | Plan only; coexistence and incremental cutover from manual state |
| [`production-canary-authorization-request.md`](production-canary-authorization-request.md) | Execution-ready R1 proposal: topology, A/B/A probes, exact mutation/cleanup, invariants and operator actions |
| [`r1-authorization-candidate.json`](r1-authorization-candidate.json) | Phase V-C R1 authorization, retired by Phase VI-B — not executable; a fresh candidate-bound authorization is required |
| [`release-blockers.md`](release-blockers.md) | Status vocabulary, release-blocking items and supported configuration |

Planning artifacts:

* [`../spec/architecture-phase/requirements.md`](../spec/architecture-phase/requirements.md)
* [`../spec/architecture-phase/design.md`](../spec/architecture-phase/design.md)
* [`../spec/architecture-phase/tasks.md`](../spec/architecture-phase/tasks.md)

The executable prototype is in [`../test/integration/`](../test/integration/).
