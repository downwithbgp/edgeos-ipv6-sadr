# Boot-time safety review

**Status:** off-device review of the early boot guard and systemd integration. **No target boot was
observed.** Everything below is **Verified (target source)**, **Strongly indicated** or **Unverified**
as labelled. This review does not claim the boot window is closed.

## 1. Evidence inspected

- Vendor unit `debian/vyatta-router.service` from the matching `vyatta-cfg` source:
  `Type=oneshot`, `RemainAfterExit=true`, `Wants=imi.service nsm.service ribd.service`,
  `After=imi.service nsm.service ribd.service`, `WantedBy=multi-user.target`.
- Vendor init script `/etc/ubnt/init/vyatta-router`: creates or repairs `/config/config.boot`,
  runs pre-config scripts, loads the boot file with `vyatta-boot-config-loader`, then runs
  post-config scripts.
- Read-only target evidence: systemd 232, `/etc/systemd/system`, `ip -6 monitor` support; no
  observed boot transcript or forwarding-sysctl timing (**Unverified**).
- SADR units in `systemd/` and package lifecycle scripts.

## 2. Findings

### 2.1 Ordering is not activation or success propagation

`Before=vyatta-router.service` guarantees ordering only when both units are in the same transaction.
It does not make the router depend on the guard, and a failed oneshot does not prevent the router from
starting. The guard is therefore an **early mitigation**, not a hard boot gate.

The guard now declares `WantedBy=sysinit.target multi-user.target`, so it is activated in both the
early and router-adjacent targets. This avoids relying on a single target's activation path.

### 2.2 Forwarding timing

The vendor router unit does not itself declare a forwarding sysctl. The init script loads the boot
configuration, which may configure interfaces and forwarding. The guard is now ordered
`Before=systemd-sysctl.service network-pre.target vyatta-router.service`, after local filesystems.
This installs terminal guards before the normal sysctl and network-pre phases and before the router
loads configuration.

This does **not** cover forwarding enabled by the kernel command line, an earlier vendor service, a
pre-existing forwarding state, or a configuration path that enables forwarding before the guard's
`ip rule` operations. Those cases require a target boot trace and packet capture (**Unverified**).

### 2.3 Missing, malformed or inaccessible `config.boot`

The guard no longer uses `ConditionPathExists`; a missing or unreadable file is a visible unit
failure, not a silent skip. However, the vendor init script may create a default config or move a
malformed file aside and continue. In that case there are no configured SADR policies, so the
absence of guards does not by itself leave a configured constrained source unprotected. The
dangerous cases are:

- a valid SADR configuration exists but the guard cannot read or parse it;
- the guard encounters conflicting foreign state at a guard priority;
- the guard is skipped or fails while the router still loads the valid SADR configuration.

In those cases the monitor (after `vyatta-router`) is the first successful enforcement point. The
window between router start and monitor reconciliation is an **unavoidable boot-time exposure** until
the target proves a stronger mechanism.

### 2.4 Conflicting foreign state

`boot-guard` refuses a conflicting rule at the same priority rather than deleting it. The unit then
fails; because failure does not block the router, the configured source may be unguarded until the
monitor reports the conflict. Preserving foreign state and preserving management connectivity takes
precedence over deleting the conflict. Hardware must verify the reporting and recovery path.

### 2.5 Native configuration application and rollback

The SADR subtree runs `reconcile-working` from its `end:` action. The vendor engine is not atomic and
`existsEffective` can miss the still-executing subtree. A failed commit can leave the working
configuration applied in the kernel while the active configuration remains older. The monitor reads
the active configuration and should converge back, but exact vendor rollback/commit-confirm behaviour
is **Unverified** (see the transaction review).

Native configuration application does not flush the RPDB or managed tables. The guard rules are
ordinary RPDB rules; a vendor operation that removes them is either a foreign action or a rollback
path that must be covered by the transaction tests.

### 2.6 Restart, shutdown and upgrade

- Guard is oneshot with `RemainAfterExit=yes`; reboot clears kernel rules and runs the guard again.
- Monitor has `Restart=on-failure`, `RestartSec=5`, and a preserved runtime directory.
- Package postinst enables the units and restarts the monitor; it does not re-run the guard outside
  boot. A package upgrade therefore relies on the boot guard at next boot and on reconciliation for
  the running system.
- Interrupted install/upgrade/removal must not remove the last active protection. Package lifecycle
  safeguards are reviewed separately.

## 3. Unit changes made

`edgeos-ipv6-sadr-guard.service` now:

- activates from `sysinit.target` and `multi-user.target`;
- runs after local filesystems and `systemd-tmpfiles-setup`;
- runs before `systemd-sysctl`, `network-pre.target` and `vyatta-router.service`;
- has no conditional skip for a missing `config.boot`;
- keeps `Type=oneshot`, `RemainAfterExit=yes` and no restart loop.

No `Requires=`/`Wants=` dependency was added to `vyatta-router.service`. A hard dependency could
turn a guard/parser failure into a router boot failure and lose management connectivity. The
trade-off is explicitly the failure-propagation gap above.

## 4. Required target checks (hardware gate H3)

1. Boot trace (`systemd-analyze`/journal) proving guard start before router and before forwarding.
2. Packet capture from a constrained source across the boot window, including a deliberately missing
   and malformed `config.boot`.
3. Guard failure injection (conflict, unreadable config, failed `ip` operation) and observation of
   router start, management connectivity and monitor recovery.
4. Package upgrade and interrupted upgrade, then reboot.
5. Native configuration commit, failed commit, rollback and commit-confirm, checking managed guards
   before and after.
6. Reboot, shutdown and monitor restart at each state.

Until those checks pass, the boot window remains a named non-guarantee. This review does not claim
continuous fail-closed behavior on EdgeOS.
