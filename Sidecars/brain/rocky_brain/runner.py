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


class StreamFilter:
    """Streaming-safe tool-call extractor. Feed token deltas in via
    :meth:`feed`; get back (clean_text_to_emit, [completed_block_bodies]).
    Inside a `<|tool_call>...<tool_call|>` block, deltas are buffered
    silently (the conversation UI never sees the raw markers). When the
    end marker arrives, the block body is returned for the caller to
    parse + dispatch as a tool_call event.

    Handles markers split across chunks: text is held back only when
    `pending` ends with a partial start marker prefix; the safe
    leading prefix is emitted on every feed.
    """

    def __init__(self, start: str, end: str) -> None:
        self.start = start
        self.end = end
        self.pending = ""    # text not yet emitted
        self.in_block = False
        self.block = ""

    def feed(self, delta: str) -> tuple[str, list[str]]:
        emit_parts: list[str] = []
        completed: list[str] = []
        cursor = delta
        while cursor:
            if self.in_block:
                self.block += cursor
                cursor = ""
                idx = self.block.find(self.end)
                if idx >= 0:
                    completed.append(self.block[:idx])
                    cursor = self.block[idx + len(self.end):]
                    self.block = ""
                    self.in_block = False
            else:
                self.pending += cursor
                cursor = ""
                idx = self.pending.find(self.start)
                if idx >= 0:
                    emit_parts.append(self.pending[:idx])
                    cursor = self.pending[idx + len(self.start):]
                    self.pending = ""
                    self.in_block = True
                else:
                    # Emit all of `pending` except the trailing window
                    # that could still be a partial start marker.
                    safe_len = max(0, len(self.pending) - len(self.start) + 1)
                    if safe_len > 0:
                        emit_parts.append(self.pending[:safe_len])
                        self.pending = self.pending[safe_len:]
        return "".join(emit_parts), completed

    def finish(self) -> tuple[str, list[str]]:
        """Flush any pending text at end-of-stream. Unclosed tool-call
        blocks return their captured body as both a completed block
        AND visible text (so the user sees what was there)."""
        if self.in_block:
            # Model never closed the block. Return body as completed
            # (parser may recover) AND as visible text fallback.
            unclosed_body = self.block
            self.block = ""
            self.in_block = False
            return unclosed_body, [unclosed_body]
        out = self.pending
        self.pending = ""
        return out, []


def get_tool_markers(processor) -> tuple[str, str]:
    """Resolve (start, end) tool-call markers for the active model.
    Falls back to Gemma 4 defaults when no parser is registered, since
    those are the most common shape Rocky targets in v0.2."""
    try:
        from mlx_vlm.tool_parsers import (
            _infer_tool_parser_from_processor,
            load_tool_module,
        )

        parser_name = _infer_tool_parser_from_processor(processor)
        if parser_name:
            module = load_tool_module(parser_name)
            start = getattr(module, "tool_call_start", None)
            end = getattr(module, "tool_call_end", None)
            if start and end:
                return start, end
    except Exception as e:  # noqa: BLE001
        trace(f"tool-marker resolution failed: {e!s}")
    return "<|tool_call>", "<tool_call|>"


def parse_tool_call_block(body: str, processor) -> list[dict]:
    """Parse the body of a `<|tool_call>...<tool_call|>` block (the
    text *between* the markers). Returns 0+ normalised calls."""
    calls: list[dict] = []
    try:
        from mlx_vlm.tool_parsers import (
            _infer_tool_parser_from_processor,
            load_tool_module,
        )

        parser_name = _infer_tool_parser_from_processor(processor)
        if parser_name:
            module = load_tool_module(parser_name)
            parser_fn = (
                getattr(module, "parse_tool_call", None)
                or getattr(module, "parse_tool_calls", None)
            )
            if callable(parser_fn):
                try:
                    parsed = parser_fn(body)
                except Exception as ex:  # noqa: BLE001
                    trace(f"native parser rejected block: {ex!s}")
                    parsed = None
                if isinstance(parsed, dict):
                    normalised = _normalise_tool_call(parsed, 1)
                    if normalised:
                        calls.append(normalised)
                elif isinstance(parsed, list):
                    for p in parsed:
                        normalised = _normalise_tool_call(
                            p, len(calls) + 1
                        )
                        if normalised:
                            calls.append(normalised)
    except Exception as e:  # noqa: BLE001
        trace(f"native tool-parser unavailable: {e!s}")
    return calls


