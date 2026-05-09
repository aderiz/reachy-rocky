---
title: Tools registry
type: concept
status: current
last_updated: 2026-05-08
sources:
  - Sources/Cognition/ToolRegistry.swift
  - Sources/Cognition/CognitionEngine.swift
  - Sources/Rocky/Tools/
tags: [llm, tools, cognition]
---

# Tools registry

The bridge between the LLM and the rest of Rocky. Every robot motion,
every external lookup, every spoken word goes through here. Reasons:

- One canonical schema list to hand to the LLM each turn.
- Closed-set dispatch — the LLM cannot invent a tool name and have it
  silently match something it shouldn't.
- One place to log invocations, latencies, and arg/result payloads.
- Tools can be added without touching the cognition engine.

## The contract

`ToolRegistry` is an actor (`Sources/Cognition/ToolRegistry.swift`)
holding a `[String: Tool]` map. A `Tool` is a `(ToolSchema, Handler)`
pair where the handler is `@Sendable (JSONValue) async throws ->
JSONValue`.

```swift
public func register(
    name: String,
    description: String,
    parameters: JSONValue = .object([...]),
    handler: @escaping Handler
)
```

`schemas` returns the OpenAI-style array passed to the LLM each turn
(`{ "type": "function", "function": { "name": ..., "description": ...,
"parameters": ... } }`). `invoke(name:argumentsJSON:llmMessageId:)`
parses the JSON args, runs the handler, and emits a `tool_invocation`
telemetry event with name, args, result, and latency.

## Where tools live

Two places, by design:

### Built-ins — `AppServices.registerInitialTools()`

The tools that need privileged access to robot state, services, or the
log bus. Registered eagerly during `AppServices` boot:

| Tool                      | Purpose |
|---------------------------|---------|
| `look_at`                 | Orient the head to yaw/pitch (degrees), with a calm 1.2 s default duration. |
| `set_motor_mode`          | `enabled` / `disabled` / `gravity_compensation`. |
| `wake_up`                 | Plays the recorded `wake_up` move. |
| `go_to_sleep`             | Plays the recorded `goto_sleep` move. |
| `stop_motion`             | Cancels any in-flight `goto`. |
| `play_emotion`            | Plays a named recorded move from the Pollen emotions library. |
| `express`                 | Convenience: emotion + optional spoken line. |
| `pause_face_tracking`     | Suppresses face-target updates without killing the sidecar. |
| `resume_face_tracking`    | Re-enables face-target updates. |
| `say`                     | Sends `text` to TTS. Runs `cleanupForTTS` first. |
| `stop_speaking`           | Cancels the in-flight TTS clip. |
| `get_state`               | Snapshot of robot + services for diagnostics. |

### External — `Sources/Rocky/Tools/`

Each external tool is a self-contained type with a static
`register(in registry: ...)` entry point that AppServices calls during
boot. Each owns its own dependencies (URLSession, EventStore,
LocationManager) so the registration site stays narrow.

| File                  | Tool             | What it returns |
|-----------------------|------------------|-----------------|
| `TimeTool.swift`      | `get_current_time` | Local time + day of week. |
| `WeatherTool.swift`   | `get_weather`    | Open-Meteo current + short forecast (auto-detected location, falls back to a named place). |
| `WebSearchTool.swift` | `search_web`     | Top-N Brave Search results. Disabled when `settings.braveSearchAPIKey` is empty (returns a structured "no key" error to the LLM, not a network call). |
| `CalendarTool.swift`  | `read_calendar`  | EventKit upcoming events. Gated by Calendar permission. |
| `RememberTool.swift`  | `remember`       | Writes a fact into the mempalace memory sidecar. Recall happens automatically each turn — see the cognition engine's memory injection. |

The split exists because the second group has external dependencies
(network, OS frameworks, secrets) that don't belong in `AppServices`,
and because it makes adding a new tool cheap: write the file, add one
line in `registerInitialTools()`.

## Dispatch path

```
LLM stream chunk arrives
   │
   ├─▶ tool_calls field present?  ──── yes ──▶ ToolRegistry.invoke(...)
   │                                              │
   │                                              ├─▶ tool result becomes
   │                                              │   a `tool` message
   │                                              └─▶ next assistant turn
   │
   └─▶ no tool_calls — but the assistant text
       contains a fenced JSON block?
                │
                ├─▶ extractFencedToolCalls() recovers it
                │     and the engine treats it as a real
                │     tool_calls field
                └─▶ stripFencedJSONBlocks() cleans the
                    transcript so the user doesn't see
                    the raw JSON
```

### Fenced fallback (Gemma)

Some models — Gemma 4 e4b in particular — don't emit OpenAI
`tool_calls` reliably. Instead they wrap invocations in markdown:

````
```json
{"tool": "say", "args": {"text": "Rocky see sun. Warm."}}
```
````

`CognitionEngine.extractFencedToolCalls` scans the assistant text for
fenced JSON bodies and matches one of these shapes:

- `{"tool_calls": [...]}` — a literal forwarded `tool_calls` array.
- `{"function": "<name>", ...}` — name + args at the top level.
- `{"name": "<name>", "arguments": {...}}` — OpenAI-nested form.
- `{"tool": "<name>", "args": {...}}` — the form documented in the
  Rocky persona prompt.

Each recovered call is dispatched as if it had come through the
native `tool_calls` field. `stripFencedJSONBlocks` then removes the
fenced JSON from the transcript so the chat view shows only Rocky's
sentence, not the call payload.

For models with strong native tool-calling (Qwen 2.5 27B 4-bit, etc.),
the fenced path is a no-op fallback — `tool_calls` arrive natively
and the regex finds nothing to recover.

## TTS cleanup

Every path that speaks runs through `CognitionEngine.cleanupForTTS`
before the audio is generated:

- Strips wrapping double quotes.
- Strips `<|...|>` template tokens that some models leak.
- Strips a leading `=` (a Gemma idiom).
- Strips literal `tool_code` markers.
- Expands abbreviations: `°C` → "degrees", `kph` / `km/h` →
  "kilometres per hour", `%` → "percent", 2–5-letter all-caps
  acronyms get spelled out letter-by-letter.
- Strips bare `name{args}` patterns where a model wrote the call
  inline as text.

Without this, TTS pronounces "17°C" as "one seven degree symbol c" and
"15 kph" as "one five kuh-puh-huh."

## Telemetry

Each invocation publishes `tool_invocation` (name, args, result,
duration_ms, llmMessageId). The cognition engine also publishes
`llm_tool_call` when the call is *requested*, before dispatch. The
two together form a complete causal trace from "LLM asked for X" to
"X returned Y after Z ms."

## See also

- `decisions/0003-sidecar-convention.md` — sidecars (mempalace, mlx-tts)
  as tool-handler dependencies.
- `concepts/voice-pipeline.md` — `say` + `stop_speaking` route through
  the listen pipeline's echo gate.
- `concepts/permissions-authority.md` — `read_calendar` and
  `get_weather` (location) gate on permissions.
