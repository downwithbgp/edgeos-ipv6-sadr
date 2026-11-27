# Operations and diagnostics

**Status:** proposed for v0.1.0. Command names and exact output are illustrative until the
configuration/operational templates are implemented and reviewed.

## 1. Configuration model

```text
protocols {
    ipv6-sadr {
        destination-exception 2001:db8:1::/64
        destination-exception 2001:db8:100::/64
        destination-exception 2001:db8:200::/56

        policy provider-a {
            source-prefix 2001:db8:a000::/56
            source-prefix 2001:db8:a000:1::/64
            next-hop 2001:db8:aa00::1
            interface eth0
            table 10001
            description "Provider A transit"
        }

        policy provider-b {
            source-prefix 2001:db8:b000::/56
            next-hop 2001:db8:bb00::1
            interface eth1
            description "Provider B transit"
        }
    }
}
```

* `destination-exception` is global and exact. Connected routes are automatic. The operator must
  list every non-connected internal prefix that should bypass the provider default.
* `source-prefix` may repeat. Exact duplicates across policies are rejected.
* `next-hop` is optional only for an interface-only route. A link-local next hop requires
  `interface`.
* `table` is optional; deterministic auto-allocation is used when omitted. Explicit tables are
  checked against the reserved range and ownership.
* `disable` keeps internal reachability and blocks external traffic. Delete the policy to restore
  native routing intentionally.

The subtree is intended to support normal EdgeOS discovery, tab completion, validation,
`show configuration commands`, `compare`, `commit`, `save`, deletion, rollback and commit-confirm.

## 2. Operational commands

```text
show ipv6-sadr status
show ipv6-sadr policy [<name>]
show ipv6-sadr route <source> <destination> [iif <interface>]
show ipv6-sadr health [--json]
```

### `status`

A compact table:

```text
Policy       Source prefix              Table  Egress                         Health
provider-a   2001:db8:a000::/56         10001  2001:db8:aa00::1 dev eth0       effective
provider-a   2001:db8:a000:1::/64       10001  2001:db8:aa00::1 dev eth0       effective
provider-b   2001:db8:b000::/56         10002  2001:db8:bb00::1 dev vxlan...   protected
internal     connected + exceptions      10000  local whitelist                 effective
```

### `policy`

Shows source prefixes, rule priorities, provider table/route/guard, internal-rule presence,
interface state, next-hop resolution, ownership/shadow status, last reconciliation error and health
reason.

### `route`

Runs the kernel lookup, not a userspace approximation:

```text
ip -6 route get <destination> from <source> [iif <interface>]
```

It reports the selected table/rule, `dev`, next hop, metric and preferred source, and explains
whether the lookup was local or forwarded. It does not claim end-to-end connectivity. On the target,
the route's `src` is the preferred source, not a rewrite of the packet source.

### `health`

Exit codes:

| Code | Meaning |
|---|---|
| 0 | every configured, non-disabled policy is effective |
| 2 | configured but incomplete (some owned objects missing) |
| 3 | dependency unavailable (interface/address/next hop) |
| 4 | protected (guard active; intended route absent) |
| 5 | shadowed (a preceding rule prevents the policy) |
| 6 | ownership conflict |
| 7 | reconciliation failed |
| 8 | policy disabled (intentional; external path blocked) |

`--json` emits the helper's own JSON because the target `ip -j` route/rule output is text. A health
check that reports `effective` for a missing guard, a shadowed policy or a foreign route is a bug.

## 3. Migration from the manual runtime PoC

The manual state is table `41913`, rules `10410–10414`, and the runtime script. It is **not**
adopted or deleted automatically. The extension uses tables `10000+` and rules `20000+`; the manual
rules are earlier and therefore shadow a new policy until removed. The extension may install its
objects while shadowed; it reports `shadowed` and does not claim enforcement.

Procedure:

1. Back up configuration and runtime state; preserve management/console access.
2. Create `protocols ipv6-sadr` policies covering **every** constrained source prefix, including the
   transfer /128 if it is currently a separate policy. Add the internal destination exceptions.
