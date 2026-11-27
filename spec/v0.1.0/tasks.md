# v0.1.0 implementation plan

**Status:** implementation complete off-device; independent review and final gates pending.

| Task | Status | Evidence |
|---|---|---|
| T0 contract reconciliation | complete | `docs/v0.1.0-refinements.md`, normative docs |
| T1 production module/CLI | complete | `22ee8fb`; L0 suites |
| T2 templates/services | complete | `b3c12ea`; structural checks |
| T3 unit/property/failure | complete | `934b97f`; 599 assertions |
| T4 packaging/CI | complete off-device | `2d25ea6`; lifecycle 13, artifact 17, reproducible hash |
| T5 production netns | complete | `c2304db`; 145 pass / 0 fail |
| T6 hardware/migration design | complete as plans | `docs/hardware-qualification-plan.md`, `docs/migration-plan.md` |
| T7 independent reviews/final gates | in progress | v8 |

**Branch:** `feat/v0.1.0`, checked out in the main workspace. `main` remains the architecture
baseline at `4af7bb4` and is preserved in history.

## 0. v0.1.0 refinements (normative; supersedes conflicting text below)

The plan review is accepted as a blocking correction. The implementation follows these refinements;
where the earlier sections differ, this section wins.

* **T0 contract reconciliation** is the first task: update `docs/requirements.md`,
  `docs/security-invariants.md`, `docs/testing-strategy.md`, `docs/operations.md`,
  `docs/platform-compatibility.md`, `AGENTS.md` and the ADR so they agree on the refinements below.
  No production code starts until this is done.
* **Boot guard** parses `/config/config.boot` directly for `protocols ipv6-sadr` source prefixes
  before `vyatta-router.service`; it writes exact `/run/edgeos-ipv6-sadr/boot-guards.json` intent
  before installing terminal guards. No persistent snapshot is required. The monitor runs
  `After=vyatta-router.service` and reads active configuration via the verified
  `listActiveNodes`/`returnActiveValue` API. Working configuration is used only by the commit action.
* **Terminal guard:** permanent `from S unreachable` at slot 6. Provider tables also carry
  `unreachable <internal-prefix>` guards at a higher metric so a missing internal rule/table cannot
  send an internal destination to a provider.
* **Active/staging pairs:** pair A `0/1`, pair B `2/3`; one active, one staging. Install/verify the
  new table and guards, install the staging pair, structural/ownership/table check, remove the old
  pair. If staging is before old it takes effect after the new table is verified; if after, old
  remains until removal. Old pair is previous-effective fallback; terminal and provider internal
  guards cover missing tables. Test both orders; post-cutover route lookup verifies the selected
  table; packet path is L1/hardware.
* **Disabled creation** installs no provider route from the first mutation. **Prefix shrink/removal**
  installs the new guard first and removes the old guard last. **Internal exception removal** removes
  the real route before the guard. **Nested-policy deletion** falls to the enclosing policy (not
  native); test/document.
* **Internal-interface classification** is re-evaluated every reconcile. Policy interfaces and their
  bridge/VLAN ancestors/children are excluded; unknown interfaces are not trusted.
* **Orphan guards** are removable only when they match exact tuples recorded in boot-guard intent and
  are absent from desired state; otherwise `orphaned-guard`/conflict. A manifest alone never
  authorizes deletion.
* **Health** adds `orphaned-guard`; `disabled` overrides `protected`; overall severity is
  failed > conflict > orphaned-guard > shadowed > dependency-unavailable > protected > incomplete >
  effective; disabled only when all are disabled; mixed disabled/effective is effective. Exit codes
  0,2,3,4,5,6,7,8,9.
* **Observed state:** route/rule text; `ip -j -d link` for link attributes only. Treat
  `FIB table does not exist` as an absent managed table.
* **Packaging** lands before the installed-package netns run. **prerm remove** refuses on saved or
  active policy config or live extension objects; upgrade is allowed.
* **Hardware/migration execution** is post-v0.1.0; this phase produces plans only. ADR milestones
  M4/M5/M6 are marked post-v0.1.0.
* **Tests** add: disabled creation; both pair orders; prefix shrink; nested deletion; exception
  removal; internal-interface dynamic ancestor/child exclusion; provider lookup present/internal
  lookup missing; table disappearance; missing terminal default; process kill at each mutation;
  commit-confirm simulation; shadow overlap/from-all/non-source; orphan repair; foreign preservation.

## 1. Scope

Implement the approved internal-whitelist + provider-table RPDB architecture as a production
reconciler with native EdgeOS configuration, operational diagnostics, tests and Debian packaging.
Produce a review-ready v0.1.0 implementation and a hardware qualification/migration plan.

