#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
framework_dir="$PWD/.build/SourcePackages/artifacts/webrtc/WebRTC/WebRTC.xcframework/macos-x86_64_arm64"
mkdir -p .build/hdr
common=(Apps/TransportLab/Sources/HEVCCodec.swift Apps/TransportLab/Sources/EncoderTelemetry.swift Apps/TransportLab/Sources/LabH264Factory.swift)
xcrun swiftc -O -F "$framework_dir" -framework WebRTC -Xlinker -rpath -Xlinker "$framework_dir" \
  "${common[@]}" Tests/HEVCNALTests.swift -o .build/hdr/HEVCNALTests
.build/hdr/HEVCNALTests
xcrun swiftc -O -F "$framework_dir" -framework WebRTC -Xlinker -rpath -Xlinker "$framework_dir" \
  "${common[@]}" Apps/TransportLab/Sources/HDRVideoView.swift Tests/HDRRendererProbe.swift -o .build/hdr/HDRRendererProbe
.build/hdr/HDRRendererProbe Apps/TransportLab/Resources/Main10Probe.hevc
