#!/bin/bash
# Run the generic-Linux SADR proof of concept in a privileged, network-isolated
# container. This is not an EdgeOS test.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
REQUIRE=${REQUIRE_NETNS_TEST:-0}
IMAGE=${SADR_NETNS_IMAGE:-edgeos-ipv6-sadr-lab:local}

if ! command -v docker >/dev/null 2>&1; then
    if [ "$REQUIRE" = "1" ]; then
        echo "FAIL: docker is required but not available" >&2
        exit 1
    fi
    echo "SKIP: docker is not available (set REQUIRE_NETNS_TEST=1 to fail)" >&2
    exit 0
fi

if ! docker info >/dev/null 2>&1; then
    if [ "$REQUIRE" = "1" ]; then
        echo "FAIL: docker daemon is not accessible" >&2
        exit 1
    fi
    echo "SKIP: docker daemon is not accessible (set REQUIRE_NETNS_TEST=1 to fail)" >&2
    exit 0
fi

docker build -t "$IMAGE" "$ROOT/test/integration"

exec docker run --rm --privileged --network=none \
    -e REQUIRE_NETNS_TEST="$REQUIRE" \
    -v "$ROOT":/repo:ro \
    -w /repo \
    "$IMAGE" \
    bash -c 'bash test/integration/netns-sadr.sh && bash test/integration/r1-canary-sim.sh'
