# Phase VI-D — complete R1 A/B/A execution evidence

**Result:** dataplane A/B/A and every cleanup layer PASS; the adapter result file reports
`status: fail` only because the foreground tool command hit its two-minute cap and the process later
received SIGPIPE (rc=141) after all stages had completed. Acceleration: **UNKNOWN**. The Phase VI-C
report remains the historical record of its own FAIL and is not reclassified.

## 1. Authorization and binding

- Fresh authorization: `docs/r1-authorization-viid.json`; consumed at the production mutation
  boundary **2026-11-28T01:54:54Z**, then marked retired/consumed; not reusable.
- Executed binding: adapter
  `7b4322cab1c451f56934683c7c704ef55e39ebae6505c630dbcb9a1c8039f0db`, cleanup
  `3c329ca6b3dcd20e98f9a0dc0adff37db84c9a533954fadd18f70f5f84040c81`, install
  `dc5e4e4d26f1c5a4d528d50a98de0d1e297b85459709b30cbc85f6b7ffcd678f`, manifest
  `4be0761bcaa93092776ac2071d072a1969e5b1f3f2555d70d862cb2809d599c9`.
- Current files after the post-run harness corrections (script-independent runtime-directory
  fallback, `set -e` hardening): adapter
  `00d8880ba84132ae7392731b13f07cec6c881fefeb9fbadf43249befd7edca6a`, cleanup
  `3c329ca6b3dcd20e98f9a0dc0adff37db84c9a533954fadd18f70f5f84040c81`, install
  `dc5e4e4d26f1c5a4d528d50a98de0d1e297b85459709b30cbc85f6b7ffcd678f`, manifest
  `1d1b0b4393ac1671c2bef522b72c030159ecbaa640da6287faa100fab8f09e63`; these are not the
  executed binding.
- Topology: production ER-X over the existing permitted lab VXLAN, explicit controller
  interface/gateway override, pinned controller MACs, no firewall change.

## 2. Timeline

| Time (UTC) | Stage | Result |
|---|---|---|
| 01:53:07–01:53:49 | standalone A1 | PASS 20/20 matching, 10/10 control |
| 01:54:11–01:54:32 | in-session preflight | PASS (fingerprint, protected=5, table 41913=2, BGP, containment) |
| 01:54:32–01:54:54 | in-session A1 | PASS 20/20 + 10/10 |
| 01:54:54 | mutation boundary | crossed; authorization consumed |
| 01:54:54–01:55:05 | deploy | runtime directory, install/cleanup hash-verified |
| 01:55:05–01:55:30 | B | matching 0/20, control 10/10; exact rule body; terminal lookup |
| 01:55:30–01:55:35 | rule removal | exact deletion, verified absence |
| 01:55:41–01:56:02 | A2 | matching 20/20, control 20 (cumulative) |
| 01:56:02–01:56:10 | timer teardown + runtime-directory cleanup | PASS |
| 01:56:10 | controller cleanup + final audit | PASS |
| after 01:56:10 | adapter exit | rc=141 (SIGPIPE; external tool cap), recorded as a harness failure |

## 3. Dataplane

| Phase | Matching | Control | Status |
|---|---:|---:|---|
| A1 | 20/20 | 10/10 | PASS |
| B | 0/20 | 10/10 | PASS (rule effective) |
| A2 | 20/20 | 20 (cumulative) | PASS (restoration) |

Forwarding-path checks passed in A1/B/A2 (router MAC next hop, hop limit decrement, no direct L2,
no off-link, no wrong-provider packet). The observation is for this tested lab-VXLAN topology; no
claim of software-only or hardware-accelerated forwarding is made.

## 4. Cleanup (independent results)

| Layer | Result |
|---|---|
| Exact RPDB rule deletion | PASS (`cleanup_rc=0`) |
| Verified rule absence | PASS (count 0 after removal) |
| A2 dataplane restoration | PASS before any teardown |
| Recovery timer teardown | PASS (timer not active) |
| Runtime-directory cleanup | PASS (safe mode: path/type/owner/mode validated, top-level files/symlinks only, verified absent) |
| Controller endpoint cleanup | PASS (namespaces/macvlans/processes absent; temporary VXLAN peer removed) |
| Protected state | rules 10410–10414 = 5; table 41913 = 2 routes; unchanged |

Raw captures, addresses and run logs remain outside the repository.

## 5. Acceleration classification and limits

- Acceleration is **UNKNOWN**: `/dev/hwnat0` is absent, no vendor FOE tool exists, the op-mode
  statistics are unavailable and dmesg carries no FOE lines; no FOE write, flush or ioctl was
  performed.
- No claim is made that the lab-VXLAN path was software-forwarded. A successful R1 with unknown
  acceleration state establishes observed forwarding for this topology only; it does not close G1.
- The result-file `fail` is a harness artifact (external SIGPIPE after completion); the stage log and
  result JSON retain every PASS. The experiment is reported as: dataplane PASS, cleanup PASS,
  adapter-result FAIL (external signal), no retry.
- The in-session window measured 119 s against the 120 s authorization bound; a future grant should
  allow teardown margin.
