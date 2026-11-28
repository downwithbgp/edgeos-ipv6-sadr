# Phase VI-A target capability matrix

Read-only discovery on the production ER-X; raw command output and real addresses are kept outside
the repository. Labels follow the repository evidence vocabulary.

| Capability | Evidence | Status |
|---|---|---|
| Device/firmware/kernel | ER-X/ER-e50; `EdgeRouter.ER-e50.v3.0.1.5862409.250924.1407`; `4.14.54-UBNT`; MIPS32r2 | Verified (target) |
| Kernel IPv6 source subtrees | exact GPL `/home/vadim/kernel_e50/.config`: `CONFIG_IPV6_SUBTREES=y` | Verified (target source) |
| Kernel multiple tables/FIB rules | `CONFIG_IPV6_MULTIPLE_TABLES=y`, `CONFIG_FIB_RULES=y`, `CONFIG_IP_ROUTE_MULTIPATH=y` | Verified (target source) |
| IPv6 stack | `CONFIG_IPV6=m` (module; not built-in) | Verified (target source); boot/module lifecycle gate |
| MT7621 platform | `SOC_MT7621=y`, `DTB_UBNT_ER=y` in the exact GPL tree | Verified (target source) |
| `ip` version | `iproute2-ss171113` | Verified (target) |
| `ip -6 route add ... from` usage | target route usage text shows `from ADDRESS` only in the `route get` synopsis; route-add `from` is upstream-4.14 Strongly indicated, not target-verified; actual add not executed | Verified (target help) / add Strongly indicated |
| RPDB operations | target supports `rule`/`table`/`route`/`suppress_prefixlength`/`unreachable`; target/iproute2 evidence | Verified (target) |
| Target RPDB shape | 7 rules: `local`, five protected at `10410–10414` (`10410` is `suppress_prefixlength`, two are `unreachable`), `32766` main; table `41913` = 2 routes | Verified (target, read-only) |
| Source-specific routes installed | `ip -6 route show table all` `from` count = 0 | Verified (target) |
| `proto 194` route rendering | no proto-194 routes present; not exercised | Unverified |
| IPv6 forwarding | `/proc/sys/net/ipv6/conf/all/forwarding=1`, `disable_ipv6=0` | Verified (target) |
| `proto zebra` routes | 3 main-table routes | Verified (target) |
| Routing daemons | UBNT `ribd`/`nsm`/`imi`; Quagga `bgpd`/`ospfd`/`ospf6d`; `vtysh` wrapper | Verified (target/investigation) |
| Daemon source-specific policy | no inspected daemon/config exposes source-specific RPDB, per-table or source-qualified route policy | Verified (target/investigation); no support found |
| Native static tables | `protocols static table 1..200`; `route6`/`interface-route6`; no source-prefix rule, no terminal guard, leaf-only installs, no link-event repair | Verified (target/templates); lifecycle Strongly indicated |
| Native IPv6 fwmark | kernel supports `ip -6 rule fwmark`; installed static-table `mark` leaf is IPv4-only | Verified (target template + source) |
| Config model source-prefix | no native source-prefix rule/route template; native source-specific SADR requires the extension | Verified (target/templates) |
| Lab VXLAN underlay | target `vxlan<lab>` remote the controller underlay; controller `vxlan<lab-peer>` | Verified (target/controller, read-only; exact values omitted) |
| Lab VXLAN route | `ip -6 route get <lab-destination> from <synthetic-source> iif vxlan<lab>` selects `dev vxlan<lab>` | Verified (target, read-only) |
| VXLAN firewall hook | `VYATTA_FW_IN_HOOK` has no `vxlan<lab>` chain; `VYATTA_FW_OUT_HOOK` empty; `VYATTA_POST_FW_FWD_HOOK -j ACCEPT` | Verified (target, read-only) |
| Server-VLAN firewall | `SERVERv6_IN-30` drops destinations in `IPV6_LOCAL_NETS`; counter 137 at discovery | Verified (target, read-only) |
| Kernel HNAT/PPE | `CONFIG_RA_HW_NAT=y`, `CONFIG_HNAT_V2=y`, `CONFIG_RA_HW_NAT_IPV6=y`, `CONFIG_RA_HW_NAT_TBL_16K=y`, `CONFIG_PPE_MCAST=y`; `RA_HW_NAT_BINDING_THRESHOLD=30`; no ACL/meter/accounting policy stage in this build | Verified (target source) |
| HNAT bind/ageout | bind after >30 pps; ~5 s ageout (TCP/UDP/other); 16K FOE; flow egress frozen until ageout | Strongly indicated (target source); fast-path behavior Unverified |
| NIC `hw-tc-offload` | `off [fixed]`; a NIC feature, not HNAT evidence | Verified (target); do not conflate |
| `show ubnt offload` | prior read-only inventory: HWNAT configured and module reported loaded; statistics unavailable | Verified (target, prior inventory) |
| `/proc/config.gz` | absent; exact config established from the GPL source, not inferred from absence | Verified (target/source) |
| Target source-specific forwarding | generic-Linux candidate only; target execution not exercised | Unverified |

The matrix is the evidence base for ADR-0002. It does not authorize target mutation or production
changes. The exact target addresses, route contents and raw output remain outside the repository.
