# Testing strategy


> **v0.1.0 refinements:** `docs/v0.1.0-refinements.md` is normative and supersedes conflicting text in this document.

**Status:** architecture-phase strategy. The executable lab is in `test/integration/`; the
production unit/mock suite is a v0.1.0 deliverable.

## 1. Evidence layers

| Layer | Environment | What it can prove | What it cannot prove |
|---|---|---|---|
| L0 — static/unit | unprivileged host | validation, canonicalisation, collision logic, desired-state generation, idempotency, API-error handling | kernel dataplane, EdgeOS engine |
| L1 — Linux netns | privileged container, generic kernel | actual packet paths, RPDB/table semantics, failure and lifecycle logic | EdgeOS 3.0.1, 4.14 kernel, ER-X offload |
| L2 — emulated EdgeOS | exact firmware rootfs under qemu | template discovery, config-engine priority/visibility, commit/rollback, engine ordering | hardware dataplane, real WAN |
| L3 — hardware | ER-X, supported firmware | target kernel/userspace behaviour, boot, offload, real interfaces, performance | other hardware/firmware |

**Golden rule:** an L1 result is labelled `Verified (generic Linux)` and never presented as EdgeOS
evidence. L3 is required before a compatibility or performance claim.

## 2. L0 — unit, configuration and mock tests

### Validation and canonicalisation

* IPv6 prefix parsing and canonical network form; host bits set; /48, /56, /60, /64, /128.
* Exact duplicate source prefixes across policies (reject).
* Nested/overlapping prefixes: accepted with longest-source precedence; the generated priority order
  is asserted.
* Next-hop forms: global + interface, link-local + interface, interface-only; missing/invalid
  interface; mixed-family next hop.
* Table ID and rule-priority validation, reserved ranges, auto-allocation determinism and collision
  refusal.
* Route protocol marker and ownership manifest; marker-only wrong-prefix-set conflict.
* `disable` and deletion semantics.

### Configuration API and desired state

* `my_cli_shell_api exists`/`returnValue` during an `end:` action: the current subtree is visible.
* `existsEffective` returning absent for the still-executing subtree is not interpreted as absent.
* API error is a hard failure; it never becomes an empty desired state.
* No-op commit, policy add/change/delete, last-policy deletion, failed commit, commit-confirm
  rollback.
* Desired-state snapshot is written atomically; the monitor reads the snapshot, not a live
  half-committed view.
* Scripted versus interactive configuration sessions: the SADR action must not depend on a
  session-specific firewall path. The companion's scripted firewall limitation is a platform
  caution, not a SADR mechanism.

### Idempotency and partial application

* Reconcile twice: no duplicate rules/routes; byte-identical effective snapshot.
* Inject failure at each mutation step; assert the source is on the previous effective path or
  blocked.
* Simulate a stale table/rule from a previous process; assert ownership check and safe cleanup.
* Simulate a foreign managed-range object (refusal) and a pre-range shadowing rule
  (install/report, not effective); assert the health state.

## 3. L1 — Linux network-namespace tests

The current lab (`test/integration/netns-sadr.sh`) is the foundation. Extend it with the production
reconciler and monitor when they exist.

### Topology matrix

* Two providers, distinct delegated prefixes and transfer links.
* One dual-prefix client; connected and configured internal destinations; a more-specific external
  route under a declared internal prefix.
* Nested source policies (/56 and /64) and an exact /128 transfer policy.
* At least one non-Ethernet or point-to-point egress form; link-local next hop.
* A provider-transfer address probe: a PB source to PA's on-link transfer address must not egress PA,
  and the reverse. Provider-facing connected routes are never auto-whitelisted.
* Provider source-address validation and capture points.

### Assertions

* Correct provider for each source; wrong provider capture must be zero.
* Internal destinations reachable regardless of source; a more-specific external route under an
  internal prefix must not capture the source.
* A mirrored internal `via` route whose gateway is not covered in table 10000 is rejected or its
  covering route is mirrored.
* Positive controls: a deliberate leak is observed before the fix, and the expected provider sees
  traffic after it; absence of traffic is not a pass.
* Provider route loss, internal route loss, interface down/delete/recreate (new ifindex), routing
  daemon restart (simulated), process kill between mutations.
