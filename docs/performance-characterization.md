# Performance and resource characterization

**Status:** off-device x86_64 measurements. **Not an ER-X or EdgeOS performance claim.** Profiling
uses the fake configuration API and stateful `ip` harness; target CPU, memory, event storms,
forwarding impact and hardware offload remain hardware gates.

## 1. Method

- `make test-perf` runs `test/perf/profile.pl` with the fake API/ip harness.
- Phase timing uses `Time::HiRes`; each phase is measured once after a warm process start.
- Scaling uses generated valid policies with one source prefix each and a synthetic observed state;
  it measures validation, expected-state construction and planning, not kernel mutation.
- Monitor measurements use the disposable lab image in a network namespace; RSS/PSS come from
  `/proc/<pid>/smaps_rollup`, child counts from `ps --ppid`.

These are indicative engineering measurements, not a benchmark contract.

## 2. Phase breakdown

| Workload | Read desired | Observe kernel | Build expected | Plan | Operations | `ip` invocations |
|---|---:|---:|---:|---:|---:|---:|
| Base policy config | 665–691 ms | 504–544 ms | 1.3–1.7 ms | 0.4–0.7 ms | 12 | 6 |
| Empty config, full reconcile | 306–360 ms | 339–369 ms | — | 0.1 ms | 0 | — |

The empty full reconcile took **1,774–1,789 ms** across profiler runs. Earlier isolated runs measured
521–555 ms; the difference reflects process/API/IP subprocess startup and host load, not a stable
target latency. In both cases, **more than 99% of the measured work is configuration reads and
kernel/interface observation**, not planning. Planning is below 2 ms for the base policy.

## 3. Scaling

Planning with generated policies:

| Policies | Validate | Build expected | Plan | Operations |
|---:|---:|---:|---:|---:|
| 1 | 0.5 ms | 0.7 ms | 0.2 ms | 9 |
| 10 | 1.3 ms | 3.1 ms | 4.5 ms | 72 |
| 50 | 5.9 ms | 21.5 ms | 52.8 ms | 352 |
| 100 | 11.5–12.9 ms | 27.0–27.5 ms | 98.0–99.5 ms | 702 |

Within this range planning grows roughly linearly with operation count and remains far below the
subprocess cost. The table does not model command-line/config-engine latency at 100 policies or
table/rule installation time.

## 4. Monitor resources

| Measurement | Value |
|---|---|
| Parent RSS | 13,812 KiB |
| Parent PSS | 12,259 KiB |
| `ip -6 monitor route` RSS | 2,880 KiB |
| `ip -6 monitor rule` RSS | 2,804 KiB |
| Observed parent `%CPU` at 2 s | 11.0% (startup average) |
| Observed parent `%CPU` at 7 s | 3.1% (short sample, not steady-state idle) |

The monitor creates the two `ip -6 monitor` children once and does not spawn per event in the idle
state. Event-storm coalescing, long-running memory stability, monitor restart cost and true idle CPU
require a longer target run.

## 5. Other observations

- **Forwarding impact during transitions:** the 145-assertion namespace phase exercises packet paths,
  established TCP/UDP flows, route/table loss and monitor restart with zero wrong-provider packets.
  Throughput, latency and forwarding interruption duration were not measured.
- **Event storms:** not measured in isolation. The monitor coalesces for 0.4 s and resynchronizes
  every 300 s by default; actual storm cost and kernel notification loss are target checks.
- **Child process frequency:** six `ip` invocations for the base observation/planning profile; the
  full reconcile adds verification/health observations. Each invocation is a process start; this is
  the dominant optimization opportunity if target measurements show a problem.
- **Target emulation:** unavailable; no target CPU/memory extrapolation is made.

## 6. Proposed target budgets (Recommendation; Unverified)

These are engineering budgets for the hardware session, not achieved target results:

| Metric | Proposed budget |
|---|---|
| Monitor parent RSS/PSS | ≤ 32 MiB RSS / ≤ 24 MiB PSS |
| Total monitor tree RSS | ≤ 40 MiB |
| Idle monitor CPU | < 1% of one core after startup |
| Typical 3-policy reconcile | p95 ≤ 3 s |
| 100-policy planning-only | ≤ 1 s on target (plus kernel mutation time) |
| Provider/internal loss to verified repair | p95 ≤ 10 s |
| Event storm | no unbounded queue/process growth; coalescing observed |
| Early boot guard | ≤ 2 s and completed before the router's forwarding phase |

Correctness, ownership and fail-closed behaviour take precedence over these budgets. No optimization
was made based on x86 container timings alone.
