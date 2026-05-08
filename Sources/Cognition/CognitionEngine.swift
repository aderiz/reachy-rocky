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

    public let llm: LMStudioClient
    public let registry: ToolRegistry
    public let memory: MemoryService?
    private let logBus: LogBus
    public private(set) var config: Config
    private var transcript: [ChatMessage]

    public init(
        llm: LMStudioClient,
        registry: ToolRegistry,
        memory: MemoryService? = nil,
        logBus: LogBus,
        config: Config = Config()
    ) {
        self.llm = llm
        self.registry = registry
        self.memory = memory
        self.logBus = logBus
        self.config = config
        self.transcript = [.init(role: .system, content: config.systemPrompt)]
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
            let stream = llm.chatStream(messages: messagesForLLM, tools: tools.isEmpty ? nil : tools)

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
                    let totalMs = Date().timeIntervalSince(started) * 1000
                    continuation.yield(.assistantFinal(
                        assistantText, latencyMs: totalMs, firstChunkMs: firstChunkMs
                    ))
                    if !assistantText.isEmpty {
                        transcript.append(.init(role: .assistant, content: assistantText))
                    }
                    // Post-turn write: append both sides of this exchange
                    // to the palace as verbatim drawers. Fire-and-forget
                    // so the user-facing latency is unaffected.
                    if let memory {
                        memory.recordDetached(role: .user, text: userText)
                        if !assistantText.isEmpty {
                            memory.recordDetached(role: .assistant,
                                                   text: assistantText)
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
            }
            for sig in signatures { dispatchedSignatures.insert(sig) }

            if allRepeats {
                continuation.yield(.error(
                    "model repeated identical tool calls; ending turn"
                ))
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
    private static let recallTimeoutS: Double = 1.5

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
        guard let hits, !hits.isEmpty else { return nil }
        let formatted = hits
            .prefix(topK)
            .map { "- " + $0.text.replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: "\n")
        let body = """
        Relevant snippets recalled from prior conversations with the user. \
        Use them as background context only — do NOT quote them verbatim, \
        do NOT mention that you 'remember', do NOT cite them. Just let the \
        knowledge inform your reply naturally.

        \(formatted)
        """
        Task { await logBus.publish(.error(
            scope: "memory.recall",
            message: "injected \(hits.count) hit(s)",
            recoverable: true
        )) }
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

    /// Removes any fenced JSON block from the assistant text. We don't want
    /// the raw JSON cluttering the displayed transcript when we've already
    /// dispatched it as a tool call.
    public static func stripFencedJSONBlocks(from text: String) -> String {
        var out = text
        // Match ```json ... ``` and ``` ... ``` (optional language tag).
        let pattern = "```(?:[a-zA-Z0-9_-]*)\\s*[\\s\\S]*?```"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: "")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pulls the body of every fenced code block from `text`.
    private static func fencedJSONBodies(in text: String) -> [String] {
        var bodies: [String] = []
        let pattern = "```(?:json|JSON)?\\s*([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return bodies }
        let nsRange = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: nsRange) {
            if match.numberOfRanges >= 2,
               let r = Range(match.range(at: 1), in: text) {
                bodies.append(String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        // Also accept a bare top-level JSON object if the entire reply is one.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") && bodies.isEmpty {
            bodies.append(trimmed)
        }
        return bodies
    }
}
