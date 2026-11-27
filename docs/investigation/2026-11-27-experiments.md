# Experiments — 2026-11-27

**Environment:** generic Linux, not EdgeOS. The results are **Verified (generic Linux)** only.

## 1. Artifact and environment

| Item | Value |
|---|---|
| Harness commit | `4ed46fc` (`test: strengthen SADR proof of concept after review`) |
| Host | Linux `6.8.0-149-generic`, x86_64, Docker 29.9.0 |
| Container | `debian:stable-slim`, privileged, network-isolated |
| iproute2 | `6.15.0` |
| tcpdump | `4.99.5` |
| Python | `3.13.5` |
| Test kernel | host 6.8 (not the target 4.14.54-UBNT) |

Reproduce:

```bash
make test                                  # unprivileged checks
REQUIRE_NETNS_TEST=1 make test-netns       # privileged container
```

Final result:

```text
netns: pass=65 fail=0
```

The unprivileged suite also passed, including the documentation-address hygiene check and its
negative self-tests.

## 2. Topology

```text
Internet A --- PA --- ER --- PB --- Internet B
                        |
                   +----+----+
                   |         |
                   IR        CL (dual-prefix client)
```

All addresses are documentation space. The harness uses:

* Provider A allocation `2001:db8:a000::/56`; transfer `2001:db8:aa00::/64`.
* Provider B allocation `2001:db8:b000::/56`; transfer `2001:db8:bb00::/64`.
* Client sources `2001:db8:a000:2::2` (within A), `2001:db8:a000:1::2` (nested /64) and
  `2001:db8:b000:1::2` (within B).
* External A `2001:db8:aaaa::/64`; external B `2001:db8:bbbb::/64`.
* Connected internal `2001:db8:100::/64`; configured internal `2001:db8:200::/56` with a
  more-specific external route `2001:db8:200:2::/64` via PB.
* ER loopback sources `2001:db8:a000::1/128` and `2001:db8:b000::1/128`.

PA and PB install simulated source-address-validation drops for the other provider's prefix.
Captures are taken on the provider-facing links and the ER internal link. ICMP, UDP and TCP are
exercised; ICMP alone is not treated as dataplane proof.

## 3. Scenarios and results

### 3.1 Baseline and positive controls

| Scenario | Result |
|---|---|
| PA source reaches Internet A | PASS; PA egress observed |
| PB source reaches Internet B | PASS; PB egress observed |
| Both sources reach connected internal | PASS; ER internal link observed |
| PA source to configured internal with a more-specific PB route in `main` | Leak observed on PB (deliberate positive control) |
| PB source to Internet A | Leak observed on PA (deliberate positive control) |

The leak controls prove that a later zero on the wrong provider is meaningful; absence of traffic is
not mistaken for enforcement.

### 3.2 Broad `main suppress_prefixlength 0` model (current proof of concept)

The broad model installs a rule-level terminal guard after a `main` lookup and a dedicated provider
table. It leaked in every tested case where a more-specific route existed in `main`:

| Scenario | Observed |
|---|---|
| PA source to Internet B | PB egress (wrong provider) |
| PB source to Internet A | PA egress (wrong provider) |
| PA source to the configured internal prefix | PB egress because the more-specific `/64` route bypassed the internal `/56` |

This reproduces the known limitation of the current runtime RPDB construction and rejects the broad
main-table suppressor as the target architecture.

### 3.3 Internal-whitelist model (recommended)

The model uses a global internal whitelist table and per-policy provider tables, each with terminal
guards, and rules `from S lookup internal` then `from S lookup provider`.

