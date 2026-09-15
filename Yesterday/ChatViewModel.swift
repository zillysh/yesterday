import Foundation
import Observation
import SwiftUI

/// Chat data: messages, sending, save to the Post album.

struct SearchChoice: Identifiable, Equatable, Sendable {
    let id: UUID
    let label: String
    /// Ready-made set, or empty when `query` should run a new search.
    let photoIDs: [String]
    /// If set, tapping this runs the search again with this text.
    var query: String?

    init(id: UUID = UUID(), label: String, photoIDs: [String] = [], query: String? = nil) {
        self.id = id
        self.label = label
        self.photoIDs = photoIDs
        self.query = query
    }
}

/// One stretch of photos — a night, a morning, an afternoon.
struct Moment: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var subtitle: String
    var photoIDs: [String]
    var selectedIDs: [String]
    var savedToPost: Bool

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        photoIDs: [String],
        selectedIDs: [String] = [],
        savedToPost: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.photoIDs = photoIDs
        self.selectedIDs = selectedIDs
        self.savedToPost = savedToPost
    }
}

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
    var moments: [Moment]
    var choices: [SearchChoice]
    var savedToPost: Bool
    let createdAt: Date

    static func user(_ text: String) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: .user,
            text: text,
            photoIDs: [],
            selectedIDs: [],
            moments: [],
            choices: [],
            savedToPost: false,
            createdAt: Date()
        )
    }

    static func assistant(_ reply: AssistantReply) -> ChatMessage {
        let moments = reply.moments.isEmpty && !reply.photoIDs.isEmpty
            ? [Moment(title: reply.title, subtitle: "", photoIDs: reply.photoIDs, selectedIDs: [])]
            : reply.moments
        return ChatMessage(
            id: UUID(),
            role: .assistant,
            text: reply.text,
            photoIDs: reply.photoIDs,
            selectedIDs: Set(moments.flatMap(\.selectedIDs)),
            moments: moments,
            choices: reply.choices,
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
    var dateChips: [DateChip] = []
    var isSending = false
    var saveError: String?

    private let engine = AssistantEngine()

    var modelNote: String { engine.modelNote }

    var canSend: Bool {
        !isSending && (
            !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !dateChips.isEmpty
        )
    }

    /// Promote a finished date phrase into a pill (space after date, or on send).
    func tokenizeDraftDates(force: Bool = false) {
        guard dateChips.isEmpty else { return }
        // Prefer exact phrases while typing; detector only on send.
        guard let match = DatePhrase.extract(from: draft, allowDetector: force),
              DatePhrase.isCompleteForChip(match, in: draft, force: force)
        else { return }

        var next = draft
        if let range = next.range(of: match.matchedText, options: .caseInsensitive) {
            next.removeSubrange(range)
        }
        next = next
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(.easeOut(duration: 0.15)) {
            dateChips = [DateChip(match: match)]
            draft = next
        }
    }

    func removeDateChip(_ id: UUID) {
        dateChips.removeAll { $0.id == id }
    }

    func sendPreset(_ text: String) async {
        draft = text
        dateChips = []
        tokenizeDraftDates(force: true)
        await send()
    }

    func send() async {
        tokenizeDraftDates(force: true)
        let visual = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let chip = dateChips.first
        guard canSend else { return }

        let display: String = {
            switch (chip?.label, visual.isEmpty) {
            case (let label?, false): return "\(label) · \(visual)"
            case (let label?, true): return label
            default: return visual
            }
        }()

        draft = ""
        let chipsSnapshot = dateChips
        dateChips = []
        messages.append(.user(display))
        isSending = true
        defer { isSending = false }

        if isEditingCurrentSet(visual.isEmpty ? display : visual),
           let kept = messages.last(where: { $0.role == .assistant && !$0.photoIDs.isEmpty })
        {
            PhotoLibraryService.shared.lastResultIDs = Array(kept.selectedIDs)
        }

        let reply = await engine.reply(
            to: visual,
            date: chipsSnapshot.first?.match,
            history: messages
        )
        messages.append(.assistant(reply))
    }

    func toggle(photo id: String, in messageID: UUID, momentID: UUID) {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              let momentIndex = messages[messageIndex].moments.firstIndex(where: { $0.id == momentID })
        else { return }
        if messages[messageIndex].moments[momentIndex].selectedIDs.contains(id) {
            messages[messageIndex].moments[momentIndex].selectedIDs.removeAll { $0 == id }
        } else {
            messages[messageIndex].moments[momentIndex].selectedIDs.append(id)
        }
        let selected = messages[messageIndex].moments.flatMap(\.selectedIDs)
        messages[messageIndex].selectedIDs = Set(selected)
        PhotoLibraryService.shared.lastResultIDs = selected
    }

    func pickChoice(_ choice: SearchChoice) {
        guard !isSending else { return }
        if let query = choice.query, !query.isEmpty {
            draft = query
            Task { await send() }
            return
        }
        guard !choice.photoIDs.isEmpty else { return }
        messages.append(.user(choice.label))
        let moment = Moment(
            title: choice.label,
            subtitle: "\(choice.photoIDs.count) photos",
            photoIDs: choice.photoIDs,
            selectedIDs: []
        )
        messages.append(
            ChatMessage(
                id: UUID(),
                role: .assistant,
                text: "Here are \(choice.photoIDs.count) photos from \(choice.label).",
                photoIDs: choice.photoIDs,
                selectedIDs: [],
                moments: [moment],
                choices: [],
                savedToPost: false,
                createdAt: Date()
            )
        )
        PhotoLibraryService.shared.lastResultIDs = choice.photoIDs
        _ = PhotoLibraryService.shared.preview(ids: choice.photoIDs, title: choice.label)
        _ = PhotoLibraryService.shared.consumePreview()
    }

    private func isEditingCurrentSet(_ text: String) -> Bool {
        let lower = text.lowercased()
        if DatePhrase.range(in: text) != nil { return false }
        return lower.contains("drop") || lower.contains("keep") || lower.contains("remove")
            || lower.contains("these") || lower.contains("those") || lower.contains("save")
            || lower.contains("indoor") || lower.contains("blurry") || lower.contains("screenshot")
    }

    func saveToPost(messageID: UUID, momentID: UUID) async {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              let momentIndex = messages[messageIndex].moments.firstIndex(where: { $0.id == momentID })
        else { return }
        let ids = messages[messageIndex].moments[momentIndex].selectedIDs
        guard !ids.isEmpty else { return }
        let rawTitle = messages[messageIndex].moments[momentIndex].title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = Self.albumTitle(from: rawTitle.isEmpty ? "Post" : rawTitle)
        do {
            let albumID = try await PhotoLibraryService.shared.createSavedAlbum(title: title, ids: ids)
            SavedPostsStore.shared.add(title: title, albumID: albumID, photoIDs: ids)
            messages[messageIndex].moments[momentIndex].savedToPost = true
            messages.append(
                ChatMessage(
                    id: UUID(),
                    role: .assistant,
                    text: "Saved to Posts as “\(title)”. It’s a Photos album too — Instagram can pick from it.",
                    photoIDs: [],
                    selectedIDs: [],
                    moments: [],
                    choices: [],
                    savedToPost: true,
                    createdAt: Date()
                )
            )
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    private static func albumTitle(from name: String) -> String {
        let stamp = DateFormatter.tripDay.string(from: Date())
        let clipped = String(name.prefix(40))
        return "\(clipped) · \(stamp)"
    }
}
