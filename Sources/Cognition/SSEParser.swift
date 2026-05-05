import Foundation

/// Minimal Server-Sent Events parser sufficient for OpenAI-style streaming.
///
/// SSE messages use `\n\n` as a record terminator. Each record may contain
/// one or more `data: <value>\n` lines plus other directives we ignore
/// (event:, id:, retry:). We only surface the `data` payloads.
public struct SSEParser {
    private var buffer = Data()

    public init() {}

    public mutating func consume(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var out: [String] = []
        while let separatorRange = buffer.range(of: Data("\n\n".utf8)) {
            let recordData = buffer.subdata(in: 0..<separatorRange.lowerBound)
            buffer.removeSubrange(0..<separatorRange.upperBound)
            guard let record = String(data: recordData, encoding: .utf8) else { continue }
            for line in record.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("data:") {
                    let value = line.dropFirst("data:".count)
                        .trimmingCharacters(in: .whitespaces)
                    out.append(value)
                }
            }
        }
        return out
    }
}
