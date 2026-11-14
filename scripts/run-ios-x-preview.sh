#!/bin/bash
set -euo pipefail
preview_repo="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$preview_repo" <<'PY' | ego-browser nodejs
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
print('globalThis.kkremotePreviewDirectory = ' + json.dumps(str(root / '.build/ios-x-preview')) + ';')
print((root / 'scripts/ios-x-browser-preview.mjs').read_text())
PY
