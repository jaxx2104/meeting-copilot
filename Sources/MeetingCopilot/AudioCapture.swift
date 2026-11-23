import AVFoundation

/// Captures microphone audio and delivers 16 kHz mono Float32 samples.
final class AudioCapture {
    static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.sampleRate, channels: 1, interleaved: false)!

    func start(onSamples: @escaping ([Float]) -> Void) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw CaptureError.noInputDevice }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = converter
        let target = targetFormat

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let ratio = target.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
            onSamples(Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength))))
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }

    enum CaptureError: LocalizedError {
        case noInputDevice, converterUnavailable
        var errorDescription: String? {
            switch self {
            case .noInputDevice: "マイク入力が見つかりません"
            case .converterUnavailable: "音声フォーマット変換を初期化できません"
            }
        }
    }
}

/// Splits a continuous sample stream into utterance-sized chunks using a simple energy-based VAD.
struct Segmenter {
    var silenceThreshold: Float = 0.008
    var minChunkSeconds = 2.0
    var maxChunkSeconds = 20.0
    var trailingSilenceSeconds = 0.7

    private var buffer: [Float] = []
    private var hasVoice = false

    /// Appends samples and returns a finished chunk when an utterance boundary is detected.
    mutating func append(_ samples: [Float]) -> [Float]? {
        buffer.append(contentsOf: samples)
        if Self.rms(samples) >= silenceThreshold { hasVoice = true }

        let sr = AudioCapture.sampleRate
        let duration = Double(buffer.count) / sr

        // Drop leading silence so chunks don't grow with nothing in them.
        if !hasVoice, duration > 1.0 {
            buffer.removeFirst(buffer.count - Int(0.3 * sr))
            return nil
        }

        let tailCount = Int(trailingSilenceSeconds * sr)
        let tailSilent = buffer.count > tailCount
            && Self.rms(buffer[(buffer.count - tailCount)...]) < silenceThreshold

        if hasVoice, (duration >= minChunkSeconds && tailSilent) || duration >= maxChunkSeconds {
            return flush()
        }
        return nil
    }

    mutating func flush() -> [Float]? {
        defer { buffer = []; hasVoice = false }
        return hasVoice ? buffer : nil
    }

    static func rms<C: Collection>(_ s: C) -> Float where C.Element == Float {
        guard !s.isEmpty else { return 0 }
        return (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
    }
}
