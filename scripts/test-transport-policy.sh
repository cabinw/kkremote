#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun swiftc Apps/TransportLab/Sources/TransportImpairment.swift Apps/TransportLab/Sources/ResourceTelemetry.swift Tests/TransportImpairmentTests.swift -o .build/tests/TransportImpairmentTests
.build/tests/TransportImpairmentTests
