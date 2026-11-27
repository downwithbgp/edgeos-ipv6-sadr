# Production-aware synthetic qualification design

**Status:** design only. **No mutation is authorized or executed.** Exact values for test prefixes,
interfaces, endpoints and management addresses must be supplied by the operator outside the repository.

## 1. Resource-collision assessment

| Resource | Production observation | SADR use | Decision |
|---|---|---|---|
| Table `41913` | 2 VXLAN-scoped routes | protected foreign state | Never use, adopt or delete |
| Rules `10410–10414` | 5 rules; manual SADR PoC | protected foreign state | Never modify; they precede SADR rules and shadow overlaps |
| Priority `20000–21031` | 0 rules observed | SADR-managed | Available, but each canary must verify the exact priority is free |
| Table `10000` | empty | internal whitelist | Available only after policy config; not used by first canary |
| Tables `10001–19999` | no tables observed; `19999` empty | provider tables | Available; first canary avoids any table |
| Proto `194` | 0 routes observed | SADR-owned routes | Available; first canary installs no route |
| VXLAN/`edgeos-vxlan` | active VXLAN interfaces and table `41913` | out of scope | Do not repurpose; no coexistence mutation |
| BGP | Quagga, 2 neighbors, 1 established | production control plane | Do not touch; test prefixes must not be exported |
| Firewall | 153 IPv6 / 104 IPv4 rules | production policy | No changes; test traffic must be explicitly allowed/observed |
| Offload | `hw-tc-offload` off on all observed links | functional gate | No global change; canary must not rely on fast path |

The manual rules at `10410–10414` are the key precedence conflict: they shadow SADR rules for any
overlapping source until a separately authorized migration. The first canary therefore uses a unique
source prefix and priority `21031`, and does not touch an overlapping production source.

## 2. Isolation gates (all required before a canary)

1. **Selector exclusivity:** `<TEST_SRC_PREFIX>` is not an address/route/rule source in production,
   is used only by the test endpoint, and does not overlap any configured or observed prefix.
2. **Priority safety:** the chosen priority is in `20000–21031`, is unused, and cannot shadow
   `10410–10414`, `main`/`local` or any production rule.
3. **Export safety:** the test prefix is not advertised to BGP and is not in the production routing
   tables; verify with the correct Quagga IPv6 command and the operator's export policy.
4. **Escape safety:** the test source/destination prefixes are not routed to providers or production
   networks; test endpoints and capture points are isolated.
5. **Ownership:** no existing service can adopt, delete or overwrite the test rule/table/route. The
   test uses an exact owned tuple and no auto-allocation.
6. **Rollback:** exact `ip` deletion commands, baseline snapshots and a bounded watchdog exist; no
   flush, no reboot, no firewall reset.
7. **Resource:** low-rate probes, one rule (first canary), modest CPU/memory; baseline is captured
   before the window.

If any gate cannot be demonstrated, the canary is **BLOCKED** or maintenance-window-only.

## 3. Test topology using existing infrastructure

Preferred options, in order:

- a dedicated test VLAN or physical port on the existing switching, connected to a Linux VM or
  network namespace with `<TEST_SRC_ADDR>`;
- an isolated Linux VM/namespace with a dedicated virtual Ethernet path to the router, if no
  production switch change is required;
- a test endpoint plus independent capture host that observes both expected and wrong egress.

Do not use the production VXLAN interfaces or table `41913`. Do not use production addresses or
prefixes. Do not enable a routing peer that can leak test prefixes into production BGP. FRR/Linux
peers are acceptable only in an isolated topology.

## 4. Experiment classes

