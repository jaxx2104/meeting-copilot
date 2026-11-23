import AVFoundation
import Foundation

/// `MeetingCopilot --selftest <audio-file>`: runs the transcribe -> analyze pipeline on a file and prints results.
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return }
        let path = args[i + 1]
        let model = ProcessInfo.processInfo.environment["WHISPER_MODEL"] ?? "large-v3-v20240930_626MB"
        Task.detached {
            do {
                let t = Transcriber(model: model)
                try await t.load { print($0) }
                let samples = try loadSamples(path)
                var seg = Segmenter()
                var texts: [String] = []
                var chunks: [[Float]] = []
                for start in stride(from: 0, to: samples.count, by: 1600) {
                    if let c = seg.append(Array(samples[start..<min(start + 1600, samples.count)])) { chunks.append(c) }
                }
                if let c = seg.flush() { chunks.append(c) }
                let t0 = Date()
                for c in chunks {
                    let text = try await t.transcribe(c, language: ProcessInfo.processInfo.environment["MC_LANG"] ?? "auto")
                    print("[chunk \(String(format: "%.1f", Double(c.count) / 16000))s] \(text)")
                    texts.append(text)
                }
                print("transcribe: \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
                if let msg = AppleIntelligenceProvider.availabilityMessage { print(msg) }
                let t1 = Date()
                let r = try await AppleIntelligenceProvider().analyze(transcript: texts.joined(separator: "\n"), alreadyShown: [])
                print("analyze: \(String(format: "%.1f", Date().timeIntervalSince(t1)))s")
                for s in r.supplements { print("補足: \(s.term) — \(s.explanation)") }
                for q in r.questions { print("質問: \(q)") }
                exit(0)
            } catch {
                print("selftest failed: \(error)")
                exit(1)
            }
        }
    }

    private static func loadSamples(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let conv = AVAudioConverter(from: file.processingFormat, to: target)!
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * 16000 / file.processingFormat.sampleRate) + 1024)!
        var done = false
        _ = conv.convert(to: out, error: nil) { _, status in
            if done { status.pointee = .endOfStream; return nil }
            done = true; status.pointee = .haveData; return input
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}
