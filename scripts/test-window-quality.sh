#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/window-quality
xcrun swiftc Apps/TransportLab/Sources/WindowTitleIdentity.swift Tests/WindowTitleIdentityTests.swift \
  -o .build/window-quality/title-tests
.build/window-quality/title-tests
xcrun swiftc -O Apps/TransportLab/Sources/MobileInteraction/MobileWindowSizing.swift \
  Apps/TransportLab/Sources/MobileInteraction/WindowEdgeColor.swift Tests/WindowPixelQualityTests.swift \
  -o .build/window-quality/pixel-tests
.build/window-quality/pixel-tests

# Optional: snapshots produced by the owned WindowQualityFixture capture probe.
# The second argument is a QP ceiling; omission retains production's baseline.
if [ "$#" -gt 0 ]; then
  framework_dir="$PWD/.build/SourcePackages/artifacts/webrtc/WebRTC/WebRTC.xcframework/macos-x86_64_arm64"
  xcrun swiftc -O -F "$framework_dir" -framework WebRTC -Xlinker -rpath -Xlinker "$framework_dir" \
    Apps/TransportLab/Sources/ReceiverTelemetry.swift Apps/TransportLab/Sources/HEVCCodec.swift \
    Apps/TransportLab/Sources/EncoderTelemetry.swift Apps/TransportLab/Sources/LabH264Factory.swift \
    Apps/TransportLab/Sources/RTPTrace.swift Apps/TransportLab/Sources/FrameTrace.swift \
    Apps/TransportLab/Sources/WebRTCRuntime.swift Apps/TransportLab/Sources/LabVideoSource.swift \
    Apps/TransportLab/Sources/HDRTestPattern.swift Apps/TransportLab/Sources/MobileInteraction/WindowEdgeColor.swift \
    Tests/WindowQualityCodecProbe.swift -o .build/window-quality/WindowQualityCodecProbe
  .build/window-quality/WindowQualityCodecProbe "$@"
fi
