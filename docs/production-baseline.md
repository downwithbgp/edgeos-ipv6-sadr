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
| Stable identity fingerprint | `0896090dabbf415be33b51fe09e1edad5605e65febb95db9293bbe6b2d667440` (SHA-256 of the board model string and management MAC, newline-separated) | Verified (target) |

The fingerprint is a reproducibility aid for authorization binding; it is not a secret and contains
no address. The raw model string and MAC remain outside the repository.

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
- **Correction:** `hw-tc-offload` was off on all 21 observed links, but that ethtool feature is not
  the EdgeOS hardware-forwarding state and must not be recorded as "offload disabled".
- EdgeOS offload, observed read-only with the operational wrapper
  (`/opt/vyatta/bin/vyatta-op-cmd-wrapper show ubnt offload`):
  - `system { offload { hwnat enable; ipsec enable } }` is configured;
  - `HWNAT offload module: loaded` and `IPSec offload module: loaded`;
  - `show ubnt offload statistics` reports "Offload statistics is not available for this platform".
- Acceleration states are therefore distinct: **configured** = yes (HWNAT enabled), **module
  loaded** = yes, **demonstrated accelerated forwarding** = **no**. No functional fast-path test has
  been run and no counter/statistic proves a flow was accelerated.
- Kernel module inspection under `ubnt` returned no matching `lsmod`/`/proc/modules` entries; the
  vendor operational command is authoritative for module load state.
- `tx-checksum-ipv6` was off on 20 links and on for one; `tx-checksumming` was on for all 21.
- `rx-checksumming` was mixed; `rx-vlan-offload` was off on all; `tx-vlan-offload` was off on 20 and
  on for one. These are NIC feature reports, not HWNAT state.
- No offload setting was changed.

## 3a. Management path, topology and test-endpoint capability

- Management is key-based SSH to the router's IPv4 address on the dedicated server VLAN; the
  controller sits on the same VLAN and uses the router as its gateway. A second, independent
  out-of-band path is still **not established** (serial hardware exists; login/recovery is untested).
- Interfaces observed: the switch bridge, eight 802.1Q VLANs (server, management, user, lab, IoT,
  K8s IPv6-only, K8s pod prefix, guest), two VXLAN links (a lab ULA link and the production Route64
  link) and one HE.net tunnel. Two physical ports had no carrier. No interface was created or changed.
- IPv6: the lab VXLAN carries a ULA /64; the provider-delegated /64s are on-link per VLAN; one routed
  /64 and one host route are learned via the K8s IPv6-only VLAN; the default is learned by RA from
  the provider. A ULA destination with no specific route follows the provider default, so a ULA
  destination must never be used for synthetic traffic (containment).
- RPDB precedence: the five protected manual rules match only the Route64 /56 and the router's
  Route64 VXLAN address. Priorities `20000–21031` are unused, then `32766` main and `32767` default.
  A synthetic ULA source matches none of the earlier rules, so a rule at `21031` is reached for a
  non-local destination. `ip -6 route get <on-link VLAN destination> from <synthetic ULA source>`
  selects the on-link VLAN interface (forwarding), not the provider default.
- Device-local cleanup capability: `systemd-run` 232 supports `--on-active=SECONDS` and works through
  passwordless sudo; `/tmp` is writable; `sleep`, `sh`, `bash`, `awk`, `grep`, `flock`, `date`,
  `sha256sum` and `nc` exist. `at` exists but `atd` is absent; `timeout`, `tcpdump` and `python3` are
  absent. No SADR units exist.
- Linux endpoints: the controller has a global /64 on the server VLAN and supports macvlan (including
  `private` mode), network namespaces, `tcpdump` and `python3`. The Unraid host refuses key-based SSH
  from the controller, so a physically separate second endpoint is **not available** without
  operator intervention; a namespace-based endpoint pair on the controller is the minimum viable
  topology.

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
