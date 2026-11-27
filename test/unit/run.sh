#!/bin/bash
# Unprivileged unit checks. These run on any developer machine.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

echo "== documentation address hygiene =="
perl "$ROOT/test/unit/check-doc-addresses.pl" "$ROOT"

echo "ALL UNIT TESTS PASSED"
