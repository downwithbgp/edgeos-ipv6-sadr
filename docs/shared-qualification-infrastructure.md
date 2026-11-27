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

## 6. Risks and non-goals

- Adapter drift: version the adapter contract and publish fixtures.
- Security: isolation/authorization must remain mandatory; no production defaults.
- Evidence quality: a shared report cannot substitute for project-specific packet probes and
  capture resolution.
- Non-goals: product release automation, signing infrastructure, repository merge, shared router
  configuration or a monolithic edgeos runtime.
