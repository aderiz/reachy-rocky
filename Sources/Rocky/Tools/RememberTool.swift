import Foundation
import Cognition
import Memory

/// Explicit "save this" hook for the LLM. Conversations are already
/// recorded into mempalace verbatim turn-by-turn (see
/// `CognitionEngine` → `memory.recordDetached`), so the bulk of
/// long-term context grows passively. This tool is the curated
/// counterpart: when the user says "Rocky, remember that I take my
/// coffee black" the LLM calls `remember(fact: ...)` and a single
/// drawer with `role: system` lands in the palace alongside the
/// chat history.
///
/// Tagging the drawer as `system` (rather than `user`) keeps these
/// curated facts visually distinct in the Memory inspector and
/// signals to future recall that this isn't a verbatim utterance —
/// it's a fact someone bothered to elevate.
enum RememberTool {
    static func register(in registry: ToolRegistry, memory: MemoryService) async {
        await registry.register(
            name: "remember",
            description: "Save a fact, preference, or note Rocky should keep across sessions. Call this when the user explicitly asks Rocky to remember something (\"remember that I prefer X\", \"don't forget Y\"). Conversations are already auto-recorded; only call this for things worth elevating above the raw chat log.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "fact": .object([
                        "type": .string("string"),
                        "description": .string("The fact or note to remember, in a self-contained sentence (\"Ade prefers his coffee black\"). Don't include quoting or attribution metadata — the drawer's role tag handles that."),
                    ]),
                ]),
                "required": .array([.string("fact")]),
            ]),
            handler: { args in
                guard let fact = args.asObject?["fact"]?.asString,
                      !fact.trimmingCharacters(in: .whitespaces).isEmpty
                else {
                    return .object(["error": .string("missing fact")])
                }
                do {
                    let result = try await memory.record(role: .system, text: fact)
                    return .object([
                        "ok":     .bool(result.stored),
                        "id":     .string(result.id ?? ""),
                        "stored": .string(fact),
                    ])
                } catch {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("memory sidecar unreachable: \(error)"),
                    ])
                }
            }
        )
    }
}
