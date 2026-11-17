#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun swiftc \
  Apps/TransportLab/Sources/MobileInteraction/MobileWindowSizing.swift \
  Apps/TransportLab/Sources/WindowTitleIdentity.swift \
  Apps/TransportLab/Sources/WindowControl.swift \
  Apps/TransportLab/Sources/WindowSession.swift \
  Apps/TransportLab/Sources/SignalTransport.swift \
  Apps/TransportLab/Sources/DeviceIdentity.swift \
  Apps/TransportLab/Sources/CoordSignaling.swift \
  Tests/DeviceIdentityTests.swift \
  -o .build/tests/DeviceIdentityTests
.build/tests/DeviceIdentityTests
