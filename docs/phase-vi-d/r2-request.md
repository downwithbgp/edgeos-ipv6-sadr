# Phase VI-D — narrow R2 authorization request (provider table and terminal guard)

**Status:** prepared, NOT AUTHORIZED, NOT EXECUTED. R2 is not run in this phase.

## 1. Objective

Establish, with synthetic resources, that a source-dependent RPDB lookup selects the intended
provider table, that the provider route is used, and that the terminal guard rejects traffic when the
provider route is unavailable — without any fallback to the main table.

## 2. Reused infrastructure

The successful Phase VI-D lab-VXLAN topology: production ER-X over the existing permitted lab VXLAN,
explicit controller interface/gateway, pinned controller MACs, synthetic selector
`fd42:901::a1/128`, UDP probes, independent controller-side captures, device-local timer and exact
cleanup. No production firewall or interface change.

## 3. Synthetic resources (only)

- Two managed provider tables in the extension range (e.g. `10001` and `10002`).
- One synthetic provider default/route in each table, and a terminal `unreachable default` guard.
- One source rule pair selecting the provider table (and the internal table as in the R1 model).
- One synthetic destination prefix and one control source from the lab `/64`.
- No use of table `41913`, rules `10410–10414`, `main`, vendor routes or production prefixes.

## 4. Tests and pass conditions

| Test | Pass condition |
|---|---|
| Source-dependent lookup | the constrained source selects the intended provider table (route-get and packet capture agree) |
| Provider route selection | traffic egresses the synthetic provider next hop; no wrong-table packet |
| Terminal rejection on withdrawal | with the provider route removed, the guard blocks external traffic; no main-table fallback |
| More-specific main-table route injection | a synthetic more-specific `main` route does not capture the constrained source |
| Nonmatching traffic | an unmanaged source is unaffected |
| Cleanup/restoration | exact rules/tables/routes deleted and verified; endpoint cleanup pass |

## 5. Containment and rollback

- Bounded mutation window, device-local timer armed before the rules, exact deletion and verification,
  foreign-rule refusal, no table/rule flush.
- Controller-side captures and a single timeline; raw evidence outside the repository.
- Abort and clean up on any production invariant change, wrong-provider packet or unverified removal.

## 6. Authorization required

A fresh candidate-bound authorization naming the exact tables, rules, routes, selector, destination,
window, cleanup and stop conditions. It must forbid: table `41913`/rules `10410–10414`, `main` and
vendor routes, firewall changes, interface/VXLAN/BGP changes, HWNAT changes, package installation,
migration, reboot and subsequent experiments. No R2 is authorized by this document.
