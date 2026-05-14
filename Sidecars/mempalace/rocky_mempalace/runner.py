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
WING = os.environ.get("ROCKY_MEMORY_WING", "office")
# Default room is derived per-call (one room per UTC day so each
# conversation has a natural chronological bucket). The env var can
# still pin a fixed room for tests, but the in-flight code paths
# call `_current_room()` to honour the day-by-day model.
ROOM = os.environ.get("ROCKY_MEMORY_ROOM", "").strip() or None


def _current_room() -> str:
    """UTC date → room name. One room per day under the office wing.
    The Memory tab can later group + navigate by date, and `recall`
    can be scoped to today / this week / etc. via the wing+room args
    on `tool_search`."""
    if ROOM:
        return ROOM
    return time.strftime("%Y-%m-%d", time.gmtime())


def _normalise_role(role: str) -> str:
    """mempalace's `added_by` field is free-form; we use it as a
    structured speaker tag (one of user / assistant / system / tool).
    Unknown values pass through but are coerced to lowercase."""
    r = (role or "").strip().lower()
    if r in {"user", "assistant", "system", "tool"}:
        return r
    return r or "user"

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
    return {
        "ok": True,
        "path": PALACE_PATH,
        "wing": WING,
        "room": _current_room(),
    }


def handle_add(params: dict) -> dict:
    role = _normalise_role(str(params.get("role", "user")))
    text = str(params.get("text", "")).strip()
    if not text:
        return {"stored": False, "error": "empty text"}
    # Store the body verbatim — no more `[role @ ts]` prefix. The role
    # rides on `added_by` so list_drawers / search results carry it as
    # a structured field instead of forcing the Mac to parse text. The
    # full ISO timestamp goes on `source_file` (mempalace exposes that
    # back through list_drawers as the drawer's `source_file` field,
    # and the Mac uses it to render relative timestamps).
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    room = _current_room()
    try:
        result = _mcp.tool_add_drawer(
            wing=WING, room=room, content=text,
            source_file=f"rocky/{role}/{ts}",
            added_by=role,
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
        "wing": WING,
        "room": room,
    }


