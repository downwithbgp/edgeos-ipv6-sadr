# CI and reproducibility evidence

**Status:** actual GitHub Actions observation for implementation commit `160b493` on
`feat/v0.1.0`. This is not target-hardware evidence. No release was published and PR #1 remains a
draft.

## 1. Repository and pull request

| Item | Value |
|---|---|
| Repository | `downwithbgp/edgeos-ipv6-sadr` (public) |
| Baseline branch | `main` at `4af7bb4` |
| Implementation branch | `feat/v0.1.0` at `160b493` |
| Draft PR | <https://github.com/downwithbgp/edgeos-ipv6-sadr/pull/1> |
| Merge status | **not merged**; draft |
| Workflow | `.github/workflows/ci.yml` |
| Permissions | `contents: read` |
| Checkout action | `actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683` (v4.2.2) |

## 2. Actual workflow results

| Trigger | Run | Result | Jobs |
|---|---|---|---|
| push `main` (`4af7bb4`) | <https://github.com/downwithbgp/edgeos-ipv6-sadr/actions/runs/46006106207> | success | lint/unit; netns **65/0** |
| push `feat/v0.1.0` (`160b493`) | <https://github.com/downwithbgp/edgeos-ipv6-sadr/actions/runs/46006108178> | success | lint/unit **599**; netns **145/0**; package |
| pull request #1 | <https://github.com/downwithbgp/edgeos-ipv6-sadr/actions/runs/46006120949> | success | lint/unit **599**; netns **145/0**; package |

The PR run exercised the actual `pull_request` trigger, not only a branch push. The package job ran
the lifecycle, artifact and two-build reproducibility scripts. Netns results are generic-Linux
evidence only.

## 3. Package hash comparison

| Artifact | SHA-256 |
|---|---|
| Local build (Debian stable-slim container) | `9e45b9c18b38c8c3cf485b61f3926a366d7ac876e37b1acf2b1f963d4e546f5c` |
| CI push run, first build | `9e45b9c18b38c8c3cf485b61f3926a366d7ac876e37b1acf2b1f963d4e546f5c` |
| CI push run, second build | `9e45b9c18b38c8c3cf485b61f3926a366d7ac876e37b1acf2b1f963d4e546f5c` |
| CI PR run, first build | `9e45b9c18b38c8c3cf485b61f3926a366d7ac876e37b1acf2b1f963d4e546f5c` |
| CI PR run, second build | `9e45b9c18b38c8c3cf485b61f3926a366d7ac876e37b1acf2b1f963d4e546f5c` |

Artifact validation passed **20/20** in both CI package jobs; package lifecycle passed in the local
and CI runs. Package size is 26,600 bytes (`Installed-Size` 157 KiB).

## 4. Build environment

| Item | Observed value |
|---|---|
| Source commit | `160b493cadf2e9b91e1fc4eb8187ca7d1537db9d` |
| CI runner | GitHub `ubuntu-latest`, Ubuntu resolute archive |
| CI build dependencies | `build-essential`, `debhelper 13.31ubuntu1`, `dpkg-dev`, `fakeroot` |
| Local build | `debian:stable-slim` container, `build-essential`, `debhelper`, `dpkg-dev`, `fakeroot` |
| Epoch | `SOURCE_DATE_EPOCH=1764200000` |
| Package version | `0.1.0` (`Architecture: all`) |

## 5. Reproducibility scope

The observed guarantee is empirical and bounded:

- Two independent builds in the **same CI environment** from the same committed source and
  `SOURCE_DATE_EPOCH` produced byte-identical `.deb` files.
- A local build in a **Debian stable-slim container** and the GitHub Ubuntu environment produced the
  same hash for this source/packaging revision.
- This does not guarantee identical bytes across arbitrary Debian/Ubuntu releases, `dpkg`,
  `debhelper`, `gzip`, filesystem ordering or different `SOURCE_DATE_EPOCH` values.
- There is no cryptographic signing, in-toto/SLSA attestation or external artifact store. The hash is
  a build-integrity comparison, not release provenance.
- The package installs no router configuration and does not perform hardware qualification.

## 6. Publication-sensitive review

The tracked tree was inspected before the initial push: no credentials, private keys, router
configurations, firmware archives or captured operational data were found. The repository was public
and empty before the baseline/feature push. The CI workflow has read-only repository permissions and
no release/publish step.

## 7. Remaining CI gates

- A final CI run is required after any further implementation changes; the runs above cover
  `160b493` only.
- The draft PR must not be merged.
- Tagging, release publication and artifact signing remain prohibited until hardware qualification
  and separate authorization.

## 8. Final review-fix build

The post-review implementation adds the boot/transaction/perf/qualification work and the review
fixes. Its local package hash is
`f3bcd7c2bb50765b668703c52355370782c6bd254cface89059ce5fe8d38a93f` (26,982 bytes, Installed-Size
157 KiB), artifact 20/20 and lifecycle 13/13. The final GitHub Actions runs for this head are recorded
after the final push; the earlier `160b493` runs above remain historical.
