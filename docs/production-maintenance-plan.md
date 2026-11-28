# Production maintenance-window and deferred test plan

**Status:** planning only. None of these tests is authorized or executed.

## 1. Classification

| Test | Class | Main risk | Default disposition |
|---|---|---|---|
| Guard-only rule canary | canary | global RPDB rule; unique source | possible first canary after isolation proof |
| Package install with no SADR policy | maintenance/staged | services, boot integration, package side effects | maintenance window or separate staged authorization |
| One synthetic SADR policy commit | maintenance | configuration engine, monitor/guard, route/rule state | after install and test topology proof |
| Config rollback/commit-confirm expiry | maintenance | partial/rolled-back configuration state | maintenance window |
| Cold boot/reboot | maintenance | boot ordering, forwarding window, management access | maintenance window; operator present |
| Guard failure injection | maintenance | guard missing/failure propagation | maintenance window; independent management mandatory |
| Simultaneous interface+SADR change | maintenance | interface/route ordering, loss of connectivity | maintenance window |
| Global hardware offload change | maintenance | dataplane/CPU/forwarding | separate authorization; may be deferred |
| Production BGP withdrawal | maintenance | loss of routes/session | defer unless isolated test peer |
| Production VXLAN interruption | maintenance | tunnel/control-plane impact | defer; use isolated test topology |
| High-rate traffic/event storm | maintenance | CPU/memory/control-plane pressure | isolated test topology or deferred |
| Resource exhaustion | maintenance | management loss | deferred; never on production |
| Global forwarding change | maintenance | all traffic/management | deferred; not part of v0.1.0 |

## 2. Required plan per maintenance test

Every maintenance plan must state:

- expected outage/degradation and affected services;
- maximum duration and hard deadline;
- prerequisites (package/script hashes, baseline, independent management, operator presence);
- exact mutation commands and exact rollback commands;
- observability checks and stop thresholds (`docs/production-observability.md`);
- required recovery access and watchdog status;
- evidence collection and PASS/FAIL/BLOCKED/NOT RUN criteria;
- residual risks and the authorization ID.

No test may rely on an unverified serial console or a single SSH session.

## 3. Deferred until dedicated hardware or a controlled maintenance window

- cold boot/reboot and boot-window packet capture;
- guard failure injection and vendor boot-service dependency changes;
- global offload enabled/disabled functional qualification;
- production BGP withdrawal/restoration and VXLAN interruption;
- event storms, resource exhaustion and high-rate forwarding;
- migration of manual table `41913`/rules `10410–10414`;
- any configuration change that could affect production forwarding, firewall, BGP, VXLAN, sysctl or
  management.

These remain release-blocking where they are required for the claimed supported configuration. No
release criteria are lowered because dedicated hardware is unavailable.

## 4. Installation/activation guardrail

If package installation cannot be proven to leave SADR inactive (no policy, no guard beyond the
empty-config state, monitor reading active config), installation itself is maintenance-window-only.
Do not test upgrade/removal casually on a device with active production SADR policy. See
`docs/production-installation-plan.md`.
