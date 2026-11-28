# Production migration planning

**Status:** planning only. Migration is not authorized and has not been executed. The production
manual table `41913` and rules `10410–10414` remain protected foreign state.

## 1. Coexistence facts

- The manual rules at `10410–10414` precede SADR-managed priorities `20000–21031`; for overlapping
  source selectors the manual path wins and shadows SADR.
- Manual table `41913` carries VXLAN routes and is also used by manual rules; SADR provider tables
  `10001–19999` and internal table `10000` must not adopt it.
- The production baseline has no `protocols ipv6-sadr`, no proto `194`, no managed-priority rules and
  no managed tables; production SADR state is currently absent.
- Existing VXLAN, BGP and firewall behavior must not be changed as a side effect of migration.

Simultaneous presence of both mechanisms does **not** establish equivalent forwarding semantics.
Each constrained source must be verified on the SADR path before its manual rule is removed.

## 2. Incremental adoption

1. **Inventory and map:** list every constrained source prefix and its intended provider; map to a
   SADR policy. Do not publish production addresses or configuration.
2. **Preflight:** verify no source/prefix/table/rule collision; confirm manual table/rules and VXLAN
   remain untouched; verify independent management and rollback.
3. **Stage SADR while manual rules remain:** install/activate policies only after separate
   authorization. Manual rules shadow the new rules; verify structural state and packet paths while
   the old path still carries production traffic.
4. **Coverage proof:** every constrained source has a verified SADR policy and terminal guard; no
   unknown source falls through; no synthetic test prefix leaks.
5. **Per-source cutover:** use the exact temporary guard/rollback process in `docs/migration-plan.md`;
   remove a manual rule only after independent evidence of the new path.
6. **Retire manual state only after all source cutovers** and explicit review; table `41913`/rules
   `10410–10414` are never flushed or repurposed as test fixtures.
7. **Rollback:** restore manual rules first, verify their path, then remove SADR policy/state through
   the configuration engine; never use blanket flush or reboot.

## 3. Production-specific blockers

- No dedicated test topology/independent recovery has been verified.
- Package installation/activation and target configuration-engine behavior are unqualified.
- BGP/VXLAN/firewall interactions and hardware offload behavior are unverified.
- Manual rule precedence must be measured on the target, not inferred.
- Migration must wait for the release blockers and separate maintenance-window authorization.

## 4. Non-actions

No production configuration, table, rule, interface, firewall, BGP, VXLAN, sysctl, offload or
package state was changed in this phase. The existing manual configuration remains the production
path.
