#!/usr/bin/env python3
"""Generate or verify the R1 execution manifest.

The manifest binds every executable component and sourced library used by the
qualification path. It is generated, not hand-maintained. The manifest hash is
computed over only the schema and the sorted file->sha256 map, so the generated
timestamp does not change the binding.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import sys

SCHEMA = 1
FILES = (
    "qualification/profile.sh",
    "qualification/run.sh",
    "qualification/authorization.py",
    "qualification/report.py",
    "qualification/execution_manifest.py",
    "qualification/finalize-candidate.sh",
    "qualification/adapters/r1-canary.sh",
    "qualification/adapters/r1-install.sh",
    "qualification/adapters/r1-cleanup.sh",
    "qualification/lib/identity.sh",
    "qualification/lib/controller.sh",
)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical(files):
    return json.dumps(
        {"schema": SCHEMA, "files": files},
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def generate(root, out):
    missing = [rel for rel in FILES if not (root / rel).is_file()]
    if missing:
        print(f"execution manifest: missing files: {', '.join(missing)}", file=sys.stderr)
        return 1
    files = {rel: sha256(root / rel) for rel in FILES}
    document = {
        "schema": SCHEMA,
        "generated_utc": datetime.datetime.now(datetime.timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "files": files,
        "manifest_sha256": hashlib.sha256(canonical(files)).hexdigest(),
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(document["manifest_sha256"])
    return 0


def verify(root, manifest):
    try:
        document = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"execution manifest: cannot read {manifest}: {exc}", file=sys.stderr)
        return 1
    if document.get("schema") != SCHEMA:
        print("execution manifest: schema mismatch", file=sys.stderr)
        return 1
    files = document.get("files")
    if not isinstance(files, dict) or set(files) != set(FILES):
        print("execution manifest: file set mismatch", file=sys.stderr)
        return 1
    for rel in FILES:
        path = root / rel
        if not path.is_file():
            print(f"execution manifest: missing {rel}", file=sys.stderr)
            return 1
        actual = sha256(path)
        if files[rel] != actual:
            print(f"execution manifest: hash mismatch for {rel}", file=sys.stderr)
            return 1
    expected = hashlib.sha256(canonical(files)).hexdigest()
    if document.get("manifest_sha256") != expected:
        print("execution manifest: manifest hash mismatch", file=sys.stderr)
        return 1
    print(f"execution manifest verified: {expected}")
    return 0


def main():
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--write", action="store_true")
    group.add_argument("--verify", action="store_true")
    parser.add_argument("--root", required=True)
    parser.add_argument("--out")
    parser.add_argument("--manifest")
    args = parser.parse_args()
    root = pathlib.Path(args.root).resolve()
    if args.write:
        if not args.out:
            parser.error("--write requires --out")
        return generate(root, pathlib.Path(args.out))
    if not args.manifest:
        parser.error("--verify requires --manifest")
    return verify(root, pathlib.Path(args.manifest))


if __name__ == "__main__":
    sys.exit(main())
