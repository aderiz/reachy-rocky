---
title: App lifecycle
type: concept
status: current
last_updated: 2026-05-05
sources:
  - sources/hf-docs.md
  - sources/agents-md.md
tags: [apps, lifecycle, daemon]
---

# App lifecycle

Apps are Python packages discovered via `[project.entry-points."reachy_mini_apps"]` in `pyproject.toml`. The daemon manages the entire lifecycle — your code only implements `run`.

## The contract

```python
import threading
from reachy_mini import ReachyMini, ReachyMiniApp

class MyApp(ReachyMiniApp):
    custom_app_url: str | None = None     # set to e.g. "http://0.0.0.0:8042" for a web UI

    def run(self, reachy_mini: ReachyMini, stop_event: threading.Event):
        while not stop_event.is_set():
            # ... per-tick work
            pass

if __name__ == "__main__":
    app = MyApp()
    try:
        app.wrapped_run()
    except KeyboardInterrupt:
        app.stop()
```

You implement `run`. `wrapped_run()` connects to the daemon, optionally starts the FastAPI settings server, and calls `run`. `stop()` sets the event.

## What the daemon does

1. Receives `POST /api/apps/start-app/<name>`.
2. Spawns subprocess: `python -u -m your_app.main`.
3. Subprocess inherits the daemon's environment variables (no special injection mechanism).
4. Subprocess connects via `ReachyMini()`.
5. On stop: daemon sends `SIGINT` → `KeyboardInterrupt` → `app.stop()` → `stop_event` set → `run` returns.
6. After exit, daemon resets the robot to its default pose.

**Only one app runs at a time.** A second `start-app` while one is running yields a conflict response.

## `pyproject.toml` essentials

```toml
[project.entry-points."reachy_mini_apps"]
my_app = "my_app.main:MyApp"
```

Group is `reachy_mini_apps` (underscores). Value is `<module path>:<ClassName>`.

## Optional web UI

Set `custom_app_url = "http://0.0.0.0:8042"`. The framework starts a FastAPI server serving files from `<package>/static/`. Define routes on `self.settings_app`:

```python
class MyApp(ReachyMiniApp):
    custom_app_url: str | None = "http://0.0.0.0:8042"

    def run(self, reachy_mini, stop_event):
        @self.settings_app.post("/my_endpoint")
        def _():
            return {"status": "ok"}
        # main loop...
```

Reachy Mini Control shows a settings icon to open the page.

URLs to remember (Wireless):

- Settings UI: `http://reachy-mini.local:8042`
- Daemon API: `http://reachy-mini.local:8000`

Set `custom_app_url = None` if your app doesn't need a web UI.

## Where apps live on the robot

```
/venvs/apps_venv/lib/python3.12/site-packages/<your_app_package>/
```

That's the **inner package directory**, not the repo root. Mounting the repo root over this path will hide the package — see [dev-loop-wireless](../workflows/dev-loop-wireless.md).

## Discoverability (HF Spaces)

For an app to appear in the store, the Space's `README.md` frontmatter must include:

```yaml
tags:
  - reachy_mini_python_app
```

`reachy-mini-app-assistant create` adds this automatically.

## Configuration

The subprocess inherits the daemon's env vars — there is no special config injection. For runtime config (API keys, server URLs):

- **Recommended**: a web UI via `custom_app_url`. Users enter values in the browser.
- **Alternative**: a `.env` file at a known path (see the conversation app's `.env.example`).
- **Simplest**: hardcoded defaults in `main.py`.

## See also

- [Create an app](../workflows/create-app.md)
- [Run and debug](../workflows/run-and-debug.md)
- [Architecture](architecture.md)