| Class | Mutation | Risk | Status |
|---|---|---|---|
| R0 | Read-only identity/RPDB/table/interface/systemd/resource discovery | none | completed |
| R1 | One terminal `unreachable` rule for a unique test source at priority `21031` | low; global RPDB rule, no table/route | **proposed first canary** |
| R2 | Explicit provider table `10001`, lookup rules, test default route on a test interface | medium; global rules/table | requires R1 and a verified test egress |
| R3 | Install package with no SADR policy | medium; service/boot/package side effects | maintenance-window or staged authorization |
| R4 | Commit one synthetic SADR policy | medium/high; configuration engine, monitor, guard | requires R3 and test topology |
| R5 | Boot/reboot, guard failure injection, global offload, BGP/VXLAN interruption, event storms | high | maintenance-window only or deferred |
| R6 | Production migration/removal of manual table/rules | high | separate future phase; not authorized |

## 5. First canary: exact command plan (not executed)

Operator supplies: `<TEST_SRC_PREFIX>`, `<TEST_SRC_ADDR>`, `<TEST_DST_ADDR>`, `<TEST_HOST>`,
`<MANAGEMENT>`, `<CAPTURE_IFACE>`. The test endpoint must be isolated and use `<TEST_SRC_ADDR>`.

### Preflight (read-only)

```bash
# On the router
ip -6 rule show
ip -6 route show table 10000
ip -6 route show table 10001
ip -6 route show table 41913
ip -6 route show table all
ip -6 addr show
ip -6 rule show | grep -E '^(21031):'

# Configuration/API presence (read-only)
my_cli_shell_api existsActive protocols ipv6-sadr
my_cli_shell_api listActiveNodes protocols ipv6-sadr policy

# On the test endpoint / controller
# Verify <TEST_SRC_PREFIX> is not in production, not advertised, and has no route.
# Verify the test endpoint is attached only to the isolated test VLAN/port.
```

Pass conditions: exact priority `21031` free; `<TEST_SRC_PREFIX>` absent from production rules,
addresses, tables and BGP; `ipv6-sadr` absent; baseline snapshots recorded; independent capture and
management path verified.

### Canary mutation (one rule; requires explicit batch authorization)

```bash
# Router: exact tuple, no table, no route, no flush
sudo ip -6 rule add from <TEST_SRC_PREFIX> unreachable pref 21031

# Verify
rules=$(ip -6 rule show) || { echo 'ip -6 rule show failed' >&2; exit 1; }
printf '%s\n' "$rules" | grep -Eq '^21031:[[:space:]]+from <TEST_SRC_PREFIX> unreachable' \
    || { echo 'mutation missing' >&2; exit 1; }
```

### Traffic verification

```bash
# Test endpoint, source-bound probes; expected fail-closed
ping -6 -c 5 -I <TEST_SRC_ADDR> <TEST_DST_ADDR>
# Or a low-rate TCP/UDP probe with the same source.

# Independent capture on <CAPTURE_IFACE> must show no test packet reaching a provider.
```

Production probes (IPv4/IPv6 Internet, DNS, management, BGP, VXLAN) must remain at baseline. A
production degradation stops the canary and invokes recovery.

### Rollback (bounded, exact)

```bash
sudo ip -6 rule del from <TEST_SRC_PREFIX> unreachable pref 21031
rules=$(ip -6 rule show) || { echo 'ip -6 rule show failed' >&2; exit 1; }
if printf '%s\n' "$rules" | grep -Eq '^21031:[[:space:]]+from <TEST_SRC_PREFIX> unreachable'; then
    echo 'rollback did not take effect' >&2; exit 1
fi
# Verify priority/count baseline and no table/route change.
```

A device-local watchdog should perform the same deletion after the authorized deadline if the
orchestration session is lost. It must be idempotent, tested off-device and never flush the RPDB.

## 6. Stop conditions

Stop on a wrong-provider observation, overlapping production selector, unexpected rule/table change,
BGP/firewall/VXLAN/management degradation, resource pressure, failed watchdog verification or loss
of independent observation. The default is to delete the exact owned rule and preserve production
state, not to improvise a broader recovery.

## 7. Deferred tests

Package install/activation, configuration commits/rollback, cold boot, guard failure injection,
global offload changes, production BGP/VXLAN interruption, event storms and all migration work are
deferred until their specific authorization plans and recovery evidence exist.
