---
title: Deploy the on-bot rocky_media_relay app
type: workflow
status: current
last_updated: 2026-05-11
sources:
  - sources/hf-docs.md   # SDK/apps, SDK/media-architecture
tags: [apps, media, relay, deployment, on-bot]
---

# Deploy the on-bot media relay

`rocky_media_relay` is the Reachy Mini App that runs **on the bot**
and exposes audio + video over plain WebSocket. Rocky's Mac-side
`robot-mic` and `robot-camera` sidecars subscribe to it instead of
opening WebRTC peers. See [`docs/concepts/on-bot-media-relay.md`](../concepts/on-bot-media-relay.md)
for the architecture rationale.

Source lives at `OnBot/rocky_media_relay/` in this repo.

## Validate locally

Before pushing to the bot, sanity-check the package against the
official assistant. From the project root:

```bash
"$HOME/Library/Application Support/Rocky/sidecars/robot-mic/.venv/bin/reachy-mini-app-assistant" \
    check ./OnBot/rocky_media_relay
```

Every `[OK]` should pass, including the entry-point install probe.

## Publish to Hugging Face

The doc-blessed path is to publish as a HF Space and install via the
bot's dashboard:

```bash
"$HOME/Library/Application Support/Rocky/sidecars/robot-mic/.venv/bin/reachy-mini-app-assistant" \
    publish ./OnBot/rocky_media_relay
```

Then on the bot's dashboard, install the app and start it. The
daemon launches `rocky_media_relay` as a subprocess and exposes its
settings page at `http://reachy-mini.local:8042/`.

## Dev loop without publishing

While iterating, you don't want to push every change to HF. Two
options:

1. **`pip install --editable` over SSH.** SSH to the bot, mount the
   project (or `scp` it), then:

   ```bash
   ssh pollen@reachy-mini.local
   cd /tmp/rocky_media_relay        # wherever you scp'd it
   uv pip install --editable . --python /venvs/apps_venv/bin/python
   # restart the app via the daemon's REST API or dashboard
   ```

   The bot's *single-app-at-a-time* constraint applies: starting our
   app stops any other.

2. **Mount the project from your dev machine.** Use sshfs or a
   shared NFS export. Same install command, but edits land
   immediately.

## Start / stop

Via the daemon REST API (`http://reachy-mini.local:8000/docs` for
the OpenAPI page):

```bash
# Start
curl -X POST 'http://reachy-mini.local:8000/api/apps/start' \
     -H 'Content-Type: application/json' \
     -d '{"name": "rocky_media_relay"}'

# Stop
curl -X POST 'http://reachy-mini.local:8000/api/apps/stop'
```

(Endpoints may vary across daemon versions — check the live OpenAPI.)

## Verify the relay is up

From the Mac:

```bash
curl -s http://reachy-mini.local:8042/health
```

You should get JSON with `"ok": true`, recording state, and counters.
Then the Mac-side robot-mic / robot-camera sidecars will start
receiving frames within a couple seconds of opening their WS
connections.