**Not in this phase:** installation on the production router, migration of the manual table 41913 /
rules 10410–10414, release publication, release tags, or an EdgeOS compatibility claim.

## 2. Invariants

1. Once a source prefix is covered by an effective policy, traffic is on its intended provider, on
   the previous effective provider, or blocked. It is never on an unauthorized provider.
2. A managed table never contains foreign state; a foreign route/rule causes refusal, not deletion.
3. Connected routes are not implicitly trusted. Only connected routes on explicitly declared
   internal interfaces are mirrored; provider-facing interfaces are excluded.
4. A terminal source-specific `unreachable` rule is permanently installed after each policy's
   applicable lookups. It protects against table disappearance, a missing table default and partial
   rule installation.
5. Desired state is the active/working EdgeOS configuration; netlink events trigger reconciliation
   but are not the state database. Observed kernel state is verified after every mutation.
6. A manifest or journal never authorizes destructive action. Ownership is verified from the kernel
   plus the desired/expected prefix/rule set.
7. Reachability is not inferred from a FIB entry. Health separates intent, realization,
   effectiveness and reachability.

## 3. Decisions

### 3.1 Language and components

Use **Perl 5.24** (already present on the target) plus the existing `ip` command; no new runtime,
daemon framework or routing daemon. No route/rule JSON dependency: parse the stable text output and
the distinct error cases (for example `FIB table does not exist`). Core modules only: `JSON::PP`,
`Digest::SHA`, `IO::Select`, `Fcntl`, `Socket`, `IPC::Open3`.

Components:

```text
src/lib/EdgeOS/IPv6SADR.pm     prefix/config/validation, kernel observation, planning,
                               ownership, state/journal, reconciliation, health
src/vyatta-ipv6-sadr           CLI: validate-working, reconcile-working, monitor,
                               boot-guard, status, policy, route, health
templates/protocols/ipv6-sadr  native configuration templates
templates/op/show/ipv6-sadr    native show commands
systemd/                       monitor and early boot guard units
test/unit/                     Perl Test::More unit/property tests, fake API/ip
test/integration/              production netns tests, failure injection
debian/                        Architecture: all package
```

### 3.2 Configuration model

```text
protocols {
    ipv6-sadr {
        internal-interface switch0.10
        internal-interface switch0.20
        destination-exception 2001:db8:100::/64

        policy provider-a {
            source-prefix 2001:db8:a000::/56
            source-prefix 2001:db8:a000:1::/64
            next-hop 2001:db8:aa00::1
            interface eth0
            table 10001
            description "Provider A transit"
        }

        policy provider-b {
            source-prefix 2001:db8:b000::/56
            next-hop 2001:db8:bb00::1
            interface eth1
            description "Provider B transit"
        }
    }
}
```

* `internal-interface`: explicit trust boundary for connected routes. Unknown interfaces are not
  trusted. An interface used by a policy (`interface`, or a next-hop covering interface) cannot be an
  internal interface.
* `destination-exception`: exact internal prefix. Its exact main-table route is mirrored; a
  more-specific route is not. The exception is rejected if its route is on a policy interface, has
  ECMP/ambiguous next hops, or its gateway is not covered by an internal/connected route.
* Policy: one or more canonical source prefixes; exactly one egress form (next-hop + interface, or
  interface-only); optional explicit table; optional description/disable. Link-local next hops
  require an interface. Global next hops require an interface for deterministic resolution.
* Policy names: `[A-Za-z0-9][A-Za-z0-9_.-]{0,63}`. Exact duplicate source prefixes across policies
  are rejected; overlapping prefixes are allowed and ordered longest-first.

### 3.3 RPDB layout

* Internal table: `10000`, extension-owned.
* Provider tables: explicit `10001–19999`, or deterministic FNV-1a allocation; collision is a
  configuration error.
* Priority: `20000 + (128 - prefix_length) * 8 + slot`.
  * slots `0/1`: active internal/provider pair;
  * slots `2/3`: standby pair;
  * slot `6`: terminal source guard (`from S unreachable`);
  * slot `7`: reserved.
  * Range `20000–21031`.
* Activation: install the terminal guard first, then internal-table guards/routes, then the provider
  table guard/route, then the active pair. On update, install the new table/guards/route, then the
  free pair, verify, then remove the old pair. If the free pair is lower priority it takes effect
  after the new table is verified; if higher, the old pair remains until removal. The terminal guard
  is permanent.
* Disable: keep internal/provider rules and the terminal guard; withdraw the provider route. Internal
  reachability remains; external is blocked. A disabled policy stays disabled across recreation.
* Delete: remove the provider route (table guard remains), remove active/standby pairs, remove the
  terminal guard last, then clean the table. No window of native routing while the source is still
  covered.
