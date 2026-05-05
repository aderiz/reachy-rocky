import Foundation
import Telemetry

/// Maps tool-call names emitted by the LLM to handlers. Each handler accepts
/// a parsed JSON arguments object and returns a JSON result the assistant
/// will see as a `tool` message.
public actor ToolRegistry {
    public typealias Handler = @Sendable (JSONValue) async throws -> JSONValue

    public struct Tool: Sendable {
        public let schema: ToolSchema
        public let handler: Handler
    }

    private var tools: [String: Tool] = [:]
    private let logBus: LogBus

    public init(logBus: LogBus) {
        self.logBus = logBus
    }

    public func register(_ tool: Tool) {
        tools[tool.schema.function.name] = tool
    }

    public func register(
        name: String,
        description: String,
        parameters: JSONValue = .object(["type": .string("object"), "properties": .object([:])]),
        handler: @escaping Handler
    ) {
        register(Tool(
            schema: ToolSchema(
                type: "function",
                function: .init(name: name, description: description, parameters: parameters)
            ),
            handler: handler
        ))
    }

    public var schemas: [ToolSchema] {
        tools.values.map(\.schema)
    }

    public var names: [String] {
        Array(tools.keys).sorted()
    }

    public func invoke(name: String, argumentsJSON: String, llmMessageId: String) async -> ToolResult {
        let started = Date()
        let argsValue: JSONValue
        do {
            argsValue = argumentsJSON.isEmpty
                ? .object([:])
                : try JSONValue(jsonString: argumentsJSON)
        } catch {
            await logBus.publish(.error(scope: "tool", message: "args decode: \(error)", recoverable: true))
            return ToolResult(
                name: name,
                argumentsJSON: argumentsJSON,
                resultJSON: "{\"error\":\"could not parse arguments\"}",
                latencyMs: 0,
                ok: false,
                llmMessageId: llmMessageId
            )
        }

        guard let tool = tools[name] else {
            return ToolResult(
                name: name, argumentsJSON: argumentsJSON,
                resultJSON: "{\"error\":\"unknown tool: \(name)\"}",
                latencyMs: 0, ok: false, llmMessageId: llmMessageId
            )
        }

        do {
            let result = try await tool.handler(argsValue)
            let ms = Date().timeIntervalSince(started) * 1000
            let resultJSON = result.encodedString()
            await logBus.publish(.toolInvocation(
                name: name, args: argumentsJSON, result: resultJSON,
                latencyMs: ms, llmMessageId: llmMessageId
            ))
            return ToolResult(
                name: name, argumentsJSON: argumentsJSON,
                resultJSON: resultJSON, latencyMs: ms, ok: true,
                llmMessageId: llmMessageId
            )
        } catch {
            let ms = Date().timeIntervalSince(started) * 1000
            let resultJSON = "{\"error\":\"\(error)\"}"
            await logBus.publish(.toolInvocation(
                name: name, args: argumentsJSON, result: resultJSON,
                latencyMs: ms, llmMessageId: llmMessageId
            ))
            return ToolResult(
                name: name, argumentsJSON: argumentsJSON,
                resultJSON: resultJSON, latencyMs: ms, ok: false,
                llmMessageId: llmMessageId
            )
        }
    }
}

public struct ToolResult: Sendable, Equatable {
    public let name: String
    public let argumentsJSON: String
    public let resultJSON: String
    public let latencyMs: Double
    public let ok: Bool
    public let llmMessageId: String
}
