#!/usr/bin/env python3
# Conservative shadow detector for the SADR lab.
#
# Reads `ip -6 rule show` on stdin. Reports success (exit 0) if a rule with
# priority < first_priority can match the source prefix (or has no source
# selector). A conservative false positive is preferable to missing a rule
# that prevents the policy from being effective.
import ipaddress
import re
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: shadow_check.py SOURCE_PREFIX FIRST_PRIORITY")

src = ipaddress.ip_network(sys.argv[1], strict=False)
first = int(sys.argv[2])
found = False

for line in sys.stdin:
    m = re.match(r"\s*(\d+):\s+(.*)", line)
    if not m:
        continue
    pri = int(m.group(1))
    rest = m.group(2)
    if pri >= first:
        continue
    # Built-in local/main/default rules are not shadows. Rules in the
    # extension-managed priority range are either our own policy or a
    # managed-range conflict handled separately, not a pre-range shadow.
    if pri in (0, 32766, 32767):
        continue
    if 20000 <= pri <= 21031:
        continue
    if "from all" in rest:
        found = True
        break
    fm = re.search(r"\bfrom (\S+)", rest)
    if not fm:
        # A rule with no source selector (for example mark/iif/tos) can still
        # match this traffic. Report it conservatively.
        found = True
        break
    try:
        net = ipaddress.ip_network(fm.group(1), strict=False)
    except ValueError:
        found = True
        break
    if net.version == src.version and net.overlaps(src):
        found = True
        break

sys.exit(0 if found else 1)
