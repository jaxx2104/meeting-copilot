import Foundation
import WhisperKit

/// Wraps WhisperKit. The model is downloaded once; later launches load it from disk without network.
actor Transcriber {
    private var pipe: WhisperKit?
    let model: String

    init(model: String) { self.model = model }

    static var modelsBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MeetingCopilot/models")
    }

    private var savedFolderKey: String { "modelFolder.\(model)" }

    func load(onStatus: @escaping @Sendable (String) -> Void) async throws {
        var folder = UserDefaults.standard.string(forKey: savedFolderKey)
        if folder == nil || !FileManager.default.fileExists(atPath: folder!) {
            onStatus("Whisper モデルをダウンロード中（初回のみ）: \(model)")
            let url = try await WhisperKit.download(variant: model, downloadBase: Self.modelsBase) { p in
                onStatus(String(format: "Whisper モデルをダウンロード中（初回のみ）: %.0f%%", p.fractionCompleted * 100))
            }
            folder = url.path
            UserDefaults.standard.set(url.path, forKey: savedFolderKey)
        }
        onStatus("Whisper モデルを読み込み中…（初回は CoreML のコンパイルで数分かかります）")
        let config = WhisperKitConfig(modelFolder: folder, verbose: false, logLevel: .error, prewarm: true, load: true, download: false)
        pipe = try await WhisperKit(config)
    }

    func transcribe(_ samples: [Float], language: String) async throws -> String {
        guard let pipe else { return "" }
        // "auto" lets Whisper detect per chunk. Forcing "ja" on English speech makes Whisper
        // produce a looping pseudo-translation instead of a transcript.
        let auto = language == "auto"
        let options = DecodingOptions(
            language: auto ? nil : language,
            temperatureFallbackCount: 5,
            usePrefillPrompt: true,
            detectLanguage: auto,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let results: [TranscriptionResult] = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = Self.collapseRepetitions(text)
        return Self.isHallucination(collapsed) ? "" : collapsed
    }

    /// Whisper sometimes loops ("この2つの構造を使って、この2つの構造を使って、…").
    /// Drops clauses that repeat or nearly repeat one already seen in the same chunk.
    static func collapseRepetitions(_ text: String) -> String {
        let separators = CharacterSet(charactersIn: "、。,.!?！？")
        var clauses: [(String, Character?)] = []
        var current = ""
        for ch in text {
            if ch.unicodeScalars.allSatisfy(separators.contains) {
                clauses.append((current, ch)); current = ""
            } else { current.append(ch) }
        }
        if !current.isEmpty { clauses.append((current, nil)) }

        var kept: [String] = []
        var out = ""
        for (clause, sep) in clauses {
            let c = clause.trimmingCharacters(in: .whitespaces)
            if !c.isEmpty, kept.contains(where: { similarity($0, c) > 0.6 }) { continue }
            if !c.isEmpty { kept.append(c) }
            out += clause
            if let sep { out.append(sep) }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Character-bigram Dice coefficient; cheap and good enough for spotting loops.
    private static func similarity(_ a: String, _ b: String) -> Double {
        func bigrams(_ s: String) -> [String: Int] {
            let cs = Array(s)
            guard cs.count > 1 else { return [s: 1] }
            var d: [String: Int] = [:]
            for i in 0..<(cs.count - 1) { d[String(cs[i...i + 1]), default: 0] += 1 }
            return d
        }
        let x = bigrams(a), y = bigrams(b)
        let inter = x.reduce(0) { $0 + min($1.value, y[$1.key] ?? 0) }
        let total = x.values.reduce(0, +) + y.values.reduce(0, +)
        return total == 0 ? 0 : 2 * Double(inter) / Double(total)
    }

    /// Whisper tends to emit these phrases on near-silent input.
    private static let hallucinations = [
        "ご視聴ありがとうございました", "ご清聴ありがとうございました", "チャンネル登録", "字幕", "おやすみなさい",
        "Thank you for watching", "Thanks for watching",
    ]

    static func isHallucination(_ text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if stripped.count < 2 { return true }
        return hallucinations.contains { stripped.contains($0) && stripped.count <= $0.count + 6 }
    }
}
