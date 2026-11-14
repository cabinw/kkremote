#!/bin/bash
set -euo pipefail
exec "$(dirname "$0")/../shared/build-and-run.sh" "$(dirname "$0")" "$@"
