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
        You have a head you can turn, antennas you can wiggle, and a voice. Keep
        replies short and natural; you can move while you talk. Use the
        provided tools to actually move and act — don't pretend.
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
                let totalMs = Date().timeIntervalSince(started) * 1000
                continuation.yield(.assistantFinal(
                    assistantText, latencyMs: totalMs, firstChunkMs: firstChunkMs
                ))
                if !assistantText.isEmpty {
                    transcript.append(.init(role: .assistant, content: assistantText))
                }
                return
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
}