* The terminal guard does not protect against arbitrary privileged deletion of all rules/tables or
  malicious foreign state. That is an explicit limit.

### 3.4 Desired/observed state

* **Working configuration** (`reconcile-working`, commit action): read via
  `my_cli_shell_api` `listNodes`/`returnValue`; API diagnostics are hard failures; absent is only a
  silent negative.
* **Active configuration** (`monitor`, startup, status): read via
  `my_cli_shell_api listActiveNodes`/`returnActiveValue` outside a commit. A successful commit
  updates active config; a failed commit does not. The monitor does not use a stale desired snapshot
  as authority.
* **Committed snapshot**: written after a successful `reconcile-working` apply/verify and refreshed
  by the monitor from active config. It is the early-boot guard's input, not the monitor's authority.
* **Observed state**: `ip -6 rule show`, `ip -6 route show table <id>`, `ip -6 route show exact`,
  `ip -6 link show`. Parse text; treat `FIB table does not exist` as an absent managed table, not a
  generic failure.
* **State files**: `/var/lib/edgeos-ipv6-sadr/{desired.json,manifest.json,journal.json,status.json,lock}`.
  All writes atomic (temp + rename). The manifest records owned tables/prefixes/active pairs but is
  advisory; the journal records the planned transaction but never authorizes deletion.
* **Reconciliation**: lock, re-read desired/observed, plan, verify ownership, write journal, apply,
  verify, write manifest/status, remove journal. A crash leaves the journal; the next run re-reads
  active config and observed state and completes or safely reverts. No blind journal replay.
* **Staleness**: the monitor checks the active-config generation/hash at plan time and again before
  apply; if it changed, it aborts and re-reads. The lock serializes commits and monitor mutations.
* **Retries**: up to three bounded post-apply verifications with short backoff; persistent mismatch
  reports `failed` and leaves guards in place.

### 3.5 Internal destination classification

* Connected routes are mirrored **only** for interfaces in `internal-interface`.
* Provider-facing transfer networks are never auto-whitelisted. An interface referenced by any
  policy is excluded; if it is also declared internal, the configuration is invalid.
* Explicit exceptions are exact. Withdrawal of the exact route leaves the per-prefix guard and reports
  `protected`/`incomplete`; intentional removal of the exception removes the route/guard and may
  intentionally send the destination to the provider policy.
* Overlapping internal prefixes are allowed; the more-specific exact route/guard wins. ECMP or an
  ambiguous exact route is rejected (guard only, conflict/incomplete report).
* Interface rename/recreation: connected routes are re-derived from observed kernel routes; a
  missing/renamed internal interface reports dependency unavailable. Provider routes are repaired
  after recreation.

### 3.6 Ownership and crash consistency

* Managed table = extension range; every route must carry `proto 194` and be in the expected/owned
  prefix set. A foreign route or an unexpected proto-194 prefix is a conflict; no deletion.
* Managed rule = priority range and exact source/action/table/preference. A foreign rule in the range
  is a conflict; a pre-range rule that can match the source is `shadowed`, not deleted.
* Destructive action requires table + exact prefix/type + protocol + desired/manifest agreement. The
  manifest alone is insufficient.
* Journal/pending snapshots are diagnostic; recovery recomputes the plan from active config and
  observed state, with the same ownership checks.
* Package removal refuses while `/config/config.boot` contains a `protocols ipv6-sadr` policy.

### 3.7 Health

Separate fields:

* **intent**: configured/valid/disabled/invalid.
* **realization**: owned rules/tables/routes/guards present, interface present.
* **effectiveness**: no shadow/conflict; terminal guard; rule/table precedence; provider/internal
  route presence.
* **reachability**: `unverified` by default; `next-hop-unresolved` only from neighbour state, never
  a claim of provider transit.

Health states: `effective`, `incomplete`, `dependency-unavailable`, `protected`, `shadowed`,
`conflict`, `failed`, `disabled`. Exit codes: 0 effective, 2 incomplete, 3 dependency, 4 protected,
5 shadowed, 6 conflict, 7 failed, 8 disabled (worst applicable). Human and `--json` output.

### 3.8 Source selection

Forwarded, explicitly source-bound local and unbound router-originated traffic are distinct. The
implementation does not modify `gai.conf`, labels, RAs or DHCPv6. Target source-selection tests and
RFC 6724/8043/8028/8678 analysis are qualification deliverables; no automatic optimal source claim.

## 4. Tasks

### T0. Contract reconciliation and target probes

Update the normative documents with the refinements in §0: internal-interface classification,
permanent terminal guard, provider-table internal guards, active-config monitor, `/run` + config.boot
boot guard, orphan guards, health semantics, prerm and test gates. Record the verified
`listActiveNodes`/`returnActiveValue` methods, `ip -j -d link`/route-text behaviour and `FIB table
does not exist` handling. Gate: no contradictory normative clause; evidence labels.

