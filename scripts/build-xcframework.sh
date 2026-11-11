#!/usr/bin/env bash
# Archives ICReadKit for devices and the simulator and joins them into build/ICReadKit.xcframework.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
[[ -d ICReadKit.xcodeproj ]] || bash scripts/generate-project.sh

archives="$project_root/build/archives"
output="$project_root/build/ICReadKit.xcframework"
rm -rf "$archives" "$output"

for destination in 'generic/platform=iOS' 'generic/platform=iOS Simulator'; do
  name="$(echo "$destination" | tr ' =/' '---')"
  xcodebuild archive -quiet \
    -project ICReadKit.xcodeproj \
    -scheme ICReadKit \
    -destination "$destination" \
    -archivePath "$archives/$name.xcarchive" \
    -derivedDataPath "$project_root/build/FrameworkDerivedData" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    CODE_SIGNING_ALLOWED=NO
done

xcodebuild -create-xcframework \
  -framework "$archives/generic-platform-iOS.xcarchive/Products/Library/Frameworks/ICReadKit.framework" \
  -framework "$archives/generic-platform-iOS-Simulator.xcarchive/Products/Library/Frameworks/ICReadKit.framework" \
  -output "$output"
echo "Built $output"