3. Commit and save. The extension installs its tables, guards and rules. The manual rules still win
   for their sources; health reports `shadowed` for those policies. This is expected.
4. Verify the extension-owned tables: provider route + unreachable default, internal routes +
   per-prefix guards, exact rules, no conflict. Verify `ip -6 route get` for representative
   source/destination pairs.
5. Install a temporary fail-closed guard at a priority **before** the manual rules, for example
   `ip -6 rule add from <source> unreachable pref 9000`. This is a migration-only object outside the
   extension range; it must be removed after the cutover. The source is now blocked, so the manual
   rules can be removed without a wrong-provider window.
6. Remove the manual rules `10410–10414`, keeping any terminal `unreachable` rule last if the
   temporary guard is not used. Do not remove the manual rules before step 4 passes.
7. Remove the manual table 41913 routes and the runtime restore responsibility for them.
8. Remove the temporary guard. Verify health is `effective`, internal traffic works, and no source
   uses the wrong provider.
9. Save and reboot only after a recovery path is confirmed.

Never remove the manual rules first. Never delete table 41913 while it is the only protection for a
source.

## 4. Disable, deletion and package removal

* **Disable:** internal destinations remain reachable; external traffic is blocked; health `disabled`.
  The provider route is withdrawn. Delete the policy to restore native routing.
* **Delete a policy:** the provider route is removed while the guard remains, then the source rules
  are removed, then the table is cleaned. The final state is intentional native routing. During the
  transition external traffic is blocked.
* **Delete the last policy:** the internal table/guards and extension-owned objects are removed. The
  source is intentionally unconstrained; native routing applies.
* **Package removal:** `prerm` refuses while configured policies exist. Delete policies intentionally
  first, or keep the package. Uninstall must not silently remove an active policy and permit
  cross-provider egress. If no policies exist, only extension-owned objects are removed.

## 5. Troubleshooting

| Health | Likely cause | Action |
|---|---|---|
| `effective` | all owned objects present, dependency up | none |
| `incomplete` | reconciliation not finished or an owned object missing | inspect status/log; re-run reconcile; do not assume reachability |
| `dependency-unavailable` | interface/address/next hop missing or down | restore the dependency; the source remains protected |
| `protected` | provider route absent; guard active | restore the provider route or interface; external traffic is blocked |
| `shadowed` | a foreign rule precedes the policy and can match the source (overlap, `from all`, or a non-source selector) | inspect `ip -6 rule`; remove/relocate the foreign rule; re-check |
| `conflict` | foreign route/rule, marker-only mismatch, table collision | do not delete blindly; inspect the object; correct ownership or table |
| `failed` | last reconciliation error | read the recorded error; the source should be blocked or on the previous path |
| `disabled` | policy administratively disabled | internal works; delete the policy to restore native external routing |

Useful read-only checks:

```text
ip -6 rule show
ip -6 route show table 10000
ip -6 route show table 10001
ip -6 route get <destination> from <source>
ip -6 route get <destination> from <source> iif <interface>
```

The shadow detector is conservative: a preceding rule with no source selector (`fwmark`, `iif`,
`oif`, `tos`) is reported even if it would not match every packet. Treat `shadowed` as a prompt to
inspect, not proof of a broken policy.

Do not use `ip -6 route flush` or `ip -6 rule flush` as a troubleshooting shortcut.

## 6. Known operational limits

* A route/guard does not prove provider transit; remote failures are not detected.
* Unbound local sockets may select a different source; bind the source explicitly for router-originated
  sessions that must follow a provider policy.
* Internal prefixes must be declared; a forgotten BGP-learned prefix is not automatically whitelisted.
* The target `ip -j` route/rule output is text; use the helper's JSON or the text form.
* The boot window before the first guard is a named non-guarantee unless the early guard service is
  implemented and qualified.
* A disabled policy remains disabled across interface recreation; the provider route is not restored.
* The event monitor is proposed as `ip -6 monitor link` + `addr` (+ a filtered route monitor) under
  systemd, or a narrow netlink helper. Target monitor output, service ordering and early boot are
  qualification gates.
