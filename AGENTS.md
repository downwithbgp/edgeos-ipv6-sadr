# Repository instructions for agents

## Mission and current phase

`edgeos-ipv6-sadr` provides native, persistent IPv6 source-address-dependent routing (SADR) on
Ubiquiti EdgeOS without NAT66, NPTv6 or address translation.

**Current phase: architecture.** The deliverable is an evidence-backed architecture proposal plus an
executable, isolated proof of concept. Do **not** produce a production Debian package, modify the
maintainer's live router configuration, install packages on it, tag a release or publish artifacts
until the architecture review gate is passed.

## Hard constraints

1. **No live router mutation.** Read-only inspection is allowed where access is available. Do not
   change configuration, run `commit`, install packages or execute the operator's runtime restore
   script. Configuration mutation requires explicit authorization after architecture review.
2. **No real infrastructure addresses in the repository.** Use `2001:db8::/32` for IPv6 examples
   and `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24` for IPv4. Do not copy router
   configuration, credentials, keys, firmware archives or vendor binaries into the repository.
3. **No silent scope expansion.** IPv4 SADR, NAT66, NPTv6, load balancing, provider health
   monitoring, DHCPv6-PD orchestration, DNS renumbering, host source-address-selection management,
   RA policy, routing-daemon replacement, BGP extensions, Babel, VRF orchestration, VXLAN
   management, firewall policy generation and Kubernetes awareness are out of scope for v0.1.0.
4. **No kernel modifications or additional kernel modules** unless a named experiment proves they
   are unavoidable and the architecture review accepts the cost.
5. **No vendor file modifications** unless justified with provenance, compatibility bounds and a
   restoration procedure. Prefer additional templates and executables.
6. **Ownership boundaries are mandatory.** Never flush the RPDB or a table. Never modify `main`,
   vendor routes, kernel local routes, dynamic routing protocol routes or another application's
   tables. Refuse unsafe application on a collision.
7. **Fail closed.** A constrained source prefix must not fall back to an unrelated provider. A
   routing safety failure and a reachability failure are distinct outcomes and must be reported
   distinctly.
8. **Do not copy companion-project code.** `edgeos-vxlan` is a source of platform knowledge and
   patterns, not a code donor. Reuse concepts with citations; re-implement for routing semantics.
9. **Do not claim hardware qualification** without a target-hardware run. Label every claim using
   the evidence vocabulary below.

## Evidence vocabulary

Use these labels in documents and commit messages where a claim is non-obvious:

* **Verified (target)** — observed on the exact EdgeOS firmware/hardware.
* **Verified (target source)** — established from the matching vendor GPL source or exact firmware
  file.
* **Verified (generic Linux)** — reproduced in an isolated Linux namespace/container. Not EdgeOS.
* **Emulated EdgeOS** — observed by running official firmware userspace under emulation.
* **Strongly indicated** — primary evidence supports it, but it was not directly exercised.
* **Unverified** — requires a named experiment or hardware access.
* **Recommendation** — engineering judgement.

Record the environment, command, date and commit for every experiment in `docs/investigation/`.
Keep raw router output and real addresses out of the repository.

## Repository layout

```text
spec/architecture-phase/   planning artifacts for the current phase
docs/                      durable requirements, investigation, architecture, testing strategy
test/integration/          privileged network-namespace proof of concept
test/unit/                 fast, unprivileged checks
prototype/                 disposable prototype used to validate the routing model
.github/workflows/         CI
```

Do not add empty placeholder abstractions. Add a directory only when it contains real content.

## Build and test

```bash
make lint          # bash -n, perl -c, shellcheck where available
make test-unit     # unprivileged checks, including documentation address hygiene
make test          # lint + unit
make test-netns    # privileged Docker network-namespace proof of concept
make test-all      # test + netns
```

The netns suite requires root/CAP_NET_ADMIN (it is run in a privileged container). It proves generic
Linux behaviour only. It must exit non-zero on a failed assertion; a skipped environment must be
reported loudly and must not be mistaken for a pass in CI (`REQUIRE_NETNS_TEST=1`).

## Commit discipline

* Conventional commits: `feat:`, `fix:`, `docs:`, `test:`, `chore:`, `refactor:`.
* One logical unit per commit. Stage only the files changed by that unit.
* Every commit must pass `make test`; netns-dependent commits must record the netns result.
* Do not commit scratch files, raw router captures, real addresses, credentials or generated
  artifacts.
* Use `$TMPDIR` for throwaway probes.

## Review gates

* Architecture-phase spec: reviewed before implementation.
* Any change to routing semantics, ownership, mutation ordering or failure behaviour: independent
  review plus a matching netns or unit test.
* Any claim about target behaviour: evidence label and provenance.
* Before declaring the phase complete: review the full diff and record known unknowns.
