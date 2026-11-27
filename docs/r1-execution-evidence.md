# R1 execution evidence (Phase V-B / V-C / VI-C)

**SADR product status: R1 EXECUTED ONCE (Phase VI-C, lab-VXLAN topology). Phase V-C A1 baseline:
FAILED at the production IPv6 firewall; no production mutation was attempted in V-C.** In Phase VI-C
the single authorized lab-VXLAN R1 crossed the production mutation boundary once; A1 and B passed on
the tested path, A2 was not run because the cleanup gate failed on the experiment's runtime
directory (removed and verified manually), and acceleration classification is UNKNOWN. No RPDB rule,
device timer, runtime directory, package, configuration change or controller namespace remains.
Table `41913` and rules `10410–10414` are unchanged. Raw captures and run directories remain outside
the repository.

**Phase VI-A/VI-B disposition:** Phase V-C is accepted; the Phase V-C conditional authorization was
suspended in VI-A and retired without execution/consumption in VI-B. **Phase VI-C execution:** one
authorized lab-VXLAN R1 (not a V-C retry), window 2026-11-27T22:29:59Z–22:31:40Z, mutation boundary
crossed 22:30:45Z; A1 20/20 + control 10/10; B matching 0/20 + control 10/10; A2 NOT RUN; exact rule
deletion verified; runtime directory removed and verified; protected rules/table/BGP/defaults/memory
invariants checked; adapter result status `fail` (cleanup gate only). Executed binding: adapter
`6d22e6b0a304eb6ad8f2cc6629670c7128bb1a26be23e395a6941d93b03c61ce`, manifest
`5e6cc0cbaa5d5c5929c18359105d4c26261b15dce95bc248de378e72cb95f8d4` (record
`docs/r1-authorization-viic.json`). The current manifest/adapter were regenerated after the run for
the cleanup correction (adapter
`9cc33b2cdae732a7d30abd603d2e0cde5d2d406476f11572285607988fd3f97a`, manifest
`055044eb19c417250a5160e2fe74fbda58afe9a2379bd662abd27dc37ecdc377`) and are **not** the executed
binding. No firewall exception is authorized or created; PR #1 remains draft; a fresh
candidate-bound authorization is required for any future execution.

## 1. Phase V-B abort — root cause

The previous mutating attempt aborted in Stage 0 controller preparation, before any target
deployment:

- **Failing command:** `ip netns exec <ns> sysctl -qw net.ipv6.conf.<if>.accept_redirects=0
  net.ipv6.conf.<if>.send_redirects=0`.
- **Exit status:** `sysctl` returned **1**; `set -euo pipefail` terminated the adapter with status 1.
  Linux exposes no IPv6 `send_redirects` sysctl; the key is absent under
  `/proc/sys/net/ipv6/conf/<if>/`. Reproduced in a disposable controller namespace: the two-key
  `sysctl` set `accept_redirects` and then failed on `send_redirects`.
- **Stage and privilege:** controller-local topology, after namespace/macvlan creation and before the
  device runtime directory, timer or rule. It ran as root/CAP_NET_ADMIN on the controller under the
  existing `sudo -E` mechanism; no target privilege or mutation was involved.
- **Result contamination:** the EdgeOS login banner was SSH **stderr**. `profile.sh` captured the
  adapter with `2>&1` and then parsed stdout; the banner was therefore included in the failure
  detail. The banner was not the abort cause.
- **Coverage gap:** the generic-Linux R1 simulation built its own topology and never executed Stage 0;
  `--preflight` stopped before namespace creation. No test exercised the redirect sysctl or asserted
  that adapter results arrive through a dedicated file.
- **Latent topology defect:** Stage 0 assigned the control source as `C/64`, which made the
  destination `D` on-link in the sender namespace and would bypass the ER-X at Layer 2. The
  correction uses `C/128` and an explicit `D/128` route via the router link-local.

## 2. Phase V-C corrections

- **Stage split:** the adapter now runs controller privilege validation, Stage 0 (namespaces,
  uniquely tagged macvlans, synthetic addresses, C/128 + D/128 via router, generators, captures),
  Stage 1 (read-only identity/RPDB/containment/invariant preflight) and Stage 2 (A1), then the
  mutation stages only for `--execute`. `--baseline` runs the actual Stage 0–2 implementation used
  by R1 and never deploys device files, arms a timer or changes the target RPDB.
- **Structured results:** the adapter writes `adapter-result.json` atomically (schema 2) with UTC
  stage records, failure class/stage/command/exit/source, probes, boundary timestamp, resources and
  cleanup outcome. The harness reads that file; stdout is not authoritative. SSH uses `-q` and
  separate stderr/subprocess logs; the identity helper keeps banner text out of the framed response.
- **Instrumentation:** explicit stage enter/complete records, an ERR trap for uncaught commands,
  explicit failure classification, and a final cleanup audit. No unrestricted shell tracing.
- **Manifest:** `docs/r1-execution-manifest.json` binds the 11 execution-critical files; its
  `manifest_sha256` is generated and bound in the authorization candidate. The profile verifies the
  manifest before the canary path; the finalizer derives adapter/cleanup/install hashes from it.
- **Diagnostics/invariants:** the BGP parser now uses the summary totals (neighbours/established);
  the preflight and post-A1 checks compare protected rules, table `41913`, default routes, BGP and
  available memory.

