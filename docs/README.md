# Documentation index

| Document | Purpose |
|---|---|
| [`requirements.md`](requirements.md) | Normative routing contract, health enum, guarantees and non-guarantees |
| [`architecture/ADR-0001-routing-model.md`](architecture/ADR-0001-routing-model.md) | Proposed architecture, alternatives, consequences, v0.1.0 milestones |
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
| [`configuration-transactions.md`](configuration-transactions.md) | Working/active commit, rollback, interruption and concurrency simulation results |
| [`hardware-qualification-plan.md`](hardware-qualification-plan.md) | Plan only; target qualification is separately authorized |
| [`migration-plan.md`](migration-plan.md) | Plan only; coverage-first cutover and bounded rollback |

Planning artifacts:

* [`../spec/architecture-phase/requirements.md`](../spec/architecture-phase/requirements.md)
* [`../spec/architecture-phase/design.md`](../spec/architecture-phase/design.md)
* [`../spec/architecture-phase/tasks.md`](../spec/architecture-phase/tasks.md)

The executable prototype is in [`../test/integration/`](../test/integration/).
