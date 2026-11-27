#!/bin/bash
# Run the generic-Linux iproute2 parity probe in the disposable lab image.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
IMAGE=${SADR_NETNS_IMAGE:-edgeos-ipv6-sadr-lab:local}

if ! command -v docker >/dev/null 2>&1; then
    echo "SKIP: docker is not available" >&2
    exit 0
fi
if ! docker info >/dev/null 2>&1; then
    echo "SKIP: docker daemon is not accessible" >&2
    exit 0
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker build -t "$IMAGE" "$ROOT/test/integration"
fi

exec docker run --rm --privileged --network=none \
    -v "$ROOT":/repo:ro \
    -w /repo \
    "$IMAGE" \
    bash test/target/iproute2-parity.sh
