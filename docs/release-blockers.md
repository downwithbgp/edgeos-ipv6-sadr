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

## 2. Current release-blocking status

| Item | Status | Evidence/condition |
|---|---|---|
| Off-device unit/property/failure | PASS | 10 files, 619 assertions |
| Generic-Linux namespace | PASS | 145/0, packet/transition/monitor probes |
| iproute2 parity | PASS | 9/0; generic Linux only |
| Package build/lifecycle/artifact | PASS | artifact 20/20; lifecycle 13/13; reproducible hash |
| Actual CI push/PR (pre-Phase IV) | PASS | final code `db7b64b`; docs head `4acff35` |
| CI on the Phase IV head | PASS | `5da9759`: push run 46020441263 and PR run 46020448297, all jobs success on `checkout@v7.0.1` |
| Phase V-A CI | PASS | `e5ff8fb`: push run 46028355899 and PR run 46028363022, all jobs success; R1 simulation in the netns job |
| Production read-only baseline | PASS | sanitized inventory; no mutation |
| Production canary R1 (off-device readiness) | PASS | execution manifest binds 11 files; adapter/cleanup candidate hashes tested; qualification profile gates, cleanup 19/19, identity 14/14, manifest 4/4; install/cleanup lock and closed-state tests; generic-Linux A/B/A 10/10; netns 145/0 |
| Production canary R1 (A1 baseline, target) | BLOCKED (production IPv6 firewall) | Stage 0/1 pass; A1 0/20 matching + 0/10 control; ER-X `SERVERv6_IN-30` drop counter +30; E1 probes reached the router MAC; E2 received 0; no mutation boundary, rule, timer or runtime dir; protected state and table 41913 unchanged |
| Production canary R1 (target execution) | RETIRED (Phase VI-B) | the Phase V-C conditional authorization is retired without execution and without being consumed; R1 remains NOT RUN; no firewall exception authorized or created; a fresh candidate-bound authorization is required; see docs/phase-vi-b/ |
| SADR architecture acceptance (Phase VI-A/B) | PASS | ADR-0002 accepted; invariants I1–I9 formalized; RPDB internal-whitelist retained; native source-specific FIB rejected for this project/target; no second backend |
| Hardware offload correctness (G1) | BLOCKED | source-backed analysis: HNAT binds after the stack, has no route/RPDB invalidation, writes the bind timestamp once (active flows can keep a stale egress — Strongly indicated), bound flows bypass netfilter, and no per-prefix exclusion exists; target qualification not run; release-blocking; see docs/phase-vi-b/ |
| IPv6 module/boot lifecycle (G2) | BLOCKED | `CONFIG_IPV6=m`; no target boot trace or module-reload evidence; early guard hardware-unverified |
| Target qualification — Environment A (dedicated ER-X) | NOT RUN | plan and authorization request prepared; dedicated hardware not available/authorized |
| Target qualification — Environment B (lab-VXLAN R1) | NOT RUN | request prepared and not authorized; adapter topology override and candidate regeneration required; software path only |
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
