#!/usr/bin/env bash
# Idempotent first-run installer for the face-tracker sidecar.
#
# Creates a uv-managed virtualenv under
# ~/Library/Application Support/Rocky/sidecars/face-tracker/.venv/
# and installs the sidecar's dependencies (M3a: numpy only).
#
# Re-runs are safe; uv reuses existing artifacts when the lockfile matches.

set -euo pipefail

cd "$(dirname "$0")"

NAME="face-tracker"
VENV="$HOME/Library/Application Support/Rocky/sidecars/${NAME}/.venv"

if ! command -v uv >/dev/null 2>&1; then
    echo "error: 'uv' not found on PATH. Install from https://docs.astral.sh/uv/" >&2
    exit 1
fi

mkdir -p "$(dirname "$VENV")"
uv venv "$VENV" --python 3.12
uv pip install --python "$VENV/bin/python" --editable .

# Optional extras can be enabled by re-running setup.sh with FT_EXTRAS set:
#   FT_EXTRAS=sam,robot ./setup.sh
if [[ -n "${FT_EXTRAS:-}" ]]; then
    uv pip install --python "$VENV/bin/python" --editable ".[${FT_EXTRAS}]"
fi

echo "face-tracker venv ready at: $VENV"