def handle_recall(params: dict) -> dict:
    query = str(params.get("query", "")).strip()
    k = int(params.get("k", 5))
    if not query:
        return {"hits": []}
    # Search across ALL rooms in the office wing (rooms are per-day,
    # so a single-room search would miss yesterday's drawers). Pass
    # room=None to mempalace; it interprets that as "every room
    # under this wing."
    try:
        result = _mcp.tool_search(query=query, limit=max(1, min(k, 20)),
                                   wing=WING, room=None)
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
    """Return the drawer count across the office wing (all rooms).
    Surfaces in the Status view so the user can see how much history
    Rocky has."""
    try:
        result = _mcp.tool_list_drawers(wing=WING, room=None,
                                         limit=1, offset=0)
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
            wing=WING, room=None, limit=limit, offset=offset
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
        # `added_by` is where role lives in the new write path; fall
        # back to legacy `role`/`speaker` if present (older drawers).
        role = (d.get("added_by") or d.get("role")
                or d.get("speaker") or "")
        # `source_file` is "rocky/<role>/<ts>" — pull the ts out if
        # explicit `ts`/`timestamp` fields aren't present.
        ts = d.get("ts") or d.get("timestamp") or ""
        if not ts:
            sf = d.get("source_file") or ""
            parts = sf.split("/")
            if len(parts) >= 3:
                ts = parts[-1]
        drawers.append({
            "id": d.get("id") or d.get("drawer_id") or "",
            "text": d.get("content") or d.get("text") or d.get("body") or "",
            "role": role,
            "ts": ts,
            "room": d.get("room") or "",
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
    """Delete every drawer in the office wing AND every legacy wing,
    AND invalidate every fact in the knowledge graph. Wired to the
    destructive 'Forget everything' button. Idempotent — safe to
    call on an already-empty palace.

    Three steps:
      1. Walk all rooms in office wing → tool_delete_drawer each
      2. Same for legacy wings (default/default, rocky/conversation)
         in case they survived the one-time wipe_legacy
      3. tool_kg_timeline → tool_kg_invalidate each triple
         (mempalace doesn't expose a "wipe KG" — invalidate stamps
         every triple with an `ended` date so kg_query returns empty
         for live facts; the underlying SQLite rows remain but the
         active state is empty)
    """
    all_wings = [(WING, None),
                 ("default", "default"),
                 ("rocky", "conversation")]
    deleted = 0
    for w, r in all_wings:
        try:
            listing = _mcp.tool_list_drawers(
                wing=w, room=r, limit=10_000, offset=0
            )
        except Exception:  # noqa: BLE001
            continue
        if not isinstance(listing, dict):
            continue
        for d in (listing.get("drawers")
                  or listing.get("results") or []):
            if not isinstance(d, dict):
                continue
            did = d.get("id") or d.get("drawer_id")
            if not did:
                continue
            try:
                _mcp.tool_delete_drawer(drawer_id=did)
                deleted += 1
            except Exception:  # noqa: BLE001
                continue

    # KG wipe: iterate every triple in the timeline and invalidate
    # it. mempalace stamps `valid_to` with today's date, so kg_query
    # without an `as_of` returns nothing live. Best-effort — failures
    # silently skip rather than rolling back the drawer deletion.
    kg_invalidated = 0
    try:
        kg = _mcp.tool_kg_timeline(entity=None)
    except Exception:  # noqa: BLE001
        kg = None
    triples_raw: list = []
    if isinstance(kg, dict):
        triples_raw = (kg.get("results") or kg.get("triples")
                       or kg.get("facts") or [])
    elif isinstance(kg, list):
        triples_raw = kg
    for t in triples_raw:
        if not isinstance(t, dict):
            continue
        s = t.get("subject") or t.get("s")
        p = t.get("predicate") or t.get("p")
        o = t.get("object") or t.get("o")
        if not (s and p and o):
            continue
        try:
            _mcp.tool_kg_invalidate(subject=s, predicate=p, object=o)
            kg_invalidated += 1
        except Exception:  # noqa: BLE001
            continue
    log("info", "forget_all complete",
        drawers_deleted=deleted, kg_invalidated=kg_invalidated)
    return {
        "deleted": deleted,
        "kg_invalidated": kg_invalidated,
        "wing": WING,
    }


# --- knowledge graph -----------------------------------------------------

def handle_kg_add(params: dict) -> dict:
    """Assert a triple (subject, predicate, object) in the temporal
    knowledge graph. mempalace stores it in a local SQLite store
    alongside the drawer chroma.

    Params:
      subject, predicate, object — required, all strings
      valid_from — optional ISO date / datetime
      valid_to   — optional ISO date / datetime
      source_drawer_id — optional id of the drawer that asserted this
    """
    subject = str(params.get("subject", "")).strip()
    predicate = str(params.get("predicate", "")).strip()
    obj = str(params.get("object", "")).strip()
    if not subject or not predicate or not obj:
        return {"ok": False, "error": "subject, predicate, object required"}
    kwargs = {
        "subject": subject,
        "predicate": predicate,
        "object": obj,
    }
    vf = params.get("valid_from")
    vt = params.get("valid_to")
    src = params.get("source_drawer_id") or params.get("source_file")
    if isinstance(vf, str) and vf.strip(): kwargs["valid_from"] = vf.strip()
    if isinstance(vt, str) and vt.strip(): kwargs["valid_to"] = vt.strip()
    if isinstance(src, str) and src.strip(): kwargs["source_file"] = src.strip()
    try:
        result = _mcp.tool_kg_add(**kwargs)
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"kg_add failed: {exc}"}
    if isinstance(result, dict) and result.get("error"):
        return {"ok": False, "error": str(result["error"])}
    return {"ok": True, "result": result if isinstance(result, dict) else {}}


def handle_kg_query(params: dict) -> dict:
    """Return all triples touching `entity`. Optional `as_of` (ISO
    date/datetime) restricts to facts valid at that time.
    `direction` is one of `both` / `subject` / `object`."""
    entity = str(params.get("entity", "")).strip()
    if not entity:
        return {"triples": [], "error": "entity required"}
    as_of = params.get("as_of")
    direction = params.get("direction") or "both"
    kwargs: dict[str, Any] = {"entity": entity, "direction": str(direction)}
    if isinstance(as_of, str) and as_of.strip():
        kwargs["as_of"] = as_of.strip()
    try:
        result = _mcp.tool_kg_query(**kwargs)
    except Exception as exc:  # noqa: BLE001
        return {"triples": [], "error": f"kg_query failed: {exc}"}
    return _coerce_kg_result(result)


def handle_kg_timeline(params: dict) -> dict:
    """Chronological list of triples. Optional `entity` filter."""
    entity = params.get("entity")
    if isinstance(entity, str) and not entity.strip():
        entity = None
    try:
        result = _mcp.tool_kg_timeline(
            entity=entity if isinstance(entity, str) else None
        )
    except Exception as exc:  # noqa: BLE001
        return {"triples": [], "error": f"kg_timeline failed: {exc}"}
    return _coerce_kg_result(result)


def handle_kg_stats(_params: dict) -> dict:
    """Entity / triple / predicate counts. Used to render the graph
    overview header in the Memory tab."""
    try:
        result = _mcp.tool_kg_stats()
    except Exception as exc:  # noqa: BLE001
        return {"error": f"kg_stats failed: {exc}"}
    if not isinstance(result, dict):
        return {"entities": 0, "triples": 0, "predicates": 0}
    return {
        "entities": int(result.get("entities") or result.get("entity_count") or 0),
        "triples": int(result.get("triples") or result.get("triple_count") or 0),
        "predicates": int(result.get("predicates")
                          or result.get("predicate_count") or 0),
    }


def _coerce_kg_result(result: Any) -> dict:
    """Normalise mempalace's KG responses to {"triples": [...]}.

    mempalace's MCP tools return different keys depending on which
    one you called:
      - tool_kg_timeline → {"timeline": [...], "count": N}
      - tool_kg_query    → {"facts":    [...], "count": N}
    plus older / alternate shapes that historically used `results`
    or `triples`. Accept all of them so we don't have to special-
    case per RPC handler.
    """
    raw: list = []
    if isinstance(result, dict):
        raw = (result.get("timeline")
               or result.get("facts")
               or result.get("results")
               or result.get("triples")
               or [])
        if "error" in result and not raw:
            return {"triples": [], "error": str(result["error"])}
    elif isinstance(result, list):
        raw = result
    out = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        out.append({
            "subject": item.get("subject") or item.get("s") or "",
            "predicate": item.get("predicate") or item.get("p") or "",
            "object": item.get("object") or item.get("o") or "",
            "valid_from": item.get("valid_from") or item.get("from"),
            "valid_to": item.get("valid_to") or item.get("to"),
            "source_file": item.get("source_file"),
        })
    return {"triples": out, "count": len(out)}


# --- legacy wipe (one-shot migration) ------------------------------------

def handle_wipe_legacy(_params: dict) -> dict:
    """Delete every drawer in pre-v2 wings/rooms (`default/default`,
    `rocky/conversation`). Called once by AppServices on first launch
    of the v2 layout so the office wing starts clean. Safe to call
    multiple times — no-ops once the legacy wings are empty."""
    legacy = [
        ("default", "default"),
        ("rocky", "conversation"),
    ]
    deleted = 0
    for w, r in legacy:
        try:
            listing = _mcp.tool_list_drawers(
                wing=w, room=r, limit=10_000, offset=0
            )
        except Exception:  # noqa: BLE001
            continue
        if not isinstance(listing, dict):
            continue
        for d in (listing.get("drawers")
                  or listing.get("results") or []):
            if not isinstance(d, dict):
                continue
            did = d.get("id") or d.get("drawer_id")
            if not did:
                continue
            try:
                _mcp.tool_delete_drawer(drawer_id=did)
                deleted += 1
            except Exception:  # noqa: BLE001
                continue
    return {"deleted": deleted}


HANDLERS = {
    "init_palace": handle_init_palace,
    "add": handle_add,
    "recall": handle_recall,
    "health": handle_health,
    "count": handle_count,
    "list": handle_list,
    "delete": handle_delete,
    "forget_all": handle_forget_all,
    "wipe_legacy": handle_wipe_legacy,
    "kg_add": handle_kg_add,
    "kg_query": handle_kg_query,
    "kg_timeline": handle_kg_timeline,
    "kg_stats": handle_kg_stats,
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
        pid=os.getpid(), palace=PALACE_PATH, wing=WING,
        room=(ROOM or "per-day"))
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
