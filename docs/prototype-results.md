# Prototype results

**Status:** generic-Linux proof of concept and production-reconciler phase complete. Not EdgeOS
evidence. The production phase is `test/integration/production-phase.sh`.

## 1. Artifact

| Item | Value |
|---|---|
| Commit | `c2304db` (`test: run the production reconciler in the namespace lab`) |
| Harness | `test/integration/netns-sadr.sh` |
| Runner | `test/integration/run-in-docker.sh` |
| Image | `test/integration/Dockerfile` (`debian:stable-slim`) |
| Echo helper | `test/integration/echo6.py` |
| Result | **145 pass / 0 fail** (75 packet-path probes across the PoC and production phases; the original 65-assertion PoC is included) |
| Environment | Host Linux 6.8.0-149, Docker 29.9.0, container iproute2 6.15.0, tcpdump 4.99.5, Python 3.13.5 |

Reproduce:

```bash
make test
REQUIRE_NETNS_TEST=1 make test-netns
```

## 2. Production reconciler phase

The production phase runs the real CLI and reconciler against the kernel with a local JSON config-API
fixture. It covers boot-guard blocking before reconcile, initial apply, rule/table/guard assertions,
packet paths, established TCP/UDP flows during a concurrent provider update, provider/internal/table
loss and repair, disable, foreign-state refusal, monitor repair/restart and policy deletion. Evidence
is **Verified (generic Linux)** only; target config-engine and hardware behavior remain gates.

## 3. What the prototype demonstrates

* A two-provider, dual-prefix topology with real packet captures and simulated source-address
  validation.
* Deliberate positive controls: the broad model leaks PA-sourced traffic to PB (and vice versa), and
  a more-specific external route sends PA-sourced internal traffic to PB. Those leaks are visible
  before the recommended model is applied.
* The internal-whitelist + provider-table model:
  * sends each source to its intended provider;
  * preserves connected and configured internal destinations;
  * does not send a constrained source to the wrong provider;
  * protects a declared internal prefix even when `main` has a more-specific external route under it;
  * handles nested /64 source policy over a /56;
  * works for ICMP, UDP and TCP and for source-bound local sockets;
  * fails closed when the provider route or a real internal route is removed;
  * detects foreign routes, marker-only wrong-prefix-set conflicts and preceding-rule shadowing;
  * is idempotent on re-apply;
  * preserves internal reachability while external is blocked for `disable`;
  * survives provider veth delete/recreate (new ifindex) with no wrong-provider egress and recovers.
* A direct guard probe: unicast default + `unreachable` default coexist in one table; the unicast
  route wins while present; removing it returns "No route to host".
* The source-specific FIB candidate is rejected:
  * a more-specific main route captures the constrained source;
  * for a destination with no more-specific route, the source-specific `unreachable` guard did block
    forwarded traffic (no provider egress; `route get` failed), so the earlier guard-failure claim
    was a test artifact;
  * the target `route add ... from` parser is not target-verified, and eliminating the more-specific
    capture would require another mechanism.
* Provider-facing transfer addresses are not internal: PB source to PA's transfer address did not
  egress PA, and the reverse did not egress PB.
* Health checks now verify the internal table and source rules; internal-route loss reports
  `incomplete`, and overlap/catch-all shadowing is detected.

## 4. What the prototype does not demonstrate

* EdgeOS 3.0.1, the 4.14.54-UBNT kernel, the target MIPS iproute2 or ER-X hardware.
* Hardware offload honouring multi-table RPDB.
* The production config engine (priority 500, `exists`/`existsEffective`, commit/rollback, boot).
* An event-driven monitor; the test re-applies routes manually after recreation.
* Automatic mirroring of dynamic BGP internal routes; the test installs the exact internal routes
  directly.
* Automatic local source selection; the test binds sources explicitly.
* Remote provider transit or Internet reachability.
* Non-Ethernet/point-to-point forwarding; only route installation forms are in scope for the
  architecture phase.

## 5. Key interpretation

The generic-Linux prototype establishes that the **mechanism** is sound and that the broad
suppressor and source-specific FIB alternatives are insufficient for the strict contract. It does
not establish that the target firmware implements the same lookup/forwarding behavior. The
architecture phase therefore recommends the internal-whitelist model with named target gates; it
does not claim hardware qualification.

See [`investigation/2026-11-27-experiments.md`](investigation/2026-11-27-experiments.md) for the
scenario table and environment caveats.
