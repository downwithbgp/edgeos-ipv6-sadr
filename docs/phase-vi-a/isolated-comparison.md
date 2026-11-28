# Phase VI-A — isolated RPDB vs native source-specific FIB comparison

**Environment:** generic Linux 6.8 host, privileged Debian stable-slim container, iproute2 6.15.0.
**This is Verified (generic Linux), not EdgeOS/target evidence.** The exact target kernel/iproute2
results are in `target-capability-matrix.md`; target source-specific forwarding remains unverified.

## 1. Reproduction

```bash
REQUIRE_NETNS_TEST=1 bash test/integration/run-in-docker.sh
```

Observed in Phase VI-A:

```text
netns: pass=145 fail=0
r1-sim: pass=10 fail=0
```

The suite builds two simulated providers, internal networks, a dual-prefix client, a more-specific
external route inside an internal prefix, and captures on provider/internal interfaces. It exercises
ICMP, UDP and TCP; ICMP alone is not treated as dataplane proof.

## 2. RPDB models

### Broad `main suppress_prefixlength 0` (rejected)

The broad model leaked whenever a more-specific route existed in `main`:

| Probe | Result |
|---|---|
| 9: PA source to Internet B | egress PB (wrong provider) |
| 10: PB source to Internet A | egress PA (wrong provider) |
| 11: PA source to configured internal with a more-specific PB `/64` | egress PB (wrong) |

The rule-level terminal guard does not fix a selected more-specific route. `suppress_prefixlength 0`
suppresses only the default; a more-specific main route survives.

### Internal-whitelist model (retained)

The strict model uses `from S lookup internal`, `from S lookup provider`, and `from S unreachable`
with table-level guards. It passed the packet paths:

- probes 13–18: correct provider for PA/PB, wrong-provider containment, internal via IR;
- probes 19–22: nested `/64` source precedence, transfer-address containment;
- probes 23–29: UDP/TCP, local bound sources, external/internal preservation;
- probes 30–37: provider/internal route loss and restoration, fail-closed state, ownership,
  idempotency and interface recreation;
- probes 45–75: the production reconciler, exact rules/tables/guards, BGP-like update/withdrawal,
  monitor recovery and delete/restore (probes 45–46 are the pre-reconcile boot-guard probes).

Internal destinations were preserved even with the deliberate more-specific PB route in `main`;
no wrong-provider packet was observed. The table-level guard probe independently showed the
unicast/default pair fails closed when the intended route is removed.

## 3. Native source-specific FIB candidate (rejected)

Candidate B installed `default from PA`/`default from PB`, source-specific `unreachable` defaults,
and source-specific internal routes in `main`:

- probes 38–39: normal PA/PB provider forwarding passed;
- **probe 40: PA source to the configured internal prefix egressed PB** because the more-specific
  PB `/64` in `main` captured the source before the less-specific source-specific route;
- probe 41: connected internal still passed;
- probe 42 (paired control, before the provider default is removed): a destination with no
  more-specific route still used the PA source default; probe 44 (after removal) shows the
  source-specific `unreachable` guard (no PA/PB egress; `No route to host`);
- probe 43: the more-specific route still captured the PA source after the PA provider default was
  removed.

This falsifies candidate B as a strict SADR implementation. The destination-first Linux FIB lookup
(`ip6_fib.c`: destination trie first, source subtree only inside a matched destination node) is the
root cause; source specificity never outranks a longer destination prefix. RFC 9079 §1.3/§4 require
destination-first ordering of a source-specific routing domain (the §4 MUST binds implementations of
that Babel extension; source-first ordering can loop); Linux's destination-first lookup is that
ordering, so the observed behavior is the specified semantics, not a Linux quirk to be worked around.

## 4. The only potentially safe native variant

A native FIB implementation would need to mirror **every BGP-learned destination route per source
prefix** (with the source's provider next-hop), add source-specific internal overrides for every
more-specific external route under an internal prefix, and maintain per-source guards. That is a new
control plane with BGP update/withdraw coupling, route ownership and a route count of
`BGP prefixes × source policies`. It is not exposed by the target UBNT/Quagga daemons. It was not
implemented or run in Phase VI-A; it is recorded as a future experiment only if the architectural
decision is reopened.

## 5. What this does and does not prove

**Proven (generic Linux):** the broad main suppressor is unsafe; the RPDB internal-whitelist
prevents the tested cross-provider/internal leaks and fails closed; the native source-specific FIB
candidate is captured by a more-specific main route.

**Not proven:** EdgeOS 3.0.1/4.14.54-UBNT dataplane; target MIPS iproute2 parser execution; target
source-specific forwarding; target HNAT fast-path behavior; arbitrary production state; a future
per-source BGP-mirroring native variant.

The target route usage text shows `from` only in the `route get` synopsis (the route-add `from`
parser is upstream-4.14 Strongly indicated, not target-verified), the target GPL kernel has
`CONFIG_IPV6_SUBTREES=y` (and `IPV6=m`), and the target currently has no source-specific routes
(`from_routes=0`). Those are availability/usage facts, not suitability evidence. The target lab VXLAN (`vxlan<lab>`/controller
`vxlan<lab-peer>`) route lookup is an existing permitted path for a future R1; it is not a routing-model
result.
