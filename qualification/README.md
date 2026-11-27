# Hardware qualification harness

This directory contains an **executable, plan-first** controller. The production-aware entrypoint is
`profile.sh`; `run.sh` remains the full-matrix controller for an isolated EdgeRouter X running EdgeOS
3.0.1 build 5862409. Nothing here is authorized to mutate the production router without a scoped
authorization file.

## Safety model

- Default profile is `plan`: no SSH contact, no package install, no configuration commit.
- `--execute` always requires `--authorize`.
- `--baseline` (with `--profile canary`) runs the actual Stage 0–2 R1 implementation without an
  authorization file or target mutation: controller namespaces/macvlans, read-only target
  preflight and the bounded A1 probes only. It verifies the execution manifest and cleans
  controller resources.
- `observe` is read-only and needs no authorization file.
- `canary` and `maintenance` require `--test-id`, `--device-fingerprint`, `--adapter` and
  `--cleanup`, plus an authorization JSON whose `test_ids` contains that id and whose
  `device_fingerprint`, `adapter_sha256` and `cleanup_sha256` match the supplied files. The validated
  duration, scope, recovery, deadline and hashes are exported to the adapter, never re-read from
  disk. Expiry is checked before mutation and must cover the whole run. Canary authorization also
  requires `execution_manifest_sha256`, matching `docs/r1-execution-manifest.json`; the profile
  verifies every manifested file before execution.
- Canary/maintenance runs also require `SADR_QUAL_VERIFY_CMD`; a failed cleanup verification is a
  recovery failure, never a pass. The approval record is an explicit maintainer-approved
  authorization document; no cryptographic signing identity is implied or invented.
- `isolated` additionally requires `target_class: isolated`, an `artifact_sha256`,
  `SADR_QUAL_ISOLATED=1`, `--router`, `--artifact` and `--config`, and a preflight match for the
  exact firmware family and `4.14.54-UBNT`.
- `profile.sh` and `run.sh` validate the router value before use, so an option-injection value
  cannot reach `ssh`.
- The harness refuses missing prerequisites and marks missing test adapters `blocked`; it never
  treats a blocked step as a pass.
- A run is complete only when every executed step passed; any `fail`, `blocked` or unexecuted
  mutating step exits non-zero, for `observe` as well.
- Canary/maintenance adapters must return JSON with `ok: true`, `probes` > 0 and
  `wrong_provider == 0`. A finite probe set is evidence, not a mathematical proof of no leakage.
- `canary` and `maintenance` install an `EXIT`/`INT`/`TERM` trap that runs the authorized cleanup
  command once. Losing the orchestration session therefore does not silently leave the test objects
  behind; the trap log records whether cleanup actually ran. The `isolated` profile execs `run.sh`,
  which has no such trap: it needs an independent recovery path.
- The approved mutation scope and recovery text are exported to the adapter as
  `SADR_QUAL_APPROVED_SCOPE`/`SADR_QUAL_RECOVERY`; the adapter must confine itself to them. The
  harness cannot verify an arbitrary adapter command stayed inside its scope.


## Profiles

| Profile | Purpose | Mutation |
|---|---|---|
| `plan` | Render the complete plan; **default** | none |
| `observe` | Bounded read-only identity/RPDB/table/interface/systemd/resource baseline | none |
| `canary` | One exact authorized synthetic experiment; no package install | authorization file + bound adapter/cleanup |
| `maintenance` | Explicitly authorized disruptive test; no automatic reboot | authorization file + bound adapter/cleanup |
| `isolated` | Original full 22-step dedicated-hardware qualification | full isolated matrix |

`canary --baseline` is the non-mutating Stage 0–2 A1 mode used before R1. It has no authorization
file and never deploys device files, arms a timer or changes the target RPDB.

