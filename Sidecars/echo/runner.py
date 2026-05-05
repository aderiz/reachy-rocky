"""Echo sidecar — minimal contract-conformer for SidecarHost integration tests.

Methods:
  echo(text) -> {"text": <input>}
  add(a, b)  -> {"sum": a+b}
  slow(seconds) -> {"ok": true} after sleeping
  fail(message) -> error envelope with message
  stream_count(n) -> n stream chunks {"i": 0..n-1}, then stream_end
  crash() -> exits 7 without responding (used to test recovery)

Wire format (line-delimited JSON):
  in:  {"id": "...", "method": "...", "params": {...}}
  out: {"id": "...", "result": {...}}                 # final
       {"id": "...", "error": {"code": 1, "message": "..."}}
       {"id": "...", "stream": {...}}                 # streamed item
       {"id": "...", "stream_end": true}
       {"event": "ready"}                             # unsolicited
       {"log": {"level": "info", "msg": "..."}}
"""

from __future__ import annotations

import json
import sys
import time


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def log(level: str, msg: str, **fields):
    emit({"log": {"level": level, "msg": msg, "fields": fields}})


def respond(req_id: str, result):
    emit({"id": req_id, "result": result})


def respond_error(req_id: str, code: int, message: str):
    emit({"id": req_id, "error": {"code": code, "message": message}})


def respond_stream(req_id: str, chunk):
    emit({"id": req_id, "stream": chunk})


def respond_stream_end(req_id: str):
    emit({"id": req_id, "stream_end": True})


def handle(req):
    req_id = req.get("id")
    method = req.get("method")
    params = req.get("params") or {}
    if req_id is None or not method:
        return

    if method == "echo":
        respond(req_id, {"text": params.get("text", "")})
    elif method == "add":
        a = float(params.get("a", 0))
        b = float(params.get("b", 0))
        respond(req_id, {"sum": a + b})
    elif method == "slow":
        time.sleep(float(params.get("seconds", 0.0)))
        respond(req_id, {"ok": True})
    elif method == "fail":
        respond_error(req_id, code=int(params.get("code", 1)),
                      message=str(params.get("message", "fail")))
    elif method == "stream_count":
        n = int(params.get("n", 3))
        for i in range(n):
            respond_stream(req_id, {"i": i})
        respond_stream_end(req_id)
    elif method == "crash":
        # No response. Exit forcibly so the supervisor must recover.
        sys.exit(7)
    else:
        respond_error(req_id, code=404, message=f"unknown method: {method}")


def main():
    log("info", "echo sidecar starting", pid=__import__("os").getpid())
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
        try:
            handle(req)
        except Exception as exc:  # noqa: BLE001
            req_id = req.get("id")
            if req_id:
                respond_error(req_id, code=500, message=f"runtime error: {exc}")


if __name__ == "__main__":
    main()