| Scenario | Result |
|---|---|
| PA source to Internet A; PB source to Internet B | PASS; correct provider, no wrong-provider capture |
| PA source to Internet B; PB source to Internet A | Blocked/contained; no packet on the wrong provider |
| Both sources to connected internal | PASS; internal link observed |
| Both sources to configured internal `/56` with a more-specific PB `/64` in `main` | PASS; internal link observed, no PB capture |
| Nested `/64` source policy inside the `/56` | PASS; `/64` policy blocks external while internal still works |
| UDP and TCP from PA/PB sources | PASS; expected provider captures; internal UDP PASS |
| Local ER socket bound to each provider address | PASS; correct provider egress |
| Provider route removed | FAIL-CLOSED; no PA/PB egress, health `protected` |
| Real internal route removed; guard remains | FAIL-CLOSED; no provider egress, health incomplete/protected |
| Foreign route in a managed table | Detected as `conflict`; not deleted |
| Marker-only route with a wrong prefix set | Detected as `conflict` |
| Foreign rule before the managed range | Detected as `shadowed`, not `effective` |
| Re-apply the model | Rule count unchanged; no duplicate rules |
| `disable` | Internal path works; external blocked; health `disabled` |
| Provider veth delete/recreate (new ifindex) | Down during the gap; no wrong-provider egress; routes restored; traffic recovers |
| First application | Temporary guard blocks the source before permanent rules; the lab removes it after installing the permanent rules; the production reconciler verifies before removal |

The interface-recreation test observed both failure and recovery (`down=5 up=7`) and zero
PB-sourced packets on PA during the gap. The provider route and connected mirror were restored
manually by the test's reconciliation step; the production event monitor is still a v0.1.0 deliverable.

### 3.4 Source-specific FIB candidate (rejected)

Source-specific routes in `main` were tested on generic Linux:

* `default from PA` / `default from PB` routes worked for normal forwarding.
* A more-specific external route in `main` captured the constrained source: PA source to the
  configured internal prefix egressed PB.
* After deleting the PA source-specific provider default, the source-specific `unreachable default`
  did guard forwarded traffic for a destination with no more-specific route: the recorded probe saw
  no PA or PB egress, and `ip -6 route get` failed with "No route to host". This is **not** a
  control-plane/dataplane divergence.

Candidate B is rejected for v0.1.0 because the more-specific-route capture remains, the target
`ip` `route add ... from` parser is not target-verified, and eliminating the capture would require
additional mechanisms that erode the simplicity advantage. The guard result above is recorded as a
positive observation, not as a reason to choose B.

### 3.5 Direct guard probe

In an isolated netns with a dummy interface:

```text
table 100:
    default via <next-hop> dev d0 metric 1024 proto 194
    unreachable default dev lo metric 4096 proto 194
```

`ip -6 route get <destination> from <source>` selected the unicast default while it was present. After
deleting the unicast route, the same lookup returned `RTNETLINK answers: No route to host`. A
per-prefix unicast/unreachable pair behaved the same way. This validates the table-level guard used by
the recommended model.

## 4. What the experiments prove

**Proven (generic Linux):**

* The broad suppressor model leaks through more-specific main routes.
* The internal-whitelist + provider-table model preserves internal destinations and prevents the
  tested cross-provider leakage.
* Table-level guards fail closed when the intended route is absent.
* Nested source policy ordering can be implemented with RPDB priorities.
* Source-bound local sockets and forwarded TCP/UDP follow the source policy.
* Ownership, shadow, idempotency, disable and recreation scenarios can be detected and reconciled.

**Not proven:**

* EdgeOS 3.0.1, the 4.14.54-UBNT kernel, the target MIPS iproute2 or ER-X hardware.
* Hardware offload honouring multi-table RPDB.
* The production config-engine priority/visibility behaviour.
* A full event-driven monitor; the lab re-applies routes manually after recreation.
* Automatic mirroring of dynamic BGP internal routes; the lab configures the exact internal routes
  directly.
* Automatic local source selection; the lab binds sources explicitly.
* Remote provider transit or end-to-end Internet reachability.

## 5. Environment limitations

* veth links, not real WAN/PPPoE/VLAN/tunnel hardware.
* Simulated source-address validation with ip6tables; captures are the primary evidence.
* Tcpdump capture start/drain windows are test synchronization, not product timing.
* The lab uses a 6.8 host kernel; target-specific claims are sourced from the exact vendor kernel
  source and remain `Strongly indicated` or `Unverified` as labelled.
