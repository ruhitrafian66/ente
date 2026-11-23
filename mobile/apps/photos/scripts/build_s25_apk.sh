#!/usr/bin/env bash
# Offline fork: build the release APK for the Galaxy S25 only.
#
# Without --target-platform, `flutter build apk` compiles the Rust library and
# the Dart AOT snapshot for android-arm, android-arm64 and android-x64, and
# Gradle then discards everything except arm64-v8a (see abiFilters in
# android/app/build.gradle). Building arm64 only saves time and memory.
#
# Usage: scripts/build_s25_apk.sh [extra flutter build args]
#        scripts/build_s25_apk.sh --install   # also install on the connected device
set -euo pipefail

cd "$(dirname "$0")/.."

install=false
args=()
for arg in "$@"; do
  if [[ "$arg" == "--install" ]]; then
    install=true
  else
    args+=("$arg")
  fi
done

flutter build apk --release --flavor fdroid --target-platform android-arm64 ${args[@]+"${args[@]}"}

apk="build/app/outputs/flutter-apk/app-fdroid-release.apk"
echo "APK: $(pwd)/$apk"

if $install; then
  adb install -r "$apk"
fi
