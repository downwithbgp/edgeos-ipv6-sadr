# Shared EdgeOS qualification infrastructure proposal

**Status:** proposal only. No shared repository, runtime or refactor was created. The SADR package
remains independent.

## 1. Goal

Reduce duplicated engineering across `edgeos-ipv6-sadr` and `edgeos-vxlan` without coupling their
packages or routing semantics. The useful shared boundary is **qualification orchestration and
evidence**, not product code, daemons or configuration models.

## 2. Components suitable for extraction

| Component | Why reusable |
|---|---|
| Qualification controller | Plan/execute separation, explicit authorization, isolated-device attestation, step matrix, exit semantics |
| Result schema | `results.json` with step status/detail and summary; `results.md` report |
| Adapter contract | `ok`, `probes`, `wrong_provider`, notes; adapters own topology-specific traffic/captures |
| Device preflight/identity helpers | Exact EdgeOS version, kernel, board identity, package inventory |
| Backup/evidence collection | `config.boot`, rules, routes, packages, hashes, timestamps, run metadata |
| Artifact deployment | Hash verification, scp/dpkg install/upgrade, refusal checks |
| Evidence store | Capture/log layout, immutable run directory, run IDs and hashes |
| Configuration-engine fixtures | Reusable discovery/priority/working-vs-active/rollback fixtures |
| Traffic/capture adapters | Generic probe/capture orchestration where topology is supplied, not hard-coded |

## 3. Components that must stay project-local

- SADR policy model, ownership ranges, guard semantics and health vocabulary.
- VXLAN/interface/firewall semantics and vendor-specific lifecycle code.
- Product package contents, maintainer scripts and configuration templates.
- Any code that mutates routing, firewall or interface state without an adapter boundary.

`edgeos-vxlan` is a source of platform knowledge and patterns, not a code donor. Shared code must be
re-implemented against a documented interface, with citations rather than copied project logic.

## 4. Proposed interface

A future shared qualification repository would provide:

- a CLI/contract for `plan`, `execute`, `resume` (optional) and `report`;
- a versioned JSON schema for steps/results and adapter output;
- a preflight/backup/artifact/evidence library;
- project-specific adapter packages or directories (SADR adapter, VXLAN adapter);
- no network access, credentials or target addresses in the shared repository.

The SADR controller in `qualification/` is already close to this shape: plan mode, adapter commands,
JSON/Markdown results, isolation gates and backups.

## 5. Extraction criteria

Extract only when at least two projects need the same behavior and tests prove the interface. Keep the
first extraction small:

1. result schema + report renderer;
2. preflight/backup/evidence helpers;
3. artifact deployment helpers;
4. adapter contract documentation.

Do not extract a daemon, a database, a shared runtime or a generic configuration engine. Do not make
either product package depend on the shared repository at runtime.

## 6. Qualification without dedicated hardware

A dedicated development ER-X is not available, so the shared infrastructure must not assume a
hardware-in-the-loop target. The realistic resource set is:

| Resource | Use | Limits |
|---|---|---|
| Linux VMs / Unraid-hosted workloads | endpoints, captures, FRR routing peers | not EdgeOS userspace or kernel |
| Network namespaces + veth | the existing 145-assertion topology, failure injection | generic Linux evidence only |
| Existing switching infrastructure | a temporary isolated test VLAN/port, if a free port exists | must not disturb production VLANs |
| FRR-based peers | BGP/ECMP and withdrawal simulation | simulated peers are not production BGP |
| Production ER-X | bounded read-only discovery, later authorized canaries | operator-controlled, never CI-driven |

Consequences for the proposal:

- Adapters must declare their evidence class (generic Linux / emulated / target) and the report must
  render it; a namespace pass must never be presented as target evidence.
- Isolation gates become mandatory rather than optional: a `production` target class requires a
  scoped authorization file and an attestation of independent management.
- Failure-injection, transaction and performance suites stay namespace/VM-based; only bounded
  synthetic checks are designed for the production router.

Both packages stay independent. Production hardware access remains operator-controlled: no
unattended GitHub Actions workflow may target the production ER-X, and pull-request workflows must
never receive production credentials, addresses or network reachability. A dedicated
hardware-in-the-loop CI path stays a future goal; the namespace/VM layer is its off-device stand-in,
not a replacement for target qualification.

## 7. Risks and non-goals

- Adapter drift: version the adapter contract and publish fixtures.
- Security: isolation/authorization must remain mandatory; no production defaults.
- Evidence quality: a shared report cannot substitute for project-specific packet probes and
  capture resolution.
- Non-goals: product release automation, signing infrastructure, repository merge, shared router
  configuration or a monolithic edgeos runtime.
