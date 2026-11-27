# Platform investigation — EdgeOS 3.0.1 / ER-X

**Date:** 2026-11-27
**Status:** read-only investigation complete. No router configuration was mutated, no package was
installed and the operator's runtime restore script was not executed.
**Scope:** establish the actual kernel, IPv6 FIB/RPDB, iproute2, native routing configuration,
routing daemon, configuration-engine and boot behaviour relevant to SADR.

## 1. Evidence legend

* **Verified (target)** — observed on the ER-X or the exact installed firmware files.
* **Verified (target source)** — established from the matching vendor GPL source or upstream source
  for the exact kernel/iproute2 generation.
* **Verified (generic Linux)** — reproduced in an isolated Linux namespace/container. Not EdgeOS.
* **Emulated EdgeOS** — official firmware userspace under emulation. None was executed in this phase
  (see §7).
* **Strongly indicated** — primary evidence supports the claim, but it was not directly exercised on
  the target.
* **Unverified** — requires a named experiment or hardware access.
* **Recommendation** — engineering judgement.

Raw router output is not committed. Addresses in this document are documentation prefixes; the live
address values are omitted.

## 2. Target identity and method

| Item | Value | Label |
|---|---|---|
| Device | Ubiquiti EdgeRouter X / ER-e50 | Verified (target) |
| Firmware | `EdgeRouter.ER-e50.v3.0.1.5862409.250924.1407` | Verified (target) |
| Kernel | `4.14.54-UBNT` (SMP, MIPS32r2, mipsel) | Verified (target) |
| Userspace | Debian 9-era, `iproute2-ss171113` (`ip -V`) | Verified (target) |
| Routing daemons | UBNT `ribd`, `nsm`, `imi`; Quagga `bgpd`, `ospfd`, `ospf6d` | Verified (target) |
| Config packages | `libvyatta-cfg1`/`vyatta-cfg` `1:1.0.18+t5862406.er.3.0.1.ef8cbcb` | Verified (target) |

Method: read-only SSH inspection of files, `/proc`, `/sys`, configuration templates, package
metadata and `ip`/`vtysh` output; exact vendor kernel source; upstream iproute2 source matching the
firmware generation; companion `edgeos-vxlan` hardware/source records where cited. No `commit`,
`save`, package installation or interface mutation was performed.

## 3. Kernel, IPv6 FIB and RPDB

### 3.1 Kernel configuration

The exact kernel source tree (`/home/vadim/kernel_e50`, Linux 4.14.54 for the ER-X) contains:

```text
CONFIG_IPV6_SUBTREES=y
CONFIG_IPV6_MULTIPLE_TABLES=y
CONFIG_IPV6_ROUTER_PREF=y
CONFIG_IP_ROUTE_MULTIPATH=y
CONFIG_NET_NS=y
```

**Verified (target source).** Source subtrees and multiple routing tables are compiled in. No kernel
change is required for the recommended RPDB design.

### 3.2 Source-specific IPv6 FIB support

The exact kernel source parses `RTA_SRC` for IPv6 route addition and stores the source prefix in the
route key (`net/ipv6/route.c`: `fc_src`, `rt6i_src`). The FIB lookup descends the destination tree and
then the source subtree (`net/ipv6/ip6_fib.c`: `fib6_lookup_1`, `fib6_lookup`), so source-qualified
routes exist in principle on 4.14.54-UBNT.

**Verified (target source).** Availability is not the same as suitability: the source-specific
candidate was falsified for strict fail-closed forwarding in the generic-Linux experiment (see
`2026-11-27-experiments.md`). The recommended architecture does not depend on this feature.

### 3.3 Observed RPDB and tables

The live router had the following **shape** (addresses sanitized; priorities and table IDs are the
observed values):

```text
0:     from all lookup local
10410: from 2001:db8:a000::/56 lookup main suppress_prefixlength 0
10411: from 2001:db8:a000::/56 lookup 41913
10412: from 2001:db8:a000::/56 unreachable
10413: from 2001:db8:b000::2/128 lookup 41913
10414: from 2001:db8:b000::2/128 unreachable
32766: from all lookup main
```

```text
table 41913:
    2001:db8:b000::/64 dev vxlan<id> metric 1024
    default via 2001:db8:b000::1 dev vxlan<id> metric 1024
```

The `main` table contained the native default, connected VLAN/tunnel routes, a proto-zebra aggregate
unreachable route for the delegated allocation, and proto-zebra internal routes. The manual state
was created by `/config/rc5-post-save/restore-runtime.sh`, not by EdgeOS configuration.

**Verified (target).** This establishes feasibility, but it is not the target architecture:
`suppress_prefixlength 0` suppresses only the default, so a more-specific external route in `main`
can bypass the policy; the transfer-address policy has no internal exceptions; the table/rules are
not configuration-owned or lifecycle-managed.

