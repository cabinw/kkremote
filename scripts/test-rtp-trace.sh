#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun swiftc Apps/TransportLab/Sources/RTPTrace.swift Tests/RTPTraceTests.swift -o .build/tests/RTPTraceTests
.build/tests/RTPTraceTests
python3 Tests/RTPTraceAnalysisTests.py
xcrun swiftc Apps/TransportLab/Sources/UDPSocket.swift Tests/KernelDatagramTimestampTests.swift -o .build/tests/KernelDatagramTimestampTests
.build/tests/KernelDatagramTimestampTests
python3 Tests/ReceiverTraceAnalysisTests.py
python3 Tests/FreezeIncidentAnalysisTests.py
