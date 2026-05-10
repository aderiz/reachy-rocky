#!/usr/bin/env bash
# Idempotent installer for the Rocky brain sidecar.
#
# Creates a uv-managed virtualenv under
# ~/Library/Application Support/Rocky/sidecars/brain/.venv/
# and installs mlx-vlm + Qwen3-VL deps. Re-runs are safe; uv reuses
# existing artifacts when the lockfile matches.
#
# The model itself (Qwen3-VL-4B-Instruct-4bit, ~2.5 GB) is downloaded
# on first use by mlx-vlm into ~/.cache/huggingface/. Pass --pre-fetch
# to download eagerly during setup instead of at first conversation.
#
# Usage:
#   ./Sidecars/brain/setup.sh              # install deps; defer weight fetch
#   ./Sidecars/brain/setup.sh --pre-fetch  # install + download model now
#   FT_EXTRAS=turboquant ./Sidecars/brain/setup.sh   # install with KV compression

set -euo pipefail

cd "$(dirname "$0")"

NAME="brain"
VENV="$HOME/Library/Application Support/Rocky/sidecars/${NAME}/.venv"

if ! command -v uv >/dev/null 2>&1; then
    echo "error: 'uv' not found on PATH. Install from https://docs.astral.sh/uv/" >&2
    exit 1
fi

echo "==> Creating venv at $VENV"
mkdir -p "$(dirname "$VENV")"
uv venv "$VENV" --python 3.11
uv pip install --python "$VENV/bin/python" --editable .

if [[ -n "${FT_EXTRAS:-}" ]]; then
    uv pip install --python "$VENV/bin/python" --editable ".[${FT_EXTRAS}]"
fi

if [[ "${1:-}" == "--pre-fetch" ]]; then
    MODEL="${ROCKY_BRAIN_MODEL:-mlx-community/Qwen3-VL-4B-Instruct-4bit}"
    echo "==> Pre-fetching $MODEL (this may take a few minutes)"
    "$VENV/bin/python" -c "
from huggingface_hub import snapshot_download
snapshot_download(repo_id='$MODEL')
print('==> Model cached.')
"
fi

echo "==> Brain sidecar ready."
echo "    Model:       \${ROCKY_BRAIN_MODEL:-mlx-community/Qwen3-VL-4B-Instruct-4bit}"
echo "    First run downloads the model on demand if --pre-fetch was skipped."
