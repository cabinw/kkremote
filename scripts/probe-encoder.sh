#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
framework_dir="$PWD/.build/SourcePackages/artifacts/webrtc/WebRTC/WebRTC.xcframework/macos-x86_64_arm64"
[[ -d "$framework_dir/WebRTC.framework" ]] || { echo 'Build the Mac app first to resolve the pinned WebRTC SDK.' >&2; exit 1; }
mkdir -p .build/tests
xcrun swiftc -O -F "$framework_dir" -framework WebRTC -Xlinker -rpath -Xlinker "$framework_dir" \
  Apps/TransportLab/Sources/EncoderTelemetry.swift Apps/TransportLab/Sources/LabH264Factory.swift \
  Apps/TransportLab/Sources/TestPattern.swift Apps/TransportLab/Sources/DesktopPattern.swift \
  Tests/EncoderRateProbe.swift -o .build/tests/EncoderRateProbe
exec .build/tests/EncoderRateProbe "$@"
