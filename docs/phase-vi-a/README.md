# Phase VI-A — SADR architecture and dataplane feasibility review

**Status:** research/read-only/isolated phase complete; maintainer architecture decision pending.
**R1 remains NOT RUN and is suspended.** No production route/RPDB/firewall/interface/forwarding/
offload/package/boot/persistent change was made. No firewall exception is authorized. PR #1 remains
draft, open and unmerged.

## Deliverables

| Deliverable | Document |
|---|---|
| Disposition of Phase V-C; R1 suspension | [`disposition.md`](disposition.md) |
| Source-backed architecture decision record | [`../architecture/ADR-0002-sadr-implementation-review.md`](../architecture/ADR-0002-sadr-implementation-review.md) |
| Target capability matrix | [`target-capability-matrix.md`](target-capability-matrix.md) |
| Isolated RPDB vs native FIB results | [`isolated-comparison.md`](isolated-comparison.md) |
| Offload risk and revised target qualification plan | [`offload-risk-and-qualification.md`](offload-risk-and-qualification.md) |
| R1 topology alternatives (no firewall exception) | [`r1-topology-alternatives.md`](r1-topology-alternatives.md) |

## Recommendation (for maintainer decision)

1. **Retain RPDB with the internal-whitelist table and per-policy provider tables.** The broad
   `main suppress_prefixlength 0` model is rejected; the native source-specific FIB is rejected for
   production because the destination-first lookup lets a more-specific main route capture the
   constrained source. A safe native variant would require per-source BGP mirroring and internal
   overrides, a new control plane not exposed by the target daemons.
2. **Do not implement a second production backend** in this phase.
3. **Keep R1 suspended; create no firewall exception.** Prefer an isolated lab ER-X for target
   R1/offload evidence. If the production ER-X is required, the existing lab VXLAN (`vxlan<lab>` /
   controller `vxlan<lab-peer>`) is an existing permitted forwarding path with no `VYATTA_FW_IN_HOOK` chain
   and no firewall change; the single RPDB canary rule still requires a fresh separate R1
   authorization. A dedicated test VLAN with an exact firewall exception is the last option and
   requires separate justification/authorization.
4. **Authorize the target offload qualification plan.** HNAT/PPE IPv6 acceleration is built in, binds
   after >30 pps, has ~5 s ageout and no policy stage in this build; a flow's egress is frozen until
   ageout. Offload correctness is a gate, not only performance. No production offload change now.
5. Revisit native FIB only if a target experiment proves strict source-specific forwarding and a
   per-source BGP-mirroring/ownership model is accepted.

## Unresolved maintainer decisions

- Approve RPDB retention and the no-second-backend decision.
- Choose the future R1 topology (isolated ER-X preferred; production lab VXLAN acceptable; dedicated
  test VLAN/firewall exception only if separately authorized).
- Authorize the target offload/target qualification experiments; confirm no R1/R2/merge/release
  until the architecture gate and a fresh execution authorization.
- Resolve target `route add ... from` execution/`proto 194`, target source-specific forwarding,
  HNAT bind-path/source details, IPv6-module boot lifecycle, config-engine ordering, and performance.

## Evidence labels

The isolated result is **Verified (generic Linux)**, not EdgeOS. The target capability matrix
separates **Verified (target)**, **Verified (target source)**, **Strongly indicated** and
**Unverified**. Raw target output, real addresses and captures remain outside the repository.

## Reproduce

```bash
make test
REQUIRE_NETNS_TEST=1 bash test/integration/run-in-docker.sh   # netns 145/0; R1 sim 10/0
python3 qualification/execution_manifest.py --verify --root . --manifest docs/r1-execution-manifest.json
```

The Phase VI-A work stops at the architecture decision gate. No production mutation is authorized.
