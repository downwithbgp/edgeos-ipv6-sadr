# First production canary authorization request (R1)

**Status:** request only. **No mutation is authorized by this document.** It must be filled,
reviewed and approved by the operator for the isolated test topology.

## 1. Requested batch

- **Profile:** `canary`
- **Target class:** `production` (production router, uniquely isolated test source)
- **Device ID:** `<ER-X-DEVICE-ID>`
- **Profile / package / harness:** `<HARNESS-COMMIT>`, `<ARTIFACT-SHA256>` (if applicable)
- **Test IDs:** `R1-guard-only`
- **Approved mutation scope:** one exact terminal `unreachable` rule for a unique test source prefix
  at priority `21031`; no table, no route, no package install, no configuration commit.
- **Maximum duration:** `<SECONDS>` (proposed ≤ 120 s)
- **Authorization deadline (`not_after`):** `<YYYY-MM-DDTHH:MM:SSZ>`; the harness refuses an
  undated or expired grant.
- **Recovery:** exact rule deletion, independent management/console, bounded watchdog if approved.
- **Test source prefix/address and endpoint:** `<TEST_SRC_PREFIX>`, `<TEST_SRC_ADDR>`,
  `<TEST_HOST>`; supplied outside the repository.
- **Test topology:** dedicated test VLAN/port or isolated VM/namespace; no production VXLAN/table
  41913.

## 2. Preconditions (all must be PASS)

- Exact EdgeOS firmware/kernel/device identity verified.
- Independent management/console path verified (not only the orchestrating SSH session).
- Production baseline captured; manual table `41913`/rules `10410–10414` untouched.
- `<TEST_SRC_PREFIX>` absent from production addresses, routes, rules, firewall, BGP and VXLAN;
  priority `21031` free.
- Test endpoint attached only to the isolated topology; providers/captures independent.
- No SADR protocol/policy/live managed state present.
- BGP/VXLAN/firewall/DNS/management baseline healthy.
- Exact rollback command reviewed; no blanket flush/reboot in recovery.
- Authorization file matches device/profile/target class/test IDs/duration/scope/recovery and has an
  unexpired `not_after`.

If any precondition fails, the batch is **BLOCKED**, not rerun with a bypass.

## 3. Exact proposed mutation and rollback

```bash
# Preflight (read-only)
ip -6 rule show
ip -6 route show table 10000
ip -6 route show table 10001
ip -6 route show table 41913
ip -6 route show table all
ip -6 addr show
my_cli_shell_api existsActive protocols ipv6-sadr
my_cli_shell_api listActiveNodes protocols ipv6-sadr policy

# Mutation (only after approval)
sudo ip -6 rule add from <TEST_SRC_PREFIX> unreachable pref 21031
rules=$(ip -6 rule show) || { echo 'ip -6 rule show failed' >&2; exit 1; }
printf '%s\n' "$rules" | grep -Eq '^21031:[[:space:]]+from <TEST_SRC_PREFIX> unreachable' \
    || { echo 'mutation missing' >&2; exit 1; }

# Traffic: source-bound low-rate probes from <TEST_SRC_ADDR> to <TEST_DST> must fail closed;
# independent captures must show no provider egress. Production probes must remain at baseline.

# Rollback
sudo ip -6 rule del from <TEST_SRC_PREFIX> unreachable pref 21031
rules=$(ip -6 rule show) || { echo 'ip -6 rule show failed' >&2; exit 1; }
if printf '%s\n' "$rules" | grep -Eq '^21031:[[:space:]]+from <TEST_SRC_PREFIX> unreachable'; then
    echo 'rollback did not take effect' >&2; exit 1
fi
```

The rollback is exact and idempotent. No table/route/interface/package/config change is part of R1.

## 4. Stop conditions

Wrong-provider packet, overlapping production selector, any unapproved rule/table/interface change,
BGP/VXLAN/firewall/DNS/management degradation, resource pressure, loss of independent observation,
or failed/uncertain rollback. Stop and execute the exact rollback; do not improvise broader cleanup.

## 5. Approval record

```text
Approved by: ____________________
Role:        ____________________
Date/time:   ____________________
Device ID:   ____________________
Test IDs:    R1-guard-only
Duration:    ____________________
Topology:    ____________________
Recovery:    ____________________
```

Until this record and the matching JSON authorization exist, R1 is **BLOCKED**.
