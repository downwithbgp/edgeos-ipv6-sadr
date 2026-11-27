# Production ER-X read-only baseline

**Status:** bounded read-only discovery completed on the production ER-X. No configuration, route,
rule, interface, firewall, BGP, VXLAN, sysctl, offload, service or package state was changed. Raw
output remains outside the repository; only sanitized counts and identifiers are recorded here.

## 1. Platform

| Item | Observation | Evidence |
|---|---|---|
| Device/board | EdgeRouter X / ER-e50 | Verified (target), read-only |
| Firmware | `EdgeRouter.ER-e50.v3.0.1.5862409.250924.1407` | Verified (target) |
| Kernel | `4.14.54-UBNT`, MIPS32r2, mipsel | Verified (target) |
| iproute2 | `iproute2-ss171113` (UBNT package) | Verified (target) |
| systemd | `232` (`232-25+deb9u12`) | Verified (target) |
| CPU | 4 logical CPUs | Verified (target) |
| Memory | 247 MiB total; 121 used; 32 free; 93 buff/cache; 112 available | Verified (target) |
| Root filesystem | 214.9 MiB, 85.4 MiB used, 124.8 MiB available | Verified (target) |
| Load | approximately 1.5 (1/5/15 minute averages at observation) | Verified (target) |

The exact package set includes `vyatta-cfg`, `libvyatta-cfg1`, `vyatta-cfg-system`,
`vyatta-cfg-firewall`, `edgeos-vxlan 0.3.0`, `edgeos-vxlan-kmod 0.3.0`, and systemd 232 packages.
No credentials, private keys, raw configuration or real addresses are included in this repository.

## 2. Routing/RPDB state

- 10 IPv6 RPDB rules were observed.
- **Manual protected state:** 5 rules at `10410–10414`; two are `unreachable`, the others lookup
  `main`/table `41913`.
- **Managed priority range `20000–21031`:** 0 rules.
- **Route protocol marker `194`:** 0 routes.
- IPv6 route tables observed: `local`, `main`, `41913`.
  - table `41913`: 2 routes (VXLAN-scoped; protected foreign state);
  - `main`: 33 routes; `local`: 18.
- IPv6 protocol distribution in the observed dump: kernel 30, zebra 2, RA 1, no explicit protocol
  20.
- Tables `10000`, `10001` and `19999` were empty at observation. No provider-range table was in use.
- IPv4 RPDB/route state is present and was not modified.

**Colour of the collision risk:** table `41913` and rules `10410–10414` are confirmed foreign,
protected production state. The SADR managed priority range, internal table `10000`, provider tables
`10001–19999`, and proto `194` were clear at observation. Existing manual rules precede SADR's
`20000+` rules and will shadow them for overlapping sources until a separately authorized migration.

## 3. Interfaces, VXLAN and offload

- 21 unique network links were observed, including Ethernet, VLAN, tunnel and VXLAN types.
- Two VXLAN interfaces were observed; `edgeos-vxlan` and its kernel module are installed. Table
  `41913` carries VXLAN routes. These interfaces and table are production state and must not be
  repurposed.
- `ethtool` was available only at `/sbin/ethtool`; the unprivileged `ubnt` PATH did not include it.
- `hw-tc-offload` was **off** on all 21 observed links.
- `tx-checksum-ipv6` was off on 20 links and on for one; `tx-checksumming` was on for all 21.
- `rx-checksumming` was mixed; `rx-vlan-offload` was off on all; `tx-vlan-offload` was off on 20 and
  on for one.
- These are feature-report observations, not a claim about the UBNT proprietary fast path or
  multi-table RPDB offload behavior. No offload setting was changed.

## 4. BGP, firewall and control plane

- Quagga `vtysh` is available. `show ip bgp summary` reported 2 neighbors, 1 established and 1
  active. ASNs, addresses and route content are intentionally not reproduced here.
- The attempted IPv6 BGP summary form was not accepted by this Quagga build; IPv6 BGP route/export
  behavior remains to be checked with the correct vendor command form.
- `ip6tables` and `iptables` exist under `/sbin`; passwordless read-only `sudo -n /sbin/ip6tables -S`
  and `/sbin/iptables -S` succeeded. Counts: 153 IPv6 rules and 104 IPv4 rules. No firewall content
  or change is recorded in the repository.
- 5 systemd timers were listed; `crontab -l` was empty; `/config/scripts` contained one entry.
- Serial console devices and `/dev/console` are present. `/proc/consoles` showed `ttyS1` as a
  console. Whether serial recovery is usable from the operator's location and whether a second
  independent management path exists is **not established** by this inventory.
- `vyatta-router.service` properties observed:
  - `Wants=ribd.service imi.service nsm.service`
  - `After=ribd.service imi.service sysinit.target system.slice systemd-journald.socket basic.target nsm.service`
  - `WantedBy=enable-login.service multi-user.target netplug.service ssh.service`
  - `Before=shutdown.target enable-login.service multi-user.target netplug.service ssh.service serial-getty@ttyS1.service`
- The SADR guard/monitor units are not installed (`protocols ipv6-sadr` is absent).

## 5. Configuration and SADR presence

- `/config/config.boot` exists and is approximately 50.6 KiB.
- `ipv6-sadr` mentions in the saved configuration: **0**.
- Configuration API: the `protocols` root exists; `protocols ipv6-sadr` does not; active SADR
  policy count is **0**.
- No SADR package, table `10000`, managed rule or proto `194` was present.

## 6. Production observability/recovery facts and gaps

Confirmed: SSH over the existing LAN management path; serial console devices exist; systemd and
Quagga are present; firewall and VXLAN are active; memory headroom is modest.

Not established: an independent out-of-band management path that survives loss of the current SSH
session; actual serial-console login/recovery; firewall policy semantics (only rule counts were
read); BGP export policy for synthetic prefixes; switch/VLAN isolation for a test endpoint; target
configuration-engine working/active behavior; hardware fast-path behavior.

## 7. Baseline conclusion

The production router is a **constrained, high-value platform**: it has active VXLAN, BGP, firewall
and management state, about 112 MiB available memory, and an existing manual SADR PoC in table `41913`
and rules `10410–10414`. The managed SADR resources are clear, but any synthetic experiment is global
RPDB/table state and requires exact isolation, explicit authorization, an independent observation
path and a tested rollback. Read-only discovery alone does not authorize remediation or mutation.