def fallback_extract_tool_calls(text: str) -> tuple[str, list[dict]]:
    """For models without a registered native parser (e.g. Qwen3), look
    for fenced-JSON / OpenAI-style `<tool_call>...</tool_call>` blocks
    in the FULL text. Returns (cleaned_text, [normalised_calls])."""
    calls: list[dict] = []
    cleaned = text
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
        # Warmup metrics — populated by load() + warm_up(), exposed
        # via health() so the Mac can render Health → Think with real
        # timings even if the LogBus log-event channel races and
        # misses the phase emits during sidecar startup.
        self.last_load_time_ms: int | None = None
        self.last_warmup_ms: int | None = None
        self.last_warmup_text_ms: int | None = None
        self.last_warmup_vision_ms: int | None = None
        self.last_warmup_tools_ms: int | None = None
        self.last_warmup_failed: str | None = None
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

        # `model_id` can be either a Hugging Face repo id ("mlx-community/...")
        # OR a local filesystem path. Expand ~ and resolve so the user
        # can paste paths from anywhere. mlx_vlm.load handles both cases
        # natively once the path is normalized.
        resolved = self.model_id
        if resolved.startswith("~") or resolved.startswith("/") or resolved.startswith("./"):
            resolved = os.path.abspath(os.path.expanduser(resolved))
        self.model_id = resolved
        trace(f"loading model {resolved}")
        emit_log(
            "info",
            "loading model",
            phase="load_start",
            model=resolved,
        )
        started = time.monotonic()
        self.model, self.processor = mlx_load(resolved)
        self.vision_cache = VisionFeatureCache()
        self.prompt_cache_state = PromptCacheState()
        elapsed_ms = int((time.monotonic() - started) * 1000)
        self.last_load_time_ms = elapsed_ms
        trace(f"model loaded in {elapsed_ms} ms")
        emit_log(
            "info",
            "brain model loaded",
            phase="load_done",
            model=resolved,
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
        self.warm_up()

    def warm_up(self) -> None:
        """Pre-pay every Metal-kernel JIT cost using a prompt shape
        that **matches the user's first real query**: a multi-kilobyte
        system prompt, a camera-resolution image, and a tool schema.

        Why "shape-matching" matters: MLX selects specialized kernels
        per tensor shape. A 5-token prompt + 32×32 image only JITs the
        short-prefill / few-vision-tokens kernels. The user's first
        real query carries ~2000 tokens of persona + ~640×480 camera
        frame — different kernels, paid for again on turn 1. The
        previous warmup measured ~6 s but the user still ate ~14 s of
        cold-path JIT on their first question.

        Three passes:
          1. Text-only with a long system prompt → warms the
             long-prefill language kernels.
          2. With a 384×384 image → warms the vision encoder and
             cross-attention at a realistic vision-token count.
          3. With a tool schema attached → warms the tool-calling
             template branch in the chat template + prefill.

        Caches are reset after all passes so the user's first prompt
        doesn't fight the "ok"-primed prefix.
        """
        if self.model is None or self.processor is None:
            return
        from mlx_vlm import stream_generate
        from mlx_vlm.prompt_utils import apply_chat_template
        from mlx_vlm.vision_cache import VisionFeatureCache
        from mlx_vlm.generate import PromptCacheState

        # ~2 KB filler approximating the persona's prefill cost. We
        # don't have the persona at sidecar level (it lives in
        # SettingsStore on the Mac), so we pad with neutral text that
        # tokenises to roughly the same length. The model never sees
        # this — it's discarded after warmup.
        filler_lines = [
            "Rocky is a small embodied robot. Talk in short clauses.",
            "Drop articles. Use base-form verbs. Third-person speech.",
            "Use tools for fresh data: weather, news, calendar, web.",
            "Use training knowledge for facts and explanations.",
            "Reserve 'Rocky not know' for genuinely unknown things.",
            "Never speak the user's question back to them verbatim.",
            "When uncertain, ask one short question, then move on.",
            "Match expression to text meaning. Safety on shelf first.",
        ] * 6  # ~3000 chars, in the ballpark of the real persona
        filler_system = " ".join(filler_lines)

        # A fake tool schema so apply_chat_template walks the
        # tool-calling branch of the chat template. The contents
        # don't matter — we just need the template to render the
        # tools=... clause so prefill has the same prefix shape as
        # the real chat call.
        fake_tools = [{
            "type": "function",
            "function": {
                "name": "noop",
                "description": "Placeholder for warmup.",
                "parameters": {
                    "type": "object",
                    "properties": {"x": {"type": "string"}},
                },
            },
        }]

        def _build_prompt(
            num_images: int, with_tools: bool, with_filler: bool
        ) -> str:
            msgs: list[dict] = []
            if with_filler:
                msgs.append({"role": "system", "content": filler_system})
            msgs.append({"role": "user", "content": "ok"})
            messages = self._to_content_parts(msgs)
            tools = fake_tools if with_tools else None
            try:
                return apply_chat_template(
                    self.processor, self.model.config, messages,
                    num_images=num_images,
                    tools=tools,
                    enable_thinking=self.enable_thinking,
                )
            except TypeError:
                return apply_chat_template(
                    self.processor, self.model.config, messages,
                    num_images=num_images,
                )

        def _run(prompt: str, image_list: list[str] | None) -> None:
            for _ in stream_generate(
                self.model, self.processor, prompt,
                image=image_list, max_tokens=1, temperature=0.0,
                vision_cache=self.vision_cache,
                prompt_cache_state=self.prompt_cache_state,
            ):
                break

        # Synthetic 384×384 white JPEG. Matches the common vision-
        # token grid used by Qwen3-VL / Gemma 4 / similar VLMs, so the
        # patch-embed → vision-encoder → cross-attn path JITs at the
        # right shape. Content irrelevant.
        from io import BytesIO
        from PIL import Image
        import base64
        buf = BytesIO()
        Image.new("RGB", (384, 384), color="white").save(buf, format="JPEG")
        image_uri = (
            f"data:image/jpeg;base64,"
            f"{base64.b64encode(buf.getvalue()).decode('ascii')}"
        )

        started = time.monotonic()
        text_ms = 0
        vision_ms = 0
        tools_ms = 0
        try:
            # Pass 1: long-prompt, text-only. Warms long-prefill
            # language kernels. ALWAYS runs (every model has these).
            _run(
                _build_prompt(
                    num_images=0, with_tools=False, with_filler=True
                ),
                None,
            )
            text_ms = int((time.monotonic() - started) * 1000)

            self.vision_cache = VisionFeatureCache()
            self.prompt_cache_state = PromptCacheState()

            # Pass 2: long-prompt + 384×384 image. Warms the vision
            # encoder + cross-attention kernels at realistic shapes.
            # Wrapped in try so a text-only model (no vision tower)
            # falls through cleanly instead of failing the whole
            # warmup — the caller decides whether to send images
            # later anyway.
            t_vision_start = time.monotonic()
            try:
                _run(
                    _build_prompt(
                        num_images=1, with_tools=False, with_filler=True
                    ),
                    [image_uri],
                )
                vision_ms = int((time.monotonic() - t_vision_start) * 1000)
                self.vision_cache = VisionFeatureCache()
                self.prompt_cache_state = PromptCacheState()
            except Exception as exc:  # noqa: BLE001
                trace(f"image warmup pass skipped: {exc!s}")
                vision_ms = 0

            # Pass 3: long-prompt + tools. Warms the tool-calling
            # chat-template branch — without this, the first real
            # query (which always carries the registry's tool
            # schema) JITs a third kernel variant.
            t_tools_start = time.monotonic()
            _run(
                _build_prompt(
                    num_images=0, with_tools=True, with_filler=True
                ),
                None,
            )
            tools_ms = int((time.monotonic() - t_tools_start) * 1000)

            elapsed_ms = int((time.monotonic() - started) * 1000)
            self.last_warmup_ms = elapsed_ms
            self.last_warmup_text_ms = text_ms
            self.last_warmup_vision_ms = vision_ms
            self.last_warmup_tools_ms = tools_ms
            self.last_warmup_failed = None
            trace(
                f"model warmed in {elapsed_ms} ms "
                f"(text {text_ms} ms + vision {vision_ms} ms + "
                f"tools {tools_ms} ms)"
            )
            emit_log(
                "info",
                "brain model warmed",
                phase="warm_done",
                model=self.model_id,
                warmup_ms=elapsed_ms,
                warmup_text_ms=text_ms,
                warmup_vision_ms=vision_ms,
                warmup_tools_ms=tools_ms,
            )
        except Exception as e:  # noqa: BLE001
            self.last_warmup_failed = str(e)
            trace(f"warm_up FAILED: {e!s}")
            emit_log(
                "warn",
                f"brain warm_up failed: {e!s}",
                phase="warm_failed",
                model=self.model_id,
            )
        finally:
            # Final reset so the user's first real prompt starts on a
            # clean cache, not the filler-primed prefix.
            self.vision_cache = VisionFeatureCache()
            self.prompt_cache_state = PromptCacheState()

    def health(self) -> dict[str, Any]:
        return {
            "backend": "mlx-vlm",
            "model": self.model_id,
            "loaded": self.model is not None,
            "enable_thinking": self.enable_thinking,
            # Warmup snapshot — pull-based source of truth for the
            # Mac's Health view. The push-based log-event channel
            # races against the Mac's LogBus subscription setup
            # during cold startup; polling this RPC after the
            # sidecar emits `ready` is deterministic.
            "load_time_ms": self.last_load_time_ms,
            "warmup_ms": self.last_warmup_ms,
            "warmup_text_ms": self.last_warmup_text_ms,
            "warmup_vision_ms": self.last_warmup_vision_ms,
            "warmup_tools_ms": self.last_warmup_tools_ms,
            "warmup_failed": self.last_warmup_failed,
            "warm": (
                self.model is not None
                and self.last_warmup_ms is not None
                and self.last_warmup_failed is None
            ),
        }

    # ------------------------------------------------------------------
    # Chat
    # ------------------------------------------------------------------

    def _is_qwen3(self) -> bool:
        """True when the loaded model is in the Qwen3 family — used
        to gate the `/no_think` directive that suppresses Qwen3's
        default thinking mode. We match on the model_id string
        (case-insensitive) rather than introspecting the model
        config, because the same suppression heuristic applies to
        all Qwen3 variants regardless of how mlx-vlm wires them
        (Qwen3-VL, Qwen3.5, Qwen3-A3B, etc.)."""
        name = (self.model_id or "").lower()
        return ("qwen3" in name) or ("qwen-3" in name)

    def _append_no_think_directive(self, messages: list[dict]) -> list[dict]:
        """Append ` /no_think` to the LAST user message's text so
        Qwen3 skips its `<think>...</think>` preamble. Mutates a
        copy; original messages list is unchanged. Idempotent — if
        `/no_think` is already present, returns messages as-is.

        Operates on the parts representation: messages whose
        content is a list of `{"type": "text", "text": "..."}`
        get the directive appended to the last text part.
        Tool/tool-call shaped messages are left untouched.
        """
        out = list(messages)
        # Find the last index that's a regular user message with
        # a text-bearing content list.
        for i in range(len(out) - 1, -1, -1):
            m = out[i]
            if m.get("role") != "user":
                continue
            if "tool_calls" in m or "tool_call_id" in m:
                continue
            content = m.get("content")
            if not isinstance(content, list):
                continue
            # Find the last text part.
            text_idx = -1
            for j in range(len(content) - 1, -1, -1):
                if isinstance(content[j], dict) and content[j].get("type") == "text":
                    text_idx = j
                    break
            if text_idx < 0:
                continue
            current = content[text_idx].get("text") or ""
            if "/no_think" in current:
                return out  # already there
            new_parts = list(content)
            new_parts[text_idx] = {
                **content[text_idx],
                "text": f"{current.rstrip()} /no_think",
            }
            out[i] = {**m, "content": new_parts}
            return out
        return out

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

        # Qwen3.x ships with thinking mode ON by default — every reply
        # gets prefixed with a `<think>...</think>` block, which adds
        # 5–15 s of latency and pollutes the chat bubble. The
        # documented way to disable thinking is to append `/no_think`
        # to the user message; the model's chat template treats this
        # as a sentinel and skips the reasoning preamble. `enable_thinking=False`
        # in apply_chat_template isn't reliable across Qwen3 variants
        # — this directive is. Other models (Gemma, Llama) ignore it
        # as ordinary content, so it's safe to apply broadly when the
        # loaded model is in the Qwen3 family.
        if self._is_qwen3() and messages:
            messages = self._append_no_think_directive(messages)

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

        # Streaming-safe tool-call extraction. The StreamFilter
        # suppresses bytes between `<|tool_call>` and `<tool_call|>` so
        # the conversation UI never renders raw markers. Each captured
        # block fires exactly ONE tool_call event — there is no
        # post-stream re-parse on the same text (which was the source
        # of the duplicate-speech bug).
        start_marker, end_marker = get_tool_markers(self.processor)
        stream_filter = StreamFilter(start_marker, end_marker)
        text_buffer: list[str] = []
        tool_calls: list[dict] = []
        call_seq = 0
        chunks_seen = 0

        def emit_calls_from(blocks: list[str]) -> None:
            nonlocal call_seq
            for body in blocks:
                for tc in parse_tool_call_block(body, self.processor):
                    call_seq += 1
                    tc["id"] = f"call_brain_{call_seq}"
                    tool_calls.append(tc)
                    emit({"id": request_id, "stream": {"tool_call": tc}})

        def _run_stream(use_image: bool, _prompt: str) -> bool:
            """Drive `stream_generate` and pump deltas + tool calls
            to the client. Returns True on success, False on failure
            (caller decides whether to retry without image).
            Captures into the enclosing buffers via closure.

            Caches are passed FRESH per call. Reusing the warmup-
            primed caches across model boundaries caused
            `broadcast_shapes` errors on Qwen3-VL: the warmup
            prefix (filler system + fake tools) doesn't match the
            user's real prefix (persona + real tools), and
            mlx-vlm's prefix-reuse path tried to broadcast cached
            K/V tensors of one shape against new K/V tensors of
            another shape. Fresh state per call sacrifices a small
            prefix-reuse perf win for correctness.
            """
            nonlocal chunks_seen
            from mlx_vlm.vision_cache import VisionFeatureCache as _VC
            from mlx_vlm.generate import PromptCacheState as _PC
            try:
                for chunk in stream_generate(
                    self.model,
                    self.processor,
                    _prompt,
                    image=image_list if use_image else None,
                    max_tokens=max_tokens,
                    temperature=temperature,
                    vision_cache=_VC(),
                    prompt_cache_state=_PC(),
                ):
                    chunks_seen += 1
                    if chunks_seen == 1:
                        trace(
                            f"first chunk type={type(chunk).__name__} "
                            f"prompt_tokens={getattr(chunk, 'prompt_tokens', '?')} "
                            f"prompt_tps={getattr(chunk, 'prompt_tps', 0):.1f}"
                        )
                    delta = getattr(chunk, "text", "") if not isinstance(chunk, str) else chunk
                    if not delta:
                        continue
                    clean_delta, blocks = stream_filter.feed(delta)
                    if clean_delta:
                        text_buffer.append(clean_delta)
                        emit({"id": request_id, "stream": {"delta": clean_delta}})
                    if blocks:
                        emit_calls_from(blocks)
                return True
            except Exception as e:  # noqa: BLE001
                trace(f"stream_generate FAILED: {e!s}")
                return False

        success = _run_stream(use_image=image_list is not None, _prompt=prompt)
        if not success:
            emit({
                "id": request_id,
                "error": {"code": 500, "message": "generate failed"},
            })
            return

        # Flush filter state at end-of-stream.
        tail_text, tail_blocks = stream_filter.finish()
        if tail_text:
            text_buffer.append(tail_text)
            emit({"id": request_id, "stream": {"delta": tail_text}})
        if tail_blocks:
            emit_calls_from(tail_blocks)

        full_text = "".join(text_buffer)
        trace(
            f"generate done: text_len={len(full_text)} "
            f"chunks_seen={chunks_seen} tool_calls={len(tool_calls)}"
        )

        # Fallback for models without native start/end markers (Qwen3
        # emits fenced-JSON or `<tool_call>...</tool_call>` instead).
        # Only run when the stream filter captured nothing, so we never
        # double-emit a call that was already caught natively.
        if not tool_calls:
            cleaned_fallback, fallback_calls = fallback_extract_tool_calls(full_text)
            if fallback_calls:
                for tc in fallback_calls:
                    tool_calls.append(tc)
                    emit({"id": request_id, "stream": {"tool_call": tc}})
                full_text = cleaned_fallback

        emit({"id": request_id, "stream_end": True})
        emit({
            "id": request_id,
            "result": {
                "text": full_text.strip(),
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
    # Warm-up runs before `ready` so the first `chat_stream` call
    # doesn't pay the ~5–15 s Metal-kernel JIT cost. Failure is
    # logged but non-fatal: the user just falls back to today's
    # cold-on-first-turn behaviour.
    brain.warm_up()
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
