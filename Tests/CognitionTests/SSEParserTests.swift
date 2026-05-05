import Testing
import Foundation
import Cognition

@Suite("SSEParser")
struct SSEParserTests {
    @Test("yields data payloads on record boundary")
    func basic() {
        var p = SSEParser()
        let chunk = Data("data: hello\n\ndata: world\n\n".utf8)
        let payloads = p.consume(chunk)
        #expect(payloads == ["hello", "world"])
    }

    @Test("buffers partial records across consume calls")
    func partial() {
        var p = SSEParser()
        var got = p.consume(Data("data: hel".utf8))
        #expect(got.isEmpty)
        got = p.consume(Data("lo\n\n".utf8))
        #expect(got == ["hello"])
    }

    @Test("ignores non-data lines")
    func ignoresOtherDirectives() {
        var p = SSEParser()
        let payloads = p.consume(Data("event: ping\nid: 7\ndata: ok\n\n".utf8))
        #expect(payloads == ["ok"])
    }

    @Test("[DONE] surfaces as a payload")
    func done() {
        var p = SSEParser()
        let payloads = p.consume(Data("data: [DONE]\n\n".utf8))
        #expect(payloads == ["[DONE]"])
    }
}
