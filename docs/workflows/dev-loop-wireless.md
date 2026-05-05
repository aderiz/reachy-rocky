---
title: Dev loop on Wireless (Approach A)
type: workflow
status: current
last_updated: 2026-05-05
sources:
  - sources/hf-docs.md   # platforms/reachy_mini/development_workflow
tags: [dev, sshfs, wireless]
---

# Dev loop on Wireless — Approach A (recommended)

Recommended workflow: **clone the repo on the robot, mount it back to your laptop with sshfs, edit locally, run remotely.** Avoids the slow inverse mount where `pip install` reads thousands of small files over WiFi.

## Prerequisites (laptop)

- macOS: install macFUSE + sshfs (e.g., `brew install --cask macfuse && brew install gromgit/fuse/sshfs-mac`).
- Linux (Debian/Ubuntu): `sudo apt install sshfs`.
- SSH access to robot: `ssh pollen@reachy-mini.local` (password `root`).

## Setup (one time)

```bash
# 1) On the robot — clone your app
ssh pollen@reachy-mini.local
cd /home/pollen
git clone https://github.com/<you>/<your_app>.git
exit

# 2) On the laptop — mount it locally
mkdir -p ~/wireless_dev
sshfs pollen@reachy-mini.local:/home/pollen/<your_app> ~/wireless_dev \
    -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3
```

Now `~/wireless_dev` is your live workspace. Edit in any IDE.

## Install + run on the robot

```bash
ssh pollen@reachy-mini.local
cd /home/pollen/<your_app>

# Editable install — changes apply immediately
/venvs/apps_venv/bin/pip install -e .

# Run as a module (matches how the daemon launches apps)
/venvs/apps_venv/bin/python -m <your_module>.main

# Or run a one-off script directly
/venvs/apps_venv/bin/python <your_script>.py
```

## Unmount when done

```bash
fusermount -u ~/wireless_dev      # Linux
umount ~/wireless_dev             # macOS
```

## Faster sync option (rsync)

For one-shot pushes without a persistent mount:

```bash
rsync -avz /path/to/your_app/src/your_app/ \
    pollen@reachy-mini.local:/venvs/apps_venv/lib/python3.12/site-packages/your_app/
```

Add `--delete` to mirror deletions.

## VS Code Remote-SSH (cross-platform alternative)

Install the **Remote - SSH** extension, connect to `pollen@reachy-mini.local`, open `/home/pollen/<your_app>`. Works on Windows/macOS/Linux without sshfs.

## Approach B / C variants (rare)

- **B — Override installed app sources**: mount your local `src/your_app/` over the existing `/venvs/apps_venv/lib/python3.12/site-packages/<app_name>/` on the robot. Use after `reachy-mini-app-assistant` has installed the app once.
- **C — Mount local source and run directly**: skip pip install entirely; mount the repo onto the robot and run `python main.py`. Fast iteration, but the app isn't registered with Reachy Mini Control.

For both variants, mount the **inner package directory only**, not the repo root — see pitfalls below.

## Pitfalls

- **Wrong mount point for site-packages.** A repo has `src/your_app/__init__.py`, but `site-packages/your_app/` contains the package directly. If you mount the repo over site-packages, Python can't find the package.
- **Slow pip from inverse mount.** Don't mount your laptop onto the robot and `pip install` from there — it reads many small files over WiFi and is glacial.
- **mDNS doesn't resolve on guest WiFi.** Use the robot's IP (find it on your router or with the Reachy Mini Control app), a phone hotspot, or a USB-C-to-Ethernet adapter.

## See also

- [Create an app](create-app.md)
- [Run and debug](run-and-debug.md)
- [App lifecycle](../concepts/app-lifecycle.md)
