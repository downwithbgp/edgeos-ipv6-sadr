# Package safety review

**Status:** off-device review and fixture checks. No package was installed on a router. No release
was published.

## 1. Changes made in this phase

- Removed the explicit `EDGEOS_IPV6_SADR_SKIP_PLATFORM_CHECK` bypass from `preinst`. Installation now
  always requires a readable `/etc/version`, the exact supported family, kernel
  `4.14.54-UBNT`, and working `ip -6 rule/route` operations.
- The platform gate applies to `install`; `upgrade` is allowed to avoid a lock where a firmware/kernel
  transition makes `apt upgrade` impossible while `prerm remove` refuses because SADR configuration
  is still present.
- Renamed remaining fixture seams to explicitly test-only `EDGEOS_IPV6_SADR_TEST_*` variables:
  `TEST_VERSION_FILE`, `TEST_KERNEL`, `TEST_IP`, `TEST_CONFIG_BOOT`, `TEST_API`, `TEST_SYSTEMCTL`,
  `TEST_STATE_DIR`.
- `postrm` now stops the monitor before disabling units and refuses a runtime-state path outside
  `/run/edgeos-ipv6-sadr` or `/tmp/*` before `rm -rf`.
- `prerm remove` still refuses while saved or active SADR configuration exists or extension-owned
  rules/routes remain; `upgrade` is allowed.
- Package lifecycle fixture checks pass **13/13**, including the unexpected-state-path refusal.

## 2. Trust boundary and residual test seams

The `TEST_*` variables are environment inputs to shell maintainer scripts. A caller able to set them
is already able to run `dpkg`, `apt` or the scripts as root. They therefore do not create an
unprivileged privilege escalation path. They can, however, make a privileged operation spoof the
platform/kernel/API/systemctl checks or execute a caller-selected binary. They are intended only for
the fixture harness and should not be present in a production package-manager environment.

The package still ships these seams rather than a container-only fixture. That is a deliberate,
documented testability trade-off, not a production bypass: there is no single
"skip platform check" switch. A future packaging test can move the seams out of the shipped scripts
by running the real scripts in an isolated fixture container with a fake `/etc/version`, `uname`,
`ip`, API and `systemctl` on PATH.

## 3. Lifecycle findings

| Path | Behaviour |
|---|---|
| Install | Firmware/kernel/RPDB gate; package files, templates, units installed; monitor enabled/restarted when systemd is running |
| Upgrade | Platform gate skipped intentionally; units enabled; monitor restarted; existing configuration/state is not removed |
| Remove | Refused while saved/active SADR config or live managed objects remain; otherwise monitor stopped, units disabled, runtime state removed |
| Purge | Same runtime-state cleanup; no configuration or router data removed |
| Interrupted install/upgrade | `preinst` may fail before unpack; postinst failure can leave package unpacked. The package does not remove active protection silently; target tests remain required |
| Interrupted remove | `prerm` refusal happens before package removal; no managed rules/tables are flushed by the package |
| Reboot | Kernel state clears; guard runs before router; monitor after router; boot window remains a named non-guarantee |

The package never removes `/config/config.boot`, never flushes the RPDB/tables, and never modifies
foreign routes/rules.

## 4. Remaining package gates

- Exercise the real lifecycle in a disposable EdgeOS-compatible image or target hardware: install,
  upgrade, removal refusal, interrupted upgrade and service restart.
- Verify systemd 232 activation/enablement and failure propagation (see `boot-safety-review.md`).
- Replace the `TEST_*` seams with isolated fixture containers if release engineering requires no
  test-only inputs in shipped maintainer scripts.
- Rebuild and revalidate the package after any script change; release publication remains disabled.
