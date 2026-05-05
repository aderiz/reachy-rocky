---
title: Run and debug
type: workflow
status: current
last_updated: 2026-05-05
sources:
  - sources/hf-docs.md
  - sources/agents-md.md
tags: [debugging, daemon, logs]
---

# Run and debug

## Daemon control (Wireless)

```bash
ssh pollen@reachy-mini.local

sudo systemctl status reachy-mini-daemon
sudo systemctl restart reachy-mini-daemon       # wait ~30 s before starting an app
sudo systemctl stop reachy-mini-daemon
sudo systemctl start reachy-mini-daemon
```

## Logs

```bash
# Live tail
sudo journalctl -u reachy-mini-daemon -f

# Recent, filtering out HTTP access noise
sudo journalctl -u reachy-mini-daemon --since '5 min ago' \
    | grep -v "uvicorn\|GET \|POST "
```

App stdout/stderr is captured by the daemon and appears in the same journal stream. (When running the daemon in a foreground terminal — Lite/sim — the app's logs print to that terminal directly.)

## Health checks

```bash
# Robot self-check
reachyminios_check

# Daemon control-loop frequency (should be ~20 ms / 50 Hz)
curl http://reachy-mini.local:8000/api/daemon/status

# From Python
python -c "from reachy_mini import ReachyMini; m=ReachyMini(); print(m.client.get_status())"
```

A healthy report looks like:

```
ControlLoopStats(period=~19.99ms, read_dt=~1.94 ms, write_dt=~0.19 ms)
```

If the period is much higher than 20 ms, motion will look shaky. Causes:

- Heavy CPU load from another process on the CM4.
- USB latency (Lite-only — N/A here).

## App lifecycle via REST

```bash
curl -X POST http://reachy-mini.local:8000/api/apps/start-app/<app_name>
curl -X POST http://reachy-mini.local:8000/api/apps/stop-current-app
curl http://reachy-mini.local:8000/api/apps/list
curl -X POST http://reachy-mini.local:8000/api/apps/install \
     -H "Content-Type: application/json" \
     -d '{"url": "https://huggingface.co/spaces/<user>/<app>"}'
```

Interactive endpoint browser: `http://reachy-mini.local:8000/docs`.

## Manual install / offline deploy

When you can't push through HF (e.g., no internet):

```bash
scp -r /path/to/my_app pollen@reachy-mini.local:/tmp/my_app
ssh pollen@reachy-mini.local "/venvs/apps_venv/bin/pip install /tmp/my_app"
```

## Debug a silent app crash

If `start-app` returns OK but the app does nothing, an import is probably failing silently. Test the import directly:

```bash
ssh pollen@reachy-mini.local \
    "/venvs/apps_venv/bin/python -c 'from my_app.main import MyApp'"
```

Resolve missing deps in `pyproject.toml` and reinstall.

## Stale bytecode after manual file edits

```bash
ssh pollen@reachy-mini.local \
    "find /venvs/apps_venv/lib/python3.12/site-packages/my_app -name __pycache__ -exec rm -rf {} +"
```

## Common issues

| Issue | Resolution |
|---|---|
| "An app is already running" | `curl -X POST http://reachy-mini.local:8000/api/apps/stop-current-app` |
| Daemon in a bad state | `sudo systemctl restart reachy-mini-daemon` (wait 30 s) |
| `reachy-mini.local` doesn't resolve | Use IP address; or hotspot; or USB-C-to-Ethernet |
| App not picking up code changes | Restart the app; clear `__pycache__` if needed |
| Robot static / motors silent | Make sure motors are enabled (`mini.enable_motors()` or wakeup); see [safety limits](../concepts/safety-limits.md) |
| Audio empty | Check mic FPC cable orientation; see HF troubleshooting (open gap) |

## Tip — log config at app startup

```python
import logging, sys
logger = logging.getLogger(__name__)

def run(self, mini, stop_event):
    logger.info("=" * 50)
    logger.info("MY APP STARTING")
    logger.info(f"  Python: {sys.version}")
    logger.info("=" * 50)
    # ...
```

Makes it easy to tell which version is running when reading `journalctl`.

## See also

- [Dev loop on Wireless](dev-loop-wireless.md)
- [Create an app](create-app.md)
- [App lifecycle](../concepts/app-lifecycle.md)
