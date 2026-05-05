import Testing
import Foundation
import Cognition

@Suite("JSONValue")
struct JSONValueTests {
    @Test("round-trips primitives, arrays, and objects")
    func roundTrip() throws {
        let original = JSONValue.object([
            "x": .number(1.0),
            "y": .number(-3.5),
            "ok": .bool(true),
            "label": .string("hi"),
            "nope": .null,
            "list": .array([.number(1), .number(2), .number(3)]),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == original)
    }

    @Test("init(jsonString:) parses tool-call-style arguments")
    func fromString() throws {
        let v = try JSONValue(jsonString: "{\"x\":1,\"name\":\"door\"}")
        #expect(v.asObject?["x"]?.asNumber == 1)
        #expect(v.asObject?["name"]?.asString == "door")
    }
}
