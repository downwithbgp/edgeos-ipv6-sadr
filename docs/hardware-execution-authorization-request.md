# Hardware execution authorization request

**Status:** DEFERRED. An isolated ER-X is not available; this request is not actionable in Phase IV.
No hardware execution is authorized by this document.

The production-aware replacement for the first executable batch is
[`production-canary-authorization-request.md`](production-canary-authorization-request.md). This
document is retained as the scope definition for the full 22-step matrix once dedicated hardware
exists.

## 1. Requested authorization

Authorize one isolated EdgeRouter X qualification session using the repository's plan-first harness.
The session is **not** authorized to touch the production router, migrate the manual SADR
configuration, publish a release, merge the draft PR or claim target compatibility in advance.

Explicit acknowledgements requested from the operator:

- [ ] The target is an isolated ER-X, not the production router.
- [ ] Independent management connectivity (console or separate management path) is available.
- [ ] `config.boot`, rules, routes, package inventory and the manual restore procedure are backed up.
- [ ] The existing manual table `41913` and rules `10410–10414` will not be modified.
- [ ] The session may install/upgrade/remove the package only on the isolated device.
- [ ] Packet captures and test prefixes/interfaces are isolated from production traffic.
- [ ] A named rollback owner and maintenance window are recorded.

## 2. Target and artifact

```text
Device:       EdgeRouter X / ER-e50 (isolated)
EdgeOS:       3.0.1
Firmware:     EdgeRouter.ER-e50.v3.0.1.5862409.*
Kernel:       4.14.54-UBNT
Package:      edgeos-ipv6-sadr 0.1.0
Artifact SHA: to be recorded at execution time
Harness:      qualification/run.sh (commit to be recorded in the run metadata)
```

The preinst must accept the exact firmware/kernel and reject unsupported combinations. The harness
must refuse `--execute` unless `--authorize`, `SADR_QUAL_ISOLATED=1`, the exact preflight identity and
all required adapters are present.

## 3. Session scope

Run the 22-step matrix in `qualification/README.md`:

- identity/firmware/kernel preflight and artifact hash;
- independent management attestation;
- configuration/rules/routes/package backups;
- install, configure, structural verification;
- continuous packet probes and captures on every relevant egress;
- established TCP/UDP flows during changes;
- provider/internal/rule/table loss and repair;
- monitor interruption/restart and resynchronization;
- config failure/rollback/commit-confirm;
- cold boot/reboot and guard-before-forwarding;
- upgrade, removal refusal and interrupted lifecycle;
- offload enabled/disabled functional checks;
- local/unbound source selection;
- BGP internal-route mirroring/withdrawal/ECMP;
- native firewall/VXLAN coexistence;
- CPU/memory/throughput/recovery/boot measurements;
- cleanup and verification of no managed residue.

## 4. Stop conditions

Stop immediately on:

- a wrong-provider packet or an unexplained cross-provider capture;
- loss of independent management;
- unclassified mutation of rules, tables or foreign objects;
- a guard/manager failure that leaves a configured constrained source unprotected;
- a package lifecycle operation that would remove active protection;
- any need to change production forwarding, firewall, BGP, VXLAN, offload or startup configuration.

On stop, preserve captures/logs, restore the backed-up configuration/package state and report the
failure. Do not improvise around a failed fail-closed check.

## 5. Evidence and reporting

The harness writes `results.json`, `results.md`, backups, captures and logs under an immutable run
directory. Report probe counts, capture filters, observation resolution, device identity, package
hash, harness commit and all deviations. A finite probe set is evidence, not a mathematical proof of
no leakage.

## 6. Out of scope

Production-router installation/migration, release tagging/publication, merging the draft PR,
hardware qualification claims before evidence is reviewed, and any change to the manual table/rules
or production forwarding/firewall/BGP/VXLAN/offload settings.

## 7. Approval record

```text
Approved by: ____________________
Role:        ____________________
Date/time:   ____________________
Device:      ____________________
Window:      ____________________
Rollback owner: _________________
```
