#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="${TMPDIR:-/tmp}/sadr-qualification-plan.$$"
trap 'rm -rf "$OUT"' EXIT

bash "$ROOT/qualification/run.sh" --plan --out "$OUT" \
    --router admin@isolated-router.invalid \
    --artifact /nonexistent/edgeos-ipv6-sadr_0.1.0_all.deb \
    --firmware 'EdgeRouter.ER-e50.v3.0.1.5862409.example' >/dev/null

python3 - "$OUT/results.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
required = {
    "preflight", "independent-management", "backup", "artifact", "install",
    "configure", "structural", "packets", "flows", "transitions", "monitor",
    "rollback", "cold-boot", "upgrade", "remove-refusal", "offload-on",
    "offload-off", "source-selection", "bgp-internal", "coexistence",
    "resources", "cleanup",
}
ids = [s["id"] for s in data["steps"]]
assert data["mode"] == "plan", data["mode"]
assert len(ids) == len(set(ids)), "duplicate step ids"
assert required.issubset(ids), sorted(required - set(ids))
assert all(s["status"] == "planned" for s in data["steps"])
assert data["summary"]["complete"] is False
print("PASS: qualification plan has the complete step matrix and executes nothing")
PY
