# Production rollback and recovery design

**Status:** design only. No rollback or watchdog was installed or executed on production.

## 1. Recovery hierarchy

1. **Exact owned-resource rollback** (first choice): delete only the exact test rule/table/route or
   remove the exact synthetic configuration/package object.
2. **Configuration restoration** from a verified backup, only for an authorized configuration
   experiment.
3. **Manual operator recovery** via the independently verified management path.
4. **Device-local watchdog** (proposed, not installed): executes only the pre-approved exact
   rollback after a bounded deadline if orchestration is lost.
5. **Hardware power/console recovery** only with explicit operator control; never automatic reboot.

Never use blanket RPDB flush, table flush, firewall reset, indiscriminate process kill or automatic
reboot as recovery. Do not touch table `41913` or rules `10410–10414`.

## 2. Required pre-mutation record

- Backup `/config/config.boot`; record its SHA-256.
- Snapshot `ip -6 rule show`, `ip -6 route show table all`, IPv4 RPDB, interfaces, package inventory.
- Record the exact experimental resource inventory (table, priority, prefix, route type, protocol,
  interface, package/script hash).
- Record the exact rollback command(s) and expected post-rollback baseline.
- Record independent management/console status and a contact/owner.
- Record the authorized deadline and maximum test duration.
- Record BGP/VXLAN/firewall/DNS/management baseline checks from
  `docs/production-observability.md`.

A configuration file backup alone is not proof of recoverability: kernel rules/tables, package
state, service state and configuration-engine activation must be understood and tested.

## 3. Exact first-canary rollback

For the R1 guard-only canary:

```bash
sudo ip -6 rule del from <TEST_SRC_PREFIX> unreachable pref 21031
rules=$(ip -6 rule show) || { echo 'ip -6 rule show failed' >&2; exit 1; }
if printf '%s\n' "$rules" | grep -Eq '^21031:[[:space:]]+from <TEST_SRC_PREFIX> unreachable'; then
    echo 'rollback did not take effect' >&2; exit 1
fi
# Compare priority/rule count and full baseline; no table/route should have changed.
```

The rollback is idempotent (a second delete is harmless) and scoped to the exact tuple.

## 4. Device-local watchdog requirements

Before a watchdog is proposed for production use it must be:

- **narrowly scoped:** allowlist only the exact authorized rollback tuples and deadline;
- **idempotent:** repeated execution leaves the same state;
- **independent:** runs locally on the device, not only in the orchestrating SSH session;
- **bounded:** rejects deadlines/commands outside the authorization file;
- **non-destructive:** no flush, reboot, firewall reset, interface deletion or foreign-object touch;
- **tested off-device:** fake `ip`/state fixtures prove allowlist rejection, exact deletion,
  idempotency and failure reporting;
- **auditable:** writes a local log with timestamp, command, result and baseline hash.

A watchdog is **not installed or authorized** in this phase. The production serial console exists but
its recovery usability has not been verified; an independent management path must be attested before
any mutating canary.

## 5. Abort and recovery evidence

On stop: preserve captures/logs, execute the exact rollback, verify baseline rules/tables and
production probes, record rollback duration, and report any residual difference. If rollback cannot
be verified, stop and escalate through the independent management path; do not improvise broad
cleanup.
