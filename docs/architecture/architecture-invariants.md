# Architecture invariants (Phase VI-B)

**Status:** accepted architecture contract for the retained RPDB implementation. These invariants are
testable product contracts: each states what must hold, how the implementation enforces it, which
tests exercise it, and what remains unproven.

**Scope:** IPv6 only; the ER-X / EdgeOS 3.0.1 target and the generic-Linux lab. They apply to the
whole dataplane, **including hardware-offloaded flows**: an invariant that holds only on the software
path does not hold.

Evidence labels follow the repository vocabulary (Verified (target), Verified (target source),
Verified (generic Linux), Strongly indicated, Unverified).

## 1. Invariants

### I1 — No unauthorized provider egress

> For every source prefix covered by an effective policy, a packet from that source is forwarded on
> its intended provider, on the previous effective provider during a transition, or blocked. It is
> never forwarded through an unauthorized provider.

**Enforcement:** per-source RPDB rules select a source-specific provider table before the destination
lookup; the internal-whitelist table keeps internal destinations out of provider selection; the
provider table has an `unreachable` default guard; a terminal `from S unreachable` rule follows the
source's lookups. Broad `lookup main suppress_prefixlength 0` is not used.

**Tests:** netns probes 9–11 (the broad model leaks and is rejected), 13–22, 47–58; unit
`03-reconcile`, `08-property`. **Gap:** target dataplane, including HNAT-offloaded flows
(`G1`).

### I2 — Internal routing is independent of provider selection

> Internal destinations remain reachable regardless of which provider is selected for a source, and
> are not resolved through a provider table.

**Enforcement:** the internal-whitelist table is consulted first for each constrained source; it
contains the explicitly controlled internal prefixes and per-prefix `unreachable` guards; provider
tables additionally guard every internal prefix.

**Tests:** netns probes 17–18, 25, 33, 51–53; internal-route-loss probes 32/62.

### I3 — Internal whitelist membership is explicitly controlled

> Only operator-designated internal interfaces' connected prefixes and operator-designated exact
> destination exceptions are in the whitelist. Nothing else is auto-whitelisted.

**Enforcement:** `build_expected` derives whitelist entries from configured internal interfaces
(connected IPv6 prefixes only) and from `destination_exceptions`; an exception requires an exact
`main`-table route, rejects ambiguous/ECMP routes, rejects policy-interface routes, and requires a
gateway covered by an internal route. Connected routes on policy interfaces are never
auto-whitelisted. `Reconcile.pm` `build_expected` (line 115 onward).

**Tests:** unit `02-plan`, `06-templates`; netns "non-connected manual route is not trusted" and
ownership probes.

**Gap:** BGP-learned internal prefixes are not discovered; they require explicit exception entries
(named non-guarantee). The ambiguous/ECMP and gateway-coverage rejection branches are implemented
(`Reconcile.pm`) but not covered by a test; `SADRTest` has an ambiguous fixture that no test uses.

### I4 — BGP-learned destinations do not become internal exceptions

> An external BGP-learned route (including a more-specific route under an internal prefix) never
> becomes an internal routing exception and never bypasses provider selection.

**Enforcement:** constrained sources never look up `main`; the whitelist contains only explicitly
controlled prefixes. The rejected broad model (`lookup main suppress_prefixlength 0`) is unsafe
because `fib6_rule_suppress` compares destination length only, so a more-specific main route wins
(`fib6_rules.c`); probes 9–11 and 40 demonstrate the leak in both RPDB and native-FIB forms.

**Tests:** netns probes 11, 19–22, 40, 50–56; unit `08-property`.

### I5 — Provider withdrawal fails closed

> When the intended provider route is withdrawn, becomes unresolved or its interface is down,
> constrained sources are blocked for external destinations; they do not fall back to another
> provider or to the native default.

**Enforcement:** provider table terminal `unreachable default`; per-prefix guards; the reconciler
removes the unicast default before removing rules; health reports `protected`/`dependency-unavailable`
distinctly from reachability.

