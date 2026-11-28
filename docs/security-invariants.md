# Security and correctness invariants


> **v0.1.0 refinements:** `docs/v0.1.0-refinements.md` is normative and supersedes conflicting text in this document.

**Status:** v0.1.0 implementation and off-device failure evidence complete; target qualification
pending. This file states the invariants the implementation preserves; see
[`v0.1.0-evidence.md`](v0.1.0-evidence.md). The terminal guard cannot protect against arbitrary
privileged deletion of all rules/tables or malicious foreign state; the boot window remains a named
non-guarantee until hardware qualification.

## 1. Primary invariant

For every source prefix covered by an **effective** policy:

> At every supported interruption point, traffic from that source is on its intended provider, on
> the previous effective provider, or blocked. It is never forwarded through an unauthorized
> provider.

The invariant covers configuration commits, route loss, interface down/delete/recreate, provider
next-hop loss, commit-confirm rollback, package upgrade and abrupt process termination.

A source that has never been constrained may use native routing until its first policy is fully
verified. During that first application a temporary terminal guard blocks it. The boot window before
the first reconciliation is a named non-guarantee unless an early boot guard is implemented and
verified.

## 2. Safe failure versus reachability failure

A failure to preserve routing safety and a failure to restore reachability are distinct outcomes:

* **Safety failure:** a constrained source uses an unauthorized provider. This is a release-blocking
  bug.
* **Reachability failure:** the intended provider path is unavailable; the source is blocked. This is
  reported as `protected`/`dependency-unavailable`/`incomplete`; it is the required failure mode
  when a valid provider route cannot be established.

Failing closed is preferred to unintended egress. The health output must distinguish the two.

## 3. Mutation ordering

The implementation must be safe if killed between any two operations.

### First policy for an unconstrained source

1. Verify table/rule ownership and shadowing.
2. Install a temporary `from S unreachable` rule. The source is blocked.
3. Ensure the internal table and per-prefix guards.
4. Install the provider table's terminal `unreachable default`.
5. Install the provider route (and connected mirror if needed). If this fails, leave the guards and
   temporary block; report `protected`/`incomplete`.
6. Install the permanent internal and provider rules before the temporary guard.
7. Verify; remove the temporary guard only after verification.
8. If the commit fails before the policy becomes effective, restore the previous effective state and
   remove the temporary guard. If restoration fails, leave the source blocked and report `failed`.

### More-specific policy under an existing broader policy

Keep the broader policy effective; build the new table/guard/route; install the new rules in the
inactive pair; perform a structural/ownership/table check. No temporary guard is needed because the
broader policy remains valid.

### Update an existing policy

Build the new table/guard/route first. Install the new rules in the inactive pair; perform a
structural/ownership/table check; remove the active pair and table. The old pair remains effective
until removal; if interrupted before cleanup, it still handles and reconciliation completes the
transition. Post-swap safety rests on the new table guard.

### Delete a policy intentionally

Remove the provider route but keep the terminal guard and rules; remove the source rules (intentional
unconstraining); remove the table/guard. If interrupted after the provider route removal, the source
is blocked. The final state is intentional native routing.

### Disable

Keep the internal and provider rules; withdraw the provider route; keep the terminal guard. Internal
traffic works; external traffic is blocked. Deleting the policy is the explicit way to restore
native external routing. A disabled policy MUST remain disabled across interface recreation; the
provider route MUST NOT be restored.

### Package removal

Refuse while configured policies exist. If no policies exist, remove only extension-owned objects.
Never silently remove an active policy in a way that permits cross-provider egress.

## 4. Failure scenarios

| Scenario | Required state | Required report |
|---|---|---|
| Provider route removed | Guard active; no provider egress | `protected` |
| Provider interface down/absent | Guard active; no provider egress | `dependency-unavailable` or `protected` |
| Next hop unresolved | Route may exist; packets not delivered; no fallback | `dependency-unavailable` / reason `next-hop-unresolved` |
| Interface recreated (new ifindex) | Guard active; owned routes repaired; no wrong-provider egress | `incomplete` then `effective` |
| Disabled policy + interface recreation | Provider route stays absent; internal works; external blocked | `disabled` |
| Internal real route removed | Per-prefix guard blocks; no provider fallback | `protected` / `incomplete` |
| Foreign route in managed table | No destructive cleanup; conflict reported | `conflict` |
| Marker-only route with wrong prefix set | Conflict; not deleted | `conflict` |
| Foreign earlier rule matching S | Policy not effective; no claim of enforcement | `shadowed` |
| Process killed between mutations | Source on previous/intended path or blocked | `incomplete`/`protected` on restart |
| Commit-confirm rollback | Previous effective policy restored or source blocked | `effective` or `protected` |
| Package removal with policies | Refused | clear `prerm` message |
| Boot before first reconciliation | Native routing may apply; named non-guarantee | documented; early guard gate |

## 5. Ownership and destructive-action rules

* The extension owns only its internal table, provider tables, exact source rules, exact routes and
  the route protocol marker.
* No `ip rule flush`, no `ip route flush table`, no unrelated `main` mutation.
* A destructive action requires table + exact prefix set + protocol marker + manifest agreement. A
  marker-only match is not ownership.
* A foreign object in a managed table or managed priority range is a conflict and is refused; it is
  never deleted. A foreign rule before the range that can match a configured source is reported as
  `shadowed`; the policy is not effective, but the extension may install its owned objects so
  migration can proceed.
* The manual table 41913 and rules 10410–10414 are migration inputs, not objects to seize.
* Shadow detection must consider overlap, `from all` and rules whose match is not source-only. A
  conservative false positive is acceptable.
* Connected routes on policy egress/next-hop interfaces are not internal; provider-facing transfer
  links are never auto-whitelisted. A gateway covering route on a policy interface causes the
  exception to be rejected, not mirrored.

## 6. Non-guarantees

* No end-to-end provider health or remote transit verification.
* No RFC 6724 source-selection control for unbound local sockets.
* No zero-exposure boot window unless the early guard service is implemented and verified.
* No automatic discovery of internal BGP prefixes; exact exceptions are operator-owned.
* No claim for untested firmware, hardware offload paths or other platforms.
* No claim that a route/guard proves connectivity.

## 7. Verification mapping

| Invariant | Test |
|---|---|
| No wrong-provider egress | netns negative probes and captures; positive leak controls |
| Fail-closed on provider route loss | netns provider-route-removal test |
| Fail-closed on internal route loss | netns internal-route-removal test |
| Interface recreation safety | netns delete/recreate with continuous probes and captures |
| First-application safety | netns temporary-guard test |
| Ownership/collision refusal | netns foreign-route/marker-only tests |
| Shadow detection | netns preceding-rule test |
| Idempotency | netns re-apply rule-count test |
| Config API correctness | unit/mock and emulated-engine tests (v0.1.0) |
| Boot ordering | emulated and hardware tests (v0.1.0) |
| Offload correctness | hardware forwarded TCP/UDP (v0.1.0) |

The current generic-Linux results are in
[`investigation/2026-11-27-experiments.md`](investigation/2026-11-27-experiments.md). They are not
hardware qualification.