### 3.4 Target lookup diagnostics

`ip -6 route get <destination> from <source>` works on the target and returns the selected route,
`dev`, `src` (preferred source) and metric. It is the correct basis for a "which path and why?"
diagnostic.

**Verified (target).** The route's `src` is the kernel's preferred source, not a rewrite of the
packet's source. The diagnostic must not conflate the two.

## 4. iproute2 capabilities and defects

### 4.1 Version and operations

`ip -V` reports `iproute2-ss171113` (a 2017-11-13 snapshot, 4.14-era). The target `ip` supports:

* `ip -6 rule add/del/show` with `from PREFIX`, `lookup TABLE`, `pref NUMBER`, `suppress_prefixlength`,
  `unreachable`, `fwmark` and `table`;
* `ip -6 route add/del/replace/show` with `table`, `via`, `dev`, `metric`, `proto`, `unreachable`,
  `blackhole` and `default`;
* `ip -6 route get ADDRESS from ADDRESS [iif STRING]`.

**Verified (target).**

### 4.2 JSON output

`ip -j -6 route show ...`, `ip -j -6 rule show` and `ip -j -6 route get ...` print the human-readable
text form on this build, not JSON. `ip -j -d link show` is reliable (companion evidence).

**Verified (target).** Operational helpers must not depend on route/rule JSON on this firmware. Use
the stable text form or a scoped helper; machine-readable output may be produced by the helper.

### 4.3 `route add ... from` parser

The target usage text lists `from ADDRESS` only for `route get`, not for `route add`. Upstream
iproute2 v4.14.0 `ip/iproute.c` nevertheless parses `from` in the route-add path and sets
`RTA_SRC`/`rtm_src_len` (line ~1700 in v4.14.0). The target is a UBNT build in the same generation.

**Strongly indicated, not target-verified.** The target `ip` binary could not be executed under qemu
on the investigation host: both the target `ip` and target `busybox` are MIPS PIE binaries, and qemu
6.2/8.2 exited before the guest loader (host `mmap_min_addr`/PIE interaction). The target binary was
not run with a mutating `route add` on the router. A hardware/emulated parser probe is a named
v0.1.0 gate for candidate B; the recommended architecture does not require this operation.

## 5. Native EdgeOS routing configuration

### 5.1 Static routes

`protocols static route6 <prefix> next-hop <addr> [interface <if>] [distance <n>]` is installed by
the vendor template through `vtysh-set` into the routing daemon (proto `zebra` on the live router).
A blackhole route is available; the live router used a proto-zebra aggregate unreachable route for
the delegated allocation.

**Verified (target).** Native main-table static routes are daemon-owned, not directly extension-owned.

### 5.2 Native policy tables

`protocols static table <N>` accepts `N = 1..200` and supports:

* `route6`, `interface-route6`, `blackhole`, `distance`, `disable`;
* `mark <1..255>`, which installs `ip -6 rule pref N fwmark M table N`.

The route leaves call `/opt/vyatta/sbin/ubnt-multi-table.pl`, which runs
`ip -6 route add table N ...` (default `ip route` protocol) and has no terminal guard. The `mark`
leaf is IPv4-only in the installed template (`--v4v6=ipv4`), despite the IPv6 route support.

**Verified (target).** There is no native source-prefix rule template and no native terminal guard.
The table range excludes the manual table 41913.

### 5.3 Lifecycle of native table routes

`ubnt-multi-table.pl` is called only from the static-table leaf templates. No interface lifecycle
hook re-adds its routes after a netdevice is recreated. The script's `update_all_tables()` path is
not wired to link events in the inspected configuration.

**Verified (target source/templates); strongly indicated for lifecycle.** A native table route can
disappear with the old netdevice and is not repaired until another configuration commit. Candidate C
therefore cannot satisfy the lifecycle requirement on its own.

### 5.4 Policy hierarchy

The installed `policy` hierarchy contains access/prefix/community/route-map lists, not
`policy route`/`policy route6`. There is no generic native source-dependent forwarding mechanism.

**Verified (target).**

## 6. Routing daemon and RIB-to-FIB behaviour

The target runs UBNT `ribd`, `nsm` and `imi`, plus Quagga `bgpd`, `ospfd` and `ospf6d`. `vtysh` is a
wrapper around `/opt/vyatta/sbin/ubnt_vtysh`. Main-table BGP/static routes appear as proto `zebra`;
`nsm -k` advertises "don't delete old routes which installed by zebra", indicating daemon-owned
route cleanup is scoped to zebra routes.

**Verified (target).** Native table routes bypass the daemon and use `ip` directly. No inspected
daemon configuration exposes source-specific rules, RPDB rules or per-table policy. Replacing or
patching the daemon is out of scope.

