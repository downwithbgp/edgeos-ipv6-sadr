# Phase IV off-device status

**Status:** Phase A work is off-device only. No production mutation has been performed.

## Preserved off-device evidence

- 10 unit/property/failure files, **619 assertions**.
- Generic-Linux netns: **145 pass / 0 fail**; iproute2 parity **9/9**.
- Package lifecycle **13/13**, artifact **20/20**, reproducible package hash
  `f3bcd7c2bb50765b668703c52355370782c6bd254cface89059ce5fe8d38a93f`.
- Transaction, failure-injection and performance suites remain part of `make test`/dedicated targets.
- Qualification harness plan validation covers the full 22-step matrix without device contact.

## Target userspace/emulation options

The workstation still has no exact firmware rootfs/userspace, no `qemu-mipsel`, and only MIPS
binutils. The production ER-X exposes the target userspace read-only, but copying vendor binaries,
firmware archives, configuration or credentials into the repository is prohibited.

Legitimate offline options remain:

- obtain the exact firmware rootfs through an approved source and run it in an isolated full-system
  MIPS VM;
- build controlled fixtures from vendor source, not by copying installed binaries;
- use the production router only for bounded read-only feature/output probes, never as an emulation
  source of committed artifacts.

QEMU-user execution against target binaries would not establish kernel 4.14 semantics; full-system
emulation or future dedicated hardware is required for kernel/dataplane evidence. No host security
setting was weakened.

## Boot-safety alternatives for review

Current guard unit ordering/activation is documented in `docs/boot-safety-review.md`. Alternatives
that require architectural review before implementation:

1. **Vendor-service dependency drop-in:** add `Wants=`/`After=` to
   `vyatta-router.service.d/` so router start always pulls/orders the guard. This improves activation
   but still does not make guard failure block the router; a `Requires=` would risk management lockout.
2. **Transit-forwarding gate:** a narrowly scoped pre-router service that disables only IPv6
   transit forwarding until the guard/monitor proves terminal guards are installed, then restores the
   configured value. Must preserve management/local traffic and be target-qualified.
3. **Independent terminal bootstrap:** a minimal local binary/script with no configuration API that
   installs terminal guards from a verified local intent file before the router starts. Requires a
   separately audited artifact and rollback.
4. **Device-local watchdog:** an independently executable timer that restores a recorded guard/state
   if the orchestration connection is lost. Must be idempotent, narrowly scoped and tested off-device.

None of these was implemented before review. The existing guard remains the current mechanism.

## CI maintenance

The workflow was pinned to `actions/checkout@v4.2.2` (Node 20). The current release is `v7.0.1`
(Node 24); the workflow is now pinned to the `v7.0.1` release commit
(`3d3c42e5aac5ba805825da76410c181273ba90b1`) to remove the Node 20 runtime dependency. This is CI
maintenance only; package and functional behaviour are unchanged. The Phase IV CI result on the new
pin is recorded in `docs/ci-evidence.md` once the push/PR run completes.
