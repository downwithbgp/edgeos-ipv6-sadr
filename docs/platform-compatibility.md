# Platform compatibility


> **v0.1.0 refinements:** `docs/v0.1.0-refinements.md` is normative and supersedes conflicting text in this document.

**Status:** v0.1.0 package builds reproducibly off-device and the preinst refuses unsupported
firmware/kernel combinations. **No EdgeOS compatibility claim exists** and hardware qualification is
pending. See [`v0.1.0-evidence.md`](v0.1.0-evidence.md) and
[`hardware-qualification-plan.md`](hardware-qualification-plan.md).

## 1. Supported investigation platform

```text
Device:       Ubiquiti EdgeRouter X / ER-e50
EdgeOS:       3.0.1
Firmware:     EdgeRouter.ER-e50.v3.0.1.5862409.*
Kernel:       4.14.54-UBNT
Architecture: mipsel
```

Read-only inspection was performed on this firmware. The architecture is designed for it. Other
EdgeRouter families, EdgeOS releases, kernels and firmware builds are **not supported** until
validated.

## 2. Kernel and userspace requirements

* `CONFIG_IPV6_MULTIPLE_TABLES=y` is required for the recommended RPDB/table model.
  `CONFIG_IPV6_SUBTREES=y` is required only for the rejected source-specific FIB candidate. Both are
  present in the exact ER-X 4.14.54-UBNT kernel.
* iproute2 with IPv6 rule/table support. The target reports `iproute2-ss171113`.
* No kernel module, kernel rebuild or vendor binary patch is required by the recommended design.
* The package is expected to be `Architecture: all` (scripts and templates only). No `mipsel`
  package is needed unless a compiled helper is later introduced.

## 3. Reserved object ranges (tentative)

| Object | Range | Notes |
|---|---|---|
| Internal whitelist table | `10000` | Global, extension-owned |
| Provider tables | `10001–19999` | Auto or explicit; collision-checked |
| Source rules | `20000–21031` | Below `main` (32766); evaluated after the manual PoC (10410–10414) |
| Route protocol marker | `194` | Ownership aid; not a security boundary |

Native `protocols static table` uses `1–200`. The manual proof of concept uses table `41913`. Both
are outside the extension's ranges and are never adopted automatically.

## 4. Interface forms

The architecture is intended to support, where the platform permits:

* Ethernet and VLAN;
* tunnels and VXLAN (as a Layer 3 dependency, without managing the interface);
* bridge interfaces that are Layer 3 dependencies;
* PPP/PPPoE and interface-only/point-to-point routes;
* global-unicast next hops and interface-scoped link-local next hops.

The initial qualification focuses on routed interfaces and a link-local/global next hop. Bridge,
PPP, tunnel and interface-only forwarding require explicit hardware validation. VXLAN management
remains out of scope.

## 5. Target quirks

* `ip -j -6 route` and `ip -j -6 rule` print text, not JSON. Helpers must not depend on route/rule
  JSON; `ip -j -d link` is reliable.
* The target `ip` usage omits `from` for `route add`. Upstream v4.14 source parses it, but the target
  binary is not target-verified; the recommended design does not need `route add ... from`.
* The configuration engine is not atomic and groups changes by priority. The SADR subtree is
  proposed at priority 500; target ordering requires emulation/hardware validation.
* `ip monitor` is present and lists link/address/route/rule objects; systemd 232 is present
  (Verified (target): `ip monitor help`, `systemctl --version`). The event stream, service ordering
  and early-boot behaviour remain Unverified gates.
* `existsEffective` may miss the still-executing subtree during `end:`; use working-config
  `exists`.
* Scripted and interactive commits can differ for vendor firewall actions. SADR does not depend on
  firewall commits.
* Native table routes are not repaired after netdevice recreation. The extension owns its routes.
* Hardware offload interaction with multi-table RPDB is unverified and is a qualification gate.

## 6. Firmware guard

A future package must refuse installation on an unsupported firmware/kernel. The guard should check:

* `/etc/version` matches the supported `EdgeRouter.ER-e50.v3.0.1.5862409.*` family;
* `uname -r` is `4.14.54-UBNT`;
* the required `ip` operations are present;
* the package is not installed over an incompatible kernel/package set.

The exact guard and error messages are v0.1.0 implementation deliverables.

## 7. Hardware qualification status

**None.** The target was inspected read-only. No package was installed, no configuration was
committed, no interface was mutated and no dataplane/offload measurement was performed.

Claims in this repository are labelled:

* `Verified (target)` — read-only observation on the exact router.
* `Verified (target source)` — exact vendor kernel/source.
* `Verified (generic Linux)` — netns/container experiment.
* `Strongly indicated` / `Unverified` — as stated in the investigation record.

Nothing in this file should be read as a hardware compatibility guarantee.

## 8. Non-claims

* No compatibility with other EdgeRouter models or EdgeOS versions.
* No hardware offload/throughput claim.
* No claim that the target 4.14 kernel forwards source-specific FIB routes with the same semantics
  as the generic-Linux experiment.
* No claim that the boot window is closed; it is a named non-guarantee until the early guard service
  is implemented and qualified.
* No claim of provider health, failover or end-to-end connectivity.
