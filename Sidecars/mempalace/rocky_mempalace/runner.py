"""Rocky memory sidecar — line-delimited JSON wrapper around MemPalace.

Methods callable from Swift:
    init_palace()                                       -> {"ok": true, "path": "..."}
    add(role, text, [meta])                             -> {"id": "...", "stored": bool}
    recall(query, [k])                                  -> {"hits": [{text, role, score, ts}]}
    health()                                            -> {"ok": true}

Wire format (line-delimited JSON):
    in:  {"id": "...", "method": "...", "params": {...}}
    out: {"id": "...", "result": {...}}                 # final
         {"id": "...", "error": {"code": 1, "message": "..."}}
         {"event": "ready"}                             # unsolicited
         {"log": {"level": "info", "msg": "...", "fields": {...}}}

Storage details:
- Palace path comes from $MEMPALACE_PALACE_PATH (set in manifest.json).
- Wing/room come from $ROCKY_MEMORY_WING / $ROCKY_MEMORY_ROOM. Default
  to "rocky" / "conversation" if unset.
- All drawers go into the same wing+room; mempalace handles dedup
  internally based on content hash.

Stdout protection:
- mempalace.mcp_server does `os.dup2(2, 1)` at module-load time — an
  fd-level redirect that points fd 1 (stdout) at fd 2 (stderr) so any
  print() inside mempalace lands on stderr. That breaks our line-JSON
  contract because our wire writes also use fd 1.
- We save the original stdout fd via `os.dup(1)` BEFORE importing
  mempalace, then write our envelopes directly to that saved fd via
  `os.write`. This bypasses both `sys.stdout` rebinding AND fd-level
  dup2, keeping our wire clean while mempalace's chatter still goes
  to stderr.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any


# --- preserve real stdout fd BEFORE mempalace's dup2(2, 1) ---------------

try:
    _REAL_STDOUT_FD = os.dup(1)
except OSError:
    _REAL_STDOUT_FD = 1  # fallback; emits will still go somewhere
_io_lock = threading.Lock()


def emit(obj: dict[str, Any]) -> None:
    line = (json.dumps(obj) + "\n").encode("utf-8")
    with _io_lock:
        try:
            os.write(_REAL_STDOUT_FD, line)
        except OSError:
            # If the saved fd somehow got closed (shouldn't happen during
            # normal lifetime), fall back to whatever sys.stdout points at
            # so we at least don't crash.
            sys.stderr.write(line.decode("utf-8"))
            sys.stderr.flush()


def log(level: str, msg: str, **fields: Any) -> None:
    emit({"log": {"level": level, "msg": msg,
                  "fields": {k: str(v) for k, v in fields.items()}}})


def respond(req_id: str, result: Any) -> None:
    emit({"id": req_id, "result": result})


def respond_error(req_id: str, code: int, message: str) -> None:
    emit({"id": req_id, "error": {"code": code, "message": message}})


# --- bootstrap palace path + import mempalace ----------------------------

PALACE_PATH = os.path.abspath(
    os.path.expanduser(os.environ.get("MEMPALACE_PALACE_PATH",
                                       "~/Library/Application Support/Rocky/Memory"))
)
WING = os.environ.get("ROCKY_MEMORY_WING", "rocky")
ROOM = os.environ.get("ROCKY_MEMORY_ROOM", "conversation")

# Ensure mempalace's MempalaceConfig sees the right path. The env var
# is the source of truth so we just normalise it back into the env in
# case the manifest passed it with `~`.
os.environ["MEMPALACE_PALACE_PATH"] = PALACE_PATH


def ensure_palace_initialised() -> None:
    """Run `mempalace init` if the palace dir is missing its bootstrap.

    Idempotent. Only fires when `mempalace.yaml` is absent. setup.sh
    runs the same command at install time, so this is a fallback for
    fresh palace dirs created after install.
    """
    yaml = Path(PALACE_PATH) / "mempalace.yaml"
    if yaml.exists():
        return
    Path(PALACE_PATH).mkdir(parents=True, exist_ok=True)
    log("info", "initialising palace", path=PALACE_PATH)
    # Use the same python / mempalace as we're running under.
    cmd = [sys.executable, "-m", "mempalace", "init", PALACE_PATH,
           "--yes", "--no-llm"]
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=120)
    except subprocess.CalledProcessError as exc:
        log("error", "mempalace init failed",
            stderr=exc.stderr, stdout=exc.stdout, returncode=exc.returncode)
    except subprocess.TimeoutExpired:
        log("error", "mempalace init timed out")


ensure_palace_initialised()

# Import mempalace AFTER we've snapshotted stdout. mcp_server.py
# unconditionally does `sys.stdout = sys.stderr` at module-load time
# to free stdout for its own JSON-RPC server. That happens here.
try:
    from mempalace import mcp_server as _mcp  # noqa: E402
    from mempalace import config as _mp_config  # noqa: E402
except Exception as exc:  # noqa: BLE001
    log("error", "mempalace import failed", error=str(exc))
    raise

# Force the config to honor our palace path even if the lazy lookup
# captured a different value at import time. config.MempalaceConfig
# reads the env var on every property access, so this is just defensive.
os.environ["MEMPALACE_PALACE_PATH"] = PALACE_PATH


# --- handlers ------------------------------------------------------------

def handle_init_palace(_params: dict) -> dict:
    ensure_palace_initialised()
    return {"ok": True, "path": PALACE_PATH, "wing": WING, "room": ROOM}


def handle_add(params: dict) -> dict:
    role = str(params.get("role", "user"))
    text = str(params.get("text", "")).strip()
    if not text:
        return {"stored": False, "error": "empty text"}
    # Tag the role + ISO timestamp inline so search hits include the
    # speaker without a separate metadata round-trip.
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    content = f"[{role} @ {ts}] {text}"
    try:
        result = _mcp.tool_add_drawer(
            wing=WING, room=ROOM, content=content,
            source_file=f"rocky/{role}/{ts}", added_by="rocky"
        )
    except Exception as exc:  # noqa: BLE001
        return {"stored": False, "error": f"add_drawer failed: {exc}"}
    if isinstance(result, dict) and result.get("success") is False:
        return {"stored": False, "error": str(result.get("error", "unknown"))}
    return {
        "stored": True,
        "id": (result or {}).get("drawer_id") if isinstance(result, dict) else None,
        "role": role,
        "ts": ts,
    }


def handle_recall(params: dict) -> dict:
    query = str(params.get("query", "")).strip()
    k = int(params.get("k", 5))
    if not query:
        return {"hits": []}
    try:
        result = _mcp.tool_search(query=query, limit=max(1, min(k, 20)),
                                   wing=WING, room=ROOM)
    except Exception as exc:  # noqa: BLE001
        return {"hits": [], "error": f"search failed: {exc}"}
    if isinstance(result, dict) and "error" in result and not result.get("results"):
        return {"hits": [], "error": str(result.get("error"))}
    raw_hits = []
    if isinstance(result, dict):
        # mempalace returns either {"results": [...]} or a list-like;
        # accept both.
        raw_hits = result.get("results") or result.get("hits") or []
    elif isinstance(result, list):
        raw_hits = result
    hits = []
    for item in raw_hits[:k]:
        if not isinstance(item, dict):
            continue
        text = item.get("content") or item.get("text") or ""
        if not text:
            continue
        hits.append({
            "text": text,
            "score": item.get("similarity") or item.get("score"),
            "distance": item.get("distance"),
            "wing": item.get("wing"),
            "room": item.get("room"),
            "id": item.get("id") or item.get("drawer_id"),
        })
    return {"hits": hits, "count": len(hits)}


def handle_health(_params: dict) -> dict:
    return {"ok": True, "palace": PALACE_PATH, "wing": WING, "room": ROOM}


def handle_count(_params: dict) -> dict:
    """Return the drawer count for our wing/room. Surfaces in the
    Status view so the user can see how much history Rocky has.
    """
    try:
        result = _mcp.tool_list_drawers(wing=WING, room=ROOM, limit=1, offset=0)
    except Exception as exc:  # noqa: BLE001
        return {"count": 0, "error": f"list_drawers failed: {exc}"}
    if not isinstance(result, dict):
        return {"count": 0}
    # tool_list_drawers returns either {"total": N, "drawers": [...]} or
    # {"count": N, ...}; accept either.
    n = result.get("total") or result.get("count") or 0
    return {"count": int(n)}


def handle_list(params: dict) -> dict:
    """List drawers in chronological order (most-recent first by
    default). Used by the Memory tab to show what Rocky has stored
    so the user can review + selectively delete entries. Distinct
    from `recall` which is semantic — this is just a chronological
    page.

    Params:
      limit: max drawers to return (default 50, capped at 500).
      offset: pagination offset (default 0).
    """
    limit = int(params.get("limit") or 50)
    limit = max(1, min(limit, 500))
    offset = max(0, int(params.get("offset") or 0))
    try:
        result = _mcp.tool_list_drawers(
            wing=WING, room=ROOM, limit=limit, offset=offset
        )
    except Exception as exc:  # noqa: BLE001
        return {"drawers": [], "total": 0,
                "error": f"list_drawers failed: {exc}"}
    if not isinstance(result, dict):
        return {"drawers": [], "total": 0}
    raw = result.get("drawers") or result.get("results") or []
    total = result.get("total") or result.get("count") or len(raw)
    drawers = []
    for d in raw:
        if not isinstance(d, dict):
            continue
        drawers.append({
            "id": d.get("id") or d.get("drawer_id") or "",
            "text": d.get("text") or d.get("body") or "",
            "role": d.get("role") or d.get("speaker") or "",
            "ts": d.get("ts") or d.get("timestamp") or "",
        })
    return {"drawers": drawers, "total": int(total)}


def handle_delete(params: dict) -> dict:
    """Delete a single drawer by id. Used by the Memory tab's
    per-row delete button.
    """
    drawer_id = (params.get("id") or params.get("drawer_id") or "").strip()
    if not drawer_id:
        return {"deleted": False, "error": "id required"}
    try:
        _mcp.tool_delete_drawer(drawer_id=drawer_id)
        return {"deleted": True, "id": drawer_id}
    except Exception as exc:  # noqa: BLE001
        return {"deleted": False, "id": drawer_id,
                "error": f"{type(exc).__name__}: {exc}"}


def handle_forget_all(_params: dict) -> dict:
    """Delete every drawer in the wing/room. Wired to the destructive
    'Forget everything' button in Settings. Idempotent — safe to call
    on an already-empty palace.
    """
    try:
        listing = _mcp.tool_list_drawers(wing=WING, room=ROOM,
                                          limit=10_000, offset=0)
    except Exception as exc:  # noqa: BLE001
        return {"deleted": 0, "error": f"list_drawers failed: {exc}"}
    drawers = []
    if isinstance(listing, dict):
        drawers = listing.get("drawers") or listing.get("results") or []
    deleted = 0
    for d in drawers:
        if not isinstance(d, dict):
            continue
        drawer_id = d.get("id") or d.get("drawer_id")
        if not drawer_id:
            continue
        try:
            _mcp.tool_delete_drawer(drawer_id=drawer_id)
            deleted += 1
        except Exception:  # noqa: BLE001
            continue
    return {"deleted": deleted, "wing": WING, "room": ROOM}


HANDLERS = {
    "init_palace": handle_init_palace,
    "add": handle_add,
    "recall": handle_recall,
    "health": handle_health,
    "count": handle_count,
    "list": handle_list,
    "delete": handle_delete,
    "forget_all": handle_forget_all,
}


# --- main loop -----------------------------------------------------------

def handle(req: dict) -> None:
    req_id = req.get("id")
    method = req.get("method")
    params = req.get("params") or {}
    if req_id is None or not method:
        return
    fn = HANDLERS.get(method)
    if fn is None:
        respond_error(req_id, code=404, message=f"unknown method: {method}")
        return
    try:
        result = fn(params)
        respond(req_id, result)
    except Exception as exc:  # noqa: BLE001
        respond_error(req_id, code=500, message=f"{type(exc).__name__}: {exc}")


def main() -> None:
    log("info", "rocky-mempalace starting",
        pid=os.getpid(), palace=PALACE_PATH, wing=WING, room=ROOM)
    emit({"event": "ready"})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as exc:
            log("error", "json decode failure", line=line[:200], error=str(exc))
            continue
        handle(req)


if __name__ == "__main__":
    main()
