#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun swiftc Apps/TransportLab/Sources/SignalTransport.swift Tests/SignalTransportTests.swift \
  -o .build/tests/SignalTransportTests
.build/tests/SignalTransportTests
