# Phase VI-B — exact authorization requests for subsequent experiments

**Status:** requests only. Nothing in this document is authorized. Each request needs a separate
maintainer authorization; none authorizes R2, production deployment, merge, tag or release.

For every request: containment is the dedicated/lab environment or the existing permitted lab path;
rollback is exact and verified; raw captures and real addresses stay outside the repository.

## Request A — Environment A: dedicated ER-X hardware qualification

**Establishes:** G1 (hardware-offload correctness), G2 (boot/`IPV6=m` lifecycle), I1/I2/I5/I9 on the
exact platform, AC-1…AC-10, the T1–T17 dataplane matrix, and the software-forwarding performance
baseline.

**Environment:** a dedicated ER-X / ER-e50 matching the production firmware, isolated from
production, with two lab provider transits, internal VLANs and a tunnel; capture points on both
provider egresses and the internal link; traffic generator and FOE counters.

**Mutation scope:** configuration, interfaces, routes, RPDB rules, offload on/off, reboots on the
dedicated device only. No production device.

**Containment/rollback:** isolated lab; out-of-band console; snapshot/restore of the device
configuration; no production connectivity; the device is expendable and can be reset.

**Required authorization:** hardware access and configuration/offload changes on the dedicated
device; a named test window; the exact test plan and stop conditions.

## Request B — Environment B: R1 over the permitted lab VXLAN

**Establishes:** R1 A/B/A on the production firmware over the software path (one rule, bounded
window); production identity/containment/cleanup; internal reachability over the lab path. It does
**not** establish G1.

**Mutation scope:** one `from <selector>/128 unreachable pref <PREF>` rule, maximum 120 s including
cleanup; no table/route/interface/firewall/offload/package/persistent change.

**Prerequisite:** the adapter's controller-path derivation must accept an explicit
interface/gateway override (the current derivation uses the IPv4 default route and the IPv6 default
gateway, which is not the lab VXLAN on the controller). After that change, regenerate the execution
manifest and the candidate hashes and reissue `r1-lab-vxlan-authorization-request.md`.

**Containment/rollback:** device-local `systemd-run` timer armed before the rule; exact deletion and
verification by `r1-cleanup.sh`; foreign/ambiguous rules refused; controller-side independent
captures; production invariants before/after; no automatic retry.

**Required authorization:** a fresh, candidate-bound authorization for test id `R1-guard-only` with a
maintainer `not_after` deadline and the regenerated hashes.

## Request C — offload maintenance experiment (only if Environment A is unavailable)

**Establishes:** whether the global HNAT switch changes forwarding behaviour as the source predicts
(bind/ageout/refresh), and the software-forwarding performance baseline on a non-production router.

**Mutation scope:** `system offload { hwnat }` / `/proc/mt7621/hw_nat` on a **non-production test
router** only, within an authorized maintenance window; no production offload change.

**Containment/rollback:** dedicated device or an explicitly authorized maintenance window; current
offload state recorded read-only first; restore the exact previous state; verify; no production
traffic.

**Required authorization:** the device, window, exact toggle sequence and rollback procedure.

## Request D — target source-specific parser / `proto 194` experiment

**Establishes:** whether the target `ip -6 route add ... from` parses and installs source-specific
routes and how `proto 194` renders; closes the VI-A unresolved target-parser item. Not required for
the retained RPDB model.

**Mutation scope:** one source-specific route in an isolated target netns/table (or a qemu probe of
the target binary), with exact deletion; no production table/rule change.

**Containment/rollback:** isolated namespace/table; exact route deletion and verification; no
production RPDB/FIB object.

**Required authorization:** the exact command, table/namespace, containment and rollback.

## Request E — target IPv6 module / boot lifecycle experiment

**Establishes:** G2 — whether `CONFIG_IPV6=m` leaves a window before `ipv6` loads, whether rules/
tables/RPDB state survive a module reload, and whether the early guard ordering is safe.

**Mutation scope:** controlled reboot and module reload on a dedicated test router (or an authorized
maintenance window on the production device only if the maintainer accepts the reboot risk); no
persistent configuration change beyond what the test requires.

**Containment/rollback:** out-of-band access; configuration snapshot; reboot recovery plan; no
production traffic dependency.

**Required authorization:** the device, window, reboot, and the exact observation plan.

## Explicit non-authorizations

None of these requests authorizes: a production firewall exception; a second RPDB rule or R2; a
production offload/module/package change; production deployment; merge, tag or release; a claim of
hardware qualification or offload correctness before the evidence exists.
