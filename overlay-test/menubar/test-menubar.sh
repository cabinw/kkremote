#!/bin/bash
set -euo pipefail
menubar_dir="$(cd "$(dirname "$0")" && pwd)"
root_dir="$(cd "$menubar_dir/.." && pwd)"
app_bundle="$menubar_dir/build/OverlayTestMenuBar.app"
mkdir -p "$app_bundle/Contents/MacOS"

cat > "$app_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OverlayTestMenuBar</string>
<key>CFBundleIdentifier</key><string>com.cabinw.kkremote.overlay-test.menubar</string>
<key>CFBundleName</key><string>OverlayTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

xcrun swiftc -O "$menubar_dir/OverlayTestMenuBar.swift" -o "$app_bundle/Contents/MacOS/OverlayTestMenuBar"

if [[ "${1:-}" == "--help" ]]; then
  exec "$app_bundle/Contents/MacOS/OverlayTestMenuBar" --help
fi

exec "$app_bundle/Contents/MacOS/OverlayTestMenuBar" --root "$root_dir" "$@"
