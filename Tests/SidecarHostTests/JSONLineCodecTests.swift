import Testing
import SidecarHost
import Foundation

@Suite("JSONLineCodec")
struct JSONLineCodecTests {
    @Test("decodes a response envelope")
    func response() throws {
        let codec = JSONLineCodec()
        var buffer = Data()
        let line = #"{"id":"abc","result":{"ok":true}}\n"#
            .replacingOccurrences(of: #"\n"#, with: "\n")
            .data(using: .utf8)!

        let envelopes = try codec.consume(line, into: &buffer)
        #expect(envelopes.count == 1)
        guard case .response(let id, _) = envelopes[0] else {
            Issue.record("expected response envelope; got \(envelopes[0])")
            return
        }
        #expect(id == "abc")
    }

    @Test("decodes an unsolicited event")
    func event() throws {
        let codec = JSONLineCodec()
        var buffer = Data()
        let line = (#"{"event":"target","payload":{"yaw_rad":0.1}}"# + "\n").data(using: .utf8)!
        let envelopes = try codec.consume(line, into: &buffer)
        guard case .event(let name, _) = envelopes[0] else {
            Issue.record("expected event envelope")
            return
        }
        #expect(name == "target")
    }

    @Test("buffers partial lines across consume calls")
    func partial() throws {
        let codec = JSONLineCodec()
        var buffer = Data()
        let firstHalf = #"{"id":"x","result":{"ok":"#.data(using: .utf8)!
        let secondHalf = ("true}}" + "\n").data(using: .utf8)!

        var envelopes = try codec.consume(firstHalf, into: &buffer)
        #expect(envelopes.isEmpty)

        envelopes = try codec.consume(secondHalf, into: &buffer)
        #expect(envelopes.count == 1)
    }

    @Test("decodes a log line")
    func log() throws {
        let codec = JSONLineCodec()
        var buffer = Data()
        let line = (#"{"log":{"level":"info","msg":"hi","fields":{"k":"v"}}}"# + "\n").data(using: .utf8)!
        let envelopes = try codec.consume(line, into: &buffer)
        guard case .log(let level, let msg, let fields) = envelopes[0] else {
            Issue.record("expected log envelope")
            return
        }
        #expect(level == "info")
        #expect(msg == "hi")
        #expect(fields["k"] == "v")
    }
}
