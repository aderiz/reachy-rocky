import Foundation
import Telemetry

/// High-level orchestrator: takes a user transcript, runs an LLM turn against
/// LM Studio, dispatches any tool calls, and surfaces the final assistant
/// reply as `Output` events. Owns the rolling conversation transcript so the
/// model sees prior turns.
public actor CognitionEngine {
    public struct Config: Sendable {
        public var systemPrompt: String
        public var maxToolRounds: Int

        public init(
            systemPrompt: String = Self.defaultSystemPrompt,
            maxToolRounds: Int = 4
        ) {
            self.systemPrompt = systemPrompt
            self.maxToolRounds = maxToolRounds
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
    private let logBus: LogBus
    public private(set) var config: Config
    private var transcript: [ChatMessage]

    public init(
        llm: LMStudioClient,
        registry: ToolRegistry,
        logBus: LogBus,
        config: Config = Config()
    ) {
        self.llm = llm
        self.registry = registry
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
        var rounds = 0

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
            let stream = llm.chatStream(messages: transcript, tools: tools.isEmpty ? nil : tools)

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
            // Loop: feed tool outputs back to the model for another turn.
        }

        // Hit max rounds — surface a soft warning rather than hanging.
        continuation.yield(.error("hit max tool rounds (\(config.maxToolRounds))"))
    }

    // MARK: - Markdown tool-call recovery

    /// Detects `{"tool": "name", "args": {...}}` (or `{"name": "...", "arguments": {...}}`)
    /// inside fenced code blocks. Used when an LLM that doesn't natively emit
    /// `tool_calls` falls back to JSON-in-markdown.
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
            // Accept both shapes:
            //   {"tool": "name", "args": {...}}
            //   {"name": "name", "arguments": {...}}  (OpenAI native)
            //   {"name": "name", "arguments": "{...}"} (string-encoded args)
            let name = (json["tool"] as? String) ?? (json["name"] as? String)
            guard let name, allowed.contains(name) else { continue }

            let argsJSON: String
            if let argsStr = json["arguments"] as? String {
                argsJSON = argsStr
            } else {
                let argsObj = json["args"] ?? json["arguments"] ?? [String: Any]()
                if let data = try? JSONSerialization.data(withJSONObject: argsObj),
                   let s = String(data: data, encoding: .utf8) {
                    argsJSON = s
                } else {
                    argsJSON = "{}"
                }
            }
            found.append((name, argsJSON))
        }
        return found
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
