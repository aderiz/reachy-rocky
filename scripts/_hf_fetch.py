#!/usr/bin/env python3
"""Fetch every file under a Hugging Face repo subdirectory recursively.

Used by `download-models.sh` to install CoreML / MLX model weights into
`~/Library/Application Support/Rocky/Models/`. Walks the HF tree API,
fetches files via the resolve endpoint (which transparently handles
git-LFS), and reproduces the directory layout on disk.

Usage:
    python3 scripts/_hf_fetch.py \\
        --repo FluidInference/silero-vad-coreml \\
        --subdir silero_vad.mlmodelc \\
        --dest ~/Library/Application\\ Support/Rocky/Models/silero-vad/silero_vad.mlmodelc
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request


def list_tree(repo: str, path: str) -> list[dict]:
    url = f"https://huggingface.co/api/models/{repo}/tree/main/{path}"
    with urllib.request.urlopen(url) as r:
        return json.loads(r.read().decode("utf-8"))


def fetch_file(repo: str, path: str, out_path: str) -> None:
    url = f"https://huggingface.co/{repo}/resolve/main/{path}"
    print(f"    -> {path}", flush=True)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with urllib.request.urlopen(url) as r, open(out_path, "wb") as f:
        f.write(r.read())


def walk(repo: str, subdir: str, entries: list[dict], dest_root: str) -> None:
    """Recursively walk a directory listing, mirroring it under dest_root."""
    for entry in entries:
        path = entry["path"]
        # Strip the subdir prefix so files land at dest_root + relative path.
        if path.startswith(subdir + "/"):
            relative = path[len(subdir) + 1:]
        elif path == subdir:
            continue
        else:
            relative = path
        if entry["type"] == "directory":
            children = list_tree(repo, path)
            walk(repo, subdir, children, dest_root)
        else:
            out_path = os.path.join(dest_root, relative)
            fetch_file(repo, path, out_path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, help="HF repo id, e.g. FluidInference/silero-vad-coreml")
    parser.add_argument("--subdir", required=True, help="repo subdir to fetch, e.g. silero_vad.mlmodelc")
    parser.add_argument("--dest", required=True, help="destination directory (created if missing)")
    args = parser.parse_args()

    print(f"==> Listing {args.repo}/{args.subdir}", flush=True)
    entries = list_tree(args.repo, args.subdir)
    walk(args.repo, args.subdir, entries, args.dest)
    print("    done.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
