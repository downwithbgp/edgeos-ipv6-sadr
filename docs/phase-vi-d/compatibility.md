# Phase VI-D — v0.1.0 acceleration compatibility boundary

**Scope:** off-device implementation and regression evidence. No target contact, no package
deployment, no HWNAT change, no driver modification and no FOE manipulation.

## 1. Supported-mode boundary

The accepted architecture remains RPDB-based SADR. For v0.1.0, **HWNAT-enabled SADR is
unsupported**. The minimum supported deployment objective is correct operation with hardware
forwarding acceleration **disabled**. Selective exclusion and synchronized FOE invalidation remain
future research; neither is a v0.1.0 implementation requirement. The product never disables HWNAT
itself.

## 2. Detection semantics

The acceleration detector (`src/lib/EdgeOS/IPv6SADR/Acceleration.pm`) reads two sources:

| Source | Values | Meaning |
|---|---|---|
| `/config/config.boot` | enabled / disabled / unknown | configured `system offload { hwnat ... }` state; absent stanza means disabled; a stanza without enable/disable is unknown |
| `/proc/mt7621/hw_nat` | 1 / 0 / unknown | effective runtime hook state; file absent means the driver/interface is absent |
| driver interface | present / absent | derived from the proc interface; absence means acceleration cannot be active |

Classification (conservative):

| Driver | Effective | Configured | State | Activation |
|---|---|---|---|---|
| absent | — | any | `compatible` | allowed |
| present | disabled (0) | disabled/unknown | `compatible` | allowed |
| present | disabled (0) | enabled | `inconsistent` | refused until resolved |
| present | enabled (1) | any | `incompatible` | refused |
| present | unknown/unreadable | any | `indeterminate` | refused |

Configured and effective state are never conflated: module/driver presence alone does not establish
enabled acceleration, and configuration alone does not establish effective runtime state.

Test seams (also constructor options): `IPV6_SADR_CONFIG_BOOT`, `IPV6_SADR_HWNAT_PROC`.

## 3. Behaviour

**Initial activation.** `reconcile` detects the state before any plan/apply. If the desired
configuration has policies and no SADR-managed rules/tables exist (first activation) and the state is
not `compatible`, it dies with an explicit, actionable error
(`hardware acceleration is not compatible with SADR activation: ...; disable HWNAT and retry`) before
any mutation or partial policy installation. The failure is written to `status.json` as
`failed` with that error.

**Existing active policies.** If HWNAT becomes enabled or its state becomes indeterminate after SADR
activation, `reconcile` preserves the existing rules, guards and tables, logs a
`CRITICAL: hardware acceleration is not compatible; SADR invariants are not enforceable for
already-bound flows` message, and continues. It never removes terminal guards, never flushes state
and never disables acceleration.

**Operational status.** Health includes an `acceleration` object
(`state`, `compatible`, `critical`, `configured`, `driver`, `effective`, `detail`). When policies
exist and the state is not `compatible`, health sets `compatibility_violation: 1`, appends the
violation to `checks.conflicts`, and reports state **`unqualified`** (unless the routing state is
already `failed`). Exit code for `unqualified` is **10**; the human-readable status prints the
acceleration state and a `compatibility: CRITICAL ...` line. `status.json` written by reconcile
records the state; the read-only health computation independently re-detects it.

**Explicit non-actions:** no silent HWNAT disable, no driver/module modification, no FOE
manipulation, no vendor-template change, no removal of guards as error recovery, and no claim that an
RPDB/netfilter guard protects already-bound flows.

**Boot guard:** the early boot guard installs fail-closed terminal guards before the configuration
API is available; it is deliberately not gated by the acceleration check because it cannot enable
acceleration and never removes protections.

## 4. Configuration-engine prevention (investigation)

- The `system offload { hwnat ... }` node is a vendor-managed EdgeOS template. Rejecting a commit
  that enables HWNAT while SADR policies are active would require modifying vendor-managed
  templates or adding a global commit hook. That is intrusive and is **not authorized** in this
  phase (VI-D §5).
- The extension's own configuration node cannot veto a sibling vendor node's commit in a race-free
  way with the mechanisms currently inspected.
- Therefore prevention at commit time is **not established**. The implemented boundary is
  conservative but asynchronous: the next reconcile/monitor cycle refuses first activation or
  reports the critical violation for existing policies.

**Remaining limitation (qualification gate G1d):** HWNAT can be enabled after SADR activation and
before the next reconcile. During that window, already-bound and newly bound flows are outside the
SADR guarantee; the next reconcile reports `unqualified` but cannot retroactively protect them. A
vendor-supported validation or transaction-level prevention would be required to close G1d; it is
documented, not implemented.

## 5. Regression evidence

`test/unit/t/10-acceleration.t` (off-device, fake `/config/config.boot` and `/proc/mt7621/hw_nat`
fixtures) covers:

- effective enabled → `incompatible`; disabled → `compatible`; configured-enabled/effective-disabled
  → `inconsistent`; unreadable effective → `indeterminate`; absent driver → `compatible`; missing
  configuration with effective disabled → `compatible`; `hwnat` without a value → configured
  unknown;
- first activation refused with an explicit error and **no routing mutation** (the fake `ip` log is
  empty);
- status exposes `acceleration.state=incompatible`, `compatibility_violation=1`, health state
  `unqualified`, exit code 10;
- an existing policy survives a later HWNAT-enabled transition: the reconcile still succeeds, the
  protections are preserved, and the critical violation is logged.

The full unit/property/failure and qualification gates are recorded in `docs/phase-vi-d/README.md`.
