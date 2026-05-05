#!/usr/bin/env bash
# Build (debug) and launch Rocky.app. Tries to use a proper .app bundle
# so macOS permission prompts fire correctly. For a quick non-app run,
# use `swift run Rocky` directly.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
"$REPO/scripts/build-app.sh"
open "$REPO/build/Rocky.app"
