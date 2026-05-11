"""Brain sidecar runner — JSON-line wire over stdin/stdout.

Follows the mlx-vlm v0.5.0 canonical chat pattern from
`mlx_vlm/chat.py` exactly:

  - messages use the OpenAI content-parts shape:
        {"role": "...", "content": [{"type": "text", "text": "..."}]}
  - apply_chat_template receives `model.config` (the object, not a
    dict) and the typed `tools=` kwarg
  - chat_template_kwargs={"enable_thinking": False} suppresses the
    thinking channel on models that support it
  - images travel as a list of `data:image/...;base64,...` URIs which
    mlx-vlm's `load_image` decodes natively
  - vision_cache + prompt_cache_state are per-instance (KV cache
    reuse across turns; first-frame vision encode cached when the
    same image is sent twice)
  - chunk iteration is `chunk.text` directly — `GenerationResult` is
    the canonical type
  - tool calls are extracted via mlx_vlm.tool_parsers's gemma4 parser
    when the model emits the Gemma 4 `<|tool_call>...<tool_call|>`
    format; otherwise the fenced-JSON path runs as a fallback

The streaming wire to Swift stays the same: `delta` events per chunk,
`tool_call` events for each parsed invocation, `stream_end`, then a
final `result` envelope.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import re
import sys
import threading
import time
from collections import OrderedDict
from typing import Any, Optional

logger = logging.getLogger("rocky.brain")
LOCK = threading.Lock()


def emit(envelope: dict) -> None:
    """Write a JSON envelope on stdout. Always flushed."""
    with LOCK:
        sys.stdout.write(json.dumps(envelope, separators=(",", ":")) + "\n")
        sys.stdout.flush()


def emit_log(level: str, message: str, **fields: Any) -> None:
    emit({
        "log": {
            "level": level,
            "ts": time.time(),
            "msg": message,
            "fields": fields,
        }
    })


def trace(line: str) -> None:
    sys.stderr.write(f"[brain.py] {line}\n")
    sys.stderr.flush()


# ---------------------------------------------------------------------------
# Tool-call extraction
# ---------------------------------------------------------------------------

# Fallback: catch the few wrappers we know about regardless of the
# model's preferred format. The native mlx-vlm `gemma4` parser is
# tried first for models whose template uses `<|tool_call>` /
# `<tool_call|>`; this regex picks up anything else (Qwen3 fenced
# JSON, OpenAI-style `<tool_call>...</tool_call>`).
FALLBACK_TOOL_CALL_PATTERNS = [
    re.compile(r"<tool_call>\s*(?P<json>\{[\s\S]*?\})\s*</tool_call>", re.I),
    re.compile(r"```json\s*(?P<json>\{[\s\S]*?\})\s*```", re.I),
]


def _normalise_tool_call(payload: Any, idx: int) -> Optional[dict]:
    """Coerce whatever the parser/regex spat out into the OpenAI shape
    `{"id":..., "name":..., "arguments":<json-str>}`."""
    if not isinstance(payload, dict):
        return None
    name = payload.get("name") or payload.get("tool") or payload.get("function")
    if isinstance(name, dict):
        name = name.get("name")
    if not isinstance(name, str):
        return None
    arguments = (
        payload.get("arguments")
        or payload.get("args")
        or payload.get("parameters")
        or {}
    )
    if isinstance(arguments, dict):
        arguments_str = json.dumps(arguments, separators=(",", ":"))
    elif isinstance(arguments, str):
        arguments_str = arguments
    else:
        arguments_str = json.dumps(arguments)
    return {
        "id": f"call_brain_{idx}",
        "name": name,
        "arguments": arguments_str,
    }


def extract_tool_calls(
    text: str, processor
) -> tuple[str, list[dict]]:
    """Strip recognised tool-call wrappers from `text` and return
    (cleaned_text, [normalised_call_dicts])."""
    calls: list[dict] = []
    cleaned = text

    # Native parser via the model's chat-template fingerprint.
    try:
        from mlx_vlm.tool_parsers import (
            _infer_tool_parser_from_processor,
            load_tool_module,
        )

        parser_name = _infer_tool_parser_from_processor(processor)
        if parser_name:
            module = load_tool_module(parser_name)
            # Most parsers expose either `parse_tool_calls(text) ->
            # list` or `tool_call_start` / `tool_call_end` markers
            # we can strip after parsing. Try the first; the
            # gemma4 parser exposes `parse_tool_calls`.
            parser_fn = getattr(module, "parse_tool_calls", None)
            if callable(parser_fn):
                native_calls = parser_fn(cleaned) or []
                trace(f"native parser={parser_name!r} found={len(native_calls)}")
                for c in native_calls:
                    normalised = _normalise_tool_call(c, len(calls) + 1)
                    if normalised:
                        calls.append(normalised)
                start = getattr(module, "tool_call_start", None)
                end = getattr(module, "tool_call_end", None)
                if start and end:
                    pattern = re.compile(
                        re.escape(start) + r"[\s\S]*?" + re.escape(end)
                    )
                    cleaned = pattern.sub("", cleaned)
    except Exception as e:  # noqa: BLE001
        trace(f"native tool-parser unavailable: {e!s}")

    # Fallback patterns (Qwen / generic fenced-JSON / OpenAI-style).
    if not calls:
        for pat in FALLBACK_TOOL_CALL_PATTERNS:
            def _consume(match: re.Match) -> str:
                try:
                    payload = json.loads(match.group("json"))
                except json.JSONDecodeError:
                    return match.group(0)
                normalised = _normalise_tool_call(payload, len(calls) + 1)
                if normalised:
                    calls.append(normalised)
                    return ""
                return match.group(0)

            cleaned = pat.sub(_consume, cleaned)

    return cleaned.strip(), calls


# ---------------------------------------------------------------------------
# Brain
# ---------------------------------------------------------------------------


class Brain:
    """Wraps an mlx-vlm model + processor + per-instance caches. Single-
    threaded by design; the runner serialises requests with `LOCK` so two
    `chat_stream` calls don't fight."""

    def __init__(self, model_id: str) -> None:
        self.model_id = model_id
        self.model = None
        self.processor = None
        self.vision_cache = None
        self.prompt_cache_state = None
        self.default_max_tokens = int(
            os.environ.get("ROCKY_BRAIN_MAX_TOKENS", "768")
        )
        self.default_temperature = float(
            os.environ.get("ROCKY_BRAIN_TEMPERATURE", "0.6")
        )
        # User-configurable: thinking-channel models (gemma 4, Harmony
        # variants) emit `<|channel|>thought<channel|>...` before the
        # final answer. Default off so Rocky gets the direct response.
        self.enable_thinking = (
            os.environ.get("ROCKY_BRAIN_ENABLE_THINKING", "").lower()
            in {"1", "true", "yes"}
        )

    def load(self) -> None:
        from mlx_vlm import load as mlx_load
        from mlx_vlm.vision_cache import VisionFeatureCache
        from mlx_vlm.generate import PromptCacheState

        trace(f"loading model {self.model_id}")
        started = time.monotonic()
        self.model, self.processor = mlx_load(self.model_id)
        self.vision_cache = VisionFeatureCache()
        self.prompt_cache_state = PromptCacheState()
        elapsed_ms = int((time.monotonic() - started) * 1000)
        trace(f"model loaded in {elapsed_ms} ms")
        emit_log(
            "info",
            "brain model loaded",
            model=self.model_id,
            load_time_ms=elapsed_ms,
        )

    def hot_swap(self, model_id: str) -> None:
        if model_id == self.model_id and self.model is not None:
            return
        self.model_id = model_id
        self.model = None
        self.processor = None
        self.vision_cache = None
        self.prompt_cache_state = None
        self.load()

    def health(self) -> dict[str, Any]:
        return {
            "backend": "mlx-vlm",
            "model": self.model_id,
            "loaded": self.model is not None,
            "enable_thinking": self.enable_thinking,
        }

    # ------------------------------------------------------------------
    # Chat
    # ------------------------------------------------------------------

    def _to_content_parts(self, messages: list[dict]) -> list[dict]:
        """Convert OpenAI-shape `{"role":..., "content": "..."}` messages
        to mlx-vlm's `{"role":..., "content": [{"type":"text","text":...}]}`
        shape. Tool-shaped messages (with `tool_calls` or
        `tool_call_id`) are passed through verbatim — mlx-vlm's
        templater preserves them for the Jinja tool path."""
        out: list[dict] = []
        for m in messages:
            if not isinstance(m, dict):
                continue
            role = m.get("role")
            if not isinstance(role, str):
                continue
            # Pass tool-call-bearing messages straight through so the
            # template's tool-calling branch sees them.
            if "tool_calls" in m or "tool_call_id" in m or role == "tool":
                out.append(m)
                continue
            raw_content = m.get("content")
            if isinstance(raw_content, list):
                # Already in parts form — pass through.
                out.append({"role": role, "content": raw_content})
                continue
            text = raw_content if isinstance(raw_content, str) else ""
            out.append({
                "role": role,
                "content": [{"type": "text", "text": text}],
            })
        return out

    def chat_stream(self, request_id: str, params: dict[str, Any]) -> None:
        from mlx_vlm import stream_generate
        from mlx_vlm.prompt_utils import apply_chat_template

        if self.model is None:
            self.load()

        raw_messages = params.get("messages") or []
        tools = params.get("tools") or []
        image_b64 = params.get("image_b64")
        max_tokens = int(params.get("max_tokens") or self.default_max_tokens)
        temperature = float(
            params.get("temperature") or self.default_temperature
        )

        messages = self._to_content_parts(raw_messages)

        # Image: pass as a data URI which mlx-vlm's `load_image`
        # decodes natively. Lists per the canonical chat.py.
        image_list = None
        if image_b64:
            image_list = [f"data:image/jpeg;base64,{image_b64}"]

        # Apply chat template using model.config (the OBJECT, not a
        # dict) and native tools=. enable_thinking forwarded.
        try:
            prompt = apply_chat_template(
                self.processor,
                self.model.config,
                messages,
                num_images=1 if image_list else 0,
                tools=tools or None,
                enable_thinking=self.enable_thinking,
            )
        except TypeError:
            # Older mlx-vlm builds don't accept `tools=` and/or
            # `enable_thinking=` — retry without them.
            prompt = apply_chat_template(
                self.processor,
                self.model.config,
                messages,
                num_images=1 if image_list else 0,
            )
        except Exception as e:  # noqa: BLE001
            trace(f"apply_chat_template FAILED: {e!s}")
            emit({
                "id": request_id,
                "error": {"code": 500, "message": f"prompt template failed: {e!s}"},
            })
            return

        trace(
            f"chat_stream: messages={len(messages)} tools={len(tools)} "
            f"image={'yes' if image_list else 'no'} "
            f"prompt_chars={len(prompt)} "
            f"enable_thinking={self.enable_thinking}"
        )

        # Stream tokens.
        text_buffer: list[str] = []
        chunks_seen = 0
        try:
            for chunk in stream_generate(
                self.model,
                self.processor,
                prompt,
                image=image_list,
                max_tokens=max_tokens,
                temperature=temperature,
                vision_cache=self.vision_cache,
                prompt_cache_state=self.prompt_cache_state,
            ):
                chunks_seen += 1
                if chunks_seen == 1:
                    trace(
                        f"first chunk type={type(chunk).__name__} "
                        f"prompt_tokens={getattr(chunk, 'prompt_tokens', '?')} "
                        f"prompt_tps={getattr(chunk, 'prompt_tps', 0):.1f}"
                    )
                delta = getattr(chunk, "text", "") if not isinstance(chunk, str) else chunk
                if delta:
                    text_buffer.append(delta)
                    emit({"id": request_id, "stream": {"delta": delta}})
        except Exception as e:  # noqa: BLE001
            trace(f"stream_generate FAILED: {e!s}")
            emit({
                "id": request_id,
                "error": {"code": 500, "message": f"generate failed: {e!s}"},
            })
            return

        full_text = "".join(text_buffer)
        trace(f"generate done: text_len={len(full_text)} chunks_seen={chunks_seen}")

        # Extract any tool calls the model emitted.
        cleaned_text, tool_calls = extract_tool_calls(full_text, self.processor)
        for tc in tool_calls:
            emit({"id": request_id, "stream": {"tool_call": tc}})

        emit({"id": request_id, "stream_end": True})
        emit({
            "id": request_id,
            "result": {
                "text": cleaned_text,
                "tool_calls": tool_calls,
                "stop_reason": "stop",
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
        emit_log("error", f"brain failed to load: {e!s}", model=model_id)
    emit({"event": "ready", "payload": {"model": model_id}})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            envelope = json.loads(line)
        except json.JSONDecodeError as e:
            emit({"id": None, "error": {"code": 400, "message": f"invalid JSON: {e!s}"}})
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
                emit({"id": request_id, "error": {"code": 400, "message": "missing 'name'"}})
                continue
            try:
                brain.hot_swap(target)
                emit({"id": request_id, "result": {"model": target}})
            except Exception as e:  # noqa: BLE001
                emit({"id": request_id, "error": {"code": 500, "message": f"set_model: {e!s}"}})
            continue

        if method == "chat_stream":
            try:
                brain.chat_stream(request_id, params)
            except Exception as e:  # noqa: BLE001
                trace(f"chat_stream dispatch FAILED: {e!s}")
                emit({"id": request_id, "error": {"code": 500, "message": f"chat_stream: {e!s}"}})
            continue

        emit({"id": request_id, "error": {"code": 404, "message": f"unknown method: {method}"}})


if __name__ == "__main__":
    serve()
