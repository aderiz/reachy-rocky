import Foundation

/// OpenAI-compatible chat-completions message. LM Studio mirrors this shape.
public struct ChatMessage: Sendable, Equatable, Hashable, Codable {
    public enum Role: String, Sendable, Codable {
        case system, user, assistant, tool
    }

    public let role: Role
    public let content: String?
    public let name: String?              // for tool messages
    public let toolCallId: String?        // for tool result messages
    public let toolCalls: [ToolCall]?     // for assistant messages

    public init(
        role: Role,
        content: String? = nil,
        name: String? = nil,
        toolCallId: String? = nil,
        toolCalls: [ToolCall]? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallId = toolCallId
        self.toolCalls = toolCalls
    }

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCallId = "tool_call_id"
        case toolCalls = "tool_calls"
    }
}

public struct ToolCall: Sendable, Equatable, Hashable, Codable {
    public let id: String
    public let type: String      // "function"
    public let function: Function

    public struct Function: Sendable, Equatable, Hashable, Codable {
        public let name: String
        public let arguments: String   // JSON string per OpenAI spec
    }
}

/// Top-level tool definition the assistant can call.
public struct ToolSchema: Sendable, Equatable, Hashable, Codable {
    public let type: String              // "function"
    public let function: Function

    public struct Function: Sendable, Equatable, Hashable, Codable {
        public let name: String
        public let description: String
        public let parameters: ParametersJSON     // JSON-Schema object
    }

    /// We don't try to model JSON-Schema in Swift's type system — just carry
    /// the JSON object verbatim. `JSONValue` covers null/bool/number/string/
    /// array/object and round-trips cleanly through JSONEncoder/Decoder.
    public typealias ParametersJSON = JSONValue
}

public struct ChatChunk: Sendable {
    public let contentDelta: String?
    public let toolCallDeltas: [ToolCallDelta]
    public let finishReason: String?

    public init(
        contentDelta: String? = nil,
        toolCallDeltas: [ToolCallDelta] = [],
        finishReason: String? = nil
    ) {
        self.contentDelta = contentDelta
        self.toolCallDeltas = toolCallDeltas
        self.finishReason = finishReason
    }
}

public struct ToolCallDelta: Sendable {
    public let index: Int
    public let id: String?
    public let name: String?
    public let argumentsDelta: String?

    public init(index: Int, id: String? = nil, name: String? = nil, argumentsDelta: String? = nil) {
        self.index = index
        self.id = id
        self.name = name
        self.argumentsDelta = argumentsDelta
    }
}
