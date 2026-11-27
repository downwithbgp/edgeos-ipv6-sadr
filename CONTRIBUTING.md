# Contributing

## Scope

This project is about IPv6 source-address-dependent routing on EdgeOS. It is infrastructure
software: correctness, ownership and failure behaviour matter more than feature count.

Read [`AGENTS.md`](AGENTS.md) before changing routing semantics. The current phase is architecture;
production packaging and live-router migration are explicitly gated.

## What a change needs

1. **A stated problem and semantic contract.** What routing behaviour changes? What is guaranteed,
   what is not, and what happens on failure?
2. **Evidence.** Use the labels from `AGENTS.md`. Generic Linux namespace results are welcome but do
   not substitute for target evidence. State the environment and command.
3. **A test.** Routing changes need a netns or unit test that would fail before the change. Ownership
   or collision changes need tests for the refusal path, not only the happy path.
4. **Safe ordering.** Any mutation of kernel routing state must explain why an interruption at each
   step cannot permit unintended cross-provider egress. Destructive cleanup must be scoped to
   verified extension-owned objects.
5. **Documentation.** Update the requirements, ADR, testing strategy or investigation record that
   the change affects.

## Development checks

```bash
make test
make test-netns   # privileged container; generic Linux only
```

`make test` must pass before every commit. Record the netns result in the commit message or the
matching evidence file when the change touches the dataplane.

## Style

* Bash: `#!/bin/bash`, `set -euo pipefail` unless a documented reason exists, quote expansions,
  prefer `ip -6` over `ping6`, and keep commands observable. Run `shellcheck`.
* Perl: `use strict; use warnings;`, no shell interpolation of untrusted config values.
* Do not parse human-readable `ip -d link` output on the target; it is defective on the supported
  MIPS build. `ip -j -d link` is reliable. Route and rule JSON is *not* reliable on the target
  build; parse the stable text form or use a scoped helper.
* Use documentation address ranges in every example and fixture.
* Do not add dependencies that are not present on the supported firmware unless the package ships
  them and the architecture review accepts the maintenance cost.

## Commits

Use conventional commits. Keep the subject imperative and scoped. Explain *why* in the body when the
change affects routing safety, ownership or lifecycle semantics. Do not mix unrelated refactors with
behavioural changes.

## Reporting issues

Include the firmware version, kernel, `ip -V`, the relevant configured policy, the effective rules
and routes, and the actual versus expected route lookup. Redact real addresses and credentials.
