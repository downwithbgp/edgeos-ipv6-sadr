#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Verify the generated execution manifest and the candidate's binding to it.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP="${TMPDIR:-/tmp}/sadr-manifest-test.$$"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP"
MANIFEST="$ROOT/docs/r1-execution-manifest.json"
CAND="$ROOT/docs/r1-authorization-candidate.json"

python3 "$ROOT/qualification/execution_manifest.py" --verify --root "$ROOT" --manifest "$MANIFEST" >/dev/null
echo "PASS: committed execution manifest verifies"

python3 "$ROOT/qualification/execution_manifest.py" --write --root "$ROOT" --out "$TMP/manifest.json" >/dev/null
python3 "$ROOT/qualification/execution_manifest.py" --verify --root "$ROOT" --manifest "$TMP/manifest.json" >/dev/null
echo "PASS: generated execution manifest verifies"

python3 - "$TMP/manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
doc["files"]["qualification/profile.sh"] = "0" * 64
json.dump(doc, open(path, "w", encoding="utf-8"))
PY
if python3 "$ROOT/qualification/execution_manifest.py" --verify --root "$ROOT" --manifest "$TMP/manifest.json" >/dev/null 2>&1; then
    echo "FAIL: a tampered manifest was accepted" >&2
    exit 1
fi
echo "PASS: a tampered manifest is rejected"

python3 - "$CAND" "$MANIFEST" <<'PY'
import json, sys
cand = json.load(open(sys.argv[1], encoding="utf-8"))
manifest = json.load(open(sys.argv[2], encoding="utf-8"))
assert cand["execution_manifest_sha256"] == manifest["manifest_sha256"], "manifest binding"
files = manifest["files"]
assert cand["adapter_sha256"] == files["qualification/adapters/r1-canary.sh"], "adapter binding"
assert cand["cleanup_sha256"] == files["qualification/adapters/r1-cleanup.sh"], "cleanup binding"
assert cand["install_sha256"] == files["qualification/adapters/r1-install.sh"], "install binding"
print("PASS: authorization candidate is bound to the execution manifest")
PY
