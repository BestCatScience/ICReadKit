#!/usr/bin/env bash
# Builds the sample app for an iPhone simulator, installs it and runs the Maestro flows in maestro/ci.
# The Maestro CLI is pinned to a version and checksum and cached under build/maestro.
# MAESTRO_DEVICE_ID picks the simulator; MAESTRO_JUNIT_PATH also writes a JUnit report.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

maestro_version="2.7.0"
maestro_sha256="a4ccab6b604617e7aef6db4f885666056eabe5cfa32befaa3bc994041b8fcbb5"
maestro_url="https://github.com/mobile-dev-inc/maestro/releases/download/cli-${maestro_version}/maestro.zip"
cache="$project_root/build/maestro"
archive="$cache/maestro-${maestro_version}.zip"
maestro_bin="$cache/cli-${maestro_version}/maestro/bin/maestro"

if [[ ! -x "$maestro_bin" ]]; then
  mkdir -p "$cache"
  if [[ ! -f "$archive" ]]; then
    curl -fL --retry 3 --output "$archive.part" "$maestro_url"
    mv "$archive.part" "$archive"
  fi
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  if [[ "$actual" != "$maestro_sha256" ]]; then
    echo "Maestro archive checksum mismatch: $actual" >&2
    exit 1
  fi
  unzip -q -o "$archive" -d "$cache/cli-${maestro_version}"
  chmod +x "$maestro_bin"
fi

java_home="${JAVA_HOME:-$(/usr/libexec/java_home -v '17+' 2>/dev/null || true)}"
[[ -x "$java_home/bin/java" ]] || java_home="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
[[ -x "$java_home/bin/java" ]] || { echo 'Maestro needs Java 17 or newer.' >&2; exit 1; }

device="${MAESTRO_DEVICE_ID:?Set MAESTRO_DEVICE_ID to an iPhone simulator UDID}"
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b

[[ -d ICReadKit.xcodeproj ]] || bash scripts/generate-project.sh
xcodebuild build -quiet -project ICReadKit.xcodeproj -scheme ICReadSample \
  -destination "id=$device" -derivedDataPath build/MaestroDerivedData CODE_SIGNING_ALLOWED=NO
xcrun simctl install "$device" build/MaestroDerivedData/Build/Products/Debug-iphonesimulator/ICReadSample.app

report=()
if [[ -n "${MAESTRO_JUNIT_PATH:-}" ]]; then
  mkdir -p "$(dirname "$MAESTRO_JUNIT_PATH")"
  report=(--format=junit --output="$MAESTRO_JUNIT_PATH")
fi
JAVA_HOME="$java_home" MAESTRO_CLI_NO_ANALYTICS=1 MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED=true \
  "$maestro_bin" --device="$device" test --test-output-dir="$cache/output" ${report[@]+"${report[@]}"} maestro/ci
