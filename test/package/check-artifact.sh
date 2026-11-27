#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Positive and negative validation of a built .deb.
set -euo pipefail

DEB=${1:-}
if [ -z "$DEB" ] || [ ! -f "$DEB" ]; then
    echo "usage: check-artifact.sh <edgeos-ipv6-sadr_*.deb>" >&2
    exit 2
fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

fields=$(dpkg-deb -f "$DEB")
for field in "Package: edgeos-ipv6-sadr" "Architecture: all"; do
    if printf '%s\n' "$fields" | grep -qx "$field"; then
        ok "control field $field"
    else
        bad "missing control field $field"
    fi
done

listing=$(mktemp)
trap 'rm -f "$listing" "$TMP/list" 2>/dev/null || true' EXIT
dpkg-deb -c "$DEB" >"$listing"
for path in \
    ./opt/vyatta/sbin/vyatta-ipv6-sadr \
    ./usr/share/perl5/EdgeOS/IPv6SADR.pm \
    ./usr/share/perl5/EdgeOS/IPv6SADR/Reconcile.pm \
    ./usr/share/perl5/EdgeOS/IPv6SADR/Health.pm \
    ./usr/share/perl5/EdgeOS/IPv6SADR/BootGuard.pm \
    ./usr/share/perl5/EdgeOS/IPv6SADR/Monitor.pm \
    ./opt/vyatta/share/vyatta-cfg/templates/protocols/ipv6-sadr/node.def \
    ./opt/vyatta/share/vyatta-op/templates/show/ipv6-sadr/node.def \
    ./lib/systemd/system/edgeos-ipv6-sadr-guard.service \
    ./lib/systemd/system/edgeos-ipv6-sadr-monitor.service
do
    if grep -q " $path$" "$listing"; then
        ok "package contains $path"
    else
        bad "package is missing $path"
    fi
done

if grep -qE '^-rwxr-xr-x .* \./opt/vyatta/sbin/vyatta-ipv6-sadr$' "$listing"; then
    ok "CLI is executable"
else
    bad "CLI is not executable"
fi
if grep -qE '\./(test|debian|src|\.github)/' "$listing"; then
    bad "package contains source, test or build-only paths"
else
    ok "package contains no source/test/build-only paths"
fi
if grep -qE '\./config/' "$listing"; then
    bad "package contains router configuration"
else
    ok "package does not contain router configuration"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sadr-artifact.XXXXXX")
dpkg-deb -x "$DEB" "$TMP"
if PERL5LIB="$TMP/usr/share/perl5" perl -e '
    require "EdgeOS/IPv6SADR.pm";
    require "EdgeOS/IPv6SADR/Reconcile.pm";
    require "EdgeOS/IPv6SADR/Health.pm";
    require "EdgeOS/IPv6SADR/BootGuard.pm";
    require "EdgeOS/IPv6SADR/Monitor.pm";
    exit($EdgeOS::IPv6SADR::VERSION eq "0.1.0" ? 0 : 1);
'; then
    ok "installed Perl modules compile and report version 0.1.0"
else
    bad "installed Perl modules do not compile or version mismatch"
fi
rm -rf "$TMP"

if dpkg-deb -I "$DEB" | grep -q 'preinst'; then
    ok "package carries maintainer scripts"
else
    bad "package is missing maintainer scripts"
fi

echo
if [ "$FAIL" -ne 0 ]; then
    echo "artifact validation: pass=$PASS fail=$FAIL"
    exit 1
fi
echo "artifact validation: pass=$PASS fail=0"
