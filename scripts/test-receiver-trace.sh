#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
framework_dir="$PWD/.build/SourcePackages/artifacts/webrtc/WebRTC/WebRTC.xcframework/macos-x86_64_arm64"
mkdir -p .build/receiver-trace
xcrun swiftc -O -F "$framework_dir" -framework WebRTC -Xlinker -rpath -Xlinker "$framework_dir" \
  Apps/TransportLab/Sources/{RTPTrace,FrameTrace,WebRTCRuntime,EncoderTelemetry,ReceiverTelemetry,HEVCCodec,LabH264Factory,HDRVideoView}.swift \
  Tests/ReceiverTelemetryTests.swift -o .build/receiver-trace/ReceiverTelemetryTests
.build/receiver-trace/ReceiverTelemetryTests
python3 Tests/ReceiverTraceAnalysisTests.py
