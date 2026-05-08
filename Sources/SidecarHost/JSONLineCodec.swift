import Foundation

/// Reads line-delimited JSON from a byte stream. Handles partial reads by
/// buffering until a `\n` boundary is seen.
///
/// Each emitted element is a single decoded JSON envelope. Consumers branch
/// on the envelope's shape (`id+result`, `id+error`, `id+stream`, `event`, `log`).
public struct JSONLineCodec: Sendable {
    public init() {}

    /// Append `bytes` to `buffer`, return decoded envelopes for any complete lines.
    /// Updates `buffer` in place to retain any trailing partial line.
    ///
    /// Per-line resilient: a single malformed line is downgraded to a
    /// `.log` envelope (`stream=stdout-text`) and the remaining lines
    /// in the same batch still decode. Python sidecars and their
    /// dependencies routinely `print()` non-JSON status to stdout
    /// (model loaders, MLX warmup, progress bars); throwing on the
    /// first one used to drop the rest of the batch and spam the
    /// activity log with `decode: ...` errors.
    public func consume(_ bytes: Data, into buffer: inout Data) -> [Envelope] {
        buffer.append(bytes)

        var envelopes: [Envelope] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            // Skip empty lines (a sidecar that prints "\n\n" shouldn't crash us).
            guard !line.isEmpty else { continue }
            do {
                envelopes.append(try Envelope.decode(from: line))
            } catch {
                let text = String(data: Data(line), encoding: .utf8)
                    ?? "<\(line.count) non-utf8 bytes>"
                envelopes.append(.log(
                    level: "info",
                    message: text,
                    fields: ["stream": "stdout-text"]
                ))
            }
        }
        return envelopes
    }

    public enum Envelope: Sendable {
        case response(id: String, result: Data)
        case error(id: String, code: Int, message: String)
        case streamChunk(id: String, data: Data)
        case streamEnd(id: String)
        case event(name: String, payload: Data)
        case log(level: String, message: String, fields: [String: String])
        case unknown(Data)

        static func decode(from data: any DataProtocol) throws -> Envelope {
            let bytes = Data(data)
            guard let any = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw SidecarError.decode(message: "expected JSON object")
            }

            // Log line: {"log": {...}}
            if let log = any["log"] as? [String: Any] {
                let level = (log["level"] as? String) ?? "info"
                let message = (log["msg"] as? String) ?? ""
                let fields = (log["fields"] as? [String: Any]).map { dict in
                    dict.compactMapValues { $0 as? String }
                } ?? [:]
                return .log(level: level, message: message, fields: fields)
            }

            // Event: {"event": "...", "payload": ...}
            if let name = any["event"] as? String {
                let payload = any["payload"] ?? [String: Any]()
                let payloadData = try JSONSerialization.data(withJSONObject: payload)
                return .event(name: name, payload: payloadData)
            }

            // Response forms require an "id"
            guard let id = any["id"] as? String else {
                return .unknown(bytes)
            }

            if any["stream_end"] as? Bool == true {
                return .streamEnd(id: id)
            }
            if let stream = any["stream"] {
                let streamData = try JSONSerialization.data(withJSONObject: stream)
                return .streamChunk(id: id, data: streamData)
            }
            if let err = any["error"] as? [String: Any] {
                let code = (err["code"] as? Int) ?? -1
                let message = (err["message"] as? String) ?? ""
                return .error(id: id, code: code, message: message)
            }
            if let result = any["result"] {
                let resultData = try JSONSerialization.data(withJSONObject: result)
                return .response(id: id, result: resultData)
            }
            return .unknown(bytes)
        }
    }

    /// Encode an outgoing request as a single newline-terminated line.
    public func encodeRequest<P: Encodable>(id: String, method: String, params: P) throws -> Data {
        let wire = RequestWire(id: id, method: method, params: params)
        let encoder = JSONEncoder()
        var data = try encoder.encode(wire)
        data.append(0x0A)
        return data
    }
}

private struct RequestWire<P: Encodable>: Encodable {
    let id: String
    let method: String
    let params: P
}
