#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"

cd "$ROOT/Apps/AndroidClient"
./gradlew testDebugUnitTest assembleDebug "$@"
echo "ANDROID_BUILD_PASSED apk=$ROOT/Apps/AndroidClient/app/build/outputs/apk/debug/app-debug.apk"
