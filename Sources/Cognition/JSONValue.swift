import Foundation

/// Minimal type-erased JSON value. Round-trips cleanly through
/// `JSONEncoder` / `JSONDecoder`. Used by `ToolSchema.parameters` so
/// callers can declare arbitrary JSON-Schema bodies without us having
/// to model JSON-Schema in Swift.
public enum JSONValue: Sendable, Equatable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "JSONValue: unrecognized JSON type"
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:        try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

public extension JSONValue {
    /// Convenience for parsing tool-call argument strings.
    init(jsonString: String) throws {
        let data = Data(jsonString.utf8)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Convenience for forwarding arguments to a tool handler.
    func encodedString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
    }

    var asObject: [String: JSONValue]? {
        if case .object(let o) = self { return o } else { return nil }
    }

    var asString: String? {
        if case .string(let s) = self { return s } else { return nil }
    }

    var asNumber: Double? {
        if case .number(let n) = self { return n } else { return nil }
    }

    var asBool: Bool? {
        if case .bool(let b) = self { return b } else { return nil }
    }
}
