import Testing
import Foundation
import Telemetry
import Cognition

@Suite("ToolRegistry")
struct ToolRegistryTests {
    @Test("registered tool fires its handler with parsed args")
    func invokeOK() async {
        let bus = LogBus()
        let registry = ToolRegistry(logBus: bus)
        await registry.register(
            name: "look_at",
            description: "Look at a 3D point in world frame.",
            handler: { args in
                let x = args.asObject?["x"]?.asNumber ?? 0
                return .object(["received_x": .number(x)])
            }
        )
        let result = await registry.invoke(
            name: "look_at",
            argumentsJSON: "{\"x\": 1.5, \"y\": 0, \"z\": 0}",
            llmMessageId: "msg_1"
        )
        #expect(result.ok)
        let out = try? JSONValue(jsonString: result.resultJSON)
        #expect(out?.asObject?["received_x"]?.asNumber == 1.5)
    }

    @Test("unknown tool returns ok=false")
    func unknown() async {
        let registry = ToolRegistry(logBus: LogBus())
        let result = await registry.invoke(
            name: "nope", argumentsJSON: "{}", llmMessageId: "x"
        )
        #expect(!result.ok)
    }

    @Test("malformed args surface as parse error")
    func badArgs() async {
        let registry = ToolRegistry(logBus: LogBus())
        await registry.register(name: "noop", description: "") { _ in .object([:]) }
        let result = await registry.invoke(
            name: "noop", argumentsJSON: "not json", llmMessageId: "x"
        )
        #expect(!result.ok)
    }

    @Test("schemas surface registered tool definitions")
    func schemas() async {
        let registry = ToolRegistry(logBus: LogBus())
        await registry.register(name: "alpha", description: "a") { _ in .null }
        await registry.register(name: "beta",  description: "b") { _ in .null }
        let names = await registry.names
        #expect(names == ["alpha", "beta"])
    }
}
