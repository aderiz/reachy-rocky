import Foundation
import Telemetry

/// OpenAI-compatible streaming chat client targeting LM Studio.
///
/// LM Studio defaults to `http://localhost:1234/v1`, no auth. The same
/// surface works against any OpenAI-compatible endpoint.
public struct LMStudioConfig: Sendable, Equatable {
    public var baseURL: URL
    public var model: String
    public var apiKey: String?

    public init(
        baseURL: URL = URL(string: "http://localhost:1234/v1")!,
        model: String = "qwen2.5-7b-instruct",
        apiKey: String? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }
}

public actor LMStudioClient {
    private let session: URLSession
    private let logBus: LogBus
    public private(set) var config: LMStudioConfig

    public init(
        config: LMStudioConfig = LMStudioConfig(),
        session: URLSession = .shared,
        logBus: LogBus
    ) {
        self.config = config
        self.session = session
        self.logBus = logBus
    }

    public func setConfig(_ config: LMStudioConfig) {
        self.config = config
    }

    /// `GET /v1/models`. Lightweight reachability + identity probe.
    public func listModels() async throws -> [String] {
        let url = config.baseURL.appendingPathComponent("models")
        var req = URLRequest(url: url)
        addAuth(&req)
        let (data, response) = try await session.data(for: req)
        try ensureOK(response, body: data)

        struct ModelsResponse: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        let r = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return r.data.map(\.id)
    }

    /// Streamed chat completion. Yields `ChatChunk`s as they arrive.
    /// Cancel the consumer task to abort the stream.
    public nonisolated func chatStream(
        messages: [ChatMessage],
        tools: [ToolSchema]? = nil
    ) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runStream(
                        messages: messages,
                        tools: tools,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internals

    private func runStream(
        messages: [ChatMessage],
        tools: [ToolSchema]?,
        continuation: AsyncThrowingStream<ChatChunk, Error>.Continuation
    ) async throws {
        let url = config.baseURL.appendingPathComponent("chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        addAuth(&req)

        struct Body: Encodable {
            let model: String
            let messages: [ChatMessage]
            let stream: Bool
            let tools: [ToolSchema]?
        }
        let body = Body(model: config.model, messages: messages, stream: true, tools: tools)
        req.httpBody = try JSONEncoder().encode(body)

        await logBus.publish(.llmRequest(messageCount: messages.count, toolCount: tools?.count ?? 0))

        let started = Date()
        let (bytes, response) = try await session.bytes(for: req)
        try ensureOK(response, body: Data())

        var parser = SSEParser()
        var carry = Data()
        var partialToolArgs: [Int: String] = [:]
        var partialToolNames: [Int: String] = [:]

        for try await byte in bytes {
            carry.append(byte)
            // Flush every ~64 bytes to amortize parser overhead.
            if carry.count >= 64 {
                let flush = carry
                carry.removeAll(keepingCapacity: true)
                let payloads = parser.consume(flush)
                for p in payloads {
                    if let chunk = try await parsePayload(
                        p, started: started,
                        partialToolArgs: &partialToolArgs,
                        partialToolNames: &partialToolNames
                    ) {
                        continuation.yield(chunk)
                    } else {
                        continuation.finish()
                        return
                    }
                }
            }
        }
        // Final flush.
        if !carry.isEmpty {
            for p in parser.consume(carry) {
                if let chunk = try await parsePayload(
                    p, started: started,
                    partialToolArgs: &partialToolArgs,
                    partialToolNames: &partialToolNames
                ) {
                    continuation.yield(chunk)
                } else { return }
            }
        }
    }

    private func parsePayload(
        _ payload: String,
        started: Date,
        partialToolArgs: inout [Int: String],
        partialToolNames: inout [Int: String]
    ) async throws -> ChatChunk? {
        if payload == "[DONE]" {
            return nil  // signals end
        }
        guard let data = payload.data(using: .utf8) else {
            return ChatChunk()
        }
        struct Wire: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable {
                    let content: String?
                    let toolCalls: [DeltaToolCall]?
                    enum CodingKeys: String, CodingKey {
                        case content
                        case toolCalls = "tool_calls"
                    }
                }
                struct DeltaToolCall: Decodable {
                    let index: Int
                    let id: String?
                    let function: Function?
                    struct Function: Decodable {
                        let name: String?
                        let arguments: String?
                    }
                }
                let delta: Delta
                let finishReason: String?
                enum CodingKeys: String, CodingKey {
                    case delta
                    case finishReason = "finish_reason"
                }
            }
            let choices: [Choice]
        }
        let w = try JSONDecoder().decode(Wire.self, from: data)
        guard let choice = w.choices.first else { return ChatChunk() }
        let deltaContent = choice.delta.content
        var toolDeltas: [ToolCallDelta] = []
        if let tcs = choice.delta.toolCalls {
            for tc in tcs {
                if let name = tc.function?.name {
                    partialToolNames[tc.index] = name
                }
                if let args = tc.function?.arguments {
                    partialToolArgs[tc.index, default: ""] += args
                }
                toolDeltas.append(ToolCallDelta(
                    index: tc.index,
                    id: tc.id,
                    name: tc.function?.name,
                    argumentsDelta: tc.function?.arguments
                ))
            }
        }
        let elapsedMs = Date().timeIntervalSince(started) * 1000
        await logBus.publish(.llmChunk(
            sinceRequestMs: elapsedMs,
            contentDelta: deltaContent,
            toolCallDelta: toolDeltas.compactMap(\.argumentsDelta).joined()
        ))
        return ChatChunk(
            contentDelta: deltaContent,
            toolCallDeltas: toolDeltas,
            finishReason: choice.finishReason
        )
    }

    private func addAuth(_ req: inout URLRequest) {
        if let key = config.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private func ensureOK(_ response: URLResponse, body: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if !(200..<300).contains(status) {
            let s = String(data: body, encoding: .utf8) ?? "<binary>"
            throw LMStudioError.http(status: status, body: s)
        }
    }
}

public enum LMStudioError: Error, Sendable {
    case http(status: Int, body: String)
    case transport(message: String)
    case decode(message: String)
    case offline
}
