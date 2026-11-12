#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d .build/KKRemoteLab.xcarchive ]] || { echo 'Create a signed archive first.' >&2; exit 1; }
[[ -f Config/ExportOptions.local.plist ]] || { echo 'Configure Config/ExportOptions.local.plist first.' >&2; exit 1; }
xcodebuild -exportArchive -archivePath .build/KKRemoteLab.xcarchive \
  -exportOptionsPlist Config/ExportOptions.local.plist -exportPath .build/TestFlight \
  -allowProvisioningUpdates
