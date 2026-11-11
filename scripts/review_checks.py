#!/usr/bin/env python3
"""Security review checks for the kit, run in CI and by the Claude Code hooks.

They mirror a first-pass security review: code that invites attacks, hard-coded
URLs, and new open-source dependencies. Each rule names the reason a reviewer
would give, so a failure reads like review feedback.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KIT_SOURCES = ROOT / "Sources" / "ICReadKit"

# (pattern, reason). Applied to Swift files in the kit only.
KIT_RULES = [
    (re.compile(r"https?://"), "URL の直書き: SDK は通信しない。送り先は組み込み先が決める"),
    (re.compile(r"\b(print|debugPrint|NSLog|os_log)\s*\("), "ログ出力: カードから読んだものを SDK が書き出さない"),
    (re.compile(r"\bLogger\s*\("), "ログ出力: カードから読んだものを SDK が書き出さない"),
    (re.compile(r"\b(UserDefaults|FileManager|SecItemAdd|NSKeyedArchiver)\b"), "保存: カードのデータを端末に残さない"),
    (re.compile(r"\bURLSession\b"), "通信: SDK はネットワークに出ない"),
    (re.compile(r"ins:\s*0x(20|24|2C|2c)\b|\b(verify|changeReferenceData|resetRetryCounter)\s*\("),
     "暗証番号の命令: 間違えるとカードのロックに近づく"),
]
ALLOWED_INSTRUCTIONS = "static let allowed: Set<UInt8> = [select, readBinary]"


def kit_problems(name: str, text: str) -> list[str]:
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("//") or stripped.startswith("///"):
            continue
        for pattern, reason in KIT_RULES:
            if pattern.search(line):
                found.append(f"{name}:{number}: {reason}")
    if name.endswith("APDU.swift") and ALLOWED_INSTRUCTIONS not in text:
        found.append(f"{name}: 送れる命令が SELECT と READ BINARY 以外に広がっている")
    return found


def manifest_problems(package_swift: str, project_yml: str) -> list[str]:
    found = []
    if re.search(r"\.package\s*\(", package_swift):
        found.append("Package.swift: 新しい依存の追加は、組み込み先との衝突を招く")
    if re.search(r"^packages:", project_yml, re.MULTILINE):
        found.append("project.yml: 新しい依存の追加は、組み込み先との衝突を招く")
    return found


def problems(root: Path = ROOT) -> list[str]:
    found = []
    for path in sorted((root / "Sources" / "ICReadKit").rglob("*.swift")):
        found += kit_problems(str(path.relative_to(root)), path.read_text(encoding="utf-8"))
    found += manifest_problems((root / "Package.swift").read_text(encoding="utf-8"),
                               (root / "project.yml").read_text(encoding="utf-8"))
    return found


def main() -> int:
    found = problems()
    for line in found:
        print(line, file=sys.stderr)
    if not found:
        print("Security review checks passed.")
    return 1 if found else 0


if __name__ == "__main__":
    raise SystemExit(main())
