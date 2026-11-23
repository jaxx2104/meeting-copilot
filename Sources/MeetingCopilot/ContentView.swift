import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                transcriptPane.frame(minWidth: 260)
                VSplitView {
                    supplementPane.frame(minHeight: 140)
                    questionPane.frame(minHeight: 140)
                }
                .frame(minWidth: 320)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: model.toggle) {
                Label(model.isRunning ? "停止" : "開始", systemImage: model.isRunning ? "stop.fill" : "mic.fill")
            }
            .keyboardShortcut(.space, modifiers: [.command])
            .tint(model.isRunning ? .red : .accentColor)
            .buttonStyle(.borderedProminent)

            Button(action: model.toggleScreen) {
                Label("画面", systemImage: model.screenSelected ? "rectangle.inset.filled.on.rectangle" : "rectangle.on.rectangle")
            }
            .tint(model.screenSelected ? .accentColor : nil)
            .buttonStyle(.bordered)
            .help(model.screenSelected
                  ? (model.screenText.isEmpty ? "画面を読み取り中（クリックで停止）" : "読み取った内容:\n" + model.screenText.prefix(400))
                  : "共有画面やスライドを選んで、分析に使う")

            LevelMeter(level: model.level).frame(width: 60, height: 8)

            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()

            Picker("言語", selection: $model.language) {
                Text("自動").tag("auto")
                Text("日本語").tag("ja")
                Text("English").tag("en")
            }
            .frame(width: 130)

            Picker("LLM", selection: $model.backend) {
                ForEach(LLMBackend.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 210)
            if model.backend == .ollama {
                TextField("model", text: $model.ollamaModel).frame(width: 110)
            }
            Button("今すぐ分析", action: model.analyzeNow)
                .disabled(model.isAnalyzing || (model.lines.isEmpty && !model.screenSelected))
            Button("クリア", action: model.clear)
            Button { model.pinned.toggle() } label: {
                Image(systemName: model.pinned ? "pin.fill" : "pin")
            }
            .help(model.pinned ? "前面固定を解除" : "常に前面に表示")
        }
        .padding(10)
    }

    private var transcriptPane: some View {
        Pane(title: "文字起こし", busy: model.isTranscribing) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(line.time, format: .dateTime.hour().minute().second())
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                Text(line.text).textSelection(.enabled)
                            }
                            .id(line.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: model.lines.count) {
                    if let last = model.lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }

    private var supplementPane: some View {
        Pane(title: "補足情報", busy: model.isAnalyzing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.supplements) { s in
                        Card {
                            Text(s.term).font(.headline)
                            Text(s.explanation).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private var questionPane: some View {
        Pane(title: "聞いてみたいこと", busy: model.isAnalyzing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.questions) { q in
                        Card { Label(q.text, systemImage: "questionmark.bubble").textSelection(.enabled) }
                    }
                }
                .padding(10)
            }
        }
    }
}

private struct Pane<Content: View>: View {
    let title: String
    let busy: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.subheadline.bold())
                if busy { ProgressView().controlSize(.mini) }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}

private struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.green).frame(width: geo.size.width * CGFloat(min(1, level * 8)))
            }
        }
    }
}
