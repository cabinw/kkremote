#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
framework_dir="$PWD/.build/SourcePackages/artifacts/webrtc/WebRTC/WebRTC.xcframework/macos-x86_64_arm64"
mkdir -p .build/hdr
xcrun swiftc -O -F "$framework_dir" -framework WebRTC -Xlinker -rpath -Xlinker "$framework_dir" \
  Apps/TransportLab/Sources/HEVCCodec.swift Apps/TransportLab/Sources/EncoderTelemetry.swift Apps/TransportLab/Sources/LabH264Factory.swift \
  Apps/TransportLab/Sources/LabVideoSource.swift Apps/TransportLab/Sources/HDRTestPattern.swift \
  Tests/HEVCMain10Probe.swift -o .build/hdr/Main10Probe
.build/hdr/Main10Probe .build/hdr/main10.hevc
