import Foundation
import Cognition
import Memory

/// Explicit "look it up" hook for the LLM. The pre-turn auto-recall
/// in `CognitionEngine.fetchRecallEnvelope` already injects the top
/// few most relevant drawers as background context for every turn,
/// but that's keyed off the *current user utterance*. When the user
/// asks something memory-specific ("what do you remember about me?",
/// "what did I tell you about my work?", "have we talked about X
/// before?") the auto-recall query is a meta-question that semantically
/// misses the actual facts.
///
/// `recall_memory` lets the brain run its own targeted search. The
/// model picks the query terms (e.g. "tea", "name", "schedule"),
/// asks for a larger top-K, and gets a structured list it can cite
/// directly. Tool results stream back into the next round so the
/// model can incorporate them into its reply.
enum RecallMemoryTool {
    static func register(in registry: ToolRegistry, memory: MemoryService) async {
        await registry.register(
            name: "recall_memory",
            description: "Search Rocky's long-term memory of prior conversations and saved notes. Call this when the user asks what you remember about them, what they've told you before, or when answering a question would benefit from prior context. Use specific search terms — \"tea\", \"my work\", \"calendar\" — rather than meta-questions like \"what do you remember\".",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Search terms — concrete topics, names, or phrases likely to appear in past conversation. Short noun phrases work best."),
                    ]),
                    "k": .object([
                        "type": .string("integer"),
                        "description": .string("How many memory entries to retrieve (1-15). Defaults to 8."),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ]),
            handler: { args in
                let obj = args.asObject ?? [:]
                guard let query = obj["query"]?.asString,
                      !query.trimmingCharacters(in: .whitespaces).isEmpty
                else {
                    return .object(["ok": .bool(false),
                                    "error": .string("missing query")])
                }
                // JSONValue stores numbers as Double; tools may pass
                // `k` as a JSON number or a string. Normalise both.
                let kRaw: Int
                if let n = obj["k"]?.asNumber {
                    kRaw = Int(n)
                } else if let s = obj["k"]?.asString, let parsed = Int(s) {
                    kRaw = parsed
                } else {
                    kRaw = 8
                }
                let k = max(1, min(15, kRaw))
                do {
                    let hits = try await memory.recall(query: query, k: k)
                    let formatted: [JSONValue] = hits.map { hit in
                        let parsed = Self.parseStoredContent(hit.text)
                        var entry: [String: JSONValue] = [
                            "text": .string(parsed.body),
                        ]
                        if let role = parsed.role {
                            entry["role"] = .string(role)
                        }
                        if let when = parsed.when {
                            entry["when"] = .string(when)
                        }
                        if let score = hit.score {
                            entry["similarity"] = .number(score)
                        }
                        return .object(entry)
                    }
                    return .object([
                        "ok":    .bool(true),
                        "query": .string(query),
                        "count": .number(Double(hits.count)),
                        "hits":  .array(formatted),
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

    /// Memory drawers are stored with a `[role @ iso-timestamp] body`
    /// prefix (see `Sidecars/mempalace/rocky_mempalace/runner.py`'s
    /// `handle_add`). Parsing back into structured fields makes the
    /// tool result much more useful to the LLM — it can answer
    /// "when did I tell you that?" without our prompt scaffolding
    /// having to teach it the prefix syntax.
    private static func parseStoredContent(
        _ raw: String
    ) -> (role: String?, when: String?, body: String) {
        guard raw.hasPrefix("[") else { return (nil, nil, raw) }
        guard let close = raw.firstIndex(of: "]") else { return (nil, nil, raw) }
        let inside = raw[raw.index(after: raw.startIndex)..<close]
        let body = raw[raw.index(after: close)...]
            .trimmingCharacters(in: .whitespaces)
        let parts = inside.split(separator: "@", maxSplits: 1,
                                  omittingEmptySubsequences: false)
        guard parts.count == 2 else { return (nil, nil, body) }
        let role = parts[0].trimmingCharacters(in: .whitespaces)
        let when = parts[1].trimmingCharacters(in: .whitespaces)
        return (role.isEmpty ? nil : role,
                when.isEmpty ? nil : when,
                body)
    }
}
