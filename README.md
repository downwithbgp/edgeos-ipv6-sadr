# edgeos-ipv6-sadr

Native, persistent IPv6 source-address-dependent routing (SADR) for Ubiquiti EdgeOS.

> **Status: architecture phase.** This repository currently contains investigation, requirements,
> an executable Linux proof of concept and an architecture proposal. There is **no installable
> package** and nothing here is qualified for a live router. Do not deploy it.

## The problem

A site with two IPv6 providers and provider-assigned address space must send traffic sourced from
each provider's allocation through a path that provider will accept. Destination-only routing is
not sufficient: a packet sourced from provider B's prefix can otherwise be routed through provider
A and be dropped by ingress source-address validation, or silently violate the site's egress
policy.

This project exists to make that policy:

* **native** — expressed in the EdgeOS configuration tree, not a post-boot script;
* **persistent** — restored across reboot and ordinary configuration commits;
* **deterministic** — longest-source-prefix precedence and explicit destination exceptions;
* **fail-closed** — a constrained source does not fall back to an unrelated provider;
* **owned** — the extension manages only its own tables, rules and routes;
* **verifiable** — configured state, effective kernel state and actual route lookup are inspectable.

It is not a NAT66/NPTv6 project. End-to-end addresses are preserved.

## Design direction under review

The architecture proposal evaluates three viable families:

| Candidate | Summary | Current status |
|---|---|---|
| **A. RPDB with internal and provider tables** | Source rules select an extension-owned internal whitelist table first, then a provider table; both carry terminal guards; explicit internal prefixes are mirrored exactly. | Leading candidate; under experiment |
| **B. Source-specific IPv6 FIB** | Source-qualified routes (`from <source>`) in `main`; no RPDB rules. | Under experiment; target iproute2 support unproven |
| **C. Native table routes + extension rules** | Reuse `protocols static table` for provider routes; extension owns only rules/guards. | Under experiment; native tables limited to 1–200 and are not repaired after interface recreation |

The decision record, evidence and unresolved questions are produced in
[`docs/architecture/`](docs/architecture/) and [`docs/investigation/`](docs/investigation/) as the
architecture phase completes. Nothing in this README is a compatibility claim.

## Supported investigation platform

```text
Device:       Ubiquiti EdgeRouter X / ER-e50
EdgeOS:       3.0.1
Firmware:     EdgeRouter.ER-e50.v3.0.1.5862409.*
Kernel:       4.14.54-UBNT
Architecture: mipsel
```

Read-only inspection has been performed on this firmware. No configuration mutation, package
installation or hardware qualification has been performed. Other hardware and firmware versions are
out of scope until validated.

## What this phase produces

Already present:

```text
spec/architecture-phase/   requirements, design hypotheses and task plan
test/unit/                 fast checks that do not need root or a router
.github/workflows/         CI for lint and off-device tests
```

Produced as the phase completes:

```text
docs/                      durable requirements, investigation, architecture and testing documents
test/integration/          executable Linux network-namespace proof of concept
prototype/                 disposable desired-state/apply/verify prototype used by the PoC
```

Repository conventions, evidence labels and hard safety rules are in [`AGENTS.md`](AGENTS.md).
Contribution rules are in [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Evidence language

Every non-obvious claim in this repository is labelled:

* **Verified (target)** — observed on the EdgeOS 3.0.1 / ER-X target or its exact firmware files.
* **Verified (target source)** — established from the matching vendor GPL source.
* **Verified (generic Linux)** — reproduced in an isolated Linux namespace or container. This is
  *not* EdgeOS evidence.
* **Emulated EdgeOS** — observed by running the official firmware userspace under emulation.
* **Strongly indicated** — supported by primary evidence but not directly exercised on target.
* **Unverified** — requires a named experiment or hardware access.
* **Recommendation** — engineering judgement, not an observed fact.

Generic Linux and emulated results must never be presented as hardware qualification.

## Safety

* The extension must never flush the complete RPDB or a routing table.
* It must never modify vendor routes, kernel local routes, BGP/OSPF state or another application's
  tables.
* It must refuse unsafe application on a table or rule-priority collision rather than overwrite
  unrelated state.
* Installing the package must not seize an operator's existing manual table or rules.
* Removing the package must not silently permit unintended cross-provider egress.

## License

GPL-2.0. See [`LICENSE`](LICENSE).