Canary and maintenance require `--test-id` plus `--authorization` JSON with exact `device_id`,
`device_fingerprint`, `profile`, `target_class: production`, `test_ids` (including the requested test
id), `max_duration_seconds`, `approved_mutation_scope`, `recovery`, an unexpired `not_after`,
`adapter_sha256` and `cleanup_sha256`. Isolated requires `target_class: isolated`, a
`device_fingerprint`, an `artifact_sha256` and `SADR_QUAL_ISOLATED=1`. A missing/mismatched field
aborts before any mutation. There is no generic production-safety bypass.

## Usage

```bash
# Production-aware plan; no router is contacted.
qualification/profile.sh --profile canary --plan --out "$TMPDIR/profile-plan"

# Read-only production baseline collection.
qualification/profile.sh --profile observe --execute --authorize \
  --router admin@router --out "$TMPDIR/observe"

# One authorized synthetic canary (only after a scoped authorization exists).
# The R1 concrete invocation, adapter and cleanup paths are in
# docs/production-canary-authorization-request.md.
qualification/profile.sh --profile canary --execute --authorize \
  --router admin@router --device-id ER-X-TEST --test-id R1-guard-only \
  --device-fingerprint <64-hex> --adapter qualification/adapters/r1-canary.sh \
  --cleanup qualification/adapters/r1-cleanup.sh \
  --install qualification/adapters/r1-install.sh \
  --authorization /secure/r1-authorization.json --out "$TMPDIR/canary"
```

```bash
# Non-mutating Stage 0-2 A1 baseline through the real R1 implementation.
sudo -E SADR_QUAL_SSH_KEY=<key> qualification/profile.sh --profile canary --baseline \
  --router <user>@<router> --device-id 'Ubiquiti EdgeRouter' --device-fingerprint <64-hex> \
  --adapter qualification/adapters/r1-canary.sh --out "$TMPDIR/a1-baseline"
```

```bash
# Plan only; no router is contacted.
qualification/run.sh --plan --out "$TMPDIR/qualification-plan" \
  --router admin@isolated-router --artifact /path/edgeos-ipv6-sadr_0.1.0_all.deb \
  --firmware 'EdgeRouter.ER-e50.v3.0.1.5862409.*'

# Isolated hardware session, explicitly authorized. run.sh refuses an unbound
# artifact, so the approved hash must be supplied.
ARTIFACT=/path/edgeos-ipv6-sadr_0.1.0_all.deb
SADR_QUAL_ARTIFACT_SHA256=$(sha256sum "$ARTIFACT" | awk '{print $1}')
SADR_QUAL_ISOLATED=1 SADR_QUAL_ARTIFACT_SHA256="$SADR_QUAL_ARTIFACT_SHA256" \
  qualification/run.sh --execute --authorize \
  --router admin@isolated-router \
  --device-id ER-X \
  --firmware 'EdgeRouter.ER-e50.v3.0.1.5862409.xxxxxxx' \
  --artifact "$ARTIFACT" \
  --config /path/sadr-config-commands.txt \
  --out /path/qualification-run
```

`--config` is a configuration-mode command file for the isolated policy. The controller runs the
package install, backups and structural checks; topology-specific probe adapters are supplied as
environment commands.

## Outputs

- `results.json` — machine-readable harness steps, statuses, details and summary counts.
- `results.md` — human-readable report with a status table and evidence caveats.
- `adapter-result.json` — authoritative adapter stage/probe/cleanup result for the R1 path.
- `adapter-stages.tsv`, `stages.jsonl`, `diagnostics.jsonl`, `adapter.log` — stage and diagnostic records.
- `baseline.stdout`, `baseline.stderr`, `ssh.stderr.log`, `subprocess.log` — separate subprocess logs.
- `e1.pcap`, `e2.pcap`, `icmp.pcap`, `listener.log` — packet evidence, retained with the run.
- `mutation-boundary.json` — written after A1 and immediately before device runtime deployment.
- `config.boot.before`, `rules.before`, `routes.before`, `packages.before` — read-only snapshots.

