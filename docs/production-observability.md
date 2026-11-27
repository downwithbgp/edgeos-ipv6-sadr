# Production observability plan

**Status:** plan only. No production probe or mutation has been executed. Raw baseline output remains
outside the repository.

## 1. Evidence states

- **PASS** — the check ran and met its pre-declared condition.
- **FAIL** — the check ran and violated it.
- **BLOCKED** — the check could not run safely or its prerequisite was absent.
- **NOT RUN** — not attempted (including deferred maintenance tests).

A missing observation is never a PASS. Final-state checks alone do not prove absence of transient
leakage; probes and captures must run throughout a transition.

## 2. Baseline to capture before each authorized experiment

Read-only, bounded snapshots:

```text
identity:       /etc/version, uname -r, board identity
RPDB:           ip -6 rule show, ip -4 rule show
tables:         ip -6 route show table 10000, 10001, 41913; ip -6 route show table all
interfaces:     ip -br link, ip -d link show, ip -6 addr show
systemd:        vyatta-router.service properties and timers
packages:       dpkg -l (filtered as needed)
BGP:            correct Quagga IPv6/IPv4 summary form; session/established counts
firewall:       sudo -n /sbin/ip6tables -S and /sbin/iptables -S (raw evidence only)
resources:      free -m, uptime, load, df, process snapshot
management:     current independent path/session status
```

Store raw evidence outside the repository. The repository baseline is sanitized in
`docs/production-baseline.md`.

## 3. Health checks and stop conditions

Use independent probes rather than relying on an isolated ICMP latency change.

| Area | Check | Stop condition |
|---|---|---|
| Management | Independent SSH/console command succeeds throughout | Any loss of independent management |
| IPv4 Internet | TCP/UDP probe to an approved external endpoint, plus route/address baseline | Loss or path change beyond agreed tolerance |
| IPv6 Internet | Native provider TCP/UDP probe from an approved host | Loss or wrong-provider observation |
| DNS | Query approved resolver(s), compare result shape | Failure or unexpected resolver path |
| BGP | Correct summary; neighbor/established count and session state | Any established-session loss or unexpected neighbor state |
| VXLAN | Existing VXLAN interfaces/table `41913` route shape and end-to-end tunnel probe | Missing/extra `41913` routes or failed tunnel probe |
| Internal IPv6 | Approved internal TCP/UDP probe | Loss or unexpected provider egress |
| Management DNS/SSH | Existing management path and listener reachability | Loss of access |
| RPDB/FIB | Exact rule/table snapshot; only authorized tuples may differ | Any unapproved rule/table/interface change |
| CPU/memory | Load, available memory, pressure | Sustained load/memory beyond the approved threshold |
| Control plane | No unexpected daemon restarts/log burst | Unexpected restart or resource exhaustion |

Proposed initial thresholds (Recommendation, require operator approval against the baseline):

- no BGP established-session loss;
- no change in table `41913` route count or VXLAN reachability;
- management path available for the whole window;
- available memory stays above an agreed floor (baseline available was ~112 MiB; a conservative
  floor should be set by the operator, not guessed here);
- load and CPU remain within the operator-approved envelope;
- zero wrong-provider packets in independent captures;
- any unapproved RPDB/table change is an immediate FAIL, regardless of connectivity.

Do not interpret a brief ICMP RTT change as proof of forwarding degradation. Use TCP/UDP probes and
independent captures; distinguish control-plane response from dataplane forwarding.

## 4. Continuous and final observation

- Start independent captures on every relevant egress before the first mutation.
- Run low-rate deterministic probes continuously through the experiment.
- Record observation resolution, capture filters and probe counts.
- Take a final snapshot and compare it to the baseline.
- A finite probe count is evidence, not mathematical proof of absence of leakage.

## 5. Evidence package

For each authorized batch record: device identity, package/script hashes, authorization file hash,
profile/test IDs, start/end UTC, operator, commands, pre/post snapshots, packet-probe counts and
filters, captures, health checks, PASS/FAIL/BLOCKED/NOT RUN, deviations, rollback timing and residual
risk. Never commit raw addresses, credentials, unredacted configuration or captures.
