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
                    // CRITICAL: fast-path replies are plain text. They
                    // bypass the brain loop entirely, which means none
                    // of the brain-side auto-say exit paths fire — the
                    // chat bubble would show but no audio would play.
                    // Manually invoke the `say` tool here so the
                    // reply is spoken. This is the systematic fix for
                    // the "weather replies never speak" bug: every
                    // intent registered via fastPath.register
                    // (weather, time, calendar, search, memory) hit
                    // the same dead end before this.
                    struct SayArgs: Encodable { let text: String }
                    let argsJSON = (try? JSONEncoder().encode(SayArgs(text: reply)))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    let sayResult = await registry.invoke(
                        name: "say",
                        argumentsJSON: argsJSON,
                        llmMessageId: "fast-path-say"
                    )
                    continuation.yield(.toolCallDispatched(
                        name: "say",
                        argumentsJSON: argsJSON,
                        id: "fast-path-say"
                    ))
                    continuation.yield(.toolCallResult(sayResult))
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
        // Most recent non-empty assistant text seen across rounds.
        // The auto-say at the no-tool-calls branch only fires on
        // text emitted in *that* round, so when the model emits its
        // answer text + a data tool (e.g. `get_weather`) in round 1
        // and then nothing in round 2, the text was visible in chat
        // but silent — round 2's auto-say had no input. Carry the
        // latest text forward and let every exit path consult it.
        var latestText = ""

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

            // Repetition trap detector. Some models (notably Gemma 4
            // in Harmony thought-channel mode) lock into a loop
            // emitting `<thought>call:</call><|channel|>thought` over
            // and over without ever producing a real response. Without
            // a guard, this burns the full `max_tokens` budget (~30 s
            // of wasted decode) before the stream ends naturally.
            // We watch the tail of `assistantText`: if the last
            // RepetitionWindow chars contain the same RepetitionSlice
            // sequence more than RepetitionThreshold times in a row,
            // the stream is stuck and we break out early.
            var repetitionAborted = false

            for try await chunk in stream {
                if firstChunkMs == nil {
                    firstChunkMs = Date().timeIntervalSince(started) * 1000
                }
                if let delta = chunk.contentDelta, !delta.isEmpty {
                    assistantText += delta
                    continuation.yield(.assistantDelta(delta))
                    // Check for repetition every few chunks (cheap —
                    // operates on the last ~600 chars). If detected,
                    // log + break out of the stream loop early.
                    if assistantText.count > 240,
                       Self.detectRepetitionTrap(in: assistantText) {
                        repetitionAborted = true
                        await logBus.publish(.sidecarLog(
                            sidecar: "cognition",
                            level: .warn,
                            message: "repetition trap detected; aborting stream",
                            fields: ["tail": String(assistantText.suffix(160))]
                        ))
                        break
                    }
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
            // If we aborted the stream due to repetition, scrub the
            // junk tail from assistantText so it doesn't pollute
            // latestText or the chat bubble. The text leading up
            // to the trap (if any) is preserved.
            if repetitionAborted {
                assistantText = Self.scrubRepetitionTail(from: assistantText)
            }
            // Cache the cleaned text from this round (after the
            // fenced-tool-call strip below would have run) so any
            // later exit path can recover the spoken answer if the
            // model never wrapped it in `say`. We use the raw
            // assistantText here because cleanupForTTS is also
            // applied at the auto-say site.
            if !assistantText.isEmpty {
                latestText = assistantText
            }

            if !sawToolCalls {
                // Defensive parse: some models (Gemma 4 etc.) don't emit
                // OpenAI `tool_calls` reliably. They sometimes embed tool
                // invocations inside a ```json``` fence. Try fenced
                // recovery first, then bare-call recovery as a fallback.
                let toolNames = await registry.names
                var extractedCalls = Self.extractFencedToolCalls(
                    in: assistantText, knownTools: toolNames
                )
                var prefix = "fenced"
                if extractedCalls.isEmpty {
                    // Bare-call recovery: model emitted tool-call syntax
                    // as plain content, e.g.
                    //     express({"name": "curious", "text": "..."})
                    extractedCalls = Self.extractBareCallToolCalls(
                        in: assistantText, knownTools: toolNames
                    )
                    if !extractedCalls.isEmpty { prefix = "bare" }
                }
                if extractedCalls.isEmpty {
                    // Tag-style recovery: model emitted XML-tag
                    // shape, e.g. `<say>{text: Bye bye.}</say>` or
                    // `<express>{name: curious, text: "..."}</express>`.
                    // Inner is JSON-or-pseudo-JSON-or-plain — the
                    // normaliser handles all three.
                    extractedCalls = Self.extractTagStyleToolCalls(
                        in: assistantText, knownTools: toolNames
                    )
                    if !extractedCalls.isEmpty { prefix = "tag" }
                }
                if !extractedCalls.isEmpty {
                    sawToolCalls = true
                    for (index, call) in extractedCalls.enumerated() {
                        toolNamesByIndex[index] = call.name
                        toolArgsByIndex[index] = call.argumentsJSON
                        toolIdsByIndex[index] = "\(prefix)_\(index)"
                    }
                    // Strip every recognised syntax shape so the
                    // transcript doesn't keep raw markers visible:
                    // fenced JSON blocks, bare `name({...})` calls,
                    // tag-style `<name>...</name>` blocks, Harmony
                    // thought-channel tags, and stray non-Latin
                    // glitch text (Gemma sometimes prefixes with
                    // Chinese/Cyrillic characters).
                    assistantText = Self.stripFencedJSONBlocks(from: assistantText)
                    assistantText = Self.stripBareCallBlocks(
                        from: assistantText, knownTools: toolNames
                    )
                    assistantText = Self.stripTagStyleBlocks(
                        from: assistantText, knownTools: toolNames
                    )
                    assistantText = Self.stripThoughtMarkers(assistantText)
                    assistantText = Self.stripNonLatinNoise(assistantText)
                    continuation.yield(.assistantDelta(
                        "\u{2009}"  // hairspace marker, no-op visually
                    ))
                    await logBus.publish(.sidecarLog(
                        sidecar: "cognition",
                        level: .info,
                        message: "recovered tool calls from text content",
                        fields: [
                            "shape": prefix,
                            "count": "\(extractedCalls.count)",
                        ]
                    ))
                } else {
                    // Full scrub chain for the no-tool-calls path.
                    // Both the chat bubble and the auto-say input
                    // come from `cleanedText`, so doing this once
                    // at the boundary keeps them in sync.
                    var scrubbed = Self.stripTagStyleBlocks(
                        from: assistantText, knownTools: toolNames
                    )
                    scrubbed = Self.stripThoughtMarkers(scrubbed)
                    scrubbed = Self.stripNonLatinNoise(scrubbed)
                    let cleanedText = Self.cleanupForTTS(scrubbed)
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
                    let preferred = cleanedText.isEmpty
                        ? Self.cleanupForTTS(latestText)
                        : cleanedText
                    if !spokeThisTurn {
                        await maybeAutoSay(
                            text: preferred,
                            registry: registry,
                            continuation: continuation,
                            spokeThisTurn: &spokeThisTurn
                        )
                    }
                    // Post-turn write — fire-and-forget. Same helper
                    // every other turn-exit path uses, so the write
                    // discipline is consistent. The auto-say above
                    // routes through registry.invoke("say", ...)
                    // which would also be captured by the say-tool
                    // path in writeTurnToMemory; here `calls` is
                    // empty (we're in the no-LLM-tool-calls branch)
                    // so the spoken text comes from `cleanedText`.
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
            let rawCalls: [ToolCall] = toolNamesByIndex.keys.sorted().map { idx in
                ToolCall(
                    id: toolIdsByIndex[idx] ?? "call_\(idx)",
                    type: "function",
                    function: .init(
                        name: toolNamesByIndex[idx] ?? "unknown",
                        arguments: toolArgsByIndex[idx] ?? "{}"
                    )
                )
            }
            // **Speech deduplication.** `say`, `express`, and
            // `play_emotion` all produce robot audio. The persona
            // forbids emitting more than one per turn, but Gemma
            // occasionally emits two (`express` + `say` with nearly
            // identical text), which makes Rocky speak the answer
            // twice. Keep only the FIRST speech tool in this round;
            // every other tool (data tools, motion tools) passes
            // through unchanged. This is the minimum-impact fix —
            // it doesn't defer or reorder anything, so the brain's
            // intended turn structure (data tools + one speech in
            // the same response) keeps working.
            let speechToolNames: Set<String> = ["say", "express", "play_emotion"]
            var seenSpeech = false
            let calls: [ToolCall] = rawCalls.filter { call in
                if speechToolNames.contains(call.function.name) {
                    if seenSpeech { return false }
                    seenSpeech = true
                }
                return true
            }
            if calls.count != rawCalls.count {
                await logBus.publish(.sidecarLog(
                    sidecar: "cognition",
                    level: .warn,
                    message: "dropped duplicate speech tool(s) in single round",
                    fields: [
                        "raw_count": "\(rawCalls.count)",
                        "kept_count": "\(calls.count)",
                        "raw_names": rawCalls.map(\.function.name).joined(separator: ","),
                    ]
                ))
            }
            // Sanitize the content text before committing it to
            // the transcript AND yielding a final replacement to
            // the chat bubble. The model sometimes emits a tool
            // call AS a real `tool_calls` field AND duplicates the
            // same call in content (`express({...})` written out
            // as prose). Without this strip, the bubble shows the
            // raw JSON syntax. Order matters:
            //   1. Drop fenced JSON blocks (already accounted for
            //      as proper calls upstream).
            //   2. Drop bare-call syntax (same — those would have
            //      been duplicates of the calls we're about to
            //      dispatch).
            //   3. Drop Harmony thought-channel markers so any
            //      `<thought>call:</call>` wrappers don't leak.
            //   4. Apply standard TTS cleanup so the bubble + the
            //      transcript see the same surface text.
            let toolNamesForStrip = await registry.names
            var sanitizedText = Self.stripFencedJSONBlocks(from: assistantText)
            sanitizedText = Self.stripBareCallBlocks(
                from: sanitizedText, knownTools: toolNamesForStrip
            )
            sanitizedText = Self.stripTagStyleBlocks(
                from: sanitizedText, knownTools: toolNamesForStrip
            )
            sanitizedText = Self.stripThoughtMarkers(sanitizedText)
            sanitizedText = Self.stripNonLatinNoise(sanitizedText)
            sanitizedText = Self.cleanupForTTS(sanitizedText)
            // Yield a final-replacement event so the chat bubble
            // updates from the raw delta stream to the clean text.
            // AppServices' consumer treats `assistantFinal`'s first
            // argument as the authoritative bubble content (see the
            // updated handler).
            if sanitizedText != assistantText {
                let totalMs = Date().timeIntervalSince(started) * 1000
                continuation.yield(.assistantFinal(
                    sanitizedText, latencyMs: totalMs, firstChunkMs: firstChunkMs
                ))
            }
            let assistantMsg = ChatMessage(
                role: .assistant,
                content: sanitizedText.isEmpty ? nil : sanitizedText,
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
                if speechToolNames.contains(call.function.name) {
                    spokeThisTurn = true
                }
            }
            for sig in signatures { dispatchedSignatures.insert(sig) }

            if allRepeats {
                if !spokeThisTurn {
                    await maybeAutoSay(
                        text: Self.cleanupForTTS(latestText),
                        registry: registry,
                        continuation: continuation,
                        spokeThisTurn: &spokeThisTurn
                    )
                }
                continuation.yield(.error(
                    "model repeated identical tool calls; ending turn"
                ))
                Self.writeTurnToMemory(
                    memory: memory, userText: userText, calls: calls
                )
                return
            }
            // End the turn the moment `say` fires. The preamble +
            // tool pattern was tried (with a `nonSayCalls.isEmpty`
            // carve-out that let `say` + a data tool batch loop back
            // for an answer round) and it caused two problems:
            //  1. Doubled the user's wait by playing filler audio
            //     before the real answer.
            //  2. Brain round 2 hung past the 60 s drain timeout
            //     on Gemma 4 26B-A4B, leaving the user with only
            //     the preamble and a "brain timeout" message.
            // The persona prompt now forbids preamble speaking calls
            // (data tools run first, then ONE speaking tool with the
            // full answer). With that guidance + this strict
            // end-on-say, every turn is a single brain round.
            if spokeThisTurn {
                // CRITICAL: previously the post-turn memory write
                // lived ONLY in the no-tools branch above, so every
                // real reply (which always involves `say`) skipped
                // memory recording. Only the brain's explicit
                // `remember(...)` tool was landing data, leaving
                // user statements like "my age is 44" unwritten.
                // Persist the exchange before bailing.
                Self.writeTurnToMemory(
                    memory: memory, userText: userText, calls: calls
                )
                return
            }
            // Loop: feed tool outputs back to the model for another turn.
        }

        // Hit max rounds — surface a soft warning rather than hanging.
        // Still record the exchange so the next session has the
        // user's turn at least.
        if !spokeThisTurn {
            await maybeAutoSay(
                text: Self.cleanupForTTS(latestText),
                registry: registry,
                continuation: continuation,
                spokeThisTurn: &spokeThisTurn
            )
        }
        Self.writeTurnToMemory(memory: memory, userText: userText, calls: [])
        continuation.yield(.error("hit max tool rounds (\(config.maxToolRounds))"))
    }

    /// Auto-dispatch text content to `say` when the model emitted
    /// natural-language prose but forgot to wrap it in the speech
    /// tool. Small LLMs (Gemma 4 in particular) routinely do this
    /// after a data-tool round, leaving Rocky silent while the chat
    /// shows the answer.
    ///
    /// Only fires when the text contains real letters — strip
    /// passes occasionally leave punctuation residue and saying
    /// "..." aloud is worse than saying nothing.
    private func maybeAutoSay(
        text: String,
        registry: ToolRegistry,
        continuation: AsyncThrowingStream<Output, Error>.Continuation,
        spokeThisTurn: inout Bool
    ) async {
        // DEFENSE: never speak text that still looks like a tool call.
        // The brain occasionally emits `say({"text": "..."})` or
        // `express({"name": "curious", ...})` as plain content
        // instead of as a real tool call; the bare-call recovery
        // upstream should have caught those and dispatched them as
        // real calls, but if recovery fails (malformed JSON, etc.)
        // we MUST NOT pass the raw syntax to the say tool — TTS
        // will literally pronounce the JSON aloud, which is what
        // the user saw on screen as the chat bubble.
        let toolNames = await registry.names
        var sanitized = Self.stripBareCallBlocks(
            from: text, knownTools: toolNames
        )
        sanitized = Self.stripTagStyleBlocks(
            from: sanitized, knownTools: toolNames
        )
        sanitized = Self.stripThoughtMarkers(sanitized)
        sanitized = Self.stripNonLatinNoise(sanitized)
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)

        // If stripping bare-call patterns removed too much of the
        // text, the WHOLE message was tool-call syntax. Refuse to
        // speak anything rather than speak a fragment ripped from
        // an args dict.
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.looksLikeToolCall(original, knownTools: toolNames) {
            await logBus.publish(.sidecarLog(
                sidecar: "cognition",
                level: .warn,
                message: "auto-say refused: text looks like tool-call syntax",
                fields: ["preview": String(original.prefix(80))]
            ))
            return
        }

        guard !sanitized.isEmpty,
              sanitized.contains(where: \.isLetter)
        else { return }
        struct SayArgs: Encodable { let text: String }
        let args = (try? JSONEncoder().encode(SayArgs(text: sanitized)))
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
        spokeThisTurn = true
    }

    /// Append the user's turn + Rocky's spoken text (extracted from
    /// the round's `say` tool calls, if any) to the memory palace.
    /// Fire-and-forget; failures surface on the LogBus, never block
    /// the user-facing reply path. Used by every turn-exit branch
    /// in `runStream` so post-turn writes always happen regardless
    /// of which path the brain took to end the turn.
    private static func writeTurnToMemory(
        memory: MemoryService?,
        userText: String,
        calls: [ToolCall]
    ) {
        guard let memory else { return }
        memory.recordDetached(role: .user, text: userText)
        for call in calls where call.function.name == "say" {
            guard let data = call.function.arguments.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let said = parsed["text"] as? String,
                  !said.trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }
            memory.recordDetached(role: .assistant, text: said)
        }
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
        // Strip the `[role @ timestamp] ` prefix mempalace adds when
        // storing drawers — the brain doesn't need it for the
        // auto-recall envelope (the timestamps are confusing noise
        // and small models occasionally read them aloud). The
        // explicit `recall_memory` tool still returns the raw form
        // for the brain's targeted searches.
        let formatted = hits
            .prefix(topK)
            .map { hit -> String in
                let text = hit.text.replacingOccurrences(of: "\n", with: " ")
                let stripped = text.replacingOccurrences(
                    of: #"^\[(?:user|assistant|system|tool) @ [^\]]+\]\s*"#,
                    with: "",
                    options: .regularExpression
                )
                return "- " + stripped
            }
            .joined(separator: "\n")
        let body = """
        Rocky's memory of this user. These are real, persisted \
        facts from prior conversations — Rocky already knows them. \
        Treat this list as ground truth.

        Rules:
          1. If the user asks a recall question ("how old am I", \
        "what's my name", "when is my birthday", "what do you \
        remember about me", "do you know X"), the answer is in \
        this list — find it and state it. Do NOT say "Rocky not \
        know" or fall back to the camera frame to guess; the \
        memory is more reliable than vision for facts the user \
        previously stated.
          2. Phrase the answer naturally in Rocky's voice. Don't \
        read raw timestamps or role tags ("[user @ ...]", \
        "[system @ ...]") aloud.
          3. If a memory contradicts what the user just said, \
        prefer the new statement and treat the older memory as \
        out of date.
          4. For deeper or more targeted searches, call the \
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
        guard let envelope, let body = envelope.content, !body.isEmpty else {
            return transcript
        }
        // Merge the recall envelope INTO the existing system message
        // rather than inserting a second one. Qwen3.5's chat template
        // (and a couple of other strict-template models) rejects
        // transcripts with more than one system message — the error
        // surfaces as `prompt template failed: System message must
        // ...`. Concatenating keeps the transcript shape templated
        // models accept while still giving the LLM the recalled
        // context. Models that DO tolerate multiple system messages
        // (Gemma, Llama) are unaffected — they just see a slightly
        // longer system prompt.
        var msgs = transcript
        if let firstRole = msgs.first?.role, firstRole == .system {
            let existing = msgs[0].content ?? ""
            let joined = existing.isEmpty
                ? body
                : "\(existing)\n\n\(body)"
            msgs[0] = .init(role: .system, content: joined)
        } else {
            // No system prompt up front (unusual) — fall back to
            // prepending the envelope as the new system message.
            msgs.insert(.init(role: .system, content: body), at: 0)
        }
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

    /// Scan plain text for tag-style tool invocations like
    ///     <say>{"text": "Hello."}</say>
    ///     <say>{text: Bye bye. Come back soon, question?}</say>
    ///     <express>{name: curious, text: "Apple legend."}</express>
    ///     <say>Hello.</say>
    ///
    /// Some Gemma 4 variants emit this shape instead of native
    /// `tool_calls` or bare `name({...})`. Inner content is parsed
    /// best-effort: real JSON first, then a relaxed grab of common
    /// key/value pairs (`text:`, `name:`) when the model emitted
    /// pseudo-JSON with unquoted keys.
    public static func extractTagStyleToolCalls(
        in text: String, knownTools: [String]
    ) -> [(name: String, argumentsJSON: String)] {
        guard !text.isEmpty else { return [] }
        let allowed = Set(knownTools)
        var found: [(String, String)] = []
        for tool in knownTools.sorted(by: { $0.count > $1.count }) {
            guard allowed.contains(tool) else { continue }
            let open = "<\(tool)>"
            let close = "</\(tool)>"
            var searchRange = text.startIndex..<text.endIndex
            while let openRange = text.range(of: open, range: searchRange),
                  let closeRange = text.range(
                    of: close,
                    range: openRange.upperBound..<text.endIndex
                  )
            {
                let inner = String(
                    text[openRange.upperBound..<closeRange.lowerBound]
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                let argsJSON = normaliseTagInner(inner)
                found.append((tool, argsJSON))
                searchRange = closeRange.upperBound..<text.endIndex
            }
        }
        return found
    }

    /// Take the raw inner string of a `<toolName>...</toolName>` tag
    /// and produce a valid JSON object string suitable for the tool
    /// registry. Tries:
    ///   1. Parse as JSON object directly.
    ///   2. Relaxed pseudo-JSON: capture `key: value` pairs
    ///      (unquoted keys, freeform values up to comma / closing brace).
    ///   3. Fallback — wrap the whole inner as `{"text": "<inner>"}`
    ///      since `say` and `express` both take a `text` field.
    private static func normaliseTagInner(_ raw: String) -> String {
        // 1. Direct JSON.
        if raw.hasPrefix("{"),
           let data = raw.data(using: .utf8),
           let _ = try? JSONSerialization.jsonObject(with: data)
        {
            return raw
        }
        // 2. Pseudo-JSON: `{text: Bye bye. Hello, question?}`
        if raw.hasPrefix("{"), raw.hasSuffix("}") {
            let body = String(raw.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = relaxedKeyValueParse(body) {
                return parsed
            }
        }
        // 3. Bare inner — treat as the `text` payload.
        let encoded = jsonEscape(raw)
        return "{\"text\": \"\(encoded)\"}"
    }

    /// Parse a comma-and-colon-separated string of `key: value`
    /// pairs into a JSON object. Permissive on quoting: keys may
    /// be unquoted bare identifiers (`text`, `name`); values are
    /// taken as the text up to the next top-level comma, then
    /// JSON-escaped.
    private static func relaxedKeyValueParse(_ body: String) -> String? {
        // Split on top-level commas (ignore commas inside `[]` / `{}`
        // / quoted strings).
        var depth = 0
        var inString = false
        var escape = false
        var parts: [String] = []
        var current = ""
        for c in body {
            if escape { escape = false; current.append(c); continue }
            if inString {
                if c == "\\" { escape = true }
                if c == "\"" { inString = false }
                current.append(c)
                continue
            }
            switch c {
            case "\"":
                inString = true; current.append(c)
            case "{", "[":
                depth += 1; current.append(c)
            case "}", "]":
                depth -= 1; current.append(c)
            case ",":
                if depth == 0 {
                    parts.append(current); current = ""
                } else {
                    current.append(c)
                }
            default:
                current.append(c)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(current)
        }
        var dict: [String: String] = [:]
        for part in parts {
            // Split on FIRST colon.
            guard let colon = part.firstIndex(of: ":") else { continue }
            let key = part[..<colon]
                .trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: "\"")))
            let value = part[part.index(after: colon)...]
                .trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: "\"")))
            guard !key.isEmpty else { continue }
            dict[String(key)] = String(value)
        }
        guard !dict.isEmpty else { return nil }
        // Re-emit as proper JSON, JSON-escaping each value.
        var out = "{"
        for (i, kv) in dict.enumerated() {
            if i > 0 { out += ", " }
            out += "\"\(jsonEscape(kv.key))\": \"\(jsonEscape(kv.value))\""
        }
        out += "}"
        return out
    }

    private static func jsonEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:   out.append(c)
            }
        }
        return out
    }

    /// Remove `<toolName>...</toolName>` tag spans from `text` — used
    /// alongside `stripBareCallBlocks` to scrub the chat bubble and
    /// TTS input after the calls have been routed.
    public static func stripTagStyleBlocks(
        from text: String, knownTools: [String]
    ) -> String {
        var result = text
        for tool in knownTools.sorted(by: { $0.count > $1.count }) {
            let open = "<\(tool)>"
            let close = "</\(tool)>"
            while let openRange = result.range(of: open) {
                if let closeRange = result.range(
                    of: close,
                    range: openRange.upperBound..<result.endIndex
                ) {
                    result.replaceSubrange(
                        openRange.lowerBound..<closeRange.upperBound, with: ""
                    )
                } else {
                    // Unmatched opener — drop everything from open
                    // to end-of-text (truncated stream).
                    result.replaceSubrange(
                        openRange.lowerBound..<result.endIndex, with: ""
                    )
                    break
                }
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drop the runs of non-Latin script characters Gemma 4 sometimes
    /// emits as preamble (Chinese, Cyrillic, Arabic, etc.) — these
    /// aren't English content, they're model glitches that the user
    /// definitely doesn't want spoken or displayed. We keep
    /// punctuation, digits, and the Latin alphabet; everything else
    /// in the Unicode scalar ranges of common non-Latin scripts is
    /// stripped.
    ///
    /// Pragmatic threshold: only strips clearly-non-Latin runs of
    /// length ≥ 1. We don't try to detect "this whole sentence is
    /// Spanish" because legitimate user speech might include
    /// non-Latin names; the goal is to scrub random glitches like
    /// "驱动 <say>...".
    public static func stripNonLatinNoise(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            // CJK Unified Ideographs, Hangul, Hiragana, Katakana,
            // Cyrillic, Arabic — common Gemma glitch scripts.
            let v = scalar.value
            let isCJK     = (0x4E00...0x9FFF).contains(v)
                         || (0x3400...0x4DBF).contains(v)
                         || (0x20000...0x2A6DF).contains(v)
            let isHangul  = (0xAC00...0xD7AF).contains(v)
                         || (0x1100...0x11FF).contains(v)
            let isKana    = (0x3040...0x30FF).contains(v)
            let isCyrillic = (0x0400...0x04FF).contains(v)
            let isArabic  = (0x0600...0x06FF).contains(v)
            if isCJK || isHangul || isKana || isCyrillic || isArabic {
                continue
            }
            out.append(scalar)
        }
        return String(out)
            // Collapse any whitespace that remained after stripping.
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Scan plain text for bare-call tool invocations like
    ///     say({"text": "Hello."})
    ///     express({"name": "curious", "text": "..."})
    /// emitted by the model into the assistant content stream
    /// instead of as real tool_calls. Returns matched name+args
    /// pairs in document order.
    ///
    /// Why this exists: smaller LLMs (Gemma 4 in particular) routinely
    /// emit tool-call syntax as plain text. Without recovery, the
    /// auto-say at the end of the no-tool branch would pass that
    /// raw `say({...})` string to the say tool, and TTS would
    /// pronounce the JSON aloud — heard on-device as "say open
    /// brace text colon quote rocky..." This guard catches that
    /// shape and routes it as a real call.
    ///
    /// Parser strategy: scan for each known tool name as a prefix,
    /// then walk forward through whitespace looking for `(`, then
    /// extract balanced `{...}` JSON via `(` / `)` depth tracking.
    /// Only accept matches whose extracted JSON parses successfully.
    public static func extractBareCallToolCalls(
        in text: String,
        knownTools: [String]
    ) -> [(name: String, argumentsJSON: String)] {
        guard !text.isEmpty else { return [] }
        let allowed = Set(knownTools)
        // Match longer names first so "look_at_object" wins over "look".
        let byLength = knownTools.sorted { $0.count > $1.count }
        let chars = Array(text)
        var found: [(name: String, argumentsJSON: String)] = []
        var i = 0
        while i < chars.count {
            var matched: (name: String, nextIndex: Int, args: String)? = nil
            for name in byLength {
                let nameChars = Array(name)
                guard i + nameChars.count <= chars.count else { continue }
                // Compare prefix.
                var ok = true
                for k in 0..<nameChars.count {
                    if chars[i + k] != nameChars[k] { ok = false; break }
                }
                guard ok else { continue }
                // Word boundary at left edge — don't match `display(`
                // as `play(`. Allow start-of-string or non-word char.
                if i > 0 {
                    let prev = chars[i - 1]
                    let isWord = prev.isLetter || prev.isNumber || prev == "_"
                    if isWord { continue }
                }
                // Walk forward through whitespace to find `(`.
                var j = i + nameChars.count
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                guard j < chars.count, chars[j] == "(" else { continue }
                // Find balanced closing `)` while tracking braces+parens
                // and skipping string contents (so a `)` inside a JSON
                // string doesn't terminate the call early).
                var depth = 1
                var k = j + 1
                var inString = false
                var escape = false
                while k < chars.count {
                    let c = chars[k]
                    if escape {
                        escape = false
                    } else if inString {
                        if c == "\\" { escape = true }
                        else if c == "\"" { inString = false }
                    } else {
                        if c == "\"" { inString = true }
                        else if c == "(" { depth += 1 }
                        else if c == ")" {
                            depth -= 1
                            if depth == 0 { break }
                        }
                    }
                    k += 1
                }
                guard k < chars.count, depth == 0 else { continue }
                // Args span: text between `(` and `)`, trimmed.
                let argsRaw = String(chars[(j + 1)..<k])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // The args must be a valid JSON object. Reject calls
                // whose interior won't parse — keeps us from
                // misclassifying random prose like "say (well)".
                guard let data = argsRaw.data(using: .utf8),
                      let _ = try? JSONSerialization.jsonObject(with: data)
                            as? [String: Any]
                else { continue }
                matched = (name: name, nextIndex: k + 1, args: argsRaw)
                break
            }
            if let m = matched, allowed.contains(m.name) {
                found.append((m.name, m.args))
                i = m.nextIndex
            } else {
                i += 1
            }
        }
        return found
    }

    /// Remove bare-call patterns from `text`. Used to scrub the
    /// transcript and TTS input after the calls have been routed
    /// through the registry, so the raw syntax doesn't leak into
    /// the chat bubble or speech.
    public static func stripBareCallBlocks(
        from text: String,
        knownTools: [String]
    ) -> String {
        guard !text.isEmpty else { return text }
        let byLength = knownTools.sorted { $0.count > $1.count }
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            var stripTo: Int? = nil
            for name in byLength {
                let nameChars = Array(name)
                guard i + nameChars.count <= chars.count else { continue }
                var ok = true
                for k in 0..<nameChars.count {
                    if chars[i + k] != nameChars[k] { ok = false; break }
                }
                guard ok else { continue }
                if i > 0 {
                    let prev = chars[i - 1]
                    let isWord = prev.isLetter || prev.isNumber || prev == "_"
                    if isWord { continue }
                }
                var j = i + nameChars.count
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                guard j < chars.count, chars[j] == "(" else { continue }
                var depth = 1
                var k = j + 1
                var inString = false
                var escape = false
                while k < chars.count {
                    let c = chars[k]
                    if escape { escape = false }
                    else if inString {
                        if c == "\\" { escape = true }
                        else if c == "\"" { inString = false }
                    } else {
                        if c == "\"" { inString = true }
                        else if c == "(" { depth += 1 }
                        else if c == ")" {
                            depth -= 1
                            if depth == 0 { break }
                        }
                    }
                    k += 1
                }
                guard k < chars.count, depth == 0 else { continue }
                // Accept the strip even if the inside doesn't parse —
                // we'd rather scrub a malformed `say({...})` than
                // pronounce it.
                stripTo = k + 1
                break
            }
            if let next = stripTo {
                i = next
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns true when `text` is mostly composed of tool-call
    /// syntax in any shape — bare `name({...})`, tag `<name>...
    /// </name>`, or thought-channel markers. Stripping all
    /// recognised shapes leaves <30 % of the original (whitespace
    /// excluded). Used by `maybeAutoSay` to refuse speaking text
    /// the model emitted as syntax-only.
    public static func looksLikeToolCall(
        _ text: String,
        knownTools: [String]
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var stripped = stripBareCallBlocks(from: trimmed, knownTools: knownTools)
        stripped = stripTagStyleBlocks(from: stripped, knownTools: knownTools)
        stripped = stripThoughtMarkers(stripped)
        if stripped.isEmpty { return true }
        let ratio = Double(stripped.count) / Double(max(1, trimmed.count))
        return ratio < 0.30
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
    /// Strip Harmony / Gemma 4 thought-channel markers from text so
    /// they don't show up in the chat bubble or get pronounced by
    /// TTS. Examples seen in production:
    ///
    ///   <thought>call:say({"text": "..."})</call>
    ///   <thought>call:</call><|channel|>thought<channel|>
    ///   <|channel|>thought<channel|>some prose</channel|>
    ///
    /// Strategy: remove fully-enclosed `<thought>...</thought>` and
    /// `<call>...</call>` blocks (their interiors are model-internal
    /// reasoning, not user-facing output — and the bare-call
    /// recovery already extracted any embedded tool calls), then
    /// drop the orphan channel-marker tokens that the closing
    /// tag-pair strip leaves behind.
    public static func stripThoughtMarkers(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        // Enclosed blocks — remove the entire span.
        result = removeBlockSpan(in: result, open: "<thought>", close: "</thought>")
        result = removeBlockSpan(in: result, open: "<call>", close: "</call>")
        result = removeBlockSpan(in: result, open: "<|channel|>", close: "<|/channel|>")
        // Orphan markers — any of these remaining as bare tokens
        // means a tag-pair lost its mate (truncated stream, etc.).
        // Strip the literal token; whatever prose surrounded it
        // survives.
        let orphans = [
            "<thought>", "</thought>", "<thought",
            "<call>", "</call>", "<call",
            "<|channel|>", "<|/channel|>",
            "<channel|>", "</channel|>", "<channel",
            "<|tool_call|>", "<|/tool_call|>",
            "<|start|>", "<|end|>",
        ]
        for token in orphans {
            result = result.replacingOccurrences(of: token, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove every `[open...close]` span from `text`. Greedy
    /// left-to-right; nested spans are not supported (the inner
    /// pair's close terminates the outer too, which is fine for
    /// thought markers since they don't nest in observed traces).
    private static func removeBlockSpan(
        in text: String, open: String, close: String
    ) -> String {
        var result = text
        while let openRange = result.range(of: open) {
            // Find the matching close after the open. If missing,
            // drop everything from `open` to end-of-text — partial
            // truncation, no useful content past it.
            let searchStart = openRange.upperBound
            if let closeRange = result.range(of: close, range: searchStart..<result.endIndex) {
                result.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: "")
            } else {
                result.replaceSubrange(openRange.lowerBound..<result.endIndex, with: "")
                break
            }
        }
        return result
    }

    /// Returns true when the tail of `text` is locked in a repeating
    /// pattern — used to short-circuit the brain's chunk-receive
    /// loop before the full `max_tokens` budget burns away on a
    /// stuck stream (Gemma 4 in Harmony thought-channel mode
    /// produces this failure mode reliably).
    ///
    /// Algorithm: try a few candidate slice lengths and check
    /// whether the last `len * count` chars are `count` exact
    /// copies of the trailing `len` chars. A 24-char slice
    /// repeating 5 times in a row (= 120 chars of monoculture
    /// at the tail) is a clear trap.
    public static func detectRepetitionTrap(in text: String) -> Bool {
        let chars = Array(text)
        guard chars.count >= 120 else { return false }
        // Candidate slice sizes. Most observed traps are 20-40 chars
        // ("<thought>call:</call><|channel|>...") so the sweep covers
        // that range plus shorter token loops.
        let sliceSizes = [12, 16, 20, 24, 32, 40]
        let repeats = 4
        for size in sliceSizes {
            let window = size * repeats
            guard chars.count >= window else { continue }
            let tail = chars.suffix(window)
            let pieces = stride(from: 0, to: window, by: size).map { offset -> [Character] in
                Array(tail.dropFirst(offset).prefix(size))
            }
            // All pieces equal? → trap.
            if pieces.count == repeats,
               pieces.dropFirst().allSatisfy({ $0 == pieces[0] }) {
                return true
            }
        }
        return false
    }

    /// When `detectRepetitionTrap` fires, the assistantText is the
    /// useful prefix + a junk tail. Trim the tail by re-running
    /// the detector backwards: walk the trailing region in chunks
    /// and drop anything that's still repetitive.
    public static func scrubRepetitionTail(from text: String) -> String {
        let chars = Array(text)
        guard chars.count >= 120 else { return text }
        // Binary-search-ish trim: lop progressively larger
        // suffixes until the residual no longer looks repetitive.
        var end = chars.count
        while end > 80 {
            let candidate = String(chars[0..<end])
            if !detectRepetitionTrap(in: candidate) { break }
            end -= 40
        }
        return String(chars[0..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