Statuses are `pass`, `fail`, `blocked` and `planned`. `complete` is true only when every step passed.
A run with any `fail` or `blocked` step exits non-zero.

## Adapter contract

Set these environment commands before `--execute`. Each command must print one JSON object:

```json
{"ok": true, "probes": 120, "wrong_provider": 0, "notes": "optional"}
```

| Variable | Purpose |
|---|---|
| `SADR_QUAL_CONFIGURE_CMD` | Commit the isolated SADR policy and verify it is active |
| `SADR_QUAL_STRUCTURAL_CMD` | Check intent, guards, rules, tables and health |
| `SADR_QUAL_PACKETS_CMD` | Continuous packet probes on every egress |
| `SADR_QUAL_FLOWS_CMD` | Established TCP/UDP flows during policy changes |
| `SADR_QUAL_TRANSITIONS_CMD` | Provider/internal/rule/table loss and repair |
| `SADR_QUAL_MONITOR_CMD` | Monitor interruption, restart and resynchronization |
| `SADR_QUAL_ROLLBACK_CMD` | Failed commit, rollback and commit-confirm |
| `SADR_QUAL_BOOT_CMD` | Cold boot/reboot and guard-before-forwarding |
| `SADR_QUAL_UPGRADE_CMD` | Upgrade and interrupted upgrade |
| `SADR_QUAL_REMOVE_CMD` | Removal refusal with config/live objects |
| `SADR_QUAL_OFFLOAD_ON_CMD` | Hardware offload enabled correctness |
| `SADR_QUAL_OFFLOAD_OFF_CMD` | Hardware offload disabled correctness |
| `SADR_QUAL_SOURCE_CMD` | Forwarded, source-bound local and unbound traffic |
| `SADR_QUAL_BGP_CMD` | BGP internal-route mirroring/withdrawal/ECMP |
| `SADR_QUAL_COEXIST_CMD` | Native firewall and VXLAN coexistence |
| `SADR_QUAL_RESOURCES_CMD` | CPU/memory/throughput/recovery/boot measurements |
| `SADR_QUAL_CLEANUP_CMD` | Delete only the exact authorized test objects |
| `SADR_QUAL_VERIFY_CMD` | Mandatory for canary/maintenance: verify the cleanup left no residue |

The adapter commands run on the controller. They may use `ssh`/`scp`/captures, but must return the
JSON contract above. The R1 adapter (`r1-canary.sh`) is the exception: it writes
`adapter-result.json` and the harness treats that file as authoritative; its stdout is diagnostic
only. This keeps SADR-specific topology out of the controller while preserving repeatable evidence
collection.

## Validation

`test/qualification/test-plan.sh` runs plan mode and asserts the complete step matrix is present,
statuses are `planned`, and no router contact is attempted. `test/qualification/test-profiles.sh`
drives every profile plan, the authorization validator (deadline, device/profile/test-id/scope,
duration bounds, fingerprint and dependency hashes), the execution gates, cleanup verification,
cleanup on failure and interrupt, and the non-zero exit for a failed observe collection.
`test/qualification/test-cleanup.sh` tests the device cleanup script against a fake `ip` and the
adapter plan/refusal paths (cleanup 20/20; the canary adapter also accepts SADR_QUAL_CTRL_IF/SADR_QUAL_GW6 for an explicit controller VXLAN path and SADR_QUAL_E1_MAC/SADR_QUAL_E2_MAC for optional MAC pinning). `test/qualification/test-identity.sh` covers the framed
identity parser (14/14); `test/qualification/test-manifest.sh` covers manifest generation, tamper
rejection and candidate binding (4/4). `test/integration/r1-canary-sim.sh` runs the A/B/A sequence,
the controller redirect-sysctl regression and cleanup semantics in the privileged generic-Linux
container (10/0, netns 145/0). All are part of the qualification checks.
