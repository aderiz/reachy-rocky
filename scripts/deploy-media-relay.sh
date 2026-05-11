#!/usr/bin/env bash
# Deploy OnBot/rocky_media_relay to the bot for dev iteration.
#
# Flow:
#   1. rsync the app source to the bot (~/rocky_media_relay/).
#   2. SSH in and `uv pip install --editable .` into /venvs/apps_venv/.
#   3. Print the next step (start via dashboard or daemon REST).
#
# Idempotent: re-running just refreshes the source + the editable
# install. The daemon picks up the updated entry-point on next app
# launch.
#
# Pre-req for fully unattended use:
#     ssh-copy-id pollen@reachy-mini.local
# Otherwise rsync + ssh will prompt for the bot password each step.

set -euo pipefail

cd "$(dirname "$0")/.."

BOT_USER="${ROCKY_BOT_USER:-pollen}"
BOT_HOST="${ROCKY_BOT_HOST:-reachy-mini.local}"
BOT_DEST="${ROCKY_BOT_APP_DIR:-~/rocky_media_relay}"
APPS_VENV_PY="/venvs/apps_venv/bin/python"

echo "==> Syncing OnBot/rocky_media_relay/ → ${BOT_USER}@${BOT_HOST}:${BOT_DEST}"
rsync -azv --delete \
    --exclude '__pycache__' \
    --exclude '.venv' \
    --exclude '*.egg-info' \
    OnBot/rocky_media_relay/ \
    "${BOT_USER}@${BOT_HOST}:${BOT_DEST}/"

echo
echo "==> Installing app (editable) into ${APPS_VENV_PY%/*}"
# `--system` would refuse the apps venv; we point uv at that python
# explicitly. uv is preinstalled on the Wireless image; falling back
# to plain pip if not. The entry-point in pyproject.toml registers
# the app so the daemon's app loader can discover it.
ssh "${BOT_USER}@${BOT_HOST}" "
    set -e
    cd ${BOT_DEST}
    if command -v uv >/dev/null 2>&1; then
        uv pip install --python ${APPS_VENV_PY} --editable .
    else
        ${APPS_VENV_PY} -m pip install --editable .
    fi
    echo
    echo '== Installed entry points =='
    ${APPS_VENV_PY} -c 'from importlib.metadata import entry_points; [print(f\"  {ep.name} -> {ep.value}\") for ep in entry_points(group=\"reachy_mini_apps\")]'
"

echo
echo "==> Next steps:"
echo "    1. Open the bot dashboard or POST to the daemon REST to start the app."
echo "       Example: curl -X POST http://${BOT_HOST}:8000/api/apps/start \\"
echo "                  -H 'Content-Type: application/json' \\"
echo "                  -d '{\"name\": \"rocky_media_relay\"}'"
echo "       (Verify the live endpoint shape against http://${BOT_HOST}:8000/openapi.json — the path may differ across daemon versions.)"
echo
echo "    2. Verify: curl -s http://${BOT_HOST}:8042/health"
echo
echo "    3. Open Rocky.app — robot-mic / robot-camera sidecars will connect to the relay automatically."
