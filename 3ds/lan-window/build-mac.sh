#!/bin/sh
set -eu
cd "$(dirname "$0")"
src=../../Apps/TransportLab/Sources
mkdir -p .build
swiftc -O -parse-as-library Capture.swift WindowDesk.swift DeskArt.swift "$src/WindowControl.swift" "$src/WindowSession.swift" \
    "$src/WindowTitleIdentity.swift" "$src/MobileInteraction/MobileWindowSizing.swift" -o .build/capture
swiftc -O -parse-as-library Fixture.swift -o .build/fixture
