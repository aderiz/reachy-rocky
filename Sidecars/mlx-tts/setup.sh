#!/usr/bin/env bash
# Idempotent first-run installer for the mlx-tts sidecar.
#
# The default `say` backend is stdlib-only (relies on macOS's bundled TTS)
# so we don't strictly need a venv — but creating one keeps the supervisor
# happy under the standard manifest convention.
#
# To enable the real F5-TTS-MLX voice-cloning backend, re-run with:
#   FT_EXTRAS=mlx ./setup.sh

set -euo pipefail

cd "$(dirname "$0")"

NAME="mlx-tts"
VENV="$HOME/Library/Application Support/Rocky/sidecars/${NAME}/.venv"

if ! command -v uv >/dev/null 2>&1; then
    echo "error: 'uv' not found on PATH. Install from https://docs.astral.sh/uv/" >&2
    exit 1
fi

mkdir -p "$(dirname "$VENV")"
uv venv "$VENV" --python 3.12
uv pip install --python "$VENV/bin/python" --editable .

if [[ -n "${FT_EXTRAS:-}" ]]; then
    uv pip install --python "$VENV/bin/python" --editable ".[${FT_EXTRAS}]"
fi

echo "mlx-tts venv ready at: $VENV"
