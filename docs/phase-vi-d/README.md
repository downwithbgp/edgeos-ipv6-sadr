# Phase VI-D — complete R1 and the acceleration compatibility contract

**Status:** R1 complete (A/B/A + all cleanup layers) under the renewed authorization; the
adapter result reports `fail` only because the foreground tool command hit its two-minute cap and the
process later received SIGPIPE (rc=141) after every stage had completed. Acceleration classification:
**UNKNOWN**. The compatibility boundary is implemented off-device; the target deployment and the
maintenance-window experiments are **NOT RUN**. No R2, HWNAT change, package installation, migration,
firewall change, merge, tag or release was authorized or executed. PR #1 remains draft.

## 1. R1 execution (VI-D)

- Renewed authorization `docs/r1-authorization-viid.json` (consumed at the mutation boundary
  2026-11-28T01:54:54Z; marked retired/consumed).
- Standalone A1 2026-11-28T01:53:07–01:53:49Z: 20/20 matching, 10/10 control — PASS.
- In-session A1: 20/20 + 10/10 — PASS; boundary crossed at 01:54:54Z; deploy 01:55:05Z.
- B: matching 0/20, control 10/10 — PASS; exact rule body and terminal lookup verified.
- Rule deletion and verified absence; A2: matching 20/20, control 20 (cumulative) — PASS.
- Timer teardown, runtime-directory cleanup and controller cleanup — PASS.
- Target state afterward: no rule, no timer, no runtime directory; protected rules 10410–10414 = 5
  and table 41913 = 2 unchanged; the temporary controller VXLAN was removed.
- Executed binding: adapter
  `7b4322cab1c451f56934683c7c704ef55e39ebae6505c630dbcb9a1c8039f0db`, cleanup
  `3c329ca6b3dcd20e98f9a0dc0adff37db84c9a533954fadd18f70f5f84040c81`, install
  `dc5e4e4d26f1c5a4d528d50a98de0d1e297b85459709b30cbc85f6b7ffcd678f`, manifest
  `4be0761bcaa93092776ac2071d072a1969e5b1f3f2555d70d862cb2809d599c9`.
- Current files after the post-run harness corrections (script-independent runtime-directory
  fallback, `set -e` hardening): adapter
  `00d8880ba84132ae7392731b13f07cec6c881fefeb9fbadf43249befd7edca6a`, cleanup
  `3c329ca6b3dcd20e98f9a0dc0adff37db84c9a533954fadd18f70f5f84040c81`, install
  `dc5e4e4d26f1c5a4d528d50a98de0d1e297b85459709b30cbc85f6b7ffcd678f`, manifest
  `1d1b0b4393ac1671c2bef522b72c030159ecbaa640da6287faa100fab8f09e63`; these are not the
  executed binding.
- Full evidence: [`r1-execution.md`](r1-execution.md). The VI-C report remains the historical record
  of its own **FAIL**; it is not reclassified.
- Acceleration: **UNKNOWN** — no read-only FOE interface exists on the target and no FOE write,
  flush or ioctl was performed.

## 2. Compatibility contract

- HWNAT-enabled SADR is **unsupported** for v0.1.0; the minimum supported deployment is correct
  operation with acceleration disabled. Selective exclusion/synchronized invalidation remain future
  research, not v0.1.0 requirements.
- Conservative detection and behaviour are implemented off-device: first activation is refused when
  HWNAT is enabled/inconsistent/indeterminate; existing policies keep their protections and report a
  critical violation (`unqualified`, exit 10); no silent HWNAT disable; no guard removal.
- Detection distinguishes configured, driver, effective and unknown states.
- Config-engine prevention remains a documented limitation (G1d): a commit that enables HWNAT while
  SADR is active can only be detected at the next reconcile; no vendor template/hook change was made.
- Implementation and evidence: [`compatibility.md`](compatibility.md).

## 3. Gates

[`g1-g2.md`](g1-g2.md) splits the original offload gate into G1a–G1e and keeps G2 independent.
Nothing in this phase closes G1a, G1b, G1c or G1d on the target without an authorized
deployment/experiment;
G1e is classified as an unsupported capability, not a release requirement.

## 4. Requests prepared, not executed

- [`request-c.md`](request-c.md): execution-ready HWNAT maintenance-window qualification.
- [`r2-request.md`](r2-request.md): narrow R2 provider-table lookup/terminal-guard authorization.

No second routing backend, driver modification, FOE helper deployment, hardware invalidation,
package installation, migration, firewall exception, offload change, reboot, merge, tag or release is
authorized. PR #1 remains draft.

## 5. Verification

- `make test` (final): 11 unit/property/failure files, **642 tests**; documentation hygiene 227
  literals; qualification suites cleanup **28/0**, identity **14/14**, manifest **4/4**; shellcheck,
  Perl and Python syntax checks clean.
- Acceleration compatibility: `test/unit/t/10-acceleration.t` (**23 tests**) — state matrix,
  no-mutation refusal, status exposure and the existing-policy transition.
- R1 execution: A1 20/20 + 10/10; B 0/20 + 10/10; A2 20/20 + control 20; exact rule deletion and
  verified absence, timer teardown, runtime-directory cleanup and controller cleanup all PASS; target
  and controller final state clean; protected rules/table unchanged.
- CI: the push of this phase triggers the repository workflow; the run IDs and conclusion are
  recorded in the follow-up CI evidence commit once available. No CI conclusion is claimed before
  the runs finish.
