---
title: Create a new app
type: workflow
status: current
last_updated: 2026-05-05
sources:
  - sources/hf-docs.md   # SDK/apps, SDK/quickstart, SDK/installation
  - sources/agents-md.md
tags: [apps, scaffolding]
---

# Create a new app

Always use the assistant CLI — never hand-roll the structure. The CLI sets up the entry point, the README tag, and the Hugging Face Space wiring correctly.

## Install the SDK in your dev env

```bash
uv venv reachy_mini_env --python 3.12
source reachy_mini_env/bin/activate
uv pip install reachy-mini
```

For simulation: `uv pip install "reachy-mini[mujoco]"`. Linux also needs GStreamer installed manually — see HF docs install page (open gap).

## Scaffold

```bash
# Default template — minimal app
reachy-mini-app-assistant create my_app /path/to/destination --publish

# Conversation template — LLM, audio pipeline, primary/secondary fusion baked in
reachy-mini-app-assistant create --template conversation my_app /path/to/destination --publish
```

`--publish` creates the Hugging Face Space at the same time. Drop it to scaffold locally and publish later via `reachy-mini-app-assistant publish <path>`.

## Generated structure

```
my_app/
├── index.html              # HF Space landing page
├── style.css
├── pyproject.toml          # entry point lives here
├── README.md               # contains `reachy_mini_python_app` tag
└── my_app/
    ├── __init__.py
    ├── main.py             # your app logic
    └── static/             # optional web UI
        ├── index.html
        ├── style.css
        └── main.js
```

## The entry point

```toml
[project.entry-points."reachy_mini_apps"]
my_app = "my_app.main:MyApp"
```

Group is `reachy_mini_apps` (underscores). Value is `<module>:<class>`.

## Minimal `main.py`

```python
import threading, time
import numpy as np
from reachy_mini import ReachyMini, ReachyMiniApp
from reachy_mini.utils import create_head_pose

class MyApp(ReachyMiniApp):
    custom_app_url: str | None = None        # or "http://0.0.0.0:8042" for a web UI

    def run(self, reachy_mini: ReachyMini, stop_event: threading.Event):
        t0 = time.time()
        while not stop_event.is_set():
            t = time.time() - t0
            yaw = 30.0 * np.sin(2 * np.pi * 0.2 * t)
            reachy_mini.set_target(head=create_head_pose(yaw=yaw, degrees=True))
            time.sleep(0.02)

if __name__ == "__main__":
    app = MyApp()
    try:
        app.wrapped_run()
    except KeyboardInterrupt:
        app.stop()
```

## Validate before shipping

```bash
reachy-mini-app-assistant check /path/to/my_app
```

## Test through the dashboard

On Wireless, the daemon is already running — install the app on the robot and start it via REST or Reachy Mini Control. On Lite/sim, you can also run the daemon locally:

```bash
uv pip install -e /path/to/my_app
reachy-mini-daemon                 # Lite/sim only
# open http://reachy-mini.local:8000/   on Wireless
# or   http://127.0.0.1:8000/           on Lite/sim
```

Quick iteration for Wireless: see [dev-loop-wireless](dev-loop-wireless.md).

## Plan first (per AGENTS.md)

Before writing code, drop a `plan.md` into the app directory: requirements as you understand them, technical approach, clarifying questions with answer fields. Wait for the user to fill them. This is the canonical pattern from the upstream agent guide.

## Publish later

```bash
uv pip install --upgrade huggingface_hub
hf auth login                                       # token with Write scope
reachy-mini-app-assistant publish /path/to/my_app
```

For an existing Space: `git add . && git commit -m "..." && git push`.

For an offline Wireless deploy: `scp -r my_app pollen@reachy-mini.local:/tmp/my_app && ssh pollen@reachy-mini.local "/venvs/apps_venv/bin/pip install /tmp/my_app"`.

## See also

- [Dev loop on Wireless](dev-loop-wireless.md)
- [App lifecycle](../concepts/app-lifecycle.md)
- [Run and debug](run-and-debug.md)
