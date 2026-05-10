#!/usr/bin/env bash
# Fetch CoreML model weights for Rocky's v0.2 AI stack.
#
# Models live under ~/Library/Application Support/Rocky/Models/. Each
# is fetched only if the destination is absent, so re-running is safe
# and cheap.
#
# Currently installs:
#   silero_vad.mlmodelc   (Silero VAD v6.0.0, FluidInference/silero-vad-coreml, MIT, ~1 MB)
#
# Future milestones add more here:
#   M3 — whisper-large-v3-turbo (WhisperKit STT, ~700 MB)
#   M5 — Qwen3-VL-4B-Instruct-4bit (mlx-vlm brain, ~2.5 GB)
#   M6 — Qwen3-TTS-12Hz-1.7B-CustomVoice (streaming TTS, ~2 GB)
#
# Usage:
#   ./scripts/download-models.sh           # fetch all default models
#   ./scripts/download-models.sh silero    # fetch just silero (M2)
#
# Run from the repo root.

set -euo pipefail

MODELS_DIR="$HOME/Library/Application Support/Rocky/Models"
mkdir -p "$MODELS_DIR"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON_HELPER="$REPO_ROOT/scripts/_hf_fetch.py"

# Set of models to fetch. Defaults to all; CLI args narrow.
TARGETS=("$@")
if [[ ${#TARGETS[@]} -eq 0 ]]; then
    TARGETS=(silero)
fi

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

fetch_silero() {
    local dest="${MODELS_DIR}/silero-vad/silero_vad.mlmodelc"
    if [[ -d "$dest" && -f "$dest/coremldata.bin" ]]; then
        echo "==> Silero VAD already installed at: $dest"
        return 0
    fi
    echo "==> Installing Silero VAD (FluidInference/silero-vad-coreml, ~1 MB)"
    rm -rf "$dest"
    mkdir -p "$(dirname "$dest")"
    python3 "$PYTHON_HELPER" \
        --repo FluidInference/silero-vad-coreml \
        --subdir silero_vad.mlmodelc \
        --dest "$dest"
    echo "==> Silero VAD installed: $dest"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

for target in "${TARGETS[@]}"; do
    case "$target" in
        silero|silero-vad)
            fetch_silero
            ;;
        all)
            fetch_silero
            ;;
        *)
            echo "error: unknown target '$target'. Known: silero, all" >&2
            exit 1
            ;;
    esac
done
