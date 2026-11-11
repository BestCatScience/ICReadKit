#!/usr/bin/env bash
# Compares the built framework's public API with api/ICReadKit.json and fails on a breaking change.
# Run after scripts/build-xcframework.sh. Pass --update to accept the current API as the new baseline,
# and say in the commit why the break is intended.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

framework_dir="build/ICReadKit.xcframework/ios-arm64"
baseline="api/ICReadKit.json"
current="build/api-current.json"
report="build/api-breakage.txt"
[[ -d "$framework_dir/ICReadKit.framework" ]] || { echo 'Build the XCFramework first.' >&2; exit 1; }

sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos swift-api-digester -dump-sdk -module ICReadKit -F "$framework_dir" \
  -target arm64-apple-ios16.0 -sdk "$sdk" -avoid-tool-args -abort-on-module-fail -o "$current"

if [[ "${1:-}" == '--update' ]]; then
  cp "$current" "$baseline"
  echo "Updated $baseline"
  exit 0
fi

xcrun --sdk iphoneos swift-api-digester -diagnose-sdk -input-paths "$baseline" -input-paths "$current" -o "$report" >/dev/null
# The report lists section headers as /* ... */ comments; any other line is a change.
if grep -v -E '^\s*$|^/\*' "$report"; then
  echo 'The public API changed in a way that can break a host app (see above).' >&2
  echo 'If it is intended, run scripts/check-api.sh --update and explain the break in the commit.' >&2
  exit 1
fi
echo 'Public API is compatible with the baseline.'
