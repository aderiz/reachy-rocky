"""Brain sidecar runner — JSON-line wire over stdin/stdout.

Honors Rocky's `SidecarHost` contract (`docs/concepts/sidecar-convention.md`):
emits a one-shot `{"event":"ready"}` on stdout once the model is loaded
and ready to serve requests; thereafter handles `chat_stream` /
`set_model` / `health` requests by their `id` correlation.

Streaming protocol for `chat_stream`:

    Request:
      {"id":"<id>", "method":"chat_stream",
       "params":{
         "messages": [{"role":"system","content":"..."}, ...],
         "tools": [...optional OpenAI tool schemas...],
         "image_b64": "<optional base64 JPEG>",
         "max_tokens": 768,
         "temperature": 0.6
       }}

    Stream:
      {"id":"<id>","stream":{"delta":"<token-text>"}}
      {"id":"<id>","stream":{"delta":"<token-text>"}}
      ...
      {"id":"<id>","stream":{"tool_call":{
          "id":"call_xyz","name":"get_weather","arguments":"{...}"}}}
      {"id":"<id>","stream_end":true}

    Final result:
      {"id":"<id>","result":{
          "text":"<full reply>",
          "tool_calls":[...],
          "stop_reason":"length"|"stop"|"eos"|"tool_calls",
          "vision_cache_hit": true|false }}

For now `tool_calls` are extracted post-hoc from the assistant's
text via a fenced-JSON / `<tool_call>` parser identical in spirit to
the v0.1 fenced-JSON path on `LMStudioClient`. Native Qwen3-coder
tool calling emits inside `<tool_call>...</tool_call>` tags; we
strip those from the user-facing text and surface them as discrete
events.
"""

from __future__ import annotations

import base64
import hashlib
import io
import json
import logging
import os
import re
import sys
import threading
import time
from collections import OrderedDict
from typing import Any, Optional

# Heavy imports go inside `Brain.load()` so the manifest's
# ready_timeout_s budget covers the actual model load, not Python
# import overhead.

logger = logging.getLogger("rocky.brain")
LOCK = threading.Lock()


def emit(envelope: dict) -> None:
    """Write a JSON envelope on stdout. Always flushed."""
    with LOCK:
        sys.stdout.write(json.dumps(envelope, separators=(",", ":")) + "\n")
        sys.stdout.flush()


def emit_log(level: str, message: str, **fields: Any) -> None:
    """Structured log line consumed by Rocky's LogBus."""
    emit({
        "log": {
            "level": level,
            "ts": time.time(),
            "msg": message,
            "fields": fields,
        }
    })


# ---------------------------------------------------------------------------
# Tool-call parser
# ---------------------------------------------------------------------------

# Qwen3-coder format: <tool_call>{"name": "...", "arguments": {...}}</tool_call>
TOOL_CALL_TAG = re.compile(
    r"<tool_call>\s*(?P<json>\{[\s\S]*?\})\s*</tool_call>",
    flags=re.IGNORECASE,
)


def split_tool_calls(text: str) -> tuple[str, list[dict[str, Any]]]:
    """Strip <tool_call>...</tool_call> blocks from `text`, return
    (cleaned_text, [tool_call_dicts]). Each tool_call is normalised
    to {"id": ..., "name": ..., "arguments": "<json-string>"} so it
    drops directly into the OpenAI-shape `tool_calls` Rocky's
    CognitionEngine expects.
    """
    calls: list[dict[str, Any]] = []
    counter = [0]

    def replace(match: re.Match) -> str:
        try:
            payload = json.loads(match.group("json"))
        except json.JSONDecodeError:
            # Malformed tool_call — leave the text intact for the user
            # so it isn't silently swallowed.
            return match.group(0)
        name = payload.get("name") or payload.get("tool")
        if not isinstance(name, str):
            return match.group(0)
        arguments = payload.get("arguments") or payload.get("args") or {}
        if isinstance(arguments, dict):
            arguments_str = json.dumps(arguments, separators=(",", ":"))
        elif isinstance(arguments, str):
            arguments_str = arguments
        else:
            arguments_str = json.dumps(arguments)
        counter[0] += 1
        calls.append({
            "id": f"call_brain_{counter[0]}",
            "name": name,
            "arguments": arguments_str,
        })
        return ""

    cleaned = TOOL_CALL_TAG.sub(replace, text).strip()
    return cleaned, calls


# ---------------------------------------------------------------------------
# Brain
# ---------------------------------------------------------------------------


