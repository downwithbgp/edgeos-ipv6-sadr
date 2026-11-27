# Phase VI-B — architecture acceptance and target qualification design

**Status:** complete at the target qualification execution gate. Research, vendor-source inspection,
read-only target discovery, controller-local isolated experiments and qualification-plan development
were performed; no target experiment, R1/R2, production change, merge, tag or release was executed.

**Authorization boundary:** no production route, rule, firewall, interface, offload, module, package
or persistent configuration change is authorized. No R1, R2, production deployment, merge, tag or
release is authorized. The phase stops at the target qualification execution gate.

## 1. Maintainer decisions accepted

- RPDB is retained as the production SADR implementation.
- The internal-whitelist table and per-policy provider tables are adopted.
- Broad main-table suppression is rejected.
- No second production backend will be developed.
- ADR-0002 is accepted subject to the Phase VI-B qualifications.
- All Phase V and VI-A evidence is preserved.
- Native source-specific FIB is rejected for this project's requirements and this target platform,
  not as a universally inferior routing architecture.

## 2. Phase V-C authorization retirement

The outstanding Phase V-C conditional R1 authorization is **retired without execution and without
being consumed** (`docs/r1-authorization-candidate.json` now carries `status: retired`). No firewall
exception is authorized. Future execution requires a fresh, candidate-bound authorization.

## 3. Deliverables

| Deliverable | Document |
|---|---|
| Source-backed HNAT/PPE analysis | [`hnat-analysis.md`](hnat-analysis.md) |
| Formal architecture invariants | [`../architecture/architecture-invariants.md`](../architecture/architecture-invariants.md) |
| Hardware-offload correctness acceptance criteria | [`offload-acceptance-criteria.md`](offload-acceptance-criteria.md) |
| Two-environment qualification plan and dataplane matrix | [`qualification-plan.md`](qualification-plan.md) |
| Revised R1 lab-VXLAN topology and manifest | [`r1-lab-vxlan-authorization-request.md`](r1-lab-vxlan-authorization-request.md), [`r1-lab-vxlan-manifest.json`](r1-lab-vxlan-manifest.json) |
| Capability and evidence gaps | [`capability-gaps.md`](capability-gaps.md) |
| Authorization requests for subsequent experiments | [`authorization-requests.md`](authorization-requests.md) |

## 4. Evidence discipline

Source-code observations are labelled **Verified (target source)** where the exact vendor tree
(`/home/vadim/kernel_e50`) establishes the code path, and **Strongly indicated** where source supports
a behaviour that was not exercised. Target runtime behaviour is **Unverified** until an authorized
experiment records it. Generic-Linux results are labelled separately and never substituted for target
evidence.
