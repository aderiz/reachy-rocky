#!/usr/bin/env bash
# Idempotent first-run installer for the mempalace memory sidecar.
#
# - Creates a uv-managed virtualenv under
#   ~/Library/Application Support/Rocky/sidecars/mempalace/.venv/
# - Installs the sidecar package + mempalace.
# - Initialises the palace at ~/Library/Application Support/Rocky/Memory/
#   if it doesn't exist yet (mempalace init is idempotent).
#
# Re-runs are safe.

set -euo pipefail

cd "$(dirname "$0")"

NAME="mempalace"
VENV="$HOME/Library/Application Support/Rocky/sidecars/${NAME}/.venv"
PALACE="$HOME/Library/Application Support/Rocky/Memory"

if ! command -v uv >/dev/null 2>&1; then
    echo "error: 'uv' not found on PATH. Install from https://docs.astral.sh/uv/" >&2
    exit 1
fi

mkdir -p "$(dirname "$VENV")"
uv venv "$VENV" --python 3.12
uv pip install --python "$VENV/bin/python" --editable .

# Initialise the palace directory if it isn't there yet. mempalace init
# writes a mempalace.yaml + creates the chroma backing files. The runner
# falls back to running this lazily on first request, but doing it here
# means the very first call doesn't pay the init cost.
if [[ ! -f "$PALACE/mempalace.yaml" ]]; then
    mkdir -p "$PALACE"
    echo "Initialising palace at $PALACE..."
    "$VENV/bin/mempalace" init "$PALACE" --no-mine || {
        echo "warn: mempalace init returned non-zero; will retry from runner.py" >&2
    }
fi

echo "mempalace venv ready at: $VENV"
echo "palace at: $PALACE"
