# Release blockers and supported configuration

**Status:** no release. PR #1 remains draft; v0.1.0 is a qualification candidate, not a released or
hardware-qualified product.

## 1. Status vocabulary

- **PASS** — executed with evidence.
- **FAIL** — executed and failed.
- **BLOCKED** — prerequisite/authorization missing; cannot execute safely.
- **NOT RUN** — not attempted.

## 2. Current release-blocking status

| Item | Status | Evidence/condition |
|---|---|---|
| Off-device unit/property/failure | PASS | 10 files, 619 assertions |
| Generic-Linux namespace | PASS | 145/0, packet/transition/monitor probes |
| iproute2 parity | PASS | 9/0; generic Linux only |
| Package build/lifecycle/artifact | PASS | artifact 20/20; lifecycle 13/13; reproducible hash |
| Actual CI push/PR (pre-Phase IV) | PASS | final code `db7b64b`; docs head `4acff35` |
| CI on the Phase IV head | NOT RUN | checkout repinned to `v7.0.1`; requires a green push/PR run before this phase reports complete |
| Production read-only baseline | PASS | sanitized inventory; no mutation |
| Production canary R1 | BLOCKED | requires unique test topology, independent management, scoped authorization |
| Production package installation | BLOCKED | installation side effects and authorization not approved |
| Configuration transaction/rollback | BLOCKED | target engine behavior unverified; simulation only |
| Boot ordering/failure propagation | BLOCKED | no target boot trace; guard failure does not block router by design |
| Hardware offload correctness | BLOCKED | no offload-enabled functional test |
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
