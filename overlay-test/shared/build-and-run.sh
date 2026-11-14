#!/bin/bash
set -euo pipefail
version_dir="$(cd "$1" && pwd)"
shift
version_name="$(basename "$version_dir")"
upper_name="$(printf '%s' "$version_name" | tr '[:lower:]' '[:upper:]')"
shared_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe_app="$version_dir/build/WindowOverlayProbe.app"
mkdir -p "$probe_app/Contents/MacOS"
cat > "$probe_app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WindowOverlayProbe</string>
<key>CFBundleIdentifier</key><string>com.cabinw.kkremote.overlay-probe.${version_name}</string>
<key>CFBundleName</key><string>KKRemote 遮罩 ${upper_name}</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xcrun swiftc -O "$shared_dir/OverlayProbeCore.swift" "$version_dir/WindowOverlayProbe.swift" -o "$probe_app/Contents/MacOS/WindowOverlayProbe"
exec "$probe_app/Contents/MacOS/WindowOverlayProbe" "$@"
