import AppKit
import SwiftUI

@main
struct MeetingCopilotApp: App {
    // Not @State: the SwiftUI macro plugin is unavailable without Xcode. The App struct lives for
    // the whole process, so a plain stored instance is sufficient.
    private let model = AppModel()

    init() {
        SelfTest.runIfRequested()
        // Allows `swift run` (no .app bundle) to show a regular window with focus.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("Meeting Copilot") {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 420)
        }
        .windowLevel(.floating)
        .defaultSize(width: 900, height: 560)
    }
}
