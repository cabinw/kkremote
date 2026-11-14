#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
probe_app="$PWD/build/WindowOverlayProbe.app"
mkdir -p "$probe_app/Contents/MacOS"
cat > "$probe_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WindowOverlayProbe</string>
<key>CFBundleIdentifier</key><string>com.cabinw.kkremote.overlay-probe</string>
<key>CFBundleName</key><string>KKRemote 遮罩测试</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xcrun swiftc -O WindowOverlayProbe.swift -o "$probe_app/Contents/MacOS/WindowOverlayProbe"
exec "$probe_app/Contents/MacOS/WindowOverlayProbe" "$@"
