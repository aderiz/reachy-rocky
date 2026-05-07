#!/usr/bin/env bash
# Idempotent first-run installer for the robot-camera sidecar.

set -euo pipefail

cd "$(dirname "$0")"

NAME="robot-camera"
VENV="$HOME/Library/Application Support/Rocky/sidecars/${NAME}/.venv"

if ! command -v uv >/dev/null 2>&1; then
    echo "error: 'uv' not found on PATH. Install from https://docs.astral.sh/uv/" >&2
    exit 1
fi

mkdir -p "$(dirname "$VENV")"
uv venv "$VENV" --python 3.12
uv pip install --python "$VENV/bin/python" --editable .

echo "robot-camera venv ready at: $VENV"
