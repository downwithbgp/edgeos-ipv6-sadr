# Phase VI-C — target-platform qualification and HNAT compatibility

**Status:** R1 executed once; the dataplane A1/B phases passed and the cleanup gate failed on a
leftover runtime directory, which was removed and verified. Acceleration classification: **UNKNOWN**.
No second mutating execution is authorized; R2, firewall changes, offload changes, merge, tag and
release remain unauthorized. PR #1 remains draft.

## 1. Environment and authorization

- Second ER-X: not available. Environment B (production ER-X over the permitted lab VXLAN) used.
- Requests A, C, D, E deferred/not authorized; B conditionally approved and consumed by the single
  execution recorded here.
- Temporary controller resources: a VXLAN peer (`vxlan900c`, VNI 900, fd42:900::2/64) was created
  because no controller peer existed for the target's existing `vxlan900`; it was removed and
  verified after the run. No target interface, VLAN, firewall, BGP, offload or persistent
  configuration change was made.

## 2. Adapter corrections (regression evidence)

- `SADR_QUAL_CTRL_IF` / `SADR_QUAL_GW6`: explicit controller interface and next-hop override, both
  required together; the interface must be a VXLAN device with a global /64 and the next hop inside
  it and resolving on it.
- A connected /64 route inside the E1/E2 namespaces so a global next-hop resolves (the previous
  derivation used a link-local gateway). The specific D/128 via the gateway still forces the router
  path; the adapter's route check confirms it.
- `SADR_QUAL_E1_MAC` / `SADR_QUAL_E2_MAC`: optional MAC pinning to avoid a stale target neighbor
  cache after a previous run (two non-mutating A1 attempts failed 0/0 for this reason; pinning to
  the target's cached MACs restored delivery). The values must be distinct unicast,
  locally-administered MACs.
- Device cleanup: stop the transient cleanup service as well as the timer, remove every file in the
  exact runtime directory (including timer-created logs), then rmdir; the first execution's cleanup
  gate failed because the old fixed-file-list removal left the directory behind (the transient
  service could still recreate/retain entries).
- Regression: shellcheck clean; adapter plan and cleanup suites pass (20/0), including the explicit
  override plan and the hash-binding test; the current manifest was regenerated after the post-run
  cleanup fix (current adapter
  `9cc33b2cdae732a7d30abd603d2e0cde5d2d406476f11572285607988fd3f97a`, manifest
  `055044eb19c417250a5160e2fe74fbda58afe9a2379bd662abd27dc37ecdc377`; these are **not** the executed
  binding).

## 3. Evidence and residual risk

**Run record:** standalone A1 22:26:14–22:27:07Z (PASS); in-session A1 22:30:23–22:30:37Z (PASS);
mutation boundary 22:30:45Z; deploy 22:30:56Z; B 22:31:00–22:31:20Z; cleanup 22:31:20–22:31:30Z;
final audit 22:31:40Z; adapter result status `fail` (cleanup gate only). Invariants compared:
protected rules `10410–10414`, table `41913`, BGP neighbour state, default routes, available memory.
Executed binding: adapter `6d22e6b0…`, manifest `5e6cc0cb…` (record
`docs/r1-authorization-viic.json`); the current files after the post-run cleanup fix are adapter
`9cc33b2c…`, manifest `055044eb…` and are **not** the executed binding.

| Item | Result | Status |
|---|---|---|
| Standalone lab-VXLAN A1 | matching 20/20, control 10/10, invariants checked | PASS (non-mutating) |
| In-session A1 | matching 20/20, control 10/10 | PASS |
| Mutation boundary | one exact rule `from fd42:901::a1/128 unreachable pref 21031` | CROSSED (authorized, once) |
| B phase | matching 0/20, control 10/10 | PASS (rule effective on the software path) |
| A2 phase | not run (run aborted at the cleanup gate) | NOT RUN |
| Rule cleanup | exact deletion and verification | PASS |
| Runtime-directory cleanup | adapter gate failed; the directory was present and the fixed-file-list removal left it behind; manual `find -delete` + `rmdir` removed it and verification showed it absent | FAIL → remediated |
| Protected state | rules `10410–10414` = 5; table `41913` = 2 routes | UNCHANGED |
| Timer/unit | none active; transient unit reset/stopped | ABSENT |
| Acceleration state | no read-only FOE interface; no FOE write/flush | **UNKNOWN** |
| Controller resources | VXLAN peer, namespaces, macvlans, captures/tcpdump stopped and removed | CLEAN |

**Interpretation:** the tested topology forwards correctly with the RPDB rule active (A1 passes,
B blocks the selector, control unaffected). The run does not establish hardware-offload correctness
(G1): acceleration state is unknown and no FOE observation was possible. The cleanup failure is a
harness defect, not a routing failure; it is fixed for future runs.

Raw captures, real addresses and run logs remain outside the repository; only sanitized counts and
status are recorded here.