### T1. Production module and CLI

Implement prefix/address normalization, working/active config adapters, validation, table/priority
allocation, observed-state parsing, ownership/orphan checks, planning, terminal guards,
provider-table internal guards, active/staging application, journal/manifest/status, health, route
lookup, boot guard and monitor. Split pure planning/validation from kernel mutation.

**Verification:** `perl -c`, unit tests, fake API/ip; `FIB table does not exist` handled distinctly;
no route/rule JSON.

### T2. EdgeOS templates and services

Implement `protocols ipv6-sadr` templates (priority 500, end/delete actions, validation), `show` op
templates, monitor service (`After=vyatta-router.service`, `RuntimeDirectory`) and boot guard
(`Before=vyatta-router.service`, `After=local-fs.target`, parses `/config/config.boot`, writes
`/run` intent). Emulation/hardware gates for priority/visibility/delete/rollback and guard ordering.

**Verification:** template syntax; emulated commit where possible; service unit validation; boot
guard fixture tests; target ordering documented as a gate.

### T3. Unit/property/failure tests

Cover normalization, longest-prefix ordering, allocation/exhaustion, validation, planning, ownership,
idempotency, conflicts, malformed input, overlaps, generated transitions, disabled creation, prefix
shrink/removal, nested-policy deletion, exception removal, internal-interface dynamic exclusion,
provider-table internal guards, orphan guards, shadow variants (overlap/from-all/non-source), process
kill at every mutation boundary, commit-confirm rollback simulation and foreign-state preservation.

**Verification:** `prove`/`make test`; every injected failure leaves the source blocked or on a
previous effective path; no foreign deletion.

### T4. Packaging and CI

Debian `Architecture: all`; preinst firmware/kernel guard; module/scripts/templates/op/systemd/state
installation; postinst `RuntimeDirectory`/enable; prerm refusal (saved and active config plus live
objects, remove only); postrm cleanup; reproducible build controls; CI package build/artifact
validation. Packaging lands before the installed-package netns run.

**Verification:** `dpkg-buildpackage -us -uc -b`; contents/depends; negative firmware/removal tests;
reproducibility hash; package installed in a disposable container.

### T5. Production netns integration

Run the **installed package** (or staged package rootfs) in the namespace lab with real packets:
initial apply, disabled creation, update (both pair orders), provider failure, internal withdrawal,
internal-rule loss, table disappearance, missing terminal default, interface recreation, nested
prefix changes/shrink, monitor failure/restart, concurrent events, orphan-guard repair, existing
TCP/UDP flows and continuous negative probes.

**Verification:** 0 wrong-provider packets; internal destinations blocked rather than provider-routed
under partial rules; recovery converges; no foreign objects modified.

### T6. Hardware qualification and migration design

Write `docs/hardware-qualification-plan.md` and `docs/migration-plan.md`: safety, backups,
independent management, commit/boot/reboot, recreation, kernel 4.14 RPDB, offload on/off, established
flows, real TCP/UDP, MTU/PMTUD, ICMPv6, BGP/internal mirroring, firewall/VXLAN interaction, CPU/memory;
manual table/rules untouched, coverage-first cutover, temporary guard, bounded rollback, continuous
monitoring. Hardware execution requires separate authorization.

### T7. Reviews and final gates

Independent implementation/test reviews; fix findings; run `make test`, production netns, package
build and reproducibility checks. No release/hardware/production-router action.

## 5. Acceptance criteria

* Production implementation, templates, op commands and services exist and pass lint/unit/property.
* Generic-Linux production netns suite covers the required transition/failure matrix with packet
  evidence; no wrong-provider leakage.
* Failure injection demonstrates fail-closed behavior and foreign-state preservation.
* Debian package builds reproducibly and its lifecycle scripts refuse unsafe removal/installation.
* ADR/docs/health/source-selection/hardware/migration gates are updated.
* Independent implementation/test reviews are completed; findings addressed.
* No hardware, production-router, manual-state or release action occurred.

## 6. Known risks and gates

* Config-engine priority 500, working/active visibility, delete and rollback behavior on the target.
* Early boot guard ordering and snapshot freshness; boot window remains a named non-guarantee until
  hardware qualification.
* Target kernel 4.14 RPDB semantics and hardware offload correctness.
* Active-config API availability/permissions outside a commit.
* Monitor event storms, self-generated events, lost notifications and resource cost on the ER-X.
* Dynamic BGP internal-prefix mirroring/withdrawal and ECMP handling.
* Source selection for unbound router traffic.
* The terminal guard cannot protect against arbitrary privileged deletion of all routing objects.
