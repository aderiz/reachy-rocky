import Testing
import Foundation
import Cognition

@Suite("Fenced tool-call recovery")
struct FencedToolCallTests {
    @Test("extracts tool/args fenced block")
    func toolArgs() {
        let text = """
        Sure, looking that way.
        ```json
        {"tool": "look_at", "args": {"yaw_deg": 30}}
        ```
        """
        let calls = CognitionEngine.extractFencedToolCalls(
            in: text, knownTools: ["look_at", "say"]
        )
        #expect(calls.count == 1)
        #expect(calls.first?.name == "look_at")
        let json = try? JSONSerialization.jsonObject(with: Data(calls.first!.argumentsJSON.utf8)) as? [String: Any]
        #expect((json?["yaw_deg"] as? Double) == 30)
    }

    @Test("extracts OpenAI name/arguments fenced block")
    func nameArguments() {
        let text = """
        ```json
        {"name": "say", "arguments": {"text": "hi"}}
        ```
        """
        let calls = CognitionEngine.extractFencedToolCalls(
            in: text, knownTools: ["say"]
        )
        #expect(calls.first?.name == "say")
    }

    @Test("rejects unknown tool names")
    func unknownToolName() {
        let text = "```json\n{\"tool\": \"hack\", \"args\": {}}\n```"
        let calls = CognitionEngine.extractFencedToolCalls(
            in: text, knownTools: ["look_at"]
        )
        #expect(calls.isEmpty)
    }

    @Test("strips fenced blocks from text")
    func stripFences() {
        let text = """
        Looking right now.
        ```json
        {"tool": "look_at", "args": {"yaw_deg": 30}}
        ```
        Done!
        """
        let stripped = CognitionEngine.stripFencedJSONBlocks(from: text)
        #expect(stripped.contains("Looking right now"))
        #expect(stripped.contains("Done"))
        #expect(!stripped.contains("look_at"))
    }

    @Test("accepts bare JSON object as tool call")
    func bareJSON() {
        let text = "{\"tool\": \"say\", \"args\": {\"text\": \"hi\"}}"
        let calls = CognitionEngine.extractFencedToolCalls(
            in: text, knownTools: ["say"]
        )
        #expect(calls.first?.name == "say")
    }
}
