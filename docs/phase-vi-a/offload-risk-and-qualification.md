# Phase VI-A — hardware-offload risk and revised target qualification plan

**Scope:** no production offload, firewall, interface or configuration change. This is a risk
analysis and a target qualification plan, not an execution authorization.

## 1. Target source findings

The exact ER-X GPL tree (`/home/vadim/kernel_e50/.config`, Linux 4.14.54-UBNT) contains:

```text
CONFIG_IPV6=m
CONFIG_RA_NAT_HW=y
CONFIG_RA_HW_NAT=y
CONFIG_HNAT_V2=y
CONFIG_RA_HW_NAT_IPV6=y
CONFIG_RA_HW_NAT_TBL_16K=y
CONFIG_PPE_MCAST=y
RA_HW_NAT_BINDING_THRESHOLD=30
CONFIG_NET_CLS_UBNT_FWMASK=y
```

The HNAT/PPE driver is in `net/nat/hw_nat/`; the Kconfig says "Work At Module Mode ONLY" although
UBNT built it in. IPv6 forwarding acceleration is explicitly enabled. The `!HNAT_V2` ACL/meter/
accounting policy tables are not compiled in this build, so the PPE has no classification/policy
stage; the bind decision is the Linux stack's (conntrack + FIB) decision, cached in a 16K FOE.
A flow is bound after more than 30 pps and ages out after ~5 s (TCP/UDP/other); the bind egress is
frozen until ageout.

**Risk:** a rule/table/source-policy change does not move an already-bound flow until ageout.
A fail-closed guarantee therefore has an ageout-sized hole unless offload is disabled for the
guarded prefixes/class or the fast path is proven to re-evaluate the policy. The exact bind-path
fields (table id vs only oif, source, FIB) are not source-verified to line level. The NIC
`hw-tc-offload: off [fixed]` feature is not HNAT evidence.

## 2. Read-only baseline (before any maintenance experiment)

- `show ubnt offload` (or `vbash -c 'show ubnt offload'`) and `show ubnt offload statistics`
  (statistics may be unavailable on this platform).
- HNAT/PPE proc/debug counters, `dmesg` bind/ageout lines, `lsmod`/`/proc/modules`.
- Active `system offload` configuration stanza (read-only; exact values remain outside the repo).
- Current RPDB/rules/tables and protected-state baseline; no mutation.

## 3. Qualification matrix

| Test | Offload state | Evidence | Pass condition |
|---|---|---|---|
| RPDB source selection, sustained TCP/UDP | on (matching the current production offload setting, in an authorized lab) and off (same lab) | simultaneous captures on both provider egresses; HNAT/FOE counters | each source uses its policy egress, never the wrong provider |
| Internal destination preservation | on/off | captures on internal link | internal traffic delivered; no provider capture |
| Fail-closed after provider-route withdrawal | on/off | captures; route/rule state | no wrong-provider packet; terminal guard effective |
| Rule/table change mid-flow | on/off | timeline; FOE ageout; captures | bound-flow behavior documented; no silent wrong-provider leak beyond the declared ageout |
| More-specific external route in `main` | on/off | packet capture | RPDB whitelist prevents the source leak (broad suppressor must fail) |
| Established vs new flows | on/off | flow logs/captures | established path does not bypass a changed policy silently |
| Module/boot lifecycle (`CONFIG_IPV6=m`) | boot | rule/table presence before/after `ipv6` load; early guard | no unprotected forwarding window; documented module-reload behavior |
| Config engine priority/visibility/rollback | maintenance | `exists`/`existsEffective`, scripted/interactive | no partial policy; rollback verified |
| Throughput/pps/CPU/concurrent flows | on/off | real TCP/UDP load generator; CPU counters | no incorrect-path packet; performance recorded, not inferred from ICMP |

Offload on/off is only in an isolated lab or an explicitly authorized maintenance window; never a
global production change in Phase VI-A. ICMP echo/traceroute latency is not transit-performance
evidence.

## 4. Revised gate sequence

1. Read-only target offload/HNAT inventory; confirm the actual current state.
2. Isolated lab ER-X (preferred) or the existing permitted lab-VXLAN path for functional correctness.
3. Offload-on correctness and fail-closed/ageout tests; then offload-off comparison in the lab.
4. IPv6 module/boot/config-engine tests in a maintenance window with explicit authorization.
5. Performance/flow-scale qualification with real TCP/UDP.
6. Record raw captures/counters outside the repository; document the evidence label and residual
   risk.

**Decision gate:** any offload defect that permits a wrong-provider packet or a silent fail-open
after a rule change blocks the SADR qualification claim. No production offload setting is changed
by this plan without a separate authorization.
