# Configuration transaction consistency review

**Status:** off-device review with simulated working/active configurations. **Actual EdgeOS
configuration-engine semantics remain Unverified.** No router commit, rollback or commit-confirm was
performed.

## 1. Model under test

- `reconcile-working` is the configuration `end:` action. It reads the **working** configuration,
  plans, applies and verifies; it does not wait for the commit to become active.
- The monitor reads the **active** configuration outside a commit. A failed or rolled-back commit
  does not change active configuration, so the monitor converges back to the active state.
- A lock serializes commit-hook and monitor mutations. The desired generation is re-read before
  mutation; a changed generation restarts the bounded attempt loop.
- The journal is diagnostic. Recovery recomputes from active config plus observed state; it never
  blindly replays journal operations.

## 2. Simulated cases and results

`test/unit/t/09-transaction.t` (15 assertions) exercises:

| Case | Result |
|---|---|
| Working commit applies a policy while active state is different | Working guard/lookup installed |
| Active reconcile after a failed/rolled-back commit | Active policy restored; working guard removed |
| Process failure after kernel mutation, before activation | Active reconcile converges to active state |
| Two monitor-style reconciles concurrently | Both succeed under the lock; one guard remains |
| Status in active mode while working differs | Reports active policy and effective health |

The test uses a split working/active fake API. This is a simulation, not EdgeOS evidence.

## 3. Findings

1. **The commit hook can apply before activation.** If a later commit step fails, the kernel may carry
   the working policy while the active configuration is older. The monitor is the convergence
   mechanism; the window until it runs is a boot/commit exposure.
2. **Active configuration is authoritative for the monitor.** A stale desired snapshot is rejected
   by generation re-read; it cannot overwrite a newer committed configuration.
3. **Concurrent commit and monitor are serialized.** The lock prevents interleaved plans; the
   second reconciler re-observes and is idempotent.
4. **Process interruption is recoverable.** Journal/manifest state plus active re-read converge;
   foreign objects remain refused.
5. **Commit-confirm/rollback is not target-proven.** The simulation assumes a failed/rolled-back
   commit leaves active configuration unchanged. EdgeOS `existsEffective`, rollback and confirmed
   commit timing require target tests.
6. **Simultaneous interface and SADR changes are not adequately simulated.** The fake API cannot
   reproduce vendor interface ordering, netdevice creation/removal or a partially applied subtree.
   This is a hardware requirement.

## 4. Required target checks

Add to hardware gate H2/H3:

- working vs active visibility during and after commit;
- failed commit after the SADR `end:` hook, with packet capture and monitor convergence;
- commit rollback and commit-confirm timeout;
- monitor running during a commit;
- interface and SADR changes in the same commit;
- process interruption after mutation but before activation;
- stale working/active snapshots and concurrent monitor cycles;
- foreign-state preservation through every path.

Until those checks pass, the implementation claims convergence **by design and simulation**, not
verified EdgeOS transaction semantics.
