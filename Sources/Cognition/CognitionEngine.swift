import Foundation
import Memory
import Telemetry

/// High-level orchestrator: takes a user transcript, runs an LLM turn against
/// LM Studio, dispatches any tool calls, and surfaces the final assistant
/// reply as `Output` events. Owns the rolling conversation transcript so the
/// model sees prior turns.
public actor CognitionEngine {
    public struct Config: Sendable {
        public var systemPrompt: String
        public var maxToolRounds: Int
        public var memoryRecallEnabled: Bool
        public var memoryTopK: Int

        public init(
            systemPrompt: String = Self.defaultSystemPrompt,
            maxToolRounds: Int = 4,
            memoryRecallEnabled: Bool = true,
            memoryTopK: Int = 5
        ) {
            self.systemPrompt = systemPrompt
            self.maxToolRounds = maxToolRounds
            self.memoryRecallEnabled = memoryRecallEnabled
            self.memoryTopK = memoryTopK
        }

        public static let defaultSystemPrompt = """
        You are Rocky, a small embodied robot sitting on a desk next to the user.
        You have a head you can turn, antennas you can wiggle, and a voice.

        STYLE
        - Keep replies short and natural; one or two sentences unless asked.
        - You can move while you talk.

        ACTING WITH TOOLS — IMPORTANT
        - When you want to move, look, speak, or change Rocky's state, you MUST
          call one of the provided tools. Don't pretend or roleplay actions.
        - Prefer the OpenAI tool-call format (the `tool_calls` field of your
          response). Do NOT wrap tool invocations in markdown code fences.
        - If your runtime cannot emit `tool_calls`, you MAY emit a single
          fenced JSON block on its own line in this exact form:
              ```json
              {"tool": "<tool_name>", "args": { ... }}
              ```
          Nothing else inside the fence. The harness will parse this and
          dispatch the call. You can place a short natural-language sentence
          OUTSIDE the fence, but never put commentary inside the fence.
        - Never describe a tool call without actually issuing it. If a tool
          fails, mention what failed in plain text.
        """
    }

    public enum Output: Sendable {
        case assistantDelta(String)
        case assistantFinal(String, latencyMs: Double, firstChunkMs: Double?)
        case toolCallDispatched(name: String, argumentsJSON: String, id: String)
        case toolCallResult(ToolResult)
        case error(String)
    }

    /// The active brain backend. Either `LMStudioBrain` (text-only,
    /// HTTP, v0.1 baseline) or `MLXVLMBrain` (native MLX, vision-
    /// aware, v0.2 default). The engine doesn't care which is in
    /// play — both speak the same `ChatChunk` stream shape. `var`
    /// because AppServices upgrades from LMStudioBrain → MLXVLMBrain
    /// after the brain sidecar finishes loading the model.
    public private(set) var brain: any BrainBackend

    /// Live-swap the brain backend (e.g. when the brain sidecar
    /// finishes loading the model and we upgrade from LM Studio
    /// fallback). Existing transcript is preserved across the swap.
    public func setBrain(_ brain: any BrainBackend) {
        self.brain = brain
    }

    /// Optional closure called at turn start to fetch the latest
    /// camera frame for vision-aware brains. AppServices wires this
    /// to read its `lastCameraFrame` mirror. Returns `nil` when no
    /// fresh frame is available — text-only brains ignore the
    /// image regardless.
    public typealias ImageProvider = @Sendable () async -> BrainImage?
    public var imageProvider: ImageProvider?

    public let registry: ToolRegistry
    public let memory: MemoryService?
    private let logBus: LogBus
    public private(set) var config: Config
    private var transcript: [ChatMessage]

    public init(
        brain: any BrainBackend,
        registry: ToolRegistry,
        memory: MemoryService? = nil,
        logBus: LogBus,
        config: Config = Config(),
        imageProvider: ImageProvider? = nil
    ) {
        self.brain = brain
        self.registry = registry
        self.memory = memory
        self.logBus = logBus
        self.config = config
        self.imageProvider = imageProvider
        self.transcript = [.init(role: .system, content: config.systemPrompt)]
    }

    /// Live-swap the image provider after init (e.g. when the camera
    /// sidecar comes online mid-session).
    public func setImageProvider(_ provider: ImageProvider?) {
        self.imageProvider = provider
    }

    /// M7 fast-path matcher. When non-nil and a user utterance
    /// matches one of its patterns, the engine dispatches the
    /// pattern's handler directly and yields its reply through the
    /// same Output stream the brain would have used. Bypasses
    /// `brain.chatStream` entirely for matched queries — sub-second
    /// time-to-first-word for trivial information fetches.
    public var fastPath: FastPath?

    public func setFastPath(_ fastPath: FastPath?) {
        self.fastPath = fastPath
    }

    public func setConfig(_ config: Config) {
        self.config = config
        if let first = transcript.first, first.role == .system {
            transcript[0] = .init(role: .system, content: config.systemPrompt)
        } else {
            transcript.insert(.init(role: .system, content: config.systemPrompt), at: 0)
        }
    }

    public func resetConversation() {
        transcript = [.init(role: .system, content: config.systemPrompt)]
    }

    public func send(userText: String) -> AsyncThrowingStream<Output, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try await self.runTurn(userText: userText, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internal

    private func runTurn(
        userText: String,
        continuation: AsyncThrowingStream<Output, Error>.Continuation
    ) async throws {
        transcript.append(.init(role: .user, content: userText))

        // M7 fast-path. Try to short-circuit the brain for trivial
        // queries (time, weather, calendar, search, remember,
        // greetings). On a match the registered handler fetches the
        // data, formats a Rocky-voice reply, and we yield it through
        // the same Output stream the brain would have used — sub-
        // second time-to-first-word.
        if let fastPath, let match = await fastPath.match(userText) {
            do {
                if let reply = try await fastPath.dispatch(match), !reply.isEmpty {
                    let started = Date()
                    transcript.append(.init(role: .assistant, content: reply))
                    let latencyMs = Date().timeIntervalSince(started) * 1000
                    continuation.yield(.assistantDelta(reply))
                    continuation.yield(.assistantFinal(
                        reply, latencyMs: latencyMs, firstChunkMs: latencyMs
                    ))
                    await logBus.publish(.sidecarLog(
                        sidecar: "cognition",
                        level: .info,
                        message: "fast-path hit",
                        fields: ["intent": match.intent.rawValue]
                    ))
                    return
                }
            } catch {
                // Fast-path handler failed — log and fall through to
                // the brain. Don't surface the error; the user's
                // turn still resolves via the normal path.
                await logBus.publish(.error(
                    scope: "cognition/fast-path",
                    message: "handler for \(match.intent.rawValue) failed: \(error)",
                    recoverable: true
                ))
            }
        }

        // Pre-turn recall: ask the memory sidecar for the top-K drawers
        // most relevant to this user utterance and stitch them into the
        // messages we send the LLM as a temporary system message. Not
        // appended to the persistent transcript — fresh per turn so old
        // recalls don't pile up. Failures are non-fatal: if the sidecar
        // is offline or slow, we proceed without memory. The user can
        // disable recall (but keep writes) via the Memory settings
        // toggle — useful for A/B comparing replies.
        let recallEnvelope: ChatMessage?
        if config.memoryRecallEnabled {
            recallEnvelope = await Self.fetchRecallEnvelope(
                memory: memory, query: userText,
                k: config.memoryTopK, logBus: logBus
            )
        } else {
            recallEnvelope = nil
        }

        var rounds = 0
        // Dedup ledger across this turn — small LLMs (Gemma especially)
        // sometimes loop on `get_weather({})` or similar after the
        // first tool result, fanning out 3–4 identical calls before
        // hitting `maxToolRounds`. If we see the same (name, args)
        // pair fire twice in one turn, abort the loop and force the
        // model to actually speak instead of cascading.
        var dispatchedSignatures: Set<String> = []
        // Track whether `say` fired anywhere in this turn. Small LLMs
        // routinely forget to call `say` after tool results — they
        // generate natural-language text in the assistant message
        // content, expecting that to reach the user. It doesn't:
        // text alone is rendered to the chat, but TTS only fires
        // when `say` is dispatched. If we end a turn with non-empty
        // text and no `say`, auto-dispatch the text so the user
        // actually hears Rocky.
        var spokeThisTurn = false

        while rounds < config.maxToolRounds {
            rounds += 1
            let started = Date()
            var firstChunkMs: Double?
            var assistantText = ""
            var toolNamesByIndex: [Int: String] = [:]
            var toolArgsByIndex: [Int: String] = [:]
            var toolIdsByIndex: [Int: String] = [:]
            var sawToolCalls = false

            let tools = await registry.schemas
            let messagesForLLM = Self.injectRecall(
                envelope: recallEnvelope, into: transcript
            )
            // Vision-aware brains take a camera frame at turn start;
            // text-only brains ignore it.
            let image: BrainImage? = await imageProvider?()
            let stream = brain.chatStream(
                messages: messagesForLLM,
                tools: tools.isEmpty ? nil : tools,
                image: image
            )

            for try await chunk in stream {
                if firstChunkMs == nil {
                    firstChunkMs = Date().timeIntervalSince(started) * 1000
                }
                if let delta = chunk.contentDelta, !delta.isEmpty {
                    assistantText += delta
                    continuation.yield(.assistantDelta(delta))
                }
                for tc in chunk.toolCallDeltas {
                    sawToolCalls = true
                    if let name = tc.name { toolNamesByIndex[tc.index] = name }
                    if let id = tc.id { toolIdsByIndex[tc.index] = id }
                    if let args = tc.argumentsDelta {
                        toolArgsByIndex[tc.index, default: ""] += args
                    }
                }
            }

            if !sawToolCalls {
                // Defensive parse: some models (Gemma 4 etc.) don't emit
                // OpenAI `tool_calls` reliably. They sometimes embed tool
                // invocations inside a ```json``` fence. Try to recover.
                let toolNames = await registry.names
                let extractedCalls = Self.extractFencedToolCalls(
                    in: assistantText, knownTools: toolNames
                )
                if !extractedCalls.isEmpty {
                    sawToolCalls = true
                    for (index, call) in extractedCalls.enumerated() {
                        toolNamesByIndex[index] = call.name
                        toolArgsByIndex[index] = call.argumentsJSON
                        toolIdsByIndex[index] = "fenced_\(index)"
                    }
                    // Strip fenced blocks from the assistant message we
                    // commit to the transcript so we don't keep the JSON
                    // visible in the chat.
                    assistantText = Self.stripFencedJSONBlocks(from: assistantText)
                    continuation.yield(.assistantDelta(
                        "\u{2009}"  // hairspace marker, no-op visually
                    ))
                } else {
                    // Clean up cosmetic quote-wrapping for both the
                    // chat and TTS — the persona prompt forbids it
                    // but small models keep doing it. Strip at the
                    // boundary so the transcript and the spoken
                    // audio agree.
                    let cleanedText = Self.cleanupForTTS(assistantText)
                    let totalMs = Date().timeIntervalSince(started) * 1000
                    continuation.yield(.assistantFinal(
                        cleanedText, latencyMs: totalMs, firstChunkMs: firstChunkMs
                    ))
                    if !cleanedText.isEmpty {
                        transcript.append(.init(role: .assistant, content: cleanedText))
                    }
                    // Auto-dispatch text content to `say` if the model
                    // forgot to. Small LLMs routinely emit prose into
                    // the assistant message instead of calling the
                    // tool, leaving Rocky silent while the chat shows
                    // text.
                    // Auto-say only when the cleaned text contains
                    // actual letters. The strip passes above can
                    // leave punctuation residue (`. ,` etc.) when
                    // the model emitted nothing but tool-code
                    // artifacts; saying that aloud is worse than
                    // saying nothing.
                    let toSpeak = cleanedText
                    let hasLetters = toSpeak.contains(where: \.isLetter)
                    if !spokeThisTurn, !toSpeak.isEmpty, hasLetters {
                        struct SayArgs: Encodable { let text: String }
                        let args = (try? JSONEncoder().encode(SayArgs(text: toSpeak)))
                            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        let result = await registry.invoke(
                            name: "say",
                            argumentsJSON: args,
                            llmMessageId: "auto-say"
                        )
                        continuation.yield(.toolCallDispatched(
                            name: "say",
                            argumentsJSON: args,
                            id: "auto-say"
                        ))
                        continuation.yield(.toolCallResult(result))
                    }
                    // Post-turn write: append both sides of this exchange
                    // to the palace as verbatim drawers. Fire-and-forget
                    // so the user-facing latency is unaffected.
                    if let memory {
                        memory.recordDetached(role: .user, text: userText)
                        if !cleanedText.isEmpty {
                            memory.recordDetached(role: .assistant,
                                                   text: cleanedText)
                        }
                    }
                    return
                }
            }

            // The model emitted tool calls. Append the assistant message
            // (with the tool_calls), then run each, then loop.
            let calls: [ToolCall] = toolNamesByIndex.keys.sorted().map { idx in
                ToolCall(
                    id: toolIdsByIndex[idx] ?? "call_\(idx)",
                    type: "function",
                    function: .init(
                        name: toolNamesByIndex[idx] ?? "unknown",
                        arguments: toolArgsByIndex[idx] ?? "{}"
                    )
                )
            }
            let assistantMsg = ChatMessage(
                role: .assistant,
                content: assistantText.isEmpty ? nil : assistantText,
                toolCalls: calls
            )
            transcript.append(assistantMsg)

            // Detect cascading-identical-call loops. If every call in
            // this round has already fired earlier in the turn, the
            // model is stuck — break the loop instead of letting it
            // burn another round on the same data.
            let signatures = calls.map { "\($0.function.name)::\($0.function.arguments)" }
            let allRepeats = !signatures.isEmpty
                && signatures.allSatisfy { dispatchedSignatures.contains($0) }

            for call in calls {
                continuation.yield(.toolCallDispatched(
                    name: call.function.name,
                    argumentsJSON: call.function.arguments,
                    id: call.id
                ))
                let result = await registry.invoke(
                    name: call.function.name,
                    argumentsJSON: call.function.arguments,
                    llmMessageId: call.id
                )
                continuation.yield(.toolCallResult(result))
                transcript.append(.init(
                    role: .tool,
                    content: result.resultJSON,
                    name: call.function.name,
                    toolCallId: call.id
                ))
                if call.function.name == "say" {
                    spokeThisTurn = true
                }
            }
            for sig in signatures { dispatchedSignatures.insert(sig) }

            if allRepeats {
                continuation.yield(.error(
                    "model repeated identical tool calls; ending turn"
                ))
                return
            }
            // End the turn once `say` has fired. After Rocky has
            // spoken, looping back to the brain causes the model to
            // chatter on (a different sentence than what was spoken)
            // and that follow-up text becomes the chat bubble — so
            // the chat and TTS diverge. The semantic contract is
            // "say IS the response"; nothing more is expected.
            if spokeThisTurn {
                return
            }
            // Loop: feed tool outputs back to the model for another turn.
        }

        // Hit max rounds — surface a soft warning rather than hanging.
        continuation.yield(.error("hit max tool rounds (\(config.maxToolRounds))"))
    }

    // MARK: - Memory injection

    /// Fetch top-K relevant memories and format them as a single system
    /// message. Returns `nil` when memory is offline, recall fails, or
    /// no hits come back. Recall is bounded by `recallTimeoutS` so the
    /// LLM call isn't held up by a slow sidecar.
    /// Recall budget. Wider than the original 1.5 s because the
    /// mempalace sidecar lazy-loads its ChromaDB embedding model on
    /// the first call per session ("Embedding function initialized"
    /// on stderr). On a cold start that init can take 1.5–3 s by
    /// itself, and a tight timeout silently drops the recall
    /// envelope so the brain answers the first user turn with no
    /// memory context. 4 s covers cold start with comfortable
    /// headroom; warm recalls return in ~50–150 ms so this is only
    /// a worst-case ceiling.
    private static let recallTimeoutS: Double = 4.0

    private static func fetchRecallEnvelope(
        memory: MemoryService?,
        query: String,
        k: Int,
        logBus: LogBus
    ) async -> ChatMessage? {
        guard let memory else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }
        let topK = max(1, min(k, 20))
        let started = Date()
        let hits: [MemoryService.Hit]? = await withTaskGroup(
            of: [MemoryService.Hit]?.self
        ) { group in
            group.addTask { try? await memory.recall(query: trimmed, k: topK) }
            group.addTask {
                try? await Task.sleep(
                    nanoseconds: UInt64(recallTimeoutS * 1_000_000_000)
                )
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let elapsedMs = Date().timeIntervalSince(started) * 1000
        guard let hits else {
            // Distinguish "timed out" from "no hits" so the user can
            // diagnose which side of the gate failed. Both end up
            // injecting nothing, but only the timeout is a problem.
            Task {
                await logBus.publish(.sidecarLog(
                    sidecar: "mempalace", level: .warn,
                    message: String(format: "recall timed out after %.0f ms", elapsedMs),
                    fields: ["query": trimmed]
                ))
            }
            return nil
        }
        guard !hits.isEmpty else {
            Task {
                await logBus.publish(.sidecarLog(
                    sidecar: "mempalace", level: .info,
                    message: String(format: "recall returned 0 hits in %.0f ms", elapsedMs),
                    fields: ["query": trimmed]
                ))
            }
            return nil
        }
        let formatted = hits
            .prefix(topK)
            .map { "- " + $0.text.replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: "\n")
        let body = """
        Background memories — Rocky's actual recollections of prior \
        conversations with this user. They are real and you may rely \
        on them.

        How to use them:
          • If the user asks what you remember about them, or asks \
        about something you talked about before, cite the relevant \
        items naturally in your own voice. Don't read raw timestamps \
        or role tags aloud.
          • For ordinary turns, let the memories inform your reply \
        without forcing a citation — only mention them if they \
        change what you'd say.
          • If a memory contradicts something the user just said, \
        prefer the new statement and treat the older memory as out \
        of date.
          • For deeper or more targeted searches, call the \
        `recall_memory` tool with a specific query.

        Memories:
        \(formatted)
        """
        Task {
            await logBus.publish(.sidecarLog(
                sidecar: "mempalace", level: .info,
                message: String(format: "recall %d hit(s) in %.0f ms", hits.count, elapsedMs),
                fields: ["query": trimmed]
            ))
        }
        return ChatMessage(role: .system, content: body)
    }

    /// Insert the recall envelope right after the persona system prompt
    /// (index 0) and before the conversation history. Keeps the
    /// persistent transcript untouched — the envelope is only for this
    /// LLM call.
    private static func injectRecall(
        envelope: ChatMessage?, into transcript: [ChatMessage]
    ) -> [ChatMessage] {
        guard let envelope else { return transcript }
        var msgs = transcript
        let insertAt = msgs.first?.role == .system ? 1 : 0
        msgs.insert(envelope, at: insertAt)
        return msgs
    }

    // MARK: - Markdown tool-call recovery

    /// Detects tool invocations inside fenced code blocks. Used when an LLM
    /// that doesn't natively emit `tool_calls` falls back to JSON-in-markdown.
    /// Accepts every shape we've seen Gemma / Qwen / Llama produce:
    ///
    ///   {"tool": "name", "args": {...}}                          — Rocky persona format
    ///   {"name": "name", "arguments": {...}}                     — OpenAI function format
    ///   {"name": "name", "arguments": "{...}"}                   — string-encoded args
    ///   {"function": "name", "args": {...}}                      — Gemma improv
    ///   {"function": {"name": "name", "arguments": "{...}"}}     — OpenAI nested
    ///   {"tool_calls": [<any of the above>...]}                  — array wrapper
    public static func extractFencedToolCalls(
        in text: String,
        knownTools: [String]
    ) -> [(name: String, argumentsJSON: String)] {
        let allowed = Set(knownTools)
        var found: [(String, String)] = []
        for body in fencedJSONBodies(in: text) {
            guard let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // Top-level may be a `tool_calls` array OR a single call.
            if let calls = json["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    if let entry = parseSingleCall(call), allowed.contains(entry.0) {
                        found.append(entry)
                    }
                }
            } else if let entry = parseSingleCall(json), allowed.contains(entry.0) {
                found.append(entry)
            }
        }
        return found
    }

    /// Parse a single tool-call object across the half-dozen shapes the
    /// LLM might emit. Returns nil if no recognisable name/args pair.
    private static func parseSingleCall(
        _ dict: [String: Any]
    ) -> (String, String)? {
        // Name extraction. Order matters — `function` can be either a
        // string (Gemma's shorthand) or a nested dict (OpenAI native).
        var name: String?
        var nestedFunction: [String: Any]?
        if let s = dict["tool"] as? String { name = s }
        else if let s = dict["name"] as? String { name = s }
        else if let s = dict["function"] as? String { name = s }
        else if let nested = dict["function"] as? [String: Any] {
            nestedFunction = nested
            name = nested["name"] as? String
        }
        guard let resolvedName = name else { return nil }

        // Argument extraction. Look first inside `function` (OpenAI nested),
        // then at top-level `arguments` / `args`. Both string-encoded and
        // object forms are accepted.
        if let nested = nestedFunction {
            if let argStr = nested["arguments"] as? String {
                return (resolvedName, argStr)
            }
            if let argObj = nested["arguments"],
               let d = try? JSONSerialization.data(withJSONObject: argObj),
               let s = String(data: d, encoding: .utf8) {
                return (resolvedName, s)
            }
        }
        if let argStr = dict["arguments"] as? String {
            return (resolvedName, argStr)
        }
        let argsObj = dict["args"] ?? dict["arguments"] ?? [String: Any]()
        if let d = try? JSONSerialization.data(withJSONObject: argsObj),
           let s = String(data: d, encoding: .utf8) {
            return (resolvedName, s)
        }
        return (resolvedName, "{}")
    }

    /// Removes JSON-tagged fenced blocks (``` ```json … ``` ```) from
    /// the assistant text. Tightened from "any fenced block" to
    /// "json-tagged only" because the previous version stripped
    /// legitimate `bash` / `python` code blocks the assistant might
    /// emit when explaining code — the user would type "show me a
    /// Bash one-liner" and the rendered chat showed nothing.
    /// Normalise text for TTS at the boundary. Two jobs:
    ///
    /// 1. Strip cosmetic quote-wrapping the LLM adds around spoken
    ///    phrases (`"Rocky check weather." "17 degrees today."`).
    ///    Quote characters in synthesized audio sound wrong (TTS
    ///    engines pronounce literal quote marks as awkward pauses
    ///    or skip them).
    ///
    /// 2. Expand symbols and abbreviations that TTS reads
    ///    character-by-character (`°C` → "degree-symbol C", `kph`
    ///    → "kuh-puh-huh"). Tool outputs and persona quotes both
    ///    leak these; centralising the expansion here means tools
    ///    don't each have to remember the rules.
    ///
    /// The persona prompt also instructs the model to use spoken
    /// form natively, but small models forget; cleanup at the
    /// boundary is the reliable fix.
    public static func cleanupForTTS(_ text: String) -> String {
        var out = text

        // 1. Strip chat-template artifacts. Some models (Gemma 4
        // running through harmony-style chat templates, certain
        // misconfigured tokenizers) leak template tokens into the
        // user-visible text: `<|channel|>final<|message|>...`,
        // `<channel|>`, `<|im_start|>`, etc. They make the chat
        // unreadable and confuse the TTS engine.
        out = out.replacingOccurrences(
            of: "<[^>]*\\|[^>]*>",
            with: "",
            options: .regularExpression
        )

        // 2. Strip Gemma's `tool_code` channel format. Gemma 4
        // sometimes emits tool calls as TEXT in this shape:
        //     ="tool_code"
        //     search_web{query: top news today}
        // The OpenAI tool_calls path catches the structured
        // version, but the text channel still leaks the same
        // call as gibberish. Drop the `tool_code` literal AND
        // any function-call-shaped text (`name{args}`).
        out = out.replacingOccurrences(
            of: "(?:=\\s*)?\"?tool_code\"?",
            with: "",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "[a-zA-Z_][a-zA-Z0-9_]*\\s*\\{[^}]*\\}",
            with: "",
            options: .regularExpression
        )

        // 3. Strip a leading `=` that some templates put before
        // function-call values (e.g. `="Rocky ready..."`). After
        // template tokens are gone this is sometimes the only
        // remaining artifact.
        out = out.replacingOccurrences(
            of: "^\\s*=\\s*",
            with: "",
            options: .regularExpression
        )

        // 3. Drop straight + curly quote characters. We keep the
        // punctuation between phrases (the period at the end of
        // each quoted segment), so the resulting prose still has
        // sentence breaks: `"Foo." "Bar."` → `Foo. Bar.`.
        out = out
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\u{201C}", with: "") // U+201C left "
            .replacingOccurrences(of: "\u{201D}", with: "") // U+201D right "
            .replacingOccurrences(of: "\u{2018}", with: "") // U+2018 left '
            .replacingOccurrences(of: "\u{2019}", with: "") // U+2019 right '

        // 4. Symbol / abbreviation expansion. Order matters — do
        // the multi-char patterns before the single-char ones so
        // `°C` becomes "degrees" not "degrees C".
        out = out
            .replacingOccurrences(of: "°C", with: " degrees")
            .replacingOccurrences(of: "°F", with: " degrees")
            .replacingOccurrences(of: "°",  with: " degrees")
            .replacingOccurrences(of: "%",  with: " percent")
            .replacingOccurrences(of: "&",  with: " and ")

        // Whole-word abbreviations — use word-boundary regex so
        // we don't munge embedded characters in URLs etc.
        let wordReplacements: [(pattern: String, replacement: String)] = [
            ("\\bkm/h\\b",  "kilometres per hour"),
            ("\\bkph\\b",   "kilometres per hour"),
            ("\\bkmph\\b",  "kilometres per hour"),
            ("\\bmph\\b",   "miles per hour"),
            ("\\bm/s\\b",   "metres per second"),
        ]
        for (pat, rep) in wordReplacements {
            out = out.replacingOccurrences(
                of: pat,
                with: rep,
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // 5. Acronym spacing — split runs of 2-5 uppercase letters
        // surrounded by word boundaries with a thin space, so TTS
        // engines pronounce them letter-by-letter (`CNN` →
        // `C N N`) instead of as a mangled syllable. The 2-5 cap
        // skips long all-caps shouts (rare in Rocky's persona);
        // word-boundary anchors skip embedded sequences inside
        // CamelCase or URLs.
        out = Self.spaceAcronyms(in: out)

        // Collapse runs of whitespace introduced by the
        // replacements above.
        out = out.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Insert spaces between letters of any 2-5-character all-caps
    /// word so TTS reads it letter-by-letter. `CNN` → `C N N`,
    /// `BBC` → `B B C`. Two-letter combinations like `OK` /
    /// `UK` / `US` are also spaced — TTS engines render them
    /// either way (`OK` is usually `O-K` regardless), and the
    /// uniformity is worth the slight redundancy.
    private static func spaceAcronyms(in text: String) -> String {
        let pattern = "\\b[A-Z]{2,5}\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastEnd = 0
        for match in matches {
            let r = match.range
            if r.location > lastEnd {
                result += nsText.substring(
                    with: NSRange(
                        location: lastEnd,
                        length: r.location - lastEnd
                    )
                )
            }
            let acronym = nsText.substring(with: r)
            result += acronym.map(String.init).joined(separator: " ")
            lastEnd = r.location + r.length
        }
        if lastEnd < nsText.length {
            result += nsText.substring(from: lastEnd)
        }
        return result
    }

    public static func stripFencedJSONBlocks(from text: String) -> String {
        var out = text
        let range = NSRange(out.startIndex..., in: out)
        out = Self.fenceJSONTaggedRegex.stringByReplacingMatches(
            in: out, range: range, withTemplate: ""
        )
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pulls the body of every fenced JSON code block from `text`.
    private static func fencedJSONBodies(in text: String) -> [String] {
        var bodies: [String] = []
        let nsRange = NSRange(text.startIndex..., in: text)
        for match in Self.fenceJSONBodyRegex.matches(in: text, range: nsRange) {
            if match.numberOfRanges >= 2,
               let r = Range(match.range(at: 1), in: text) {
                bodies.append(String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        // Also accept a bare top-level JSON object if the entire reply
        // is one — but only when the object has a tool-call-shaped key
        // at the top level. Without that gate, an assistant reply that
        // *describes* JSON ("the request body is `{...}`") could
        // accidentally fire a tool call against a tool name embedded
        // in the example.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if bodies.isEmpty,
           trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
           Self.bareJsonHasToolCallShape(trimmed) {
            bodies.append(trimmed)
        }
        return bodies
    }

    /// Cheap structural check: does the bare JSON have at least one of
    /// the keys we recognise as a tool-call shape? Avoids parsing
    /// twice (the caller will JSONSerialization-decode it again
    /// regardless) but is enough to gate accidental dispatch on
    /// example JSON.
    private static func bareJsonHasToolCallShape(_ text: String) -> Bool {
        for needle in ["\"tool\"", "\"name\"", "\"function\"", "\"tool_calls\""] {
            if text.contains(needle) { return true }
        }
        return false
    }

    // Compiled once — patterns are constant. NSRegularExpression is
    // safe to share across threads per Apple's docs.
    private static let fenceJSONBodyRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "```(?:json|JSON)?\\s*([\\s\\S]*?)```")
    }()
    private static let fenceJSONTaggedRegex: NSRegularExpression = {
        // Only json-tagged fences — not bare ``` … ``` and not
        // ```python / ```bash / etc.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "```(?:json|JSON)\\s*[\\s\\S]*?```")
    }()
}
