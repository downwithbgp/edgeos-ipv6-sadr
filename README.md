# edgeos-ipv6-sadr

Native, persistent IPv6 source-address-dependent routing (SADR) for Ubiquiti EdgeOS.

> **Status: v0.1.0 implementation review.** The production reconciler, native templates, early boot
> guard, monitor, unit/property/failure tests, generic-Linux namespace lab and a Debian package exist
> on branch `feat/v0.1.0`. The package is **not installed on the production router**, no release is
> published, and nothing here is hardware-qualified. Do not deploy it. See
> [`docs/v0.1.0-evidence.md`](docs/v0.1.0-evidence.md),
> [`docs/hardware-qualification-plan.md`](docs/hardware-qualification-plan.md) and
> [`docs/migration-plan.md`](docs/migration-plan.md).

## The problem

A site with two IPv6 providers and provider-assigned address space must send traffic sourced from
each provider's allocation through a path that provider will accept. Destination-only routing is not
sufficient: a packet sourced from provider B's prefix can otherwise be routed through provider A and
be dropped by ingress source-address validation, or silently violate the site's egress policy.

This project exists to make that policy:

* **native** — expressed in the EdgeOS configuration tree, not a post-boot script;
* **persistent** — restored across reboot and ordinary configuration commits;
* **deterministic** — longest-source-prefix precedence and an explicit internal destination set;
* **fail-closed** — a constrained source does not fall back to an unrelated provider;
* **owned** — the extension manages only its own tables, rules and routes;
* **verifiable** — configured state, effective kernel state and actual route lookup are inspectable.

It is not a NAT66/NPTv6 project. End-to-end addresses are preserved.

## Recommended architecture

The architecture phase recommends **RPDB with a global internal whitelist table and per-policy
provider tables**:

* The internal whitelist contains exact configured internal prefixes and connected routes on
  interfaces that are not any policy egress/next-hop interface; provider-facing transfer links are
  excluded. Each prefix has a terminal per-prefix `unreachable` guard.
* Each provider table contains the provider route and a terminal `unreachable default`.
* Each source prefix gets `from S lookup internal`, then `from S lookup provider`.
* Rules are ordered longest-source-prefix first. A first-application guard blocks a newly
  constrained source while its policy is installed.
* The extension owns only its tables, exact rules, exact routes and a route protocol marker. It never
  flushes a table or the RPDB and never writes unrelated `main` routes.

The full decision, ownership model, mutation ordering, lifecycle and v0.1.0 milestones are in
[`docs/architecture/ADR-0001-routing-model.md`](docs/architecture/ADR-0001-routing-model.md).

### Why not the alternatives?

| Candidate | Result |
|---|---|
| Broad `main suppress_prefixlength 0` + table + rule guard | **Rejected** — leaks through more-specific main routes, including external routes inside an internal prefix |
| Source-specific IPv6 FIB (`route add ... from`) | **Rejected** — more-specific main routes capture the source; its guard worked for a no-specific-route destination, but the target parser is unverified and eliminating the capture needs another mechanism |
| Native `protocols static table` routes + extension rules | **Rejected** — tables 1–200 only, no source rules, no guard, and no route repair after interface recreation |
| Routing-daemon integration | **Rejected** — no source-specific policy or RPDB rule integration; daemon replacement is out of scope |

## Evidence status

* **Target:** read-only inspection of an ER-X running EdgeOS 3.0.1 build 5862409, kernel
  4.14.54-UBNT, iproute2 `ss171113`; exact vendor kernel source and templates inspected. No
  configuration mutation, package installation or runtime-script execution.
* **Generic Linux:** executable two-provider netns proof of concept, **65 assertions, 42 packet-path
  probes, 0 failures** (plus two non-asserting recorded candidate-B observations), with
  packet captures, positive leak controls, internal-whitelist routing, nested prefixes, UDP/TCP,
  local bound sources, route-loss guards, ownership/shadow checks, disable and interface recreation.
* **Not yet:** EdgeOS configuration-engine emulation, target dataplane/offload qualification and
  hardware installation. These are named v0.1.0 gates.

Read:

* [`docs/requirements.md`](docs/requirements.md) — routing contract and non-guarantees.
* [`docs/investigation/2026-11-27-platform-investigation.md`](docs/investigation/2026-11-27-platform-investigation.md) — target evidence.
* [`docs/investigation/2026-11-27-experiments.md`](docs/investigation/2026-11-27-experiments.md) — experiment results.
* [`docs/testing-strategy.md`](docs/testing-strategy.md) — unit, netns, emulation and hardware layers.
* [`docs/operations.md`](docs/operations.md) — proposed configuration, diagnostics and migration.
* [`docs/security-invariants.md`](docs/security-invariants.md) — safety invariant and failure matrix.
* [`docs/platform-compatibility.md`](docs/platform-compatibility.md) — exact platform and non-claims.
* [`docs/prototype-results.md`](docs/prototype-results.md) — what the 65-assertion result proves.

## Supported investigation platform

```text
Device:       Ubiquiti EdgeRouter X / ER-e50
EdgeOS:       3.0.1
Firmware:     EdgeRouter.ER-e50.v3.0.1.5862409.*
Kernel:       4.14.54-UBNT
Architecture: mipsel
```

Other hardware and firmware versions are out of scope until validated. No compatibility claim is
made without hardware qualification.

## Repository contents

```text
spec/architecture-phase/   requirements, design hypotheses and task plan
docs/                      routing contract, ADR, investigation, testing, operations, security
test/integration/          privileged Linux network-namespace proof of concept
test/unit/                 fast checks and documentation-address hygiene
.github/workflows/         CI for lint, unit and netns tests
```

Repository conventions, evidence labels and hard safety rules are in [`AGENTS.md`](AGENTS.md).
Contribution rules are in [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Evidence language

Every non-obvious claim is labelled:

* **Verified (target)** — observed on the exact EdgeOS firmware/hardware read-only.
* **Verified (target source)** — established from the matching vendor GPL source.
* **Verified (generic Linux)** — reproduced in an isolated Linux namespace/container.
* **Emulated EdgeOS** — official firmware userspace under emulation.
* **Strongly indicated** — primary evidence supports it, but it was not directly exercised.
* **Unverified** — requires a named experiment or hardware access.
* **Recommendation** — engineering judgement.

Generic Linux and emulated results are never presented as hardware qualification.

## Safety

* The extension must never flush the complete RPDB or a routing table.
* It must never modify unrelated `main` routes, vendor/dynamic routes, kernel local routes or another
  application's tables.
* It must refuse unsafe application on a table, priority or ownership conflict, and report
  shadowing as not effective.
* Installation must not seize the operator's manual table or rules.
* Removal must not silently permit unintended cross-provider egress.

## Next steps

1. Architecture review of the ADR and the full diff.
2. v0.1.0 implementation: reconciler, native templates, operational commands, unit/mocks.
3. Emulated EdgeOS configuration-engine validation (priority, `exists`/`existsEffective`, boot).
4. Hardware qualification in isolated test policies, including offload and real TCP/UDP.
5. Migration of the manual runtime state; safe removal; release packaging.

## License

GPL-2.0. See [`LICENSE`](LICENSE).
