#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo 'Install XcodeGen: brew install xcodegen' >&2; exit 1; }
xcodegen generate
mode="${1:-mac}"
case "$mode" in
  mac|mac-release)
    configuration=Debug
    if [[ "$mode" == mac-release ]]; then configuration=Release; fi
    # Release + hardened runtime requires app and embedded frameworks to share a real signing identity.
    # Debug keeps ad-hoc local builds available without a developer account.
    identity=-
    if [[ "$mode" == mac-release ]]; then
      identity="${MAC_SIGN_IDENTITY:-Apple Development}"
    fi
    xcodebuild -project KKRemote.xcodeproj -scheme KKRemoteLabMac -configuration "$configuration" \
      -destination 'platform=macOS' -derivedDataPath .build/DerivedData \
      -clonedSourcePackagesDirPath .build/SourcePackages CODE_SIGN_IDENTITY="$identity" build
    if [[ "$mode" == mac-release ]]; then
      app=.build/DerivedData/Build/Products/Release/KKRemoteLabMac.app
      codesign --force --sign "$identity" --timestamp=none "$app/Contents/Frameworks/WebRTC.framework"
      codesign --force --sign "$identity" --timestamp=none --options runtime \
        --entitlements Config/TransportLabMac.entitlements "$app"
      codesign --verify --deep --strict "$app"
    fi
    ;;
  simulator)
    xcodebuild -project KKRemote.xcodeproj -scheme KKRemoteLab -configuration Debug \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/DerivedData \
      -clonedSourcePackagesDirPath .build/SourcePackages CODE_SIGNING_ALLOWED=NO build
    ;;
  archive)
    [[ -f Config/Signing.local.xcconfig ]] || { echo 'Configure Config/Signing.local.xcconfig first.' >&2; exit 1; }
    [[ "${BUILD_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] || { echo 'Set a unique positive BUILD_NUMBER for each upload.' >&2; exit 1; }
    xcodebuild -project KKRemote.xcodeproj -scheme KKRemoteLab -configuration Release \
      -destination 'generic/platform=iOS' -derivedDataPath .build/DerivedData \
      -clonedSourcePackagesDirPath .build/SourcePackages -archivePath .build/KKRemoteLab.xcarchive \
      -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive
    ;;
  *) echo 'Usage: scripts/build-lab.sh mac|mac-release|simulator|archive' >&2; exit 1 ;;
esac
