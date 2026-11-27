# Production installation plan (not authorized/executed)

**Status:** plan only. No package was installed on the production ER-X.

## 1. Installation side effects to review

The package preinst requires exact firmware/kernel and working IPv6 RPDB. On a successful install:

- package files, templates, op commands, Perl modules and systemd units are placed;
- `postinst` enables the guard and monitor units and restarts the monitor when systemd is running;
- the monitor starts and reconciles the **active** configuration;
- the boot guard is enabled for the next boot;
- no SADR configuration exists yet, so the expected active policy set is empty and the monitor
  should make no RPDB/table change;
- `/run/edgeos-ipv6-sadr` runtime state may be created.

Installation is therefore **not a no-op**: it changes package state, enabled services and boot
integration. It is a staged/maintenance-window operation even when SADR policies are empty.

## 2. Prerequisites

- Exact package SHA-256 and reviewed maintainer scripts/templates.
- Read-only production baseline (`docs/production-baseline.md`) and independent management/console
  path verified.
- Full `/config/config.boot`, RPDB, table, package and service backup, plus the manual restore
  procedure; table `41913` and rules `10410–10414` untouched.
- Verified absence of `protocols ipv6-sadr` and no live SADR resources.
- Explicit installation authorization bound to device/profile/test IDs/duration/recovery.
- Maintenance window or a documented reason installation cannot affect production; no assumption
  that empty policy makes installation risk-free.

## 3. Proposed staged sequence (not executed)

1. **Integrity review:** `dpkg-deb -I`, `dpkg-deb -c`, `sha256sum`; verify preinst/postinst/prerm/
  postrm and unit/template paths; no release publication.
2. **Preflight:** platform/firmware/kernel, RPDB/manual state, active config API absence of SADR,
  package conflicts, memory/CPU, independent management.
3. **Backup:** config.boot, `ip -6 rule/route`, packages, service state; record baseline hashes.
4. **Install without policy**, if the package is confirmed to leave empty-config reconciliation
   inactive:
   ```text
   scp <artifact> <router>:/tmp/<artifact>
   sudo dpkg -i /tmp/<artifact>
   ```
5. **Verify installation side effects:** preinst result, service enablement, monitor process/log,
   `/run` state, no new managed rules/tables, no proto 194, config/API still has no SADR subtree.
6. **Stop and review** before any policy activation. Activation is a separate authorized batch.
7. **Removal check only in an authorized window:** `prerm remove` must refuse if SADR config/live
   objects exist; without them, removal stops/restarts services and removes runtime state; verify no
   RPDB/table residue.

Do not test upgrade/removal casually on a device with active production SADR policies.

## 4. Abort/rollback

If installation must be reverted and no SADR policy/live object exists, use the package manager's
reviewed removal path; verify managed objects are absent and baseline state is restored. If live
SADR objects or active policy exist, `prerm` refusal is expected: stop and follow the separately
authorized policy-removal/reconciliation plan. Never flush RPDB/tables or reboot automatically.

## 5. Gate

Installation is **BLOCKED** until:
- exact package/script hashes are approved;
- independent management/recovery is verified;
- the empty-policy side-effect claim is accepted or installation is scheduled as maintenance;
- a scoped installation authorization identifies the test batch and rollback.
