#!/usr/bin/env python3
"""Minimal stand-in for the EdgeOS config API used by unit tests.

Reads a JSON configuration from $FAKE_CONFIG and answers the verbs the
production adapter uses. Absent paths exit 1 without diagnostics; this mirrors
the target API distinction between "absent" and a real failure.
"""
import json
import os
import sys

raw_verb = sys.argv[1] if len(sys.argv) > 1 else ""
active_verb = raw_verb in ("listActiveNodes", "returnActiveValue", "existsActive")
try:
    config_path = os.environ["FAKE_CONFIG"]
    if active_verb and os.environ.get("FAKE_ACTIVE_CONFIG"):
        config_path = os.environ["FAKE_ACTIVE_CONFIG"]
    cfg = json.load(open(config_path))
except (KeyError, OSError, ValueError) as exc:
    sys.stderr.write(f"fake_api: {exc}\n")
    sys.exit(2)

args = sys.argv[1:]
if not args:
    sys.exit(2)
verb = {
    "listActiveNodes": "listNodes",
    "returnActiveValue": "returnValue",
    "existsActive": "exists",
}.get(args[0], args[0])
path = args[1:]

node = cfg
for part in path:
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        sys.exit(1)

if verb == "listNodes":
    if isinstance(node, dict):
        print(" ".join(sorted(node)))
    elif isinstance(node, list):
        print(" ".join(str(v) for v in node))
    else:
        sys.exit(1)
elif verb == "returnValue":
    if isinstance(node, (dict, list)):
        sys.exit(1)
    print(node)
elif verb == "exists":
    sys.exit(0)
else:
    sys.exit(2)
