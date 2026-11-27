#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Controller-side preparation helpers for the R1 canary.
#
# This file is sourced by qualification/adapters/r1-canary.sh and by the
# privileged integration test. Keep it small: it exists so the exact code that
# prepares a controlled endpoint is executable off-target.

sadr_controller_require_root() {
    [ "$(id -u)" -eq 0 ]
}

sadr_controller_require_tools() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 ||
            { printf 'missing controller tool: %s\n' "$tool" >&2; return 1; }
    done
}

sadr_controller_unique_tag() {
    python3 - <<'PY'
import secrets
print(secrets.token_hex(2))
PY
}

sadr_controller_ns_exists() {
    ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

# Disable IPv6 redirects and router advertisements on a controlled endpoint.
#
# IPv6 has no net.ipv6.conf.<if>.send_redirects sysctl. Including that key made
# sysctl return 1 after setting accept_redirects, which aborted the adapter
# under set -e before phase A1. Only keys that exist on a generic Linux
# controller are used; their existence is checked by the caller's stage record.
sadr_controller_disable_redirects() {
    local iface=$1
    [ -n "$iface" ] || { printf 'interface required\n' >&2; return 1; }
    sysctl -qw \
        "net.ipv6.conf.$iface.accept_redirects=0" \
        "net.ipv6.conf.$iface.accept_ra=0" \
        "net.ipv6.conf.$iface.autoconf=0"
}
