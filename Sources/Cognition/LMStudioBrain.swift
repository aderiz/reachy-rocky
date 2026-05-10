import Foundation

/// `BrainBackend` adapter wrapping the v0.1 LM Studio HTTP client.
/// Text-only — the `image` parameter is silently dropped because LM
/// Studio's OpenAI-compat surface doesn't carry vision payloads
/// reliably across the model zoo Rocky targets (Gemma 4, Qwen 3.5,
/// Phi-4 etc. all have different vision conventions).
///
/// Kept as the failsafe v0.2 fallback when the `brain` sidecar can't
/// load (mlx-vlm import failure, model weights not yet downloaded,
/// hardware too old, etc.). The fenced-JSON tool-call recovery path
/// in `CognitionEngine.extractFencedToolCalls` is most useful with
/// this backend (Gemma 4 e4b in particular).
public actor LMStudioBrain: BrainBackend {
    private let client: LMStudioClient

    public init(client: LMStudioClient) {
        self.client = client
    }

    public nonisolated func chatStream(
        messages: [ChatMessage],
        tools: [ToolSchema]?,
        image: BrainImage?
    ) -> AsyncThrowingStream<ChatChunk, Error> {
        // image is intentionally ignored — text-only backend.
        _ = image
        return client.chatStream(messages: messages, tools: tools)
    }
}
