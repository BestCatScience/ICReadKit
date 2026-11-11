#!/usr/bin/env bash
# Generates ICReadKit.xcodeproj with the checksum-pinned XcodeGen in Tools/XcodeGen.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

tool_package="$project_root/Tools/XcodeGen"
swift package --package-path "$tool_package" resolve
xcodegen_path="$(find "$tool_package/.build/artifacts" -type f -path '*/xcodegen-2.46.0-macosx/bin/xcodegen' -print -quit)"
if [[ -z "$xcodegen_path" ]]; then
  echo 'The checksum-verified XcodeGen 2.46.0 artifact was not resolved.' >&2
  exit 1
fi
"$xcodegen_path" generate --spec "$project_root/project.yml"
