#!/usr/bin/env python3
"""Validate a scoped production qualification authorization."""
import argparse
import datetime
import hashlib
import json
import re
import sys

ap = argparse.ArgumentParser()
ap.add_argument("--file", required=True)
ap.add_argument("--profile", required=True, choices=("canary", "maintenance", "isolated"))
ap.add_argument("--device", required=True)
ap.add_argument("--test-id")
ap.add_argument("--artifact")
args = ap.parse_args()


def fail(msg, code):
    print(f"authorization: {msg}", file=sys.stderr)
    sys.exit(code)


try:
    auth = json.load(open(args.file, encoding="utf-8"))
except (OSError, ValueError) as exc:
    fail(exc, 2)

for key in ("device_id", "profile", "target_class", "test_ids",
            "max_duration_seconds", "approved_mutation_scope", "recovery",
            "not_after", "device_fingerprint"):
    if key not in auth:
        fail(f"missing {key}", 3)
if args.profile in ("canary", "maintenance"):
    for key in ("adapter_sha256", "cleanup_sha256", "install_sha256"):
        if key not in auth:
            fail(f"missing {key}", 3)

if auth["profile"] != args.profile:
    fail("profile mismatch", 4)
if auth["device_id"] != args.device:
    fail("device mismatch", 5)
if not isinstance(auth["test_ids"], list) or not auth["test_ids"]:
    fail("test_ids must be a non-empty list", 6)
if not all(isinstance(t, str) and t.strip() for t in auth["test_ids"]):
    fail("test_ids must be non-empty strings", 6)
if args.test_id is not None and args.test_id not in auth["test_ids"]:
    fail(f"test id {args.test_id!r} is not authorized", 6)
if args.profile in ("canary", "maintenance") and not args.test_id:
    fail("--test-id is required for canary/maintenance", 6)
if auth["target_class"] != ("isolated" if args.profile == "isolated" else "production"):
    fail("target_class mismatch", 7)
try:
    duration = int(auth["max_duration_seconds"])
except (TypeError, ValueError):
    fail("invalid max_duration_seconds", 8)
if duration < 1 or duration > 3600:
    fail("max_duration_seconds out of range", 9)
for key in ("approved_mutation_scope", "recovery"):
    if not isinstance(auth[key], str) or not auth[key].strip():
        fail(f"empty {key}", 10)

# Authorization is a deadline, not an indefinite grant.
try:
    not_after = datetime.datetime.strptime(auth["not_after"], "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=datetime.timezone.utc)
except (TypeError, ValueError):
    fail("not_after must be UTC YYYY-MM-DDTHH:MM:SSZ", 12)
now = datetime.datetime.now(datetime.timezone.utc)
if now > not_after:
    fail(f"authorization expired at {auth['not_after']}", 13)
remaining = (not_after - now).total_seconds()
if remaining < duration:
    fail(f"authorization expires in {int(remaining)}s, shorter than "
         f"max_duration_seconds={duration}", 15)

for key in ("device_fingerprint", "adapter_sha256", "cleanup_sha256", "install_sha256"):
    if key in auth:
        value = auth[key]
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
            fail(f"{key} must be 64 lowercase hex characters", 14)

if "artifact_sha256" in auth:
    value = auth["artifact_sha256"]
    if not isinstance(value, str):
        fail("artifact_sha256 must be a string", 14)
    if value and not re.fullmatch(r"[0-9a-f]{64}", value):
        fail("artifact_sha256 must be 64 lowercase hex characters", 14)
expected = auth.get("artifact_sha256") or ""
if args.profile == "isolated" and not expected:
    fail("isolated profile requires artifact_sha256", 14)
if args.artifact and expected:
    actual = hashlib.sha256(open(args.artifact, "rb").read()).hexdigest()
    if actual != expected:
        fail("artifact hash mismatch", 11)

print(json.dumps({
    "device_id": auth["device_id"],
    "device_fingerprint": auth["device_fingerprint"],
    "profile": auth["profile"],
    "target_class": auth["target_class"],
    "test_ids": auth["test_ids"],
    "test_id": args.test_id or "",
    "max_duration_seconds": duration,
    "approved_mutation_scope": auth["approved_mutation_scope"],
    "recovery": auth["recovery"],
    "not_after": auth["not_after"],
    "artifact_sha256": expected,
    "adapter_sha256": auth.get("adapter_sha256", ""),
    "cleanup_sha256": auth.get("cleanup_sha256", ""),
    "install_sha256": auth.get("install_sha256", ""),
}, sort_keys=True))
