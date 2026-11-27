# Phase VI-A disposition — SADR architecture and dataplane feasibility review

**Status:** architecture review in progress. Phase V-C is accepted as an accurate empirical record.
R1 remains **NOT RUN**. The outstanding conditional R1 authorization is **suspended** pending this
review. No firewall exception is authorized or created. All Phase V-C evidence and implementation
work is preserved. PR #1 remains draft, open and unmerged.

## 1. Disposition of Phase V-C

- Phase V-C harness corrections, regression evidence, containment results and the production
  firewall root-cause analysis are accepted.
- R1 is **NOT RUN**; no production rule, timer, runtime directory or device mutation was performed.
- The conditionally renewed R1 authorization is suspended. No R1 retry is authorized in Phase VI-A.
- No firewall exception is authorized. The server-VLAN `SERVERv6_IN-30` firewall block is a
  production-policy finding, not a SADR product defect.
- PR #1 remains draft/open/unmerged; no tag, release, merge or deployment.

## 2. Phase VI-A objective

Reassess whether RPDB is the appropriate implementation of RFC 8678-style SADR on the ER-X
(EdgeOS 3.0.1, Linux 4.14.54-UBNT, MT7621), without assuming the existing RPDB choice or native
source-specific FIB is optimal. SADR itself is not under reconsideration.

## 3. Authorization boundary

Authorized: research, read-only target inspection, isolated controller-side experiments and
documentation. Not authorized: production route/RPDB/firewall/interface/forwarding/offload/package/
boot/persistent configuration mutation; R1, R2, merge, release or deployment. Any target-side
mutation needed to establish a capability must first be reported with its exact experiment,
containment mechanism, rollback procedure and required authorization.

## 4. Deliverables

- Source-backed architecture decision record (ADR-0002).
- Target capability matrix.
- Reproducible isolated RPDB vs native source-specific FIB results.
- Comparative implementation assessment.
- Hardware-offload risk analysis and revised target qualification plan.
- R1 topology reconsideration without a production firewall modification.
- Recommendation and explicit unresolved assumptions/maintainer decisions.

## 5. Current architecture state (preserved)

ADR-0001 accepted RPDB with a global internal whitelist table and per-policy provider tables.
The broad `main suppress_prefixlength 0` model was rejected; the native source-specific FIB
candidate was rejected for v0.1.0 after a more-specific main route captured the constrained
source. The target kernel has `CONFIG_IPV6_SUBTREES=y` and `CONFIG_IPV6_MULTIPLE_TABLES=y`
(Verified target source). Hardware offload honouring the routing model remains unverified.
