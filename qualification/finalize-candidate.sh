#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Deterministic candidate finalization: generate the execution manifest, derive
# the executable hashes from it, write the single authorization candidate, and
# verify the result. Run after all executable changes and regression tests.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CAND="$ROOT/docs/r1-authorization-candidate.json"
MANIFEST="$ROOT/docs/r1-execution-manifest.json"
python3 "$ROOT/qualification/execution_manifest.py" --write --root "$ROOT" --out "$MANIFEST"
MANIFEST_SHA=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest_sha256"])' "$MANIFEST")
python3 - "$CAND" "$MANIFEST" "$MANIFEST_SHA" <<'PY'
import json, pathlib, sys
cand, manifest, manifest_sha = sys.argv[1:4]
mp = pathlib.Path(manifest)
m = json.loads(mp.read_text(encoding="utf-8"))
files = m["files"]
p = pathlib.Path(cand)
d = json.loads(p.read_text(encoding="utf-8"))
d["execution_manifest"] = "docs/r1-execution-manifest.json"
d["execution_manifest_sha256"] = manifest_sha
d["adapter_sha256"] = files["qualification/adapters/r1-canary.sh"]
d["cleanup_sha256"] = files["qualification/adapters/r1-cleanup.sh"]
d["install_sha256"] = files["qualification/adapters/r1-install.sh"]
p.write_text(json.dumps(d, indent=2) + "\n", encoding="utf-8")
d = json.loads(p.read_text(encoding="utf-8"))
assert d["execution_manifest_sha256"] == manifest_sha, "manifest hash did not persist"
assert d["adapter_sha256"] == files["qualification/adapters/r1-canary.sh"]
assert d["cleanup_sha256"] == files["qualification/adapters/r1-cleanup.sh"]
assert d["install_sha256"] == files["qualification/adapters/r1-install.sh"]
print("adapter=" + d["adapter_sha256"])
print("cleanup=" + d["cleanup_sha256"])
print("install=" + d["install_sha256"])
print("manifest=" + manifest_sha)
PY
python3 "$ROOT/qualification/execution_manifest.py" --verify --root "$ROOT" --manifest "$MANIFEST" >/dev/null
echo "candidate finalized and validated: $CAND"