## 7. Configuration engine and boot lifecycle

The vendor engine groups changes into priority subtrees and is **not atomic**; a failed subtree can
leave other subtrees applied. `protocols static` declares priority 450; interface tag nodes declare
310–460; `interfaces` and `protocols` roots declare no priority. A new `protocols ipv6-sadr` subtree
at priority 500 is a **recommendation** to run after interfaces/addresses and static routes; exact
ordering must be validated by emulation/hardware.

During a subtree's `end:` action, `existsEffective` may report the still-executing subtree as absent;
the working configuration `exists`/`returnValue` sees it. Configuration-API errors must be treated as
hard failures. Scripted and interactive commits can differ; the companion project hardware-proved a
scripted firewall commit limitation, which is a platform-level caution, not a SADR mechanism
dependency.

**Strongly indicated / companion hardware evidence; not re-exercised in this phase.** The qemu
firmware-emulation attempt was blocked by the host's MIPS PIE execution limitation (§4.3). The
configuration-engine gate for v0.1.0 is emulation plus target hardware.

The boot loader replays `/config/config.boot`; the subtree's `end:` action runs on that load. A
boot window before first reconciliation exists unless an early guard service is ordered before WAN
forwarding. Target boot ordering is **unverified**.

`ip monitor` lists link/address/route/rule objects (Verified (target), `ip monitor help`), and
systemd 232 with `/etc/systemd/system` is present (Verified (target), `systemctl --version`). The
actual event stream, service ordering and early boot are Unverified.

## 8. Hardware forwarding and performance

`ethtool -k` on the ER-X showed `hw-tc-offload: off [fixed]` and `tx-checksum-ipv6: off [fixed]`.
UBNT's platform offload/accelerator is proprietary and was not measured. Whether the IPv6 fast path
honours multi-table RPDB lookup is **unverified** and is a correctness gate, not only a performance
question. Do not disable offload globally without evidence.

## 9. The existing manual proof of concept

`/config/rc5-post-save/restore-runtime.sh` was read, not executed. Its SADR-relevant actions are:

* add the source/transfer rules and table routes;
* add a local /128 address used by the router;
* apply VXLAN-related sysctls from a captured file;
* restore an unrelated HEv6 firewall policy.

It is runtime-only, non-idempotent at the configuration level, has no ownership markers, no guards
beyond a terminal rule, and mixes unrelated responsibilities. This project must not absorb the HE
firewall, VXLAN or sysctl work. The manual table/rules are a migration input, not an object to seize.

**Verified (target).**

## 10. Evidence summary

| Claim | Label | Source |
|---|---|---|
| Kernel has IPv6 subtrees and multiple tables | Verified (target source) | exact 4.14.54-UBNT `.config` and source |
| IPv6 RTA_SRC routes exist in kernel 4.14 | Verified (target source) | `net/ipv6/route.c`, `ip6_fib.c` |
| Live RPDB/table shape and manual PoC | Verified (target) | read-only `ip -6 rule/route` |
| `ip -6 route get ... from` works | Verified (target) | read-only command |
| Target `ip -j` route/rule prints text | Verified (target) | read-only command |
| Native static table route6, 1–200 | Verified (target/templates) | templates, `ubnt-multi-table.pl` |
| Native table routes not repaired after netdevice recreation | Strongly indicated | leaf-only callers; no link-event repair hook found |
| `ip monitor` object support and systemd 232 | Verified (target) | read-only `ip monitor help`, `systemctl --version` |
| No native source-prefix policy | Verified (target) | template tree and `ip rule` output |
| Target iproute2 v4.14-generation `from` add parser | Strongly indicated | upstream v4.14 source; target qemu blocked |
| Commit engine non-atomic/priority/visibility | Strongly indicated / companion hardware | companion records; vendor templates |
| Boot window/ordering | Unverified | requires emulation/hardware |
| Offload honours multi-table RPDB | Unverified | requires hardware |
| Target `proto 194` rendering and rule/table collisions | Strongly indicated | generic Linux; target mutation avoided |

## 11. Named resolving experiments for v0.1.0

1. Execute the extracted target `ip` under qemu on a host with a compatible MIPS PIE setup (or run a
   read-only netns probe on hardware) to settle `route add ... from` and `proto 194` rendering.
2. Emulate the config engine with the exact firmware rootfs: subtree discovery, priority 500,
   `exists` versus `existsEffective`, no-op/delete/rollback, scripted vs interactive.
3. Hardware boot-order test with WAN forwarding and an early guard service.
4. Hardware offload/dataplane test with multi-table RPDB and real TCP/UDP.
5. Target rule-priority/table collision survey and migration rehearsal in an isolated test policy.

The recommended architecture is chosen to avoid depending on the unresolved candidate-B parser and
source-specific forwarding semantics.
