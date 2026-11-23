#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun swiftc Apps/TransportLab/Sources/WindowTitleIdentity.swift Apps/TransportLab/Sources/WindowSession.swift Apps/TransportLab/Sources/SignalTransport.swift Apps/TransportLab/Sources/MediaDatagram.swift \
  Tests/MediaDatagramTests.swift -o .build/tests/MediaDatagramTests
.build/tests/MediaDatagramTests
xcrun swiftc Apps/TransportLab/Sources/WindowTitleIdentity.swift Apps/TransportLab/Sources/WindowSession.swift Apps/TransportLab/Sources/SignalTransport.swift Apps/TransportLab/Sources/MediaDatagram.swift \
  Apps/TransportLab/Sources/RTPTrace.swift Apps/TransportLab/Sources/TransportImpairment.swift Apps/TransportLab/Sources/LoopbackDatagramPort.swift Apps/TransportLab/Sources/UDPSocket.swift Apps/TransportLab/Sources/DatagramBridge.swift \
  Tests/DatagramBridgeTests.swift -o .build/tests/DatagramBridgeTests
.build/tests/DatagramBridgeTests
