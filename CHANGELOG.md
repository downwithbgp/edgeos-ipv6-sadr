# Changelog

All notable changes to this project are documented here. The project follows semantic versioning for
its own releases once an installable package exists.

## [Unreleased]

### Added

- Architecture-phase specification, requirements and evidence conventions.
- Repository governance, contribution rules and CI foundation.

### In progress

- Linux network-namespace proof of concept for IPv6 multihoming and SADR.

### Changed

- Revised the leading hypothesis after independent review: a global internal whitelist table plus
  per-policy provider tables, first-application blocking, shadow detection, an explicit boot-window
  contract and a single health-state vocabulary.

### Known limitations

- No installable package, no EdgeOS configuration templates and no hardware qualification yet.
- Generic Linux and emulated results are not target evidence.
