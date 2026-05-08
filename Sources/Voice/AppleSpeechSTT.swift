import Foundation
import AVFoundation
import Speech

/// `STTEngine` conformer using Apple's `SFSpeechRecognizer`.
///
/// Pros: built into the OS, no model download, on-device when available
/// (macOS 13+), handles segmentation. Cons: quality lags Whisper for
/// hard-of-distance speech and noisy rooms; no explicit hallucination
/// guard. Good enough for "Rocky, do X" addressing patterns; we can
/// swap in WhisperKit later if needed.
public actor AppleSpeechSTT: STTEngine {
    public enum Status: Sendable, Equatable {
        case unauthorized(SFSpeechRecognizerAuthorizationStatus)
        case unavailable
        case ready
    }

    /// Recogniser is `var` (not `let`) so a per-call retry can
    /// upgrade nil → real instance once the locale's offline
    /// model finishes downloading. macOS Sequoia downloads
    /// Speech assets in the background after a clean install;
    /// without the retry, a first-launch user with `en-GB` (or
    /// any locale Apple downloads on demand) gets a permanently
    /// `.unavailable` STT until they relaunch.
    private var recognizer: SFSpeechRecognizer?
    private let localeIdentifier: String
    public private(set) var status: Status

    public init(localeIdentifier: String = "en-US") {
        self.localeIdentifier = localeIdentifier
        let locale = Locale(identifier: localeIdentifier)
        self.recognizer = SFSpeechRecognizer(locale: locale)
        if self.recognizer == nil {
            self.status = .unavailable
        } else {
            let auth = SFSpeechRecognizer.authorizationStatus()
            self.status = (auth == .authorized) ? .ready : .unauthorized(auth)
        }
    }

    /// Re-attempt to build the recogniser if we don't have one
    /// yet. Cheap; called per-`transcribe` so a first-launch
    /// user whose locale-data was still downloading at init
    /// time gets STT as soon as the assets land.
    private func ensureRecognizer() -> SFSpeechRecognizer? {
        if let existing = recognizer { return existing }
        let locale = Locale(identifier: localeIdentifier)
        let fresh = SFSpeechRecognizer(locale: locale)
        if fresh != nil {
            recognizer = fresh
            // Promote status if auth is good — the only thing
            // gating us before was the missing recogniser.
            if SFSpeechRecognizer.authorizationStatus() == .authorized {
                status = .ready
            }
        }
        return fresh
    }

    /// Request user authorization. Returns the resolved status. macOS shows
    /// the system prompt the first time this is called from a bundled app;
    /// `swift run` may auto-allow if the binary's parent has been granted.
    public func requestAuthorization() async -> Status {
        let resolved: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        if recognizer == nil {
            status = .unavailable
        } else if resolved == .authorized {
            status = .ready
        } else {
            status = .unauthorized(resolved)
        }
        return status
    }

    public func warmUp() async throws {
        if case .unauthorized = status {
            _ = await requestAuthorization()
        }
    }

    public func transcribe(samples: [Float], at sampleRate: Int) async throws -> Transcript {
        guard let recognizer = ensureRecognizer() else {
            throw VoiceError.sttUnavailable("no recognizer for current locale")
        }
        guard case .ready = status else {
            throw VoiceError.sttUnavailable("recognizer not authorized")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        // Re-evaluate per-call rather than caching at init.
        // `supportsOnDeviceRecognition` flips when Speech finishes
        // downloading the offline model in the background; setting
        // requiresOnDeviceRecognition = true with the model not
        // yet available silently fails.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            throw VoiceError.sttUnavailable("could not allocate PCM buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: samples.count)
            }
        }
        request.append(buffer)
        request.endAudio()

        let started = Date()
        let resumed = ResumeOnce()

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Transcript, Error>) in
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    let nsErr = error as NSError
                    // "No speech detected" is benign; treat as empty transcript.
                    if nsErr.domain == "kAFAssistantErrorDomain" && nsErr.code == 1110 {
                        let ms = Date().timeIntervalSince(started) * 1000
                        if resumed.fire() {
                            cont.resume(returning: Transcript(text: "", durationMs: ms, confidence: 0))
                        }
                        return
                    }
                    if resumed.fire() { cont.resume(throwing: error) }
                    return
                }
                guard let result, result.isFinal else { return }
                let ms = Date().timeIntervalSince(started) * 1000
                let text = result.bestTranscription.formattedString
                let confidence = Double(result.bestTranscription.segments.first?.confidence ?? 0)
                if resumed.fire() {
                    cont.resume(returning: Transcript(
                        text: text, durationMs: ms, confidence: confidence
                    ))
                }
            }
        }
    }
}

/// Continuations must be resumed exactly once, but the SFSpeech callback can
/// fire multiple times on edge paths. Class-bound flag is Sendable-safe.
private final class ResumeOnce: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
