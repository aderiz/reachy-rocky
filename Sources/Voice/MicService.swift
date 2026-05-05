import Foundation
import AVFoundation
import Telemetry

/// Captures the system's default input device into a 16 kHz mono float32
/// `AudioRingBuffer`. Caller polls/drains the buffer.
///
/// macOS doesn't gate on a permission prompt by default — the app target
/// just needs `NSMicrophoneUsageDescription` in Info.plist when run as a
/// proper .app bundle. Direct `swift run` may show a TCC prompt the first
/// time. The dashboard surfaces "no audio" if the engine fails to start.
public final class MicService: @unchecked Sendable {
    public let buffer: AudioRingBuffer
    public let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let logBus: LogBus
    private var converter: AVAudioConverter?
    private var lastTapFormat: AVAudioFormat?

    public private(set) var isRunning: Bool = false

    /// Latest RMS over the most recently delivered frame. Useful for VU meters.
    public private(set) var lastRMS: Float = 0

    public init(logBus: LogBus, ringBufferSeconds: Double = 6) {
        self.logBus = logBus
        let cap = Int(ringBufferSeconds * 16_000)
        self.buffer = AudioRingBuffer(capacity: cap)
    }

    public func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw VoiceError.audioEngine("input device returned 0 Hz sample rate")
        }
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        // Reset converter when the input format changes (device switch, etc.).
        if lastTapFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: target)
            lastTapFormat = inputFormat
        }

        let bus: AVAudioNodeBus = 0
        input.installTap(onBus: bus, bufferSize: 1024, format: inputFormat) { [weak self] pcm, _ in
            guard let self else { return }
            self.handle(pcm: pcm, target: target)
        }

        try engine.start()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    private func handle(pcm: AVAudioPCMBuffer, target: AVAudioFormat) {
        guard let converter else { return }

        // Allocate a destination buffer big enough for the resampled chunk.
        let ratio = target.sampleRate / pcm.format.sampleRate
        let outFrameCapacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio + 16)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrameCapacity) else {
            return
        }

        var error: NSError?
        let supplied = FlipOnce()
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatusPtr in
            if supplied.flag {
                inputStatusPtr.pointee = .endOfStream
                return nil
            }
            supplied.flag = true
            inputStatusPtr.pointee = .haveData
            return pcm
        }
        if status == .error, let error {
            Task { [weak self] in
                guard let self else { return }
                await self.logBus.publish(.error(
                    scope: "mic", message: "convert: \(error)", recoverable: true
                ))
            }
            return
        }
        let frames = Int(outBuffer.frameLength)
        guard let chData = outBuffer.floatChannelData else { return }
        let ch = chData[0]
        let bytes = UnsafeBufferPointer(start: ch, count: frames)

        // Compute RMS once for VU.
        var sumSq: Double = 0
        for i in 0..<frames { sumSq += Double(bytes[i]) * Double(bytes[i]) }
        lastRMS = Float((sumSq / Double(max(1, frames))).squareRoot())

        buffer.write(bytes)
    }
}

public enum VoiceError: Error, Sendable {
    case audioEngine(String)
    case sttUnavailable(String)
}

/// Helper for one-shot flags inside @Sendable closures. The AVAudioConverter
/// input block is invoked synchronously by the converter, but Swift 6 can't
/// see that and complains about captured-var mutation; this carries the
/// state in a class instance instead.
private final class FlipOnce: @unchecked Sendable {
    var flag: Bool = false
}
