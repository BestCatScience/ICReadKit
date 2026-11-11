#!/usr/bin/env python3
"""PreToolUse hook: refuse an edit that would add a security review finding.

Only findings the edit introduces count, so an unrelated edit to a file is never
blocked by something already there.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import review_checks  # noqa: E402


def proposed_text(tool: str, tool_input: dict, current: str) -> str | None:
    if tool == "Write":
        return tool_input.get("content", "")
    edits = tool_input.get("edits") if tool == "MultiEdit" else [tool_input]
    text = current
    for edit in edits or []:
        old, new = edit.get("old_string", ""), edit.get("new_string", "")
        if old and old not in text:
            return None  # the edit will fail on its own
        text = text.replace(old, new) if edit.get("replace_all") else text.replace(old, new, 1)
    return text


def findings(path: Path, text: str, root: Path) -> list[str]:
    relative = str(path.relative_to(root))
    if relative.startswith("Sources/ICReadKit/") and relative.endswith(".swift"):
        return review_checks.kit_problems(relative, text)
    if relative == "Package.swift":
        return review_checks.manifest_problems(text, "")
    if relative == "project.yml":
        return review_checks.manifest_problems("", text)
    return []


def decide(event: dict, root: Path = review_checks.ROOT) -> str | None:
    tool = event.get("tool_name", "")
    tool_input = event.get("tool_input", {})
    if tool not in ("Edit", "Write", "MultiEdit") or "file_path" not in tool_input:
        return None
    path = Path(tool_input["file_path"]).resolve()
    if root not in path.parents:
        return None
    current = path.read_text(encoding="utf-8") if path.exists() else ""
    after = proposed_text(tool, tool_input, current)
    if after is None:
        return None

    def strip_line(item: str) -> str:
        parts = item.split(": ", 1)
        return parts[1] if len(parts) == 2 else item

    before = {strip_line(item) for item in findings(path, current, root)}
    added = [item for item in findings(path, after, root) if strip_line(item) not in before]
    return "\n".join(added) if added else None


def main() -> int:
    reason = decide(json.load(sys.stdin))
    if reason:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": "セキュリティレビューの観点に触れる変更です。\n" + reason,
        }}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
