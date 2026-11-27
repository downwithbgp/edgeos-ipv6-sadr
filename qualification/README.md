# Hardware qualification harness

This directory contains an **executable, plan-first** controller for an isolated EdgeRouter X
running EdgeOS 3.0.1 build 5862409. It is not authorized to run against the production router and
does not itself install anything in this repository's test phase.

## Safety model

- Default mode is `--plan`: no SSH contact, no package install, no configuration commit.
- `--execute` requires **all** of:
  - `--authorize` (explicit acknowledgement);
  - `SADR_QUAL_ISOLATED=1` (operator attestation that the target is an isolated device);
  - `--router`, `--artifact` and `--config`;
  - a preflight match for the exact firmware family and `4.14.54-UBNT`.
- The harness refuses missing prerequisites and marks missing test adapters `blocked`; it never
  treats a blocked step as a pass.
- Packet/transition/boot adapters must return JSON with `ok: true`, and if present `probes >= 0`
  and `wrong_provider == 0`. A finite probe set is evidence, not a mathematical proof of no leakage.

## Usage

```bash
# Plan only; no router is contacted.
qualification/run.sh --plan --out "$TMPDIR/qualification-plan" \
  --router admin@isolated-router --artifact /path/edgeos-ipv6-sadr_0.1.0_all.deb \
  --firmware 'EdgeRouter.ER-e50.v3.0.1.5862409.*'

# Isolated hardware session, explicitly authorized.
SADR_QUAL_ISOLATED=1 qualification/run.sh --execute --authorize \
  --router admin@isolated-router \
  --device-id ER-X \
  --firmware 'EdgeRouter.ER-e50.v3.0.1.5862409.xxxxxxx' \
  --artifact /path/edgeos-ipv6-sadr_0.1.0_all.deb \
  --config /path/sadr-config-commands.txt \
  --out /path/qualification-run
```

`--config` is a configuration-mode command file for the isolated policy. The controller runs the
package install, backups and structural checks; topology-specific probe adapters are supplied as
environment commands.

## Outputs

- `results.json` — machine-readable steps, statuses, details and summary counts.
- `results.md` — human-readable report with a status table and evidence caveats.
- `config.boot.before`, `rules.before`, `routes.before`, `packages.before`, `install.log` — raw
  evidence, retained with the run.

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
| `SADR_QUAL_CLEANUP_CMD` | Restore configuration/package state and verify residue |

The adapter commands run on the controller. They may use `ssh`/`scp`/captures, but must return the
JSON contract above. This keeps SADR-specific topology out of the controller while preserving
repeatable evidence collection.

## Validation

`test/qualification/test-plan.sh` runs plan mode and asserts the complete step matrix is present,
statuses are `planned`, and no router contact is attempted. It is part of the repository's
qualification checks.
