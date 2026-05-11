#!/usr/bin/env bash
# Idempotent installer for the Rocky MLX-STT sidecar.
#
# Creates a uv-managed virtualenv under
# ~/Library/Application Support/Rocky/sidecars/mlx-stt/.venv/
# and installs mlx-whisper + numpy.
#
# The model itself (mlx-community/whisper-large-v3-mlx, ~3 GB) is
# downloaded on first use by mlx-whisper into ~/.cache/huggingface/.
# Pass --pre-fetch to download eagerly during setup.
#
# Usage:
#   ./Sidecars/mlx-stt/setup.sh              # install deps; defer fetch
#   ./Sidecars/mlx-stt/setup.sh --pre-fetch  # install + download model now

set -euo pipefail

cd "$(dirname "$0")"

NAME="mlx-stt"
VENV="$HOME/Library/Application Support/Rocky/sidecars/${NAME}/.venv"

if ! command -v uv >/dev/null 2>&1; then
    echo "error: 'uv' not found on PATH. Install from https://docs.astral.sh/uv/" >&2
    exit 1
fi

echo "==> Creating venv at $VENV"
mkdir -p "$(dirname "$VENV")"
uv venv "$VENV" --python 3.11
uv pip install --python "$VENV/bin/python" --editable .

if [[ "${1:-}" == "--pre-fetch" ]]; then
    MODEL="${ROCKY_STT_MODEL:-mlx-community/whisper-large-v3-mlx}"
    echo "==> Pre-fetching $MODEL (this may take a few minutes)"
    "$VENV/bin/python" -c "
from huggingface_hub import snapshot_download
snapshot_download(repo_id='$MODEL')
print('==> Model cached.')
"
fi

echo "==> MLX-STT sidecar ready."
echo "    Model: \${ROCKY_STT_MODEL:-mlx-community/whisper-large-v3-mlx}"
echo "    First transcribe downloads the model on demand if --pre-fetch was skipped."