class Brain:
    """Wraps an mlx-vlm model + processor, vision encoder cache, and
    the core `chat_stream` loop. Single-threaded by design; the runner
    serialises requests with `LOCK` so two `chat_stream` calls don't
    fight over the model state."""

    def __init__(self, model_id: str) -> None:
        self.model_id = model_id
        self.model = None
        self.processor = None
        self.vision_cache: OrderedDict[str, Any] = OrderedDict()
        self.vision_cache_size = int(
            os.environ.get("ROCKY_BRAIN_VISION_CACHE_SIZE", "8")
        )
        self.default_max_tokens = int(
            os.environ.get("ROCKY_BRAIN_MAX_TOKENS", "768")
        )
        self.default_temperature = float(
            os.environ.get("ROCKY_BRAIN_TEMPERATURE", "0.6")
        )

    def load(self) -> None:
        # Lazy heavy imports.
        from mlx_vlm import load as mlx_load  # type: ignore

        emit_log("info", "loading brain model", model=self.model_id)
        started = time.monotonic()
        model, processor = mlx_load(self.model_id)
        self.model = model
        self.processor = processor
        elapsed_ms = int((time.monotonic() - started) * 1000)
        emit_log(
            "info",
            "brain model loaded",
            model=self.model_id,
            load_time_ms=elapsed_ms,
        )

    def hot_swap(self, model_id: str) -> None:
        """Replace the in-memory model with a new one. Drops the
        vision cache because the encoder is part of the model."""
        if model_id == self.model_id and self.model is not None:
            return
        self.model_id = model_id
        self.model = None
        self.processor = None
        self.vision_cache.clear()
        self.load()

    def health(self) -> dict[str, Any]:
        return {
            "backend": "mlx-vlm",
            "model": self.model_id,
            "loaded": self.model is not None,
            "vision_cache_size": len(self.vision_cache),
            "vision_cache_capacity": self.vision_cache_size,
        }

    # ------------------------------------------------------------------
    # Chat
    # ------------------------------------------------------------------

    def chat_stream(self, request_id: str, params: dict[str, Any]) -> None:
        """Drive a single chat turn. Emits `stream` envelopes for each
        token delta + a final `result` envelope. Catches and surfaces
        errors as `error` envelopes so the caller can recover."""
        from mlx_vlm import stream_generate  # type: ignore
        from mlx_vlm.prompt_utils import apply_chat_template  # type: ignore

        if self.model is None:
            self.load()

        messages = params.get("messages") or []
        tools = params.get("tools") or []
        image_b64 = params.get("image_b64")
        max_tokens = int(params.get("max_tokens") or self.default_max_tokens)
        temperature = float(
            params.get("temperature") or self.default_temperature
        )

        # Compose the prompt via the model's chat template. mlx-vlm's
        # `apply_chat_template` takes (processor, config, messages,
        # num_images=...).
        try:
            num_images = 1 if image_b64 else 0
            # mlx-vlm 0.4+ exposes the model config on `model.config`;
            # earlier versions accept `processor.config`. Try both.
            cfg = getattr(self.model, "config", None) or getattr(
                self.processor, "config", None
            )
            prompt = apply_chat_template(
                self.processor, cfg, messages, num_images=num_images
            )
        except Exception as e:  # noqa: BLE001 — surface the error
            emit({
                "id": request_id,
                "error": {
                    "code": 500,
                    "message": f"prompt template failed: {e!s}",
                },
            })
            return

        # Tool schemas: not all Qwen3-VL builds honour native tool
        # calling via the chat template; for the fenced-JSON safety
        # net we append a system note describing the available tools
        # in qwen3-coder style. CognitionEngine's existing fenced-
        # JSON parser will recover any markdown-wrapped calls.
        if tools:
            tool_schemas_json = json.dumps(tools, indent=2)
            tool_note = (
                "\n\nYou may call any of these tools by emitting a "
                "<tool_call>{\"name\":\"...\",\"arguments\":{...}}</tool_call> "
                "block in your response:\n" + tool_schemas_json
            )
            prompt = prompt + tool_note
        sys.stderr.write(
            f"[brain.py] chat_stream: messages={len(messages)} "
            f"tools={len(tools or [])} image={'yes' if image_b64 else 'no'} "
            f"prompt_chars={len(prompt)}\n"
        )
        sys.stderr.flush()

        # Image: decode base64 → PIL image.
        image_args: list[Any] = []
        vision_cache = None
        cache_hit = False
        if image_b64:
            try:
                from PIL import Image  # type: ignore
                img_bytes = base64.b64decode(image_b64)
                image = Image.open(io.BytesIO(img_bytes)).convert("RGB")
                image_args = [image]
                # Vision encoder cache, keyed by SHA256(image_b64).
                key = hashlib.sha256(img_bytes).hexdigest()[:16]
                if key in self.vision_cache:
                    vision_cache = self.vision_cache[key]
                    cache_hit = True
                    self.vision_cache.move_to_end(key)
                else:
                    try:
                        from mlx_vlm import VisionFeatureCache  # type: ignore
                        vision_cache = VisionFeatureCache()
                    except ImportError:
                        vision_cache = None
                    self.vision_cache[key] = vision_cache
                    if len(self.vision_cache) > self.vision_cache_size:
                        self.vision_cache.popitem(last=False)
            except Exception as e:  # noqa: BLE001
                emit_log("warn", "image decode failed; skipping vision", error=str(e))
                image_args = []
                vision_cache = None

        # Stream tokens. Some Gemma / non-VLM-shaped MLX builds
        # accept image kwargs but generate zero tokens when the
        # image is present (the model's tokenizer adds an <image>
        # placeholder it can't decode). Retry once without the
        # image if the first attempt yields nothing.
        def _run(use_image: bool) -> tuple[list[str], int, int]:
            buf: list[str] = []
            chunks_seen = 0
            kwargs: dict[str, Any] = {
                "max_tokens": max_tokens,
                "temperature": temperature,
            }
            if use_image and image_args:
                kwargs["image"] = image_args
            if use_image and vision_cache is not None:
                kwargs["vision_cache"] = vision_cache
            sys.stderr.write(
                f"[brain.py] stream_generate begin: prompt_len={len(prompt)} "
                f"use_image={use_image} max_tokens={max_tokens}\n"
            )
            sys.stderr.flush()
            for chunk in stream_generate(
                self.model, self.processor, prompt, **kwargs
            ):
                chunks_seen += 1
                delta = getattr(chunk, "text", None)
                if delta:
                    buf.append(delta)
                    emit({"id": request_id, "stream": {"delta": delta}})
            sys.stderr.write(
                f"[brain.py] stream_generate end: text_len={sum(len(s) for s in buf)} "
                f"chunks_seen={chunks_seen}\n"
            )
            sys.stderr.flush()
            return buf, chunks_seen, sum(len(s) for s in buf)

        text_buffer: list[str] = []
        try:
            text_buffer, _, total = _run(use_image=bool(image_args))
            if total == 0 and image_args:
                sys.stderr.write(
                    "[brain.py] zero tokens with image — retrying without\n"
                )
                sys.stderr.flush()
                text_buffer, _, _ = _run(use_image=False)
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(f"[brain.py] generate FAILED: {e!s}\n")
            sys.stderr.flush()
            emit({
                "id": request_id,
                "error": {
                    "code": 500,
                    "message": f"generate failed: {e!s}",
                },
            })
            return

        # Post-process: extract any <tool_call>...</tool_call> blocks
        # and strip them from the user-visible text.
        full_text = "".join(text_buffer)
        cleaned_text, tool_calls = split_tool_calls(full_text)

        # Stream-emit each tool call so callers can dispatch as soon
        # as they land (CognitionEngine expects the same shape).
        for tc in tool_calls:
            emit({
                "id": request_id,
                "stream": {"tool_call": tc},
            })

        emit({
            "id": request_id,
            "stream_end": True,
        })
        emit({
            "id": request_id,
            "result": {
                "text": cleaned_text,
                "tool_calls": tool_calls,
                "stop_reason": "stop",
                "vision_cache_hit": cache_hit,
            },
        })


