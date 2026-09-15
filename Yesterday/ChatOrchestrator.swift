import Foundation
import CoreGraphics

/// Chat layer: raw text → embedding search.
@MainActor
final class ChatOrchestrator {
    let session = ChatSession()

    func handle(
        _ userText: String,
        library: PhotoLibraryService,
        history: [ChatMessage] = []
    ) async -> AssistantReply {
        _ = history
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        library.beginTurn()

        if isUndo(lower) {
            guard let previous = session.pop(), !previous.resultIDs.isEmpty else {
                return AssistantReply(text: "Nothing to go back to.", photoIDs: [], title: "")
            }
            let photos = library.summaries(for: previous.resultIDs)
            return reply(
                photos: photos,
                asked: previous.intent.summary,
                note: nil,
                spoken: "Back to the previous set."
            )
        }

        if isAccess(lower) {
            if library.isLimited {
                return AssistantReply(
                    text: "Not fully — Photos is on Limited. Tap More Photos and choose Keep All Photos.",
                    photoIDs: [],
                    title: ""
                )
            }
            if library.canRead {
                return AssistantReply(text: "Yes — full Camera Roll access.", photoIDs: [], title: "")
            }
            return AssistantReply(text: "Photos access is off. Allow Photos in Settings.", photoIDs: [], title: "")
        }

        let intent = PhotoIntent.semanticOnly(text)
        let result = await library.photosForQuery(text)

        session.append(
            ChatTurn(
                userText: text,
                intent: intent,
                resultIDs: result.photos.map(\.localIdentifier)
            )
        )

        return reply(
            photos: result.photos,
            asked: result.asked,
            note: result.note,
            spoken: ""
        )
    }

    private func reply(
        photos: [PhotoSummary],
        asked: String,
        note: String?,
        spoken: String
    ) -> AssistantReply {
        let library = PhotoLibraryService.shared
        let ids = photos.map(\.localIdentifier)
        _ = library.preview(ids: ids, title: asked)
        _ = library.consumePreview()
        library.lastResultIDs = ids
        if !ids.isEmpty {
            library.startCachingThumbnails(
                ids: Array(ids.prefix(48)),
                size: CGSize(width: 220, height: 220)
            )
        }

        var prose: String
        if !spoken.isEmpty {
            prose = spoken
        } else if photos.isEmpty {
            prose = note ?? "No close matches yet."
        } else {
            prose = "\(photos.count) from \(asked)."
            if let note, !note.isEmpty { prose += " \(note)" }
        }
        if let access = library.accessNote() {
            prose += "\n\(access)"
        }

        let moments: [Moment] = ids.isEmpty
            ? []
            : [Moment(title: asked, subtitle: "\(ids.count) photos", photoIDs: ids, selectedIDs: [])]

        return AssistantReply(
            text: prose,
            photoIDs: ids,
            title: asked,
            moments: moments
        )
    }

    private func isUndo(_ lower: String) -> Bool {
        lower == "undo" || lower == "go back" || lower == "back"
    }

    private func isAccess(_ lower: String) -> Bool {
        (lower.contains("access") || lower.contains("permission"))
            && (lower.contains("photo") || lower.contains("full") || lower.contains("library"))
    }
}
