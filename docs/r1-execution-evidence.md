# R1 execution evidence (Phase V-B continuation)

**Result: R1 NOT RUN (ABORTED in the harness before the rule).** No production rule persisted; no
timer, runtime directory or namespace remained. Table `41913` and rules `10410–10414` are unchanged.
Raw captures and the run directory stay outside the repository.

## 1. Real-target read-only preflight — PASS

- Run directory outside the repository; UTC window `2026-11-27T17:19:50Z` onward.
- Result: 4/4 steps pass:
  - framed identity: `EdgeRouter.ER-e50.v3.0.1.5862409.250924.1407`, kernel `4.14.54-UBNT`,
    fingerprint `0896090dabbf415be33b51fe09e1edad5605e65febb95db9293bbe6b2d667440`;
  - operator management attestation;
  - read-only backups;
  - adapter read-only preflight (RPDB, protected state, cleanup mechanism, containment).
- No rule, timer, runtime directory, namespace or device executable was created by the preflight.

## 2. Mutating attempt — ABORTED before the rule

- Authorization window: short-lived, created at execution initiation; approval reference recorded.
- Adapter preflight logged `17:20:38Z` identity, `17:20:39Z` RPDB, `17:20:46Z` cleanup mechanism and
  containment. The log stops there; phase A1 was never reached.
- The harness recorded the canary step `fail`; its captured output contained the EdgeOS login banner
  ahead of any JSON. The harness cleanup and cleanup verification passed.
- State verified after the attempt (read-only): `21031` rules = 0; protected rules = 5; table `41913`
  routes = 2; cleanup timer = not-found; `/run/sadr-r1-*` = none; local test namespaces = none;
  no host test links.
- Classification: **harness/adapter failure, not SADR product behavior.** The exact uncaught step
  between the containment check and phase A1 is not yet identified; the banner in the harness output
  shows an SSH stdout leak, and the adapter has no ERR trap. No RPDB rule was installed.

## 3. Authorization boundary

The mutating run crossed the conditional execution boundary (it began the harness's mutating path);
the authorization is therefore consumed. No automatic mutating retry was attempted.

## 4. Corrected harness committed with this evidence

- Shared framed identity acquisition/parsing (banner-tolerant, exactly one frame, field/duplicate/
  truncation/transport checks) used by `profile.sh`, `r1-canary.sh` and `run.sh`.
- `--preflight` mode in the profile and adapter that exercises the real identity, authorization,
  artifact, privilege and baseline path and stops before namespaces, timer, deployment or mutation.
- Operator key and known_hosts bound for root-context SSH.
- Deterministic candidate finalization (`qualification/finalize-candidate.sh`) and candidate-hash
  validation in the qualification tests.
- Frozen device executables: adapter `cf82ad4c439c6e22069c1977858b896b5f3e4684fbef2c883c15d613e337f084`,
  cleanup `0681a467d9d2e5739cb1c45bc3c968d532efa21245322d1156a4bda5e11b8883`,
  install `dc5e4e4d26f1c5a4d528d50a98de0d1e297b85459709b30cbc85f6b7ffcd678f`.

## 5. Required before another mutating attempt

1. Redirect every SSH/`rsudo` stdout in the adapter (only the final JSON on stdout) and add an
   ERR/xtrace log so an uncaught command is attributable.
2. Move privileged runtime deployment after A1, so a baseline/topology failure is PRECHECK_FAILED
   rather than an aborted mutating run.
3. Bind the shared identity library hash in the authorization candidate (dependency binding).
4. Rerun the targeted gates and the real-target preflight; then request a new mutating authorization.

R1 remains NOT RUN for SADR product behavior; no R2 work is authorized.
