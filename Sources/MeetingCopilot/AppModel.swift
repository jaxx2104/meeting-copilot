import AVFoundation
import AppKit
import Foundation
import Observation

struct TranscriptLine: Identifiable { let id = UUID(); let time: Date; let text: String }
struct SupplementItem: Identifiable { let id = UUID(); let time: Date; let term: String; let explanation: String }
struct QuestionItem: Identifiable { let id = UUID(); let time: Date; let text: String }

enum LLMBackend: String, CaseIterable, Identifiable {
    case apple = "Apple Intelligence"
    case ollama = "Ollama"
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    // Settings
    var whisperModel = UserDefaults.standard.string(forKey: "whisperModel") ?? "large-v3-v20240930_626MB"
    var language = UserDefaults.standard.string(forKey: "language") ?? "auto"
    var backend: LLMBackend = .apple
    var ollamaModel = UserDefaults.standard.string(forKey: "ollamaModel") ?? "qwen3:8b"
    var analyzeIntervalSeconds: Double = 20
    /// Keeps the window above other apps. Off by default so it doesn't cover the meeting app.
    var pinned = UserDefaults.standard.bool(forKey: "pinned") {
        didSet {
            UserDefaults.standard.set(pinned, forKey: "pinned")
            applyPin()
        }
    }

    // State
    var isRunning = false
    var isTranscribing = false
    var isAnalyzing = false
    var status = "停止中"
    var level: Float = 0
    var lines: [TranscriptLine] = []
    var supplements: [SupplementItem] = []
    var questions: [QuestionItem] = []
    var screenSelected = false
    var screenText = ""

    private let capture = AudioCapture()
    private var transcriber: Transcriber?
    private var chunks: AsyncStream<[Float]>.Continuation?
    private var workers: [Task<Void, Never>] = []
    private var analyzedUpTo = 0
    private var analyzedScreen = ""
    private let screen = ScreenReader()

    init() {
        screen.onChange = { [weak self] in
            guard let self else { return }
            screenSelected = screen.filter != nil
            if !screenSelected { screenText = ""; analyzedScreen = "" }
            if let e = screen.lastError { status = "画面の選択に失敗: \(e)" }
        }
    }

    func applyPin() {
        for w in NSApplication.shared.windows where w.isVisible { w.level = pinned ? .floating : .normal }
    }

    func toggleScreen() { screenSelected ? screen.stop() : screen.present() }

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        UserDefaults.standard.set(whisperModel, forKey: "whisperModel")
        UserDefaults.standard.set(ollamaModel, forKey: "ollamaModel")
        UserDefaults.standard.set(language, forKey: "language")

        workers.append(Task { await run() })
    }

    func stop() {
        capture.stop()
        chunks?.finish()
        chunks = nil
        workers.forEach { $0.cancel() }
        workers = []
        isRunning = false
        level = 0
        status = "停止中"
    }

    func clear() {
        lines = []; supplements = []; questions = []; analyzedUpTo = 0; analyzedScreen = ""
    }

    private func run() async {
        do {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw NSError(domain: "Mic", code: 1, userInfo: [NSLocalizedDescriptionKey: "マイクへのアクセスが許可されていません（システム設定 > プライバシーとセキュリティ > マイク）"])
            }
            if backend == .apple, let msg = AppleIntelligenceProvider.availabilityMessage { status = msg }

            if transcriber?.model != whisperModel {
                let t = Transcriber(model: whisperModel)
                try await t.load { s in Task { @MainActor in self.status = s } }
                transcriber = t
            }
            guard isRunning, let transcriber else { return }

            let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(8))
            chunks = continuation
            var segmenter = Segmenter()
            try capture.start { [weak self] samples in
                let rms = Segmenter.rms(samples)
                if let chunk = segmenter.append(samples) { continuation.yield(chunk) }
                Task { @MainActor in self?.level = rms }
            }
            status = "聞き取り中"

            workers.append(Task { await analyzeLoop() })

            for await chunk in stream {
                isTranscribing = true
                let text = (try? await transcriber.transcribe(chunk, language: language)) ?? ""
                isTranscribing = false
                if !text.isEmpty { lines.append(TranscriptLine(time: .now, text: text)) }
            }
        } catch {
            status = "エラー: \(error.localizedDescription)"
            capture.stop()
            isRunning = false
        }
    }

    private func analyzeLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(analyzeIntervalSeconds))
            guard !Task.isCancelled else { return }
            await analyzeIfNeeded()
        }
    }

    func analyzeNow() { Task { await analyzeIfNeeded(force: true) } }

    private func analyzeIfNeeded(force: Bool = false) async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }

        // One capture per analysis tick; a separate timer would OCR frames nobody analyzes.
        if screenSelected {
            do { screenText = try await screen.readText() ?? "" } catch { status = "画面取得エラー: \(error.localizedDescription)" }
        }
        let newText = lines[analyzedUpTo...].map(\.text).joined()
        let screenChanged = ScreenReader.changed(screenText, from: analyzedScreen)
        guard !lines.isEmpty || !screenText.isEmpty else { return }
        guard force || newText.count >= 40 || screenChanged else { return }

        // Recent context, bounded for the on-device model's ~4k token window.
        let recent = String(lines.map(\.text).joined(separator: "\n").suffix(1500))
        let screenSnapshot = screenText
        let shown = (supplements.suffix(10).map(\.term) + questions.suffix(5).map(\.text))
        let upTo = lines.count

        let provider: InsightProvider = backend == .apple ? AppleIntelligenceProvider() : OllamaProvider(model: ollamaModel)
        do {
            let result = try await provider.analyze(
                transcript: recent, screen: String(screenSnapshot.prefix(800)), alreadyShown: shown)
            analyzedUpTo = upTo
            analyzedScreen = screenSnapshot
            let known = Set(supplements.map { $0.term.lowercased() })
            for s in result.supplements where !known.contains(s.term.lowercased()) {
                supplements.insert(SupplementItem(time: .now, term: s.term, explanation: s.explanation), at: 0)
            }
            for q in result.questions where !questions.contains(where: { $0.text == q }) {
                questions.insert(QuestionItem(time: .now, text: q), at: 0)
            }
            if isRunning { status = "聞き取り中" }
        } catch {
            status = "LLM エラー: \(error.localizedDescription)"
        }
    }
}
