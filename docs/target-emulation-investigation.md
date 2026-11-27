# Target emulation investigation

**Status:** investigation resumed; **no target emulation was possible** in this environment. No
security setting was weakened. Generic-Linux iproute2 parity was established separately. None of
this is EdgeOS hardware or kernel evidence.

## 1. Environment inventory

| Item | Observed |
|---|---|
| Host architecture | `x86_64` |
| `vm.mmap_min_addr` | `65536` (unchanged) |
| `qemu-mipsel` / `qemu-mipsel-static` | not installed |
| `qemu-system-mipsel` | not installed |
| MIPS cross toolchain | `binutils-mipsel-linux-gnu` present; no `mipsel-linux-gnu-gcc` |
| Firmware rootfs/userspace | not found under `/home/vadim` |
| Target binaries | no target `ip`, `perl`, `busybox` or shell found |
| Source material | `vyatta-cfg` and WireGuard source trees; `kernel_e50_v3rc9` GPL tarball/source |
| Qualification archives | configuration/capture backups, not firmware images |

The architecture-phase MIPS PIE / `mmap_min_addr` limitation is therefore still blocked at the
artifact and toolchain layer, not merely at a tunable host setting. Lowering `mmap_min_addr` would not
provide a target rootfs and was not attempted.

## 2. Required approach constraints

A credible next attempt needs all of:

1. the exact EdgeOS 3.0.1 firmware rootfs/userspace for ER-e50 build 5862409;
2. a MIPS user-mode or full-system runner (QEMU user, QEMU system or an isolated VM);
3. the target Perl, shell, configuration-engine and iproute2 binaries;
4. a controlled way to present a non-target kernel without claiming kernel compatibility;
5. no weakening of the development host's security settings.

Candidate approaches:

- **Full-system MIPS VM** with the exact firmware userspace and a compatible kernel image; strongest
  for configuration-engine ordering, but does not prove the ER-X dataplane/offload.
- **QEMU user-mode** with the exact target binaries; useful for template/Perl/iproute2 syntax and
  configuration-engine discovery, but the host kernel is not 4.14.54-UBNT and cannot establish RPDB,
  netlink or forwarding semantics.
- **Cross-built controlled fixtures** using the vendor source tree; useful for unit fixtures, not a
  substitute for the shipped userspace.
- **Isolated disposable VM** with the exact firmware; preferred if full-system emulation is unstable.

No approach was executed because the firmware rootfs/userspace is absent from this environment.

## 3. Generic-Linux iproute2 parity

`make test-target-parity` runs `test/target/iproute2-parity.sh` in the disposable privileged lab
image. Results: **9 pass / 0 fail**.

| Operation | Result |
|---|---|
| `ip -6 rule add ... unreachable pref N` and text show | pass |
| `ip -6 rule add ... lookup TABLE pref N` and text show | pass |
| `ip -6 route replace unreachable PREFIX table T metric M proto 194` | pass |
| `ip -6 route replace PREFIX dev lo table T metric M proto 194` | pass |
| table-scoped route display keeps `proto 194` and metric | pass |
| `ip -6 route show exact PREFIX table T` | pass |
| missing table returns nonzero + `FIB table does not exist` | pass |
| `ip -j -d link show` JSON `ifname` | pass |
| rule/route deletion removes managed objects | pass |

This is **Verified (generic Linux)**. It does not establish target iproute2 output, target kernel
4.14 behaviour, rule-action support, table lifetime or text formatting. The target operations remain
a hardware gate.

## 4. Target operation checklist

Before a target claim, verify on the exact firmware:

- `ip -6 rule add|del` with `unreachable`, `lookup`, explicit `pref`, source prefixes and host sources;
- rule text output order/normalization and any `from`/`table` formatting differences;
- `ip -6 route replace|del` with `unreachable`, `proto 194`, metric, table and device/via forms;
- table creation/lifetime and the exact missing-table diagnostic/exit status;
- `ip -6 route show exact` and `ip -6 route show table <id>` parsing;
- `ip -j -d link show` availability and JSON shape;
- whether `proto 194` survives all paths and whether the target `ip` accepts it;
- root/CAP_NET_ADMIN requirements and sudo/PATH behaviour.

## 5. Non-claims

- No EdgeOS userspace or configuration-engine emulation evidence was produced.
- No target kernel, dataplane, offload or iproute2 compatibility is claimed.
- The generic parity probe is not a substitute for the exact firmware test.
