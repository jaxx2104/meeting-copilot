import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

/// Reads text from a window or display the user picks, so shared slides and documents can inform the analysis.
///
/// The system picker (SCContentSharingPicker) is used instead of capturing the whole screen so that only
/// what the user explicitly chose is read; unrelated windows such as chat or mail never reach the LLM.
/// Capture and OCR are both on-device (ScreenCaptureKit + Vision).
@MainActor
final class ScreenReader: NSObject, SCContentSharingPickerObserver {
    private(set) var filter: SCContentFilter?
    private(set) var lastError: String?
    var onChange: (() -> Void)?

    override init() {
        super.init()
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow, .singleDisplay]
        if let id = Bundle.main.bundleIdentifier { config.excludedBundleIDs = [id] }
        SCContentSharingPicker.shared.defaultConfiguration = config
        SCContentSharingPicker.shared.add(self)
    }

    func present() {
        SCContentSharingPicker.shared.isActive = true
        SCContentSharingPicker.shared.present()
    }

    func stop() {
        filter = nil
        SCContentSharingPicker.shared.isActive = false
        onChange?()
    }

    /// Captures the picked content once and returns its recognized text, or nil when nothing is picked.
    func readText() async throws -> String? {
        guard let filter else { return nil }
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return try await Self.recognizeText(in: image)
    }

    static func recognizeText(in image: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "ja-JP"), Locale.Language(identifier: "en-US")]
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: image)
        // Vision's coordinates have the origin at the bottom-left; sort top-to-bottom for reading order.
        return observations
            .sorted { $0.boundingBox.cgRect.midY > $1.boundingBox.cgRect.midY }
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// Whether `new` differs enough from `old` to be worth a fresh analysis (e.g. the slide changed).
    /// Compared line-wise because OCR jitter and scrolling change a few lines without changing the content.
    static func changed(_ new: String, from old: String) -> Bool {
        let a = Set(new.split(separator: "\n")), b = Set(old.split(separator: "\n"))
        guard !a.isEmpty else { return false }
        return Double(a.intersection(b).count) / Double(a.union(b).count) < 0.7
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            self.filter = filter
            self.lastError = nil
            self.onChange?()
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {}

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in
            self.lastError = error.localizedDescription
            self.onChange?()
        }
    }
}
