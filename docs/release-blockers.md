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
| CI on the Phase IV head | PASS | `5da9759`: push run 46020441263 and PR run 46020448297, all jobs success on `checkout@v7.0.1` |
| Phase V-A CI | PASS | `e5ff8fb`: push run 46028355899 and PR run 46028363022, all jobs success; R1 simulation in the netns job |
| Production read-only baseline | PASS | sanitized inventory; no mutation |
| Production canary R1 (off-device readiness) | PASS | adapter/cleanup bound by SHA-256 (candidate hashes tested); qualification 42 + 19 assertions; install/cleanup lock and closed-state tests; generic-Linux A/B/A 8/8; netns 145/0 |
| Production canary R1 (target execution) | ABORTED (pre-mutation) | first attempt aborted at the adapter self-hash before any router contact; no rule installed; corrected hashes and targeted tests pass; retry requires renewed authorization |
| Production package installation | BLOCKED | installation side effects and authorization not approved |
| Configuration transaction/rollback | BLOCKED | target engine behavior unverified; simulation only |
| Boot ordering/failure propagation | BLOCKED | no target boot trace; guard failure does not block router by design |
| Hardware offload correctness | BLOCKED | HWNAT configured and module loaded; statistics unavailable and no accelerated flow demonstrated; R1 does not test the fast path |
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