Manifest at the V-C run: `aec39bda36bc25a422cfcd334f8e9ca2e080a1a64b2cd777ce0adaec3cf00b5f`.
Phase VI-C executed the lab-VXLAN R1 with adapter
`6d22e6b0a304eb6ad8f2cc6629670c7128bb1a26be23e395a6941d93b03c61ce` and manifest
`5e6cc0cbaa5d5c5929c18359105d4c26261b15dce95bc248de378e72cb95f8d4`; the current files were
regenerated after the run for the cleanup fix (adapter
`9cc33b2cdae732a7d30abd603d2e0cde5d2d406476f11572285607988fd3f97a`, manifest
`055044eb19c417250a5160e2fe74fbda58afe9a2379bd662abd27dc37ecdc377`) and are not the executed
binding. The V-C evidence above remains bound to the hashes as executed.
Frozen device executables: adapter `14d4d94195e3ac992d886e6f79cd9166cde789e7b4869316bdaa9ba6b84328bc`,
cleanup `0681a467d9d2e5739cb1c45bc3c968d532efa21245322d1156a4bda5e11b8883`,
install `dc5e4e4d26f1c5a4d528d50a98de0d1e297b85459709b30cbc85f6b7ffcd678f`.

## 3. Real-target read-only preflight — PASS

The refactored profile/preflight path passed 7/7 at the real ER-X: manifest, framed identity,
management attestation, read-only backups, adapter preflight, Stage 1 and cleanup audit. No
mutation, timer, runtime directory or namespace was created.

## 4. Official A1 baseline (Stage 0–2) — EXECUTED, BLOCKED BY THE PRODUCTION FIREWALL

Run outside the repository; UTC window `2026-11-27T18:44:49Z` to `18:45:37Z`.

| Stage | Result | Observation |
|---|---|---|
| privilege | pass | root, netns/macvlan/capture tools available |
| stage0 | pass | unique namespaces/macvlans; selector; C/128; D/128 via router; generators/captures |
| stage1 | pass | identity/fingerprint; protected rules 5; table `41913` 2 routes; BGP 2/1; containment |
| stage2 (A1) | **fail** | matching 0/20, control 0/10 delivered; adapter stops before forwarding/invariant assertions |
| cleanup | pass | controller namespaces absent; no listener/capture residue |

Packet-path observations from the retained captures:

- E1 emitted the 20 matching + 10 control UDP probes toward `<D>`; the capture contains 33 frames
  (30 UDP plus three ICMPv6 neighbour messages). Every UDP probe used the ER-X's Ethernet MAC as the
  next hop and hop limit 64; no direct E1→E2 MAC frame was observed.
- E2 received **0** frames and the destination listener logged **0** sources.
- The matching/control probes reached the ER-X ingress but were not forwarded.

Firewall evidence (read-only):

- Hook mapping: ingress `switch0.65` → `SERVERv6_IN`.
- Rule `SERVERv6_IN-30` drops destination addresses in the `IPV6_LOCAL_NETS` set. The test
  destination is in the server-VLAN `/64`, so it is in that set.
- Exact counter: **107 → 137 packets (+30)** across the final A1 run (the earlier official runs
  moved 47 → 77 and 77 → 107; the 1-matching/1-control diagnostic moved the same counter 45 → 47).
  The drop is therefore the production IPv6 firewall, not an ND, capture or harness failure.

The adapter's automated invariant check ran before the delivery assertion and passed (diagnostics:
`A1 invariants pass: protected rules, table 41913, BGP, default routes and memory unchanged`).
The read-only post-run check confirms: `21031` rules **0**; protected rules **5**; table `41913`
routes **2**; BGP neighbours/established **2/1**; timer **not-found**; runtime directories **0**;
host test namespaces **none**.

Classification: **target-platform firewall policy, not SADR product behavior.** The harness and
adapter executed Stage 0–2 as designed; the A1 success criterion was not met because production
forwarding policy drops the synthetic destination.

## 5. Authorization and mutation boundary

Phase V-C did not create a fresh mutating authorization and did not cross the production mutation
boundary: the A1 result records `mutation_boundary_crossed=false`, no device runtime directory,
timer or rule was created, and no B/A2 phase was reached. The Phase V-B mutating authorization was
consumed by that abort (the harness had begun the mutating path); no automatic mutating retry was
made. The conditionally renewed R1 authorization is **not consumed** by this A1 failure.

## 6. Smallest necessary change

The existing server-VLAN hairpin topology cannot satisfy A1 without a production firewall change.
The smallest proposed change is a temporary, exact IPv6 firewall exception on `switch0.65` for the
synthetic test tuple only (selector/control source to the test destination, UDP/54321), scoped to
the test window and automatically removed with the rule cleanup. An approved alternative endpoint
or an existing permitted test path would avoid the firewall change. Both require explicit
maintainer authorization; the production firewall was not modified.

**Phase VI-A update:** R1 remains suspended and this exception is not authorized.
`docs/phase-vi-a/r1-topology-alternatives.md` evaluates the isolated lab ER-X and the existing
permitted lab-VXLAN path first; the firewall exception remains a last option requiring separate
justification and authorization.

## 7. Gates and artifacts

- `make lint`: pass.
- Unit: 619/619 pass.
- Qualification: profile/authorization gates pass (including the baseline stdout-vs-result-file
  test); cleanup 19/19; identity 14/14; manifest 4/4.
- Privileged generic-Linux netns: 145/0; R1 simulation 10/0, including the controller redirect-sysctl
  regression.
- Raw captures, run directories and authorization documents remain outside the repository.
- CI results for the corrective commit are recorded after the push.

R1 remains NOT RUN for SADR product behavior; R2, package installation, production migration,
firewall changes and persistent configuration changes remain unauthorized.
