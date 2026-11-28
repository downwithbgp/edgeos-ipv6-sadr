# Migration and rollback plan

**Status:** design only. **Not executed.** The existing manual table `41913` and rules `10410–10414`
remain operational and must not be modified during v0.1.0 implementation. Migration is a separately
authorized activity.

## 1. Existing state and precedence

The manual proof of concept installs table `41913` and rules `10410–10414`. The SADR reconciler uses
provider tables `10001–19999` and source rules `20000–21031`. Because `10410–10414` precede
`20000+`, the manual rules **shadow** the new policies for overlapping sources. That is useful for
staging: the new policy can be installed and verified while the existing path remains effective.

Do not remove the manual rules until every constrained source has a configured, verified SADR policy
and cutover is explicitly authorized.

## 2. Preflight

1. Inventory every constrained source prefix and its intended provider; map each to exactly one
   policy. Record source prefixes that are intentionally not constrained.
2. Back up `/config/config.boot`, `ip -6 rule show`, `ip -6 route show table all`, the manual restore
   script and the package hash. Keep the backup off the router and on independent management.
3. Verify independent management connectivity (console or separate management interface).
4. Run `validate-working`, `reconcile-working --dry-run` and `status --json`; require no conflict,
   shadow or dependency finding that would make cutover unsafe.
5. Confirm the package version and service state; confirm the manual table/rules are unchanged.
6. Use `qualification/run.sh --plan` and the hardware harness to collect preflight/backup evidence;
   migration remains a separate authorization and is not part of the harness's automatic steps.

## 3. Staging

1. Install the package only with separate authorization.
2. Commit the policies while the manual rules still take precedence. Verify:
   - terminal guards exist for every constrained source;
   - internal/provider tables and guards exist;
   - health is `effective` apart from expected manual-rule shadowing;
   - no foreign object was modified.
3. Capture packet paths for each source. Traffic should still follow the manual path.

## 4. Per-source cutover

Cut over one source prefix at a time. Use a temporary fail-closed guard so removal of the manual
rule cannot expose native routing:

1. Install a temporary `from <source> unreachable` rule at a priority below the manual rules (for
   example `10409`), and verify it is effective.
2. Remove the corresponding manual rule (`10410–10414`) only for that source.
3. Verify the new SADR lookup rule is selected (`ip -6 route get ... from ...` and captures).
4. Remove the temporary guard.
5. Repeat for the next source. Stop on any wrong-provider packet or unexpected route.

The temporary guard is a migration artifact outside the reconciler's ownership range. It must be
removed after cutover and must not remain after the migration window.

## 5. Verification

- Every constrained source is verified by kernel lookup and packet capture.
- Internal destinations remain reachable and do not use a provider.
- No foreign rule/table was modified; compare before/after snapshots outside the managed ranges.
- Table `41913` and any remaining manual rules are untouched unless intentionally retired.
- Health reports no `conflict`, `orphaned-guard`, `shadowed` or `failed` state; expected
  `disabled`/`incomplete` states are explained.
- Continuous monitoring runs through the cutover window.

## 6. Rollback

Rollback is bounded and must restore the previous effective path:

1. Reinstall the backed-up manual rules/table entries first; they precede the SADR rules.
2. Verify the manual path with packet captures.
3. Remove the new policies through the configuration engine and let reconciliation remove only
   extension-owned objects.
4. Verify no extension-owned rules/routes remain and that table `41913` is exactly as recorded.
5. If independent management was lost, stop and use console access; do not guess.

Rollback must never flush the RPDB or a table. Foreign state is preserved.

## 7. Abort criteria

Abort on any wrong-provider packet, loss of independent management, unclassified rule/table change,
unexpected health conflict, or a packet path that cannot be verified. The default on uncertainty is
to keep the manual path or block the affected source, not to fall back silently.

## 8. Authorization

Migration changes production routing and is outside v0.1.0. It requires explicit operator
authorization, the hardware qualification evidence, an independent reviewer and a named rollback
window. This plan does not authorize any router action.
