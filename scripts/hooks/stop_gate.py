#!/usr/bin/env python3
"""Stop hook: do not end a turn while the review checks or the script tests fail."""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECKS = [
    [sys.executable, "scripts/review_checks.py"],
    [sys.executable, "-m", "unittest", "discover", "-q", "-s", "scripts/tests"],
]


def failures(root: Path = ROOT, runner=subprocess.run, checks=CHECKS) -> list[str]:
    found = []
    for command in checks:
        result = runner(command, cwd=root, capture_output=True, text=True)
        if result.returncode != 0:
            found.append(f"$ {' '.join(command[1:])}\n{(result.stderr or result.stdout).strip()[-1500:]}")
    return found


def main() -> int:
    event = json.load(sys.stdin)
    if event.get("stop_hook_active"):
        return 0
    found = failures()
    if found:
        print(json.dumps({"decision": "block", "reason": "検査が通っていません。\n\n" + "\n\n".join(found)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
