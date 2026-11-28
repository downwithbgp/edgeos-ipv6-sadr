#!/usr/bin/env python3
"""Turn qualification TSV into machine-readable and human-readable results."""
import argparse
import json
import os
import sys
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=("plan", "execute"), required=True)
    ap.add_argument("--tsv", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--router", default="")
    ap.add_argument("--artifact", default="")
    ap.add_argument("--firmware", default="")
    ap.add_argument("--profile", default="plan",
                    choices=("plan", "observe", "canary", "maintenance", "isolated"))
    args = ap.parse_args()

    steps = []
    with open(args.tsv, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            while len(parts) < 5:
                parts.append("")
            steps.append(dict(zip(("id", "description", "status", "detail", "command"), parts)))

    counts = {}
    for step in steps:
        counts[step["status"]] = counts.get(step["status"], 0) + 1
    result = {
        "schema": 1,
        "mode": args.mode,
        "profile": args.profile,
        "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "router": args.router,
        "artifact": args.artifact,
        "firmware": args.firmware,
        "steps": steps,
        "summary": {
            "total": len(steps),
            "counts": counts,
            "complete": bool(steps) and all(s["status"] == "pass" for s in steps),
        },
    }
    with open(os.path.join(args.out, "results.json"), "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2, sort_keys=True)
        fh.write("\n")

    lines = [
        f"# IPv6 SADR {args.profile} qualification report",
        "",
        f"- Mode: **{args.mode}**",
        f"- Profile: **{args.profile}**",
        f"- Generated: `{result['generated']}`",
        f"- Router: `{args.router or 'not supplied'}`",
        f"- Artifact: `{args.artifact or 'not supplied'}`",
        f"- Firmware: `{args.firmware or 'not supplied'}`",
        f"- Complete: **{str(result['summary']['complete']).lower()}**",
        "",
        "| Step | Status | Detail |",
        "|---|---|---|",
    ]
    for step in steps:
        detail = step["detail"].replace("|", "\\|")
        lines.append(f"| `{step['id']}` | **{step['status']}** | {detail} |")
    lines.extend([
        "",
        "## Status meanings",
        "",
        "- **pass**: executed with required evidence.",
        "- **fail**: executed and failed; investigate/rollback.",
        "- **blocked**: an execute prerequisite or adapter was missing.",
        "- **planned**: plan mode only; nothing was executed.",
        "",
        "A finite probe set never proves absence of leakage mathematically. Report probe counts,",
        "capture filters and observation resolution; retain captures with the results.",
        "",
    ])
    with open(os.path.join(args.out, "results.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    print(json.dumps(result["summary"], sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
