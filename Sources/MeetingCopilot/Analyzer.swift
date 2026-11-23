import Foundation
import FoundationModels

// MARK: - Contract

// Plain Codable types: the @Generable macro plugin ships only with Xcode, so the schema is
// built with DynamicGenerationSchema below to keep the project buildable with Command Line Tools.
struct Supplement: Codable, Hashable, Sendable {
    var term: String
    var explanation: String
}

struct Insights: Codable, Sendable {
    var supplements: [Supplement]
    var questions: [String]

    init(supplements: [Supplement], questions: [String]) {
        self.supplements = supplements
        self.questions = questions
    }

    // Lenient: a truncated generation may omit a key; treat it as empty instead of failing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supplements = (try? c.decodeIfPresent([Supplement].self, forKey: .supplements)) ?? []
        questions = (try? c.decodeIfPresent([String].self, forKey: .questions)) ?? []
    }
}

protocol InsightProvider: Sendable {
    func analyze(transcript: String, screen: String, alreadyShown: [String]) async throws -> Insights
}

enum Prompt {
    static let instructions = """
    あなたは会議に同席しているアシスタントです。文字起こしされた会話を読み、次の2つを日本語で出してください。
    - supplements: 会話に出てきた専門用語・略語・固有名詞・前提知識の補足。一般常識レベルの語は不要
    - questions: 聞き手が今発言すると議論が前に進む質問（曖昧な点の確認、根拠・数値・期限・担当の確認、リスクの指摘など）
    画面に映っている資料やスライドの文字（OCR）が付くことがあります。会話と合わせて読み、画面にだけ出てくる用語も補足の対象にしてください。
    文字起こしと OCR には誤認識が含まれることがあります。会話や画面に根拠がない内容は作らないでください。該当がなければ空配列にしてください。
    """

    static func user(transcript: String, screen: String, alreadyShown: [String]) -> String {
        var s = "## 直近の会話\n\(transcript)\n"
        if !screen.isEmpty {
            s += "\n## 画面に映っている内容（OCR）\n\(screen)\n"
        }
        if !alreadyShown.isEmpty {
            s += "\n## すでに表示済み（重複させない）\n" + alreadyShown.map { "- \($0)" }.joined(separator: "\n")
        }
        return s
    }
}

// MARK: - Apple Foundation Models (on-device)

struct AppleIntelligenceProvider: InsightProvider {
    static var availabilityMessage: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(let reason): "Apple Intelligence が使えません: \(reason)"
        }
    }

    func analyze(transcript: String, screen: String, alreadyShown: [String]) async throws -> Insights {
        let prompt = Prompt.user(transcript: transcript, screen: screen, alreadyShown: alreadyShown)
        // Two small requests instead of one nested schema: the on-device model sometimes breaks
        // out of a string mid-object, and splitting keeps one failure from losing both lists.
        async let supplementsJSON = Self.generate(prompt: prompt, schema: Self.supplementsSchema())
        async let questionsJSON = Self.generate(prompt: prompt, schema: Self.questionsSchema())
        let (sj, qj) = (try? await supplementsJSON, try? await questionsJSON)
        if sj == nil, qj == nil { throw AnalyzeError.generationFailed }
        struct S: Decodable { var supplements: [Supplement] }
        struct Q: Decodable { var questions: [String] }
        let sups = sj.flatMap { try? JSONDecoder().decode(S.self, from: Data($0.utf8)).supplements } ?? []
        let qs = qj.flatMap { try? JSONDecoder().decode(Q.self, from: Data($0.utf8)).questions } ?? []
        return Insights(
            supplements: sups.map { Supplement(term: Self.clean($0.term), explanation: Self.clean($0.explanation)) }
                .filter { !$0.term.isEmpty && !$0.explanation.isEmpty },
            questions: Array(qs.map(Self.clean).filter { !$0.isEmpty }.prefix(3))
        )
    }

    enum AnalyzeError: LocalizedError {
        case generationFailed
        var errorDescription: String? { "オンデバイス LLM の生成に失敗しました" }
    }

    private static func generate(prompt: String, schema: GenerationSchema) async throws -> String {
        // A fresh session per request keeps us inside the on-device model's small context window.
        let session = LanguageModelSession(instructions: Prompt.instructions)
        let response = try await session.respond(
            to: prompt, schema: schema,
            options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 500)
        )
        let json = response.content.jsonString
        if ProcessInfo.processInfo.environment["MC_DEBUG"] != nil { print("raw: \(json)") }
        return json
    }

    /// Removes JSON debris the model occasionally leaks into string values.
    static func clean(_ s: String) -> String {
        // Natural text never contains JSON brackets; anything after one is leaked structure.
        var t = String(s.prefix { !"{}[]".contains($0) })
        t = t.replacingOccurrences(of: #"[",\s」]+$"#, with: "", options: .regularExpression)
        // Keep 」 only when it closes a 「 that is actually present.
        if t.filter({ $0 == "「" }).count > t.filter({ $0 == "」" }).count { t += "」" }
        if t.hasSuffix("."), !t.hasSuffix(".."), t.unicodeScalars.contains(where: { $0.value > 0x3000 }) {
            t = String(t.dropLast()) + "。"
        }
        if t.count > 200 { t = String(t.prefix(200)) + "…" }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func supplementsSchema() throws -> GenerationSchema {
        let supplement = DynamicGenerationSchema(name: "Supplement", properties: [
            .init(name: "term", description: "会話に出てきた専門用語・固有名詞・概念", schema: .init(type: String.self)),
            .init(name: "explanation", description: "その用語の簡潔な説明や背景知識。1〜2文", schema: .init(type: String.self)),
        ])
        let root = DynamicGenerationSchema(name: "Supplements", properties: [
            .init(name: "supplements", description: "会話の理解を助ける補足情報",
                  schema: .init(arrayOf: .init(referenceTo: "Supplement"), maximumElements: 3)),
        ])
        return try GenerationSchema(root: root, dependencies: [supplement])
    }

    private static func questionsSchema() throws -> GenerationSchema {
        let root = DynamicGenerationSchema(name: "Questions", properties: [
            .init(name: "questions", description: "会議の参加者として今聞くと議論が深まる質問。1文ずつ",
                  schema: .init(arrayOf: .init(type: String.self), maximumElements: 3)),
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }
}

// MARK: - Ollama (localhost)

struct OllamaProvider: InsightProvider {
    var model: String
    var endpoint = URL(string: "http://127.0.0.1:11434/api/chat")!

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "supplements": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["term": ["type": "string"], "explanation": ["type": "string"]],
                    "required": ["term", "explanation"],
                ],
            ],
            "questions": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["supplements", "questions"],
    ]

    func analyze(transcript: String, screen: String, alreadyShown: [String]) async throws -> Insights {
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "think": false,
            "format": Self.schema,
            "options": ["temperature": 0.3],
            "messages": [
                ["role": "system", "content": Prompt.instructions],
                ["role": "user", "content": Prompt.user(transcript: transcript, screen: screen, alreadyShown: alreadyShown)],
            ],
        ]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Ollama", code: 1, userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        struct ChatResponse: Decodable { struct Message: Decodable { let content: String }; let message: Message }
        let content = try JSONDecoder().decode(ChatResponse.self, from: data).message.content
        var insights = try JSONDecoder().decode(Insights.self, from: Data(content.utf8))
        insights.supplements = Array(insights.supplements.prefix(3))
        insights.questions = Array(insights.questions.prefix(3))
        return insights
    }
}