* Disabled policy combined with interface recreation: the provider route stays absent; internal
  reachability remains; external stays blocked.
* Rule/table collision, marker-only conflict, and shadowing by an exact, overlapping, catch-all or
  non-source-selector preceding rule.
* Local bound source and unbound source selection; `ip -6 route get` agreement.
* Real forwarded TCP and UDP, not only ICMP.
* Continuous negative probes during transitions.

### Test harness rules

* A missing capability is a loud skip unless `REQUIRE_NETNS_TEST=1`; CI sets it.
* Captures are per-probe and retained on failure (`SADR_CAPDIR`, `SADR_KEEP=1`).
* Capture start/drain waits are test synchronization, not product timing.
* The suite exits non-zero on any failed assertion.
* Generic-Linux results are never recorded as hardware qualification.

## 4. L2 — emulated EdgeOS

Use the exact firmware rootfs and configuration engine under qemu. Validate:

* template discovery, tab completion, `show configuration commands`, `compare`;
* priority 500 execution order relative to interfaces/addresses (default) and static (450);
* `ip -6 monitor`/systemd event-source behaviour and early-boot guard ordering;
* `exists` versus `existsEffective` during `end:`;
* commit, no-op, delete, last-policy delete, commit-confirm rollback, failed commit;
* boot configuration load and the first-reconciliation window;
* scripted versus interactive session behaviour;
* operational template discovery and exit codes.

Emulation caveats (from the companion project): MIPS userspace under qemu, host kernel, replaced
iptables for ABI reasons, module loading as a no-op. Emulation does not prove dataplane or hardware
offload. The current host could not execute the MIPS PIE firmware binaries (qemu/mmap_min_addr
limitation); this is a named environment limitation, not a pass.

## 5. L3 — hardware qualification

### Safety

* Preserve independent management and console access.
* Capture and back up configuration and runtime state off-device; keep recovery media.
* Use isolated test policies and tables; do not migrate the manual table 41913/rules 10410–10414
  during initial qualification.
* Do not modify unrelated firewall, VXLAN, DHCPv6-PD or routing state.
* Have a rollback and reboot plan; record every step.

### Functional matrix

* Install package; configure a test source prefix and provider table; commit/save/reboot.
* Verify `show configuration commands`, `compare`, delete, rollback, commit-confirm.
* Verify effective rules/tables/guards; provider route loss; interface disable/delete/recreate.
* Boot ordering with WAN forwarding; early guard service if implemented.
* Collision/shadow survey on the real router; migration rehearsal in a test policy.
* Unrelated state preservation (BGP/OSPF, RA, connected, DHCPv6-PD, firewall, VXLAN).

### Performance and dataplane

* Use real forwarded TCP and UDP (for example iperf3 or equivalent), not only ICMP echo or
  traceroute timing.
* Compare with and without the extension, with representative internal and external destinations.
* Measure CPU, memory, route/rule scale, conntrack and existing flows.
* Do not globally disable hardware offload without concrete evidence. If offload is tested, record
  the exact setting and the correctness result; a fast but policy-ignoring path is a failure.
* Account for MTU/PMTUD, tunnels, VLAN tags and PPPoE overhead.
* A FIB entry is not an end-to-end connectivity claim.

## 6. CI

* `make test`: lint, shell/Perl syntax, unit checks, documentation-address hygiene.
* `make test-netns`: privileged Docker; `REQUIRE_NETNS_TEST=1`; the suite must not silently skip.
* Emulation and hardware jobs are separate, explicitly labelled, and not substituted for each
  other.
* No release artifact is produced in the architecture phase.

## 7. Target quirks that tests must pin

| Quirk | Test consequence |
|---|---|
| Target `ip -j` route/rule output is text, not JSON | Diagnostics parse text or emit own JSON; no route/rule JSON dependency |
| Target `ip -d link` human output is defective on MIPS | Use `ip -j -d link` for link attributes |
| Commit engine is not atomic | Guard-first ordering; partial-state tests |
| `existsEffective` may miss the executing subtree | Use working-config `exists`; API errors are hard failures |
| Scripted/interactive commits differ for firewall | Keep SADR independent of firewall commits |
| Native table routes are not repaired after recreation | Extension owns its routes; recreation test |
| Offload behaviour is unverified | Hardware correctness/performance gate |
