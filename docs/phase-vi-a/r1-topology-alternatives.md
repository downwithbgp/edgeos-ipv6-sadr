# Phase VI-A — R1 topology alternatives (no production firewall change)

**Status:** R1 is suspended. No firewall exception is authorized or created. This document evaluates
future R1 topologies only; Phase VI-A authorizes research, read-only target inspection and isolated
controller-side experiments, not R1.

## 1. What blocked Phase V-C

The V-C A1 baseline's Stage 0/1 passed; A1 delivered 0/20 matching + 0/10 control because the
production server-VLAN firewall `SERVERv6_IN-30` drops forwarded destinations in `IPV6_LOCAL_NETS`.
The ER-X's `VYATTA_FW_IN_HOOK` maps `switch0.65` to `SERVERv6_IN`; no packet-path or routing-model
defect was observed (the A1 traffic was dropped at the firewall and did not exercise the routing
model). No production mutation was made.

## 2. Target observation relevant to an alternative

Read-only target discovery found the existing **lab VXLAN**:

- the target has a `vxlan<lab>` interface whose underlay remote is the controller; the controller has
  the peer `vxlan<lab-peer>`;
- `ip -6 route get <lab-destination> from <synthetic-source> iif vxlan<lab>` on the target selects
  `dev vxlan<lab>` (on-link lab path);
- `VYATTA_FW_IN_HOOK` has **no** `vxlan<lab>` chain; `VYATTA_FW_OUT_HOOK` is empty and
  `VYATTA_POST_FW_FWD_HOOK` accepts; this is an existing permitted forwarding path, independent of
  `SERVERv6_IN-30`.

Exact addresses, VNI/underlay values and raw output remain outside the repository. The target
`ip -d link` rendering is not reliable on this iproute2 generation; the route lookup and hook
mapping are the usable evidence.

## 3. Options

| Option | Production mutation | Firewall change | Strength | Recommendation |
|---|---|---|---|---|
| 1. Isolated lab ER-X (same firmware) | none on production | none | exact platform/hardware; full R1 A/B/A and offload tests in a lab | **Preferred** |
| 2. Production ER-X on existing lab VXLAN (`vxlan<lab>`/`vxlan<lab-peer>`) | one RPDB rule only, under a fresh R1 authorization | none | production ER-X dataplane, existing permitted path; no server-VLAN firewall | **Acceptable if product ER-X is required** |
| 3. Dedicated test VLAN/port with exact firewall exception | test rule and firewall exception | yes, separately authorized | strong path if isolated lab unavailable | Only if 1–2 unavailable; justify and authorize separately |
| 4. Controller-only generic-Linux lab | none on target | none | mechanism evidence only; not target-platform | Use for comparison, not target qualification |

## 4. Why option 2 is not a firewall exception

Option 2 uses the existing lab VXLAN forwarding path. It does not add, remove or modify a firewall
rule; it does not weaken `SERVERv6_IN` or any production policy. The single RPDB canary rule is
still a production routing mutation and therefore needs a fresh R1 authorization and all existing
containment/deadline/cleanup requirements. The V-C conditional authorization remains suspended.

## 5. Required conditions for any future R1

- Re-establish the exact target identity/fingerprint and frozen executable manifest.
- Fresh short-lived authorization and separate mutation-boundary consumption.
- Read-only containment and production-invariant preflight.
- A1 in the actual execution session; matching 20/20, control 10/10, router next-hop/hop-limit/no
  direct L2/no upstream escape.
- Device-local timer armed and verified before the rule; exact rule deletion/verification; B/A2
  packet counts; timer/runtime/namespace cleanup.
- No automatic retry after the mutation boundary; stop on production degradation or containment
  failure.

The isolated lab ER-X is the preferred route because it exercises the exact hardware/firmware
without production routing or firewall state. The lab VXLAN is the smallest production-ER-X
alternative and avoids a firewall exception; it is not authorized in Phase VI-A.