# ---------------------------------------------------------------------------
# Wire / dispatch
# ---------------------------------------------------------------------------


def serve() -> None:
    model_id = os.environ.get(
        "ROCKY_BRAIN_MODEL", "mlx-community/Qwen3-VL-4B-Instruct-4bit"
    )
    brain = Brain(model_id)

    try:
        brain.load()
    except Exception as e:  # noqa: BLE001
        emit({
            "log": {
                "level": "error",
                "ts": time.time(),
                "msg": f"brain failed to load: {e!s}",
                "fields": {"model": model_id},
            }
        })
        # Still emit ready so the supervisor sees us — health() will
        # report `loaded: false` and the caller can decide to fall
        # back to the LM Studio backend.
    emit({"event": "ready", "payload": {"model": model_id}})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            envelope = json.loads(line)
        except json.JSONDecodeError as e:
            emit({
                "id": None,
                "error": {"code": 400, "message": f"invalid JSON: {e!s}"},
            })
            continue
        request_id = envelope.get("id")
        method = envelope.get("method")
        params = envelope.get("params") or {}

        if method == "health":
            emit({"id": request_id, "result": brain.health()})
            continue

        if method == "set_model":
            target = params.get("name")
            if not isinstance(target, str) or not target:
                emit({
                    "id": request_id,
                    "error": {"code": 400, "message": "missing 'name'"},
                })
                continue
            try:
                brain.hot_swap(target)
                emit({"id": request_id, "result": {"model": target}})
            except Exception as e:  # noqa: BLE001
                emit({
                    "id": request_id,
                    "error": {"code": 500, "message": f"set_model: {e!s}"},
                })
            continue

        if method == "chat_stream":
            try:
                brain.chat_stream(request_id, params)
            except Exception as e:  # noqa: BLE001
                emit({
                    "id": request_id,
                    "error": {"code": 500, "message": f"chat_stream: {e!s}"},
                })
            continue

        emit({
            "id": request_id,
            "error": {"code": 404, "message": f"unknown method: {method}"},
        })


if __name__ == "__main__":
    serve()
