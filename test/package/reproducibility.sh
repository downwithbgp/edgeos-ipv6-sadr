#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build the package twice from identical committed sources and compare hashes.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/sadr-repro.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1764200000}

build_once() { # <dir>
    local dir=$1
    mkdir -p "$dir/src"
    git -C "$ROOT" archive --format=tar HEAD | tar -x -C "$dir/src"
    (cd "$dir/src" && dpkg-buildpackage -us -uc -b >"$dir/build.log" 2>&1)
    find "$dir" -maxdepth 1 -name 'edgeos-ipv6-sadr_*.deb' -print -quit
}

first=$(build_once "$TMP/a")
second=$(build_once "$TMP/b")
if [ -z "$first" ] || [ -z "$second" ]; then
    echo "FAIL: package build did not produce a .deb" >&2
    exit 1
fi

h1=$(sha256sum "$first" | awk '{print $1}')
h2=$(sha256sum "$second" | awk '{print $1}')
echo "first:  $h1"
echo "second: $h2"
if [ "$h1" = "$h2" ]; then
    echo "PASS: package build is reproducible"
else
    echo "FAIL: package build is not reproducible" >&2
    exit 1
fi

bash "$ROOT/test/package/check-artifact.sh" "$first"
