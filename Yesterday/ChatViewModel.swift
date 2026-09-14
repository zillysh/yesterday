import Foundation
import Observation

struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    var photoIDs: [String]
    var selectedIDs: Set<String>
    var savedToPost: Bool
    let createdAt: Date

    static func user(_ text: String) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: .user,
            text: text,
            photoIDs: [],
            selectedIDs: [],
            savedToPost: false,
            createdAt: Date()
        )
    }

    static func assistant(_ reply: AssistantReply) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: .assistant,
            text: reply.text,
            photoIDs: reply.photoIDs,
            selectedIDs: Set(reply.photoIDs),
            savedToPost: false,
            createdAt: Date()
        )
    }
}

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var draft = ""
    var isSending = false
    var saveError: String?

    private let engine = AssistantEngine()

    var modelNote: String { engine.modelNote }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        draft = ""
        messages.append(.user(text))
        isSending = true
        defer { isSending = false }

        if isEditingCurrentSet(text), let kept = messages.last(where: { $0.role == .assistant && !$0.photoIDs.isEmpty }) {
            PhotoLibraryService.shared.lastResultIDs = Array(kept.selectedIDs)
        }

        let reply = await engine.reply(to: text, history: messages)
        messages.append(.assistant(reply))
    }

    func toggle(photo id: String, in messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        if messages[index].selectedIDs.contains(id) {
            messages[index].selectedIDs.remove(id)
        } else {
            messages[index].selectedIDs.insert(id)
        }
        PhotoLibraryService.shared.lastResultIDs = Array(messages[index].selectedIDs)
    }

    private func isEditingCurrentSet(_ text: String) -> Bool {
        let lower = text.lowercased()
        if DatePhrase.range(in: text) != nil { return false }
        return lower.contains("drop") || lower.contains("keep") || lower.contains("remove")
            || lower.contains("these") || lower.contains("those") || lower.contains("save")
            || lower.contains("indoor") || lower.contains("blurry") || lower.contains("screenshot")
    }

    func saveToPost(messageID: UUID) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let ids = messages[index].photoIDs.filter { messages[index].selectedIDs.contains($0) }
        guard !ids.isEmpty else { return }
        do {
            let status = try await PhotoLibraryService.shared.updatePostAlbum(action: "replace", ids: ids)
            messages[index].savedToPost = true
            messages.append(
                ChatMessage(
                    id: UUID(),
                    role: .assistant,
                    text: "\(status) Instagram can pick from that album.",
                    photoIDs: [],
                    selectedIDs: [],
                    savedToPost: true,
                    createdAt: Date()
                )
            )
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}
