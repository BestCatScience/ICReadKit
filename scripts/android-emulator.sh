#!/usr/bin/env bash
# Starts a headless Android emulator in CI and waits until it has booted.
# Uses the runner's Android SDK; the system image matches the sample's compileSdk.
set -euo pipefail

api="${ANDROID_API:-35}"
image="system-images;android-${api};google_apis;x86_64"
sdk="${ANDROID_HOME:?ANDROID_HOME must point at the Android SDK}"
tools="$sdk/cmdline-tools/latest/bin"

# Let the runner user open /dev/kvm so the emulator runs with hardware acceleration.
echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules >/dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm

yes | "$tools/sdkmanager" --licenses >/dev/null || true
"$tools/sdkmanager" --install "$image" "emulator" "platform-tools" >/dev/null
echo no | "$tools/avdmanager" create avd --force --name ci --package "$image" --device pixel_6 >/dev/null

nohup "$sdk/emulator/emulator" -avd ci -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect >/tmp/emulator.log 2>&1 &
"$sdk/platform-tools/adb" wait-for-device shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done'
"$sdk/platform-tools/adb" shell settings put global window_animation_scale 0
"$sdk/platform-tools/adb" shell settings put global transition_animation_scale 0
"$sdk/platform-tools/adb" shell settings put global animator_duration_scale 0
echo "Emulator ready: $("$sdk/platform-tools/adb" devices | sed -n 2p)"
