#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_output="$task_root/.build/ios-interaction"
mkdir -p "$task_output"
xcrun swiftc "$task_root/Apps/TransportLab/Sources/MobileInteraction/ViewportGeometry.swift" \
  "$task_root/Tests/ViewportGeometryTests.swift" -o "$task_output/geometry-tests"
"$task_output/geometry-tests"
