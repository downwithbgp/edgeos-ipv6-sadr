#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Deterministic candidate finalization: hash the executables, write the single
# authorization candidate, and validate the written hashes against the files.
# Run after all executable changes and after the regression tests pass.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CAND="$ROOT/docs/r1-authorization-candidate.json"
A=$(sha256sum "$ROOT/qualification/adapters/r1-canary.sh" | awk '{print $1}')
C=$(sha256sum "$ROOT/qualification/adapters/r1-cleanup.sh" | awk '{print $1}')
I=$(sha256sum "$ROOT/qualification/adapters/r1-install.sh" | awk '{print $1}')
python3 - "$CAND" "$A" "$C" "$I" <<'PY'
import json, pathlib, sys
cand, a, c, i = sys.argv[1:5]
p = pathlib.Path(cand)
d = json.loads(p.read_text())
d["adapter_sha256"] = a
d["cleanup_sha256"] = c
d["install_sha256"] = i
p.write_text(json.dumps(d, indent=2) + "\n")
d = json.loads(p.read_text())
assert d["adapter_sha256"] == a, "adapter hash did not persist"
assert d["cleanup_sha256"] == c, "cleanup hash did not persist"
assert d["install_sha256"] == i, "install hash did not persist"
PY
echo "adapter=$A"
echo "cleanup=$C"
echo "install=$I"
echo "candidate finalized and validated: $CAND"