**Tests:** netns probes 30–33, 59–69; unit `04-health`, `07-failure`; boot-guard probes 45–46.

### I6 — Unmanaged sources keep their explicit routing behaviour

> A source with no effective policy is routed by the native `main` table exactly as before; the
> extension does not install a catch-all rule and does not alter unmanaged sources.

**Enforcement:** rules are installed only per configured source prefix; deletion intentionally
removes the source's rules and restores native routing; disable keeps internal reachability and
blocks external only for the configured source.

**Tests:** netns probe 74 (delete → native), 35/70–71 (disable semantics), ownership/idempotency
probes.

### I7 — Existing local, management and protected policy is unaffected

> `main`, the local table, vendor/kernel routes, dynamic protocol routes and the protected manual
> state (table `41913`, rules `10410–10414`) are never modified, flushed or seized.

**Enforcement:** managed tables are only the extension's internal table and policy provider tables;
ownership checks refuse foreign routes and unexpected rules in the managed range; no `ip rule flush`
or table flush exists; destructive actions require table + exact prefix set + protocol marker +
manifest agreement; shadowing foreign rules are reported, not deleted.

**Tests:** netns ownership/shadow probes; unit `07-failure`, `09-transaction`; plan/ownership unit
tests.

### I8 — Locally originated and forwarded traffic have documented behaviour

> Forwarded traffic sourced from a managed prefix follows I1. Locally originated traffic uses the
> same RPDB rules (source-rule lookup) and is documented as such; host source-address selection
> (RFC 6724) is not managed and no optimal-source claim is made. Unbound sockets may select an
> address that does not match the intended provider.

**Enforcement:** source rules match locally generated packets too; the product documents the
non-guarantee for unbound local sockets.

**Tests:** netns probes 27–29 (local loopback source), 47–58; requirements non-guarantee section.

### I9 — No transient source leakage during install, reconcile or removal

> At every interruption point of installation, reconciliation, provider update, disable, delete or
> removal, a constrained source is on its intended/previous provider or blocked; it is never
> transiently forwarded to an unauthorized provider.

**Enforcement:** mutation phases (`Reconcile.pm` `plan`): terminal `unreachable` guard first, then
routes, then lookup rules; updates install the inactive rule pair and remove the old pair only after
verification; provider-default deletion precedes rule removal; `apply_ops` tolerates already-applied
idempotent operations; `verify` re-reads the managed state. Boot guard provides a pre-reconciliation
block for configured sources (named boot-window limit).

**Tests:** netns probes 12, 45–46, 47–75; unit `09-transaction`, `05-bootguard`.

**Gap:** the boot window before the early guard is a named non-guarantee on hardware (`G1`/`G2`).

## 2. Offload gate

**G1 — hardware-offload correctness.** I1, I2, I5 and I9 must hold for flows that the MT7621
HNAT/PPE forwards. Source evidence (`docs/phase-vi-b/hnat-analysis.md`) shows:

- binding happens after the first packets traverse the stack, and the FOE entry then forwards
  without re-entering routing, RPDB or netfilter;
- no route/RPDB-change notification or automatic invalidation exists; entries are removed only by
  hardware ageing, a global proc/config toggle or explicit ioctl invalidation;
- the bind timestamp is written once and active flows can keep a stale entry alive; the ageout is an
  idle timeout, not a bound on stale forwarding (Strongly indicated);
- an ip6tables source-prefix guard cannot independently enforce fail-closed after binding;
- no per-prefix/per-interface exclusion exists in this build; only a global HNAT switch.

Therefore G1 is **release-blocking**: it must be demonstrated on an authorized target environment
(`docs/phase-vi-b/qualification-plan.md`) or the guarded traffic must not be offloaded. The
acceptance criteria are in `docs/phase-vi-b/offload-acceptance-criteria.md`.

## 3. Mechanism findings (investigation)

### 3.1 Whitelist route ownership

