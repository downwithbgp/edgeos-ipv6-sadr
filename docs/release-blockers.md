# Release blockers and supported configuration

**Status:** no release. PR #1 remains draft; v0.1.0 is a qualification candidate, not a released or
hardware-qualified product.

## 1. Status vocabulary

- **PASS** — executed with evidence.
- **FAIL** — executed and failed.
- **BLOCKED** — prerequisite/authorization missing; cannot execute safely.
- **NOT RUN** — not attempted.
- **SUSPENDED** — deliberately withheld pending a review or maintainer decision; not executed.
- **RETIRED** — a grant withdrawn without execution; it cannot be used and is not consumed.
- **EXECUTED ONCE (partial)** — a consumed grant whose run achieved the executed phases but failed a later gate; the sub-results are recorded.
- **UNSUPPORTED** — capability explicitly outside the supported product boundary.

## 2. Current release-blocking status

| Item | Status | Evidence/condition |
|---|---|---|
| Off-device unit/property/failure | PASS | 11 files, 642 assertions |
| Generic-Linux namespace | PASS | 145/0, packet/transition/monitor probes |
| iproute2 parity | PASS | 9/0; generic Linux only |
| Package build/lifecycle/artifact | PASS | artifact 20/20; lifecycle 13/13; reproducible hash |
| Actual CI push/PR (pre-Phase IV) | PASS | final code `db7b64b`; docs head `4acff35` |
| CI on the Phase IV head | PASS | `5da9759`: push run 46020441263 and PR run 46020448297, all jobs success on `checkout@v7.0.1` |
| Phase V-A CI | PASS | `e5ff8fb`: push run 46028355899 and PR run 46028363022, all jobs success; R1 simulation in the netns job |
| Production read-only baseline | PASS | sanitized inventory; no mutation |
| Production canary R1 (off-device readiness) | PASS | execution manifest binds 11 files; adapter/cleanup candidate hashes tested; qualification profile gates, cleanup 28/28, identity 14/14, manifest 4/4; install/cleanup lock and closed-state tests; generic-Linux A/B/A 10/10; netns 145/0 |
| Production canary R1 (A1 baseline, target) | BLOCKED (production IPv6 firewall) | Stage 0/1 pass; A1 0/20 matching + 0/10 control; ER-X `SERVERv6_IN-30` drop counter +30; E1 probes reached the router MAC; E2 received 0; no mutation boundary, rule, timer or runtime dir; protected state and table 41913 unchanged |
| Production canary R1 (VI-C execution) | FAIL (partial) | A1 20/20+10/10; B 0/20+10/10; exact rule deletion; cleanup gate failed on a leftover runtime directory (removed manually and verified); A2 NOT RUN; no rule/timer/directory remains; historical record, not reclassified; acceleration UNKNOWN; see docs/phase-vi-c/ |
| Production canary R1 (VI-D completion) | PASS (dataplane/cleanup); adapter result FAIL on external SIGPIPE | A1 20/20+10/10; B 0/20+10/10; exact rule deletion verified; A2 20/20 + control 20; timer/runtime/controller cleanup PASS; protected state unchanged; adapter result fail only on external SIGPIPE (rc=141) after all stages; no retry; acceleration UNKNOWN; see docs/phase-vi-d/r1-execution.md |
| SADR architecture acceptance (Phase VI-A/B) | PASS | ADR-0002 accepted; invariants I1–I9 formalized; RPDB internal-whitelist retained; native source-specific FIB rejected for this project/target; no second backend |
| G1a SADR correctness with acceleration disabled | BLOCKED | not run; the VI-D R1 ran with acceleration UNKNOWN; requires request C or an authorized dedicated environment |
| G1b Reliable acceleration-state detection | PASS (off-device); target deployment NOT RUN | detector distinguishes configured/driver/effective/unknown; 23 regression tests; see docs/phase-vi-d/compatibility.md |
| G1c Safe initial activation refusal | PASS (off-device); target deployment NOT RUN | refusal before plan/apply; no routing mutation in tests |
| G1d Incompatible runtime transition handling | BLOCKED | protections preserved and critical status implemented; commit-time prevention not established (documented limitation) |
| G1e Accelerated SADR correctness | UNSUPPORTED | not a v0.1.0 requirement; not qualified; boundary decision, not target qualification |
| IPv6 module/boot lifecycle (G2) | BLOCKED | `CONFIG_IPV6=m`; no target boot trace or module-reload evidence; early guard hardware-unverified |
| Target qualification — Environment A (dedicated ER-X) | NOT RUN | plan and authorization request prepared; dedicated hardware not available/authorized |
| Target qualification — Environment B (lab-VXLAN R1) | EXECUTED (VI-D complete A/B/A) | A1 20/20+10/10; B 0/20+10/10; A2 20/20; rule/timer/runtime/controller cleanup PASS; acceleration UNKNOWN; adapter result FAIL on external SIGPIPE; see docs/phase-vi-d/r1-execution.md |
| Selective FOE invalidation / exclusion | BLOCKED | no source-prefix exclusion; char-device ioctl path unavailable (no /dev node or tool), non-atomic and unsynchronized with RPDB; no FOE write/flush performed; see docs/phase-vi-c/invalidation-and-compatibility.md |
| HWNAT compatibility enforcement | PASS (off-device) / target NOT RUN | detection, first-activation refusal and critical status implemented and tested (23 tests); target deployment not authorized; commit-time prevention BLOCKED (G1d) |
| Maintenance-window HWNAT qualification (request C) | NOT RUN | execution-ready request prepared; no acceleration change authorized or executed |
| R2 provider-table/terminal-guard experiment | NOT RUN | narrow authorization request prepared; not executed |
| Production package installation | BLOCKED | installation side effects and authorization not approved |
| Configuration transaction/rollback | BLOCKED | target engine behavior unverified; simulation only |
| Boot ordering/failure propagation | BLOCKED | no target boot trace; guard failure does not block router by design |
| BGP/VXLAN/firewall coexistence | BLOCKED | production impact requires maintenance authorization; IPv6 BGP command form unverified |
| Source selection | BLOCKED | target local/unbound behavior not tested |
| Target emulation | BLOCKED | no exact firmware rootfs/userspace or MIPS runner |
| Migration/removal of manual state | NOT RUN | separate future phase; manual state protected |
| Maintenance-window tests | NOT RUN | deferred; see production-maintenance-plan.md |

## 3. Supported configuration

No EdgeOS configuration is **supported for release** yet. The only intended target is ER-X /
EdgeOS 3.0.1 build 5862409 / kernel 4.14.54-UBNT, and even that requires the hardware gates above.
Other models, firmware, kernels and accelerated-path claims are unsupported.

## 4. Release decision

Dedicated hardware is unavailable, but release acceptance criteria are not lowered. Production
canary/installation/configuration tests may proceed only with explicit scoped authorization and
independent recovery. Tests that cannot be safely controlled on the production router remain
deferred until dedicated hardware or an approved maintenance window.

Draft PR #1 must remain unmerged. No tag, package publication, signing/attestation claim or
compatibility claim is authorized.
