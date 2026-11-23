#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun swiftc Apps/TransportLab/Sources/RTPTrace.swift Apps/TransportLab/Sources/FrameTrace.swift Tests/FrameTraceTests.swift -o .build/tests/FrameTraceTests
.build/tests/FrameTraceTests
frameworks="${1:-.build/TransportTrace/Build/Products/Release}"
xcrun swiftc -F "$frameworks" -framework WebRTC -Xlinker -rpath -Xlinker "$PWD/$frameworks" \
  Apps/TransportLab/Sources/RTPTrace.swift Apps/TransportLab/Sources/FrameTrace.swift Apps/TransportLab/Sources/EncoderTelemetry.swift \
  Tests/EncoderTelemetryTests.swift -o .build/tests/EncoderTelemetryTests
.build/tests/EncoderTelemetryTests
python3 Tests/FrameTraceAnalysisTests.py
