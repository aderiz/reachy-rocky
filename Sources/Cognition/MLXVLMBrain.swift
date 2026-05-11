import Foundation
import SidecarHost
import Telemetry

/// `BrainBackend` adapter for the v0.2 native-MLX brain sidecar.
///
/// The Python sidecar (`Sidecars/brain/`) loads `mlx-community/Qwen3-
/// VL-4B-Instruct-4bit` and exposes:
///
///   - `chat_stream(messages, tools, image_b64?)` — streams `delta`
///     events containing token text, then `tool_call` events with
///     `{id, name, arguments}` objects, then `stream_end`, then a
///     final `result` envelope with the full text + tool_calls.
///
/// This adapter translates that wire shape into the `ChatChunk`
/// stream the `CognitionEngine` already consumes, so the engine
/// doesn't need to know which backend is talking to it.
public actor MLXVLMBrain: BrainBackend {
    private let sidecar: any Sidecar
    private let logBus: LogBus

    public init(sidecar: any Sidecar, logBus: LogBus) {
        self.sidecar = sidecar
        self.logBus = logBus
    }

    public nonisolated func chatStream(
        messages: [ChatMessage],
        tools: [ToolSchema]?,
        image: BrainImage?
    ) -> AsyncThrowingStream<ChatChunk, Error> {
        let bus = self.logBus
        return AsyncThrowingStream<ChatChunk, Error> { continuation in
            let task = Task {
                do {
                    let request = ChatStreamRequest(
                        messages: messages.map(WireMessage.init),
                        tools: tools,
                        image_b64: image.map { $0.jpegData.base64EncodedString() }
                    )
                    await bus.publish(.sidecarLog(
                        sidecar: "brain", level: .debug,
                        message: "chat_stream begin",
                        fields: [
                            "messages": "\(messages.count)",
                            "tools": "\(tools?.count ?? 0)",
                            "image": image == nil ? "none" : "\(image!.jpegData.count)B"
                        ]
                    ))
                    let stream = sidecar.stream(
                        method: "chat_stream",
                        params: request
                    )
                    var nextToolCallIndex = 0
                    var chunkCount = 0
                    var toolCallCount = 0
                    var unknownCount = 0
                    for try await line in stream {
                        chunkCount += 1
                        // Each `line` is the JSON object inside a
                        // `stream` envelope (SidecarRuntime extracts
                        // it). Decode whichever variant arrived.
                        if let delta = try? JSONDecoder().decode(
                            DeltaPayload.self, from: line
                        ), let text = delta.delta {
                            continuation.yield(ChatChunk(
                                contentDelta: text
                            ))
                            continue
                        }
                        if let payload = try? JSONDecoder().decode(
                            ToolCallPayload.self, from: line
                        ), let call = payload.tool_call {
                            toolCallCount += 1
                            let chunk = ChatChunk(
                                toolCallDeltas: [
                                    ToolCallDelta(
                                        index: nextToolCallIndex,
                                        id: call.id,
                                        name: call.name,
                                        argumentsDelta: call.arguments
                                    )
                                ]
                            )
                            nextToolCallIndex += 1
                            continuation.yield(chunk)
                            continue
                        }
                        // Unknown envelope — log a sample so we can
                        // see what we missed.
                        unknownCount += 1
                        if unknownCount <= 3 {
                            let preview = String(data: line.prefix(160), encoding: .utf8) ?? "<binary>"
                            await bus.publish(.sidecarLog(
                                sidecar: "brain", level: .warn,
                                message: "chat_stream: unknown envelope",
                                fields: ["sample": preview]
                            ))
                        }
                    }
                    await bus.publish(.sidecarLog(
                        sidecar: "brain", level: .debug,
                        message: "chat_stream end",
                        fields: [
                            "chunks": "\(chunkCount)",
                            "tool_calls": "\(toolCallCount)",
                            "unknown": "\(unknownCount)"
                        ]
                    ))
                    continuation.finish()
                } catch {
                    await bus.publish(.error(
                        scope: "brain/chat_stream",
                        message: "\(error)",
                        recoverable: true
                    ))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Wire types

/// The brain sidecar accepts an OpenAI-shape messages array. We map
/// `Cognition.ChatMessage` into a wire-friendly struct here so the
/// public `ChatMessage` API doesn't have to be `Encodable`-shaped
/// for sidecar transport.
private struct WireMessage: Encodable, Sendable {
    let role: String
    let content: String
    let name: String?
    let tool_call_id: String?

    init(_ message: ChatMessage) {
        self.role = message.role.rawValue
        self.content = message.content ?? ""
        self.name = message.name
        self.tool_call_id = message.toolCallId
    }
}

private struct ChatStreamRequest: Encodable, Sendable {
    let messages: [WireMessage]
    let tools: [ToolSchema]?
    let image_b64: String?
}

private struct DeltaPayload: Decodable, Sendable {
    let delta: String?
}

private struct ToolCallWire: Decodable, Sendable {
    let id: String
    let name: String
    let arguments: String
}

private struct ToolCallPayload: Decodable, Sendable {
    let tool_call: ToolCallWire?
}
