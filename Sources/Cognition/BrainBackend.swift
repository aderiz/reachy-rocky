import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Abstraction over the LLM/VLM that drives Rocky's cognition turn.
///
/// Three implementations exist:
///   - `LMStudioBrain` (v0.1 baseline): wraps `LMStudioClient`, talks
///     HTTP to a local LM Studio server. Text-only.
///   - `MLXVLMBrain` (v0.2 default): wraps the `brain` sidecar, runs
///     mlx-vlm + Qwen3-VL natively on Apple Silicon. Vision-aware.
///   - `HermesBrain` (future, ADR 0004): wraps Hermes Agent as the
///     opt-in advanced backend.
///
/// All three return the same `ChatChunk` stream shape so
/// `CognitionEngine` doesn't care which backend is active. The
/// `image` parameter is optional — text-only backends ignore it.
public protocol BrainBackend: Sendable {
    func chatStream(
        messages: [ChatMessage],
        tools: [ToolSchema]?,
        image: BrainImage?
    ) -> AsyncThrowingStream<ChatChunk, Error>
}

/// Lightweight image payload that can travel into the BrainBackend
/// from any vision source (camera-frame JPEG, on-disk file, etc.)
/// without dragging Foundation/CoreImage types into the protocol
/// signature. Most callsites construct via `.jpeg(...)` from a
/// `RobotCameraService.Frame.jpeg`; the backend transports the
/// bytes to wherever inference happens (in-process for VLM, base64
/// over stdio for the sidecar variant).
public struct BrainImage: Sendable, Equatable {
    public let jpegData: Data
    public init(jpegData: Data) {
        self.jpegData = jpegData
    }
}
