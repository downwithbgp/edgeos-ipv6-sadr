# Changelog

All notable changes to this project are documented here. The project follows semantic versioning for
its own releases once an installable package exists.

## [0.1.0] - 2026-11-27 — implementation review, not released

### Added

- Production Perl reconciler with native `protocols ipv6-sadr`, terminal/provider guards,
  active/staging pairs, ownership checks, health, early boot guard, monitor and CLI.
- Native configuration/op templates and systemd monitor/boot-guard units.
- 591 unit/property/failure assertions and a 145-assertion generic-Linux namespace phase with
  packet-path, established-flow and transition coverage.
- Debian package with firmware/kernel preinst guard, removal refusal, reproducible build and
  lifecycle/artifact checks.
- Hardware qualification plan, migration/rollback plan and v0.1.0 evidence record.

### Notes

- No hardware qualification, release publication or production-router mutation occurred.
- The package is not installed on a router. CI package workflow is defined but not run here.
- Route op diagnostic uses named source/destination selectors (see ADR-0001).

## [Unreleased]

### Added

- Architecture-phase specification, requirements, design hypotheses and task plan.
- Repository governance, contribution rules, CI foundation and documentation-address hygiene.
- Executable two-provider Linux network-namespace proof of concept with packet-path evidence.
- Target platform investigation for EdgeOS 3.0.1 / ER-X / Linux 4.14.54-UBNT.
- Routing contract, operations/diagnostics design, security invariants and testing strategy.
- ADR-0001 recommending an internal whitelist table plus per-policy provider tables with terminal
  guards and longest-source-prefix ordering.

### Changed

- Revised the leading hypothesis after independent planning review: internal whitelist replaces
  main-table exception lookups; first-application blocking, disable/delete semantics, shadow
  detection, boot-window contract and a single health vocabulary were added.
- Falsified the source-specific IPv6 FIB candidate for strict fail-closed forwarding and rejected the
  broad main-table suppressor and native static-table candidates.

### Results

- Generic-Linux proof of concept: **65 assertions, 0 failures** (42 packet-path probes, 15
  state/ownership checks, 8 health checks) plus two non-asserting recorded observations (commit
  `4ed46fc`).
- Broad suppressor model leaks through more-specific main routes.
- Internal-whitelist model preserves internal destinations and avoids the tested cross-provider
  leakage.
- Source-specific FIB is rejected on a more-specific-route capture; its guard did block a
  no-specific-route destination, so no control-plane/dataplane divergence is claimed.

### Known limitations

- No installable package, no EdgeOS configuration templates and no hardware qualification yet.
- No emulated configuration-engine run in this environment; the target MIPS PIE binaries could not be
  executed under the available qemu/`mmap_min_addr` policy.
- Generic Linux and emulated results are not target evidence.
- Hardware offload, boot ordering, target `route add ... from`, dynamic internal-route mirroring and
  source selection remain named gates.