The extension owns the internal table and each policy provider table, the exact source rules, the
exact routes and the `proto 194` marker. Whitelist entries are **mirrors** of connected routes plus
operator-declared exact exceptions; the connected route itself remains kernel/vendor-owned. Foreign
routes in a managed table (a different protocol or an unexpected prefix) are conflicts and are
refused, never deleted (`check_ownership`). The manual table `41913` and rules `10410–10414` are
migration inputs, not extension objects.

### 3.2 Dynamic internal route changes

`build_expected` recomputes the whitelist and provider guards from the current observation on every
reconcile; the monitor reacts to route/rule netlink events with a periodic full resync. If an internal
route disappears, the per-prefix `unreachable` guard blocks that destination instead of allowing
provider fallback (probe 32). A whitelist entry that loses its exact main-table route becomes a
dependency and remains guarded. Internal BGP prefixes are not discovered automatically; operators
declare exact exceptions.

### 3.3 Recursive next-hop resolution

The provider table's unicast default is installed via the configured `next_hop` (or interface). A
non-link-local next-hop must be covered by a connected route on the policy interface; otherwise the
policy is held in dependency state and the guard remains. There is no recursive resolution of
BGP next-hops and no copying of BGP routes into provider tables: constrained sources never consult
`main`, so BGP-learned more-specific destinations cannot bypass provider selection (I4). This is a
deliberate property of the whitelist model, not an omission.

### 3.4 Overlapping prefixes

Rule priorities are derived from the source prefix length:
`pref = RULE_BASE + (128 - len) * 8`. Longer source prefixes therefore match before shorter ones by
construction, independent of insertion order. The terminal guard uses the reserved slot within the
same block, so it always follows that source's lookups. Nested `/64` and `/56` policies, transfer
addresses and more-specific internal prefixes were exercised by netns probes 19–22 and 53–56.

### 3.5 Route withdrawal and restoration

Withdrawal is handled at three levels: the provider table's terminal `unreachable default` (table
guard), per-internal-prefix guards, and the reconciler's ordering (delete the unicast default before
removing rules). A missing provider table is fail-closed and is recreated; an internal route loss
blocks only that destination. Restoration re-adds the unicast default and verifies (probes 30–33,
59–69). An HNAT-bound flow is outside this mechanism until its FOE entry is removed (`G1`).

### 3.6 Reconciliation ordering

`plan` emits phases: (1) terminal guard rules, (2) route replacement, (3) deletion of unicast
provider defaults, (4) non-terminal rule adds, (5) non-terminal rule deletes, (6) terminal rule
deletes, (7) remaining route deletes. First application therefore blocks the source before any
lookup rule exists; updates switch an inactive rule pair after routes are in place; withdrawal
removes the provider default before rules; removal keeps the terminal guard until the source's
lookup rules are gone. `verify` re-reads the managed state and fails closed on leftovers unless
explicitly allowed.

## 4. Verification mapping and open gaps

| Invariant | Primary evidence | Target status |
|---|---|---|
| I1 | netns packet captures, probes 9–22, 47–58 | Generic Linux only; target HNAT unverified (G1) |
| I2 | netns 17–18, 25, 32–33, 51–53, 62 | Generic Linux only |
| I3 | unit plan/template tests, netns trust probes | Generic Linux + unit |
| I4 | netns 11, 19–22, 40, 50–56; kernel source | Generic Linux + target source |
| I5 | netns 30–33, 59–69; health tests | Generic Linux only |
| I6 | netns 35, 70–74 | Generic Linux only |
| I7 | netns ownership/shadow; unit transaction | Generic Linux + unit |
| I8 | netns 27–29; documented non-guarantee | Generic Linux only |
| I9 | netns 12, 45–46, 47–75; unit transaction | Generic Linux only; boot window unverified (G2) |
| G1 | `hnat-analysis.md`, `offload-acceptance-criteria.md` | Unverified — release-blocking |
| G2 | boot guard lifecycle, `CONFIG_IPV6=m` module load | Unverified — target gate |

Named non-guarantees remain: no end-to-end provider health, no RFC 6724 source-selection control, no
zero-exposure boot window on hardware, no automatic discovery of internal BGP prefixes, no claim for
untested firmware or platforms, and no claim that a route/guard proves connectivity.
