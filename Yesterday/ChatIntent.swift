import Foundation

/// Query text for embedding search.
struct PhotoIntent: Codable, Sendable, Equatable {
    var semantic: String
    var visual: String?

    static func semanticOnly(_ text: String) -> PhotoIntent {
        PhotoIntent(semantic: text, visual: text)
    }

    var summary: String {
        if let visual, !visual.isEmpty { return visual }
        return semantic
    }
}

struct ChatTurn: Identifiable, Sendable {
    let id: UUID
    var userText: String
    var intent: PhotoIntent
    var resultIDs: [String]

    init(
        id: UUID = UUID(),
        userText: String,
        intent: PhotoIntent,
        resultIDs: [String]
    ) {
        self.id = id
        self.userText = userText
        self.intent = intent
        self.resultIDs = resultIDs
    }
}

@MainActor
final class ChatSession {
    private(set) var turns: [ChatTurn] = []
    private let maxTurns = 20
    private let keepResultIDs = 5

    var current: ChatTurn? { turns.last }

    func append(_ turn: ChatTurn) {
        turns.append(turn)
        trim()
    }

    @discardableResult
    func pop() -> ChatTurn? {
        guard turns.count >= 2 else { return turns.last }
        turns.removeLast()
        return turns.last
    }

    private func trim() {
        if turns.count > maxTurns {
            turns = Array(turns.suffix(maxTurns))
        }
        let dropBefore = max(0, turns.count - keepResultIDs)
        for i in 0..<dropBefore {
            turns[i].resultIDs = []
        }
    }
}
