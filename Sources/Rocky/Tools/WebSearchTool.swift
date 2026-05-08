import Foundation
import Cognition

/// Brave Search → tool. Lets Rocky look things up that aren't in his
/// training data: news, current pricing, "is X open today", etc. The
/// LLM gets back a small JSON array of `{title, url, snippet}`
/// records — enough for it to answer or quote, not so much that the
/// prompt blows up.
///
/// Brave's free tier is 1 query/second; we don't enforce the limit
/// locally because the LLM rarely fires more than one search per
/// turn. If we start seeing 429s in the wild we'll add a token
/// bucket on the actor that owns this tool.
enum WebSearchTool {
    static let endpoint = URL(string: "https://api.search.brave.com/res/v1/web/search")!

    /// `keyProvider` reads the current API key on every call so the
    /// user can paste a key into Settings without re-launching Rocky
    /// or re-registering tools.
    static func register(
        in registry: ToolRegistry,
        keyProvider: @Sendable @escaping () async -> String,
        urlSession: URLSession = .shared
    ) async {
        await registry.register(
            name: "search_web",
            description: "Search the web via Brave Search and return the top results. Use this for current events, prices, opening hours, recent news, anything that may have changed since your training cutoff. Each result is {title, url, snippet} — quote sparingly and cite the URL when relying on it.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("The search query, in plain language."),
                    ]),
                    "count": .object([
                        "type": .string("integer"),
                        "description": .string("How many results to return (default 5, max 10)."),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ]),
            handler: { args in
                guard let raw = args.asObject?["query"]?.asString,
                      !raw.trimmingCharacters(in: .whitespaces).isEmpty
                else {
                    return .object(["error": .string("missing query")])
                }
                // Cap query length to defend against a buggy or
                // malicious LLM passing megabyte-scale strings.
                // Brave's own limit is 400 chars; anything more
                // than ~512 isn't going to help the search anyway.
                let query = String(raw.prefix(512))
                let key = await keyProvider()
                guard !key.isEmpty else {
                    return .object([
                        "error": .string(
                            "Brave Search API key not configured. Open Settings → Brain and paste a key from search.brave.com/api."
                        ),
                    ])
                }
                let count = max(1, min(10, Int(args.asObject?["count"]?.asNumber ?? 5)))
                return try await fetch(query: query, count: count,
                                       key: key, session: urlSession)
            }
        )
    }

    private static func fetch(
        query: String, count: Int, key: String, session: URLSession
    ) async throws -> JSONValue {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(count)),
        ]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status != 200 {
            let body = String(data: data, encoding: .utf8)?
                .prefix(200) ?? "<no body>"
            return .object([
                "error": .string("Brave returned HTTP \(status): \(body)"),
            ])
        }
        return parseResults(data: data, fallbackQuery: query)
    }

    /// Pull just `web.results[*].{title, url, description}` out of the
    /// Brave payload. The response carries lots of other fields
    /// (mixed news, faqs, infobox…) but the LLM gets confused by the
    /// noise — better to start with a tight result list and add
    /// fields when we see the LLM ask for them.
    private static func parseResults(
        data: Data, fallbackQuery: String
    ) -> JSONValue {
        struct BraveResponse: Decodable {
            struct Web: Decodable { let results: [Result]? }
            struct Result: Decodable {
                let title: String?
                let url: String?
                let description: String?
            }
            let web: Web?
        }
        do {
            let decoded = try JSONDecoder().decode(BraveResponse.self, from: data)
            let items = (decoded.web?.results ?? []).map { r -> JSONValue in
                .object([
                    "title":   .string(r.title ?? ""),
                    "url":     .string(r.url ?? ""),
                    "snippet": .string(r.description ?? ""),
                ])
            }
            return .object([
                "query": .string(fallbackQuery),
                "results": .array(items),
            ])
        } catch {
            return .object([
                "error": .string("Brave decode failed: \(error)"),
            ])
        }
    }
}
