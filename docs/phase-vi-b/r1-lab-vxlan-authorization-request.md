# R1 over the permitted lab VXLAN — authorization request (prepared, not authorized)

**Status:** PREPARED — NOT AUTHORIZED, NOT EXECUTED. R1 remains NOT RUN. The Phase V-C conditional
authorization is retired; this request requires a fresh, candidate-bound maintainer authorization.

**Related:** `qualification-plan.md`, `../r1-authorization-candidate.json` (retired),
`../r1-execution-manifest.json` (current executable binding), `../phase-vi-a/r1-topology-alternatives.md`.

## 1. Topology

- Target: the production ER-X (`EdgeRouter.ER-e50.v3.0.1.5862409.250924.1407`, kernel
  `4.14.54-UBNT`, fingerprint `0896090d…`), unchanged.
- Path: the existing lab VXLAN — target `vxlan<lab>`, controller peer `vxlan<lab-peer>`. The
  controller underlay and the lab `/64` are existing state; no new **target** interface, VLAN or
  firewall rule is created. The controller-side namespaces and macvlans are ephemeral, tagged per run
  and cleaned up by the adapter. `VYATTA_FW_IN_HOOK` has no `vxlan<lab>` chain (Verified (target),
  read-only).
- Test endpoints: controller-side namespaces with macvlans on the lab-VXLAN peer, a synthetic
  selector `fd42:901::a1/128` (synthetic ULA, verified unused in Phase V-C) and a destination/control
  pair derived from the lab on-link `/64`. The target must show both flows as on-link via
  `vxlan<lab>` in a read-only preflight.
- No production firewall exception is requested or created. No server-VLAN path is used.

## 2. Exact mutation scope

One RPDB rule only:

```text
ip -6 rule add from fd42:901::a1/128 unreachable pref <PREF>
```

No table, route, interface, forwarding, offload, package, boot or persistent configuration change;
no `main` or vendor object modification; no flush. The rule is installed by the existing
`r1-install.sh` under the candidate-bound hashes, with a device-local `systemd-run` timer armed
*before* the rule, a maximum window of 120 s including cleanup, and deletion by `r1-cleanup.sh`
(exact rule only; foreign/ambiguous rules refused; idempotent; deletion verified).

## 3. Independent packet observations

A1 (before the rule), B (with the rule) and A2 (after exact deletion):

- 20 matching probes (selector → destination via the router) and 10 control probes (a different
  source prefix) per phase; UDP probes only (the current adapter is UDP-only; adding TCP probes is a
  separate adapter change that must be implemented and re-hashed before execution); captures at the
  controller-side E1/E2 endpoints.
- Router-path proof: next-hop is the router MAC (not the destination MAC), hop limit decremented by
  one, no direct L2 delivery, no upstream escape (the destination `/128` route forces the router).
- Production invariants before/after: protected rules `10410–10414`, table `41913` route count,
  BGP neighbour state, default routes, available memory; any change aborts.
- Expected: A1 matching 20/20 and control 10/10; B matching 0/20 (the rule blocks the selector) and
  control 10/10; A2 matching 20/20 and control 10/10. The B phase proves the rule's effect on the
  software path only; it is not an offload test.

## 4. Rollback

`r1-cleanup.sh <selector> <pref>` deletes only the exact rule, verifies the deletion and closes the
device-local window under the same lock as the installer; the device timer is the independent
backstop; the runtime directory is removed and its removal verified. A failed verification is a
recovery failure and is reported, never ignored. No automatic retry after the mutation boundary.

## 5. Limitations of this environment

- **Not an offload test.** HNAT has no VXLAN handling, but decapsulation can pass the physical-RX
  FOE metadata to the inner skb (`skb->cb` is not cleared by `skb_scrub_packet`), and the target
  terminates the lab tunnel. Whether lab-VXLAN flows create FOE entries must be measured before any
  claim; if they are offloaded, this R1 must stop and cannot be treated as a software-path test.
  Either way it cannot establish hardware offload correctness (G1), stale-entry behaviour, provider
  withdrawal/restoration, real BGP dynamics, performance, reboot/module lifecycle or commit/rollback.
  Those require Environment A.
- One permitted path, not a provider path; one rule, bounded window; no R2.
- The current adapter derives the controller path from the IPv4 default route and the IPv6 default
  gateway. On the controller the lab VXLAN is **not** the default path, so the adapter needs an
  explicit topology override (a controller-interface/gateway parameter) before this request is
  executable. That change is not part of this phase; when made, the adapter hash and the execution
  manifest must be regenerated and this request reissued with the new candidate hashes.

## 6. Authorization requested

A fresh, candidate-bound authorization for exactly this scope:

- test id `R1-guard-only` (library-labelled; the topology is the lab VXLAN), one rule, selector and
  preference as bound in the candidate, maximum 120 s including cleanup;
- `not_after` set by the maintainer (UTC deadline);
- adapter/cleanup/install hashes bound to the regenerated execution manifest **after** the topology
  override is implemented and reviewed;
- independent controller-side observation, device-local timer, exact cleanup and verification;
- no R2, no second rule, no firewall change, no offload change, no production deployment.

Until that authorization exists, this request is inert. R1 remains NOT RUN.

## 7. What this request explicitly does not authorize

Production route/RPDB/firewall/interface/forwarding/offload/module/package/persistent changes; any
server-VLAN firewall exception; R2; production deployment; merge, tag or release; a claim of
hardware qualification or offload correctness.
