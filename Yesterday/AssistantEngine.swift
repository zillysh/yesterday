import Foundation
import FoundationModels

struct AssistantReply: Sendable {
    let text: String
    let photoIDs: [String]
    let title: String
}

@MainActor
final class AssistantEngine {
    private var session: LanguageModelSession?

    var modelNote: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "On-device"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence for chat"
        case .unavailable(.modelNotReady):
            return "Downloading Apple Intelligence"
        case .unavailable(.deviceNotEligible):
            return "On-device model unavailable"
        @unknown default:
            return "Using local photo search"
        }
    }

    func reply(to userText: String, history: [ChatMessage] = []) async -> AssistantReply {
        await PhotoLibraryService.shared.refresh()
        PhotoLibraryService.shared.beginTurn()

        // Date/range questions are answered by Photos, not the language model.
        // The on-device model was treating "Saturday" as today (Friday).
        if DatePhrase.range(in: userText) != nil, !needsModelJudgment(userText) {
            return HeuristicAssistant.reply(to: userText)
        }

        if case .available = SystemLanguageModel.default.availability {
            do {
                return try await modelReply(userText, history: history)
            } catch {
                return HeuristicAssistant.reply(to: userText)
            }
        }
        return HeuristicAssistant.reply(to: userText)
    }

    private func needsModelJudgment(_ text: String) -> Bool {
        let lower = text.lowercased()
        let cues = [
            "indoor", "outdoor", "golden", "blurry", "screenshot", "vibe",
            "dinner", "night", "portrait", "selfie", "best", "worst", "keep the", "drop the",
        ]
        return cues.contains { lower.contains($0) }
    }

    private func modelReply(_ userText: String, history: [ChatMessage]) async throws -> AssistantReply {
        let instructions = """
        You are Yesterday, a photo posting assistant in iMessage.
        Today is whatever the prompt says. Never call today Saturday unless today is Saturday.
        If the prompt includes Resolved dates, search only that range.
        The Post album is the destination. Do not preview Post album photos unless they asked to edit Post.
        Never show leftover photos from an earlier message.
        If search is empty, say so. Do not classify or list some other day.
        Always use tools. Never invent photo IDs.
        After a matching search, call previewSet with those IDs.
        Speak briefly, like a text. Do not write numbered scene labels unless they asked what is in the photos.
        """

        let session = LanguageModelSession(
            tools: PhotoToolset.all,
            instructions: instructions
        )
        self.session = session

        let recent = history.suffix(6).map { message in
            let who = message.role == .user ? "Person" : "Yesterday"
            return "\(who): \(message.text)"
        }.joined(separator: "\n")

        let todayName = PhotoFormatting.shortDay.string(from: Date())
        let weekday = DateFormatter.weekdayName.string(from: Date())
        let resolved: String
        if let range = DatePhrase.range(in: userText) {
            let start = ISO8601DateFormatter.day.string(from: range.start)
            let end = ISO8601DateFormatter.day.string(from: range.end)
            resolved = "Resolved dates: \(range.label) starts \(start) and ends before \(end). Today is \(weekday), \(todayName) — that is not \(range.label)."
        } else {
            resolved = "Today is \(weekday), \(todayName)."
        }

        let prompt = """
        \(PhotoLibraryService.shared.libraryContext())
        \(resolved)
        Recent chat (do not reuse those photo sets unless they asked to keep editing them):
        \(recent)

        Current request (honor this): \(userText)
        """

        let response = try await session.respond(to: prompt)
        let preview = PhotoLibraryService.shared.consumePreview()
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return AssistantReply(text: text, photoIDs: preview.ids, title: preview.title)
    }
}

enum HeuristicAssistant {
    @MainActor
    static func reply(to userText: String) -> AssistantReply {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let library = PhotoLibraryService.shared

        if looksLikeSave(lower) {
            let ids = library.lastResultIDs
            if ids.isEmpty {
                return AssistantReply(text: "Tell me a day first — like last Saturday or last weekend.", photoIDs: [], title: "")
            }
            return AssistantReply(
                text: "These \(ids.count) stay selected. Tap Save to Post to put them in the album.",
                photoIDs: ids,
                title: "Post"
            )
        }

        if looksLikeListAlbums(lower) {
            return AssistantReply(text: library.listAlbumsText(), photoIDs: [], title: "")
        }

        if let range = DatePhrase.range(in: text) {
            let part = DayPart.parse(lower)
            let span = range.end.timeIntervalSince(range.start)
            let askedDay = Calendar.current.startOfDay(for: range.start)
            let asked = "\(range.label) (\(PhotoFormatting.shortDay.string(from: askedDay)))"
            if span <= 72 * 3600 {
                return photosReply(
                    library.eventPhotos(on: Self.days(in: range), part: part),
                    asked: asked
                )
            }
            return photosReply(
                library.search(
                    start: range.start,
                    end: range.end,
                    favoritesOnly: lower.contains("favorite"),
                    albumName: nil,
                    limit: 120
                ),
                asked: asked
            )
        }

        if looksLikeGroup(lower) {
            let groups = library.clusterRecent(dayCount: 14, maxGroups: 8)
            if groups.isEmpty {
                return AssistantReply(text: "No days in the last two weeks in the library I can see.", photoIDs: [], title: "")
            }
            let body = groups.map { group in
                "\(PhotoFormatting.shortDay.string(from: group.day)): \(group.photos.count)"
            }.joined(separator: "\n")
            return AssistantReply(
                text: "Days I can see:\n\(body)\nName one of those days and I’ll open that set.",
                photoIDs: [],
                title: ""
            )
        }

        if let album = matchingAlbum(in: lower, library: library) {
            return photosReply(
                library.search(start: nil, end: nil, favoritesOnly: false, albumName: album.title, limit: 120),
                asked: "album \(album.title)"
            )
        }

        return AssistantReply(
            text: "I need a day or range so I don’t pull the wrong set. Try last Saturday, last weekend, last week, or a date.",
            photoIDs: [],
            title: ""
        )
    }

    @MainActor
    private static func photosReply(_ photos: [PhotoSummary], asked: String) -> AssistantReply {
        _ = PhotoLibraryService.shared.preview(ids: photos.map(\.localIdentifier), title: asked)
        let preview = PhotoLibraryService.shared.consumePreview()
        if photos.isEmpty {
            let extra = PhotoLibraryService.shared.accessNote().map { "\n\($0)" } ?? " If Photos access is limited, tap More Photos."
            return AssistantReply(
                text: "Nothing for \(asked) in Camera Roll. Today is \(PhotoFormatting.shortDay.string(from: Date())).\(extra)",
                photoIDs: [],
                title: asked
            )
        }
        var text = "\(photos.count) Camera Roll photos for \(asked)."
        if let note = PhotoLibraryService.shared.accessNote() {
            text += "\n\(note)"
        } else {
            text += " Night that ran past midnight stays together. Morning after a gap is a new day. Say morning if you want breakfast."
        }
        return AssistantReply(text: text, photoIDs: preview.ids, title: asked)
    }

    private static func days(in range: (start: Date, end: Date, label: String)) -> [Date] {
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: range.start)
        let last = calendar.startOfDay(for: range.end.addingTimeInterval(-1))
        var days: [Date] = []
        while day <= last {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    @MainActor
    private static func matchingAlbum(in lower: String, library: PhotoLibraryService) -> AlbumSummary? {
        library.albums
            .filter { $0.title.count >= 3 }
            .first { lower.contains($0.title.lowercased()) }
    }

    private static func looksLikeSave(_ lower: String) -> Bool {
        lower.contains("save") || lower.contains("add to post") || lower.contains("put in post")
            || lower.contains("that's the set") || lower.contains("thats the set")
            || lower.contains("use these")
    }

    private static func looksLikeListAlbums(_ lower: String) -> Bool {
        lower.contains("album") && (lower.contains("list") || lower.contains("what") || lower.contains("show"))
    }

    private static func looksLikeGroup(_ lower: String) -> Bool {
        lower.contains("group") || lower.contains("cluster") || lower.contains("by day")
            || lower.contains("what days") || lower.contains("which days")
    }
}

enum DayPart {
    case allDay, morning, afternoon, evening, posting

    static func parse(_ lower: String) -> DayPart {
        if lower.contains("all day") || lower.contains("whole day") || lower.contains("entire day") {
            return .allDay
        }
        if lower.contains("morning") { return .morning }
        if lower.contains("afternoon") { return .afternoon }
        if lower.contains("night") || lower.contains("evening") { return .evening }
        return .posting
    }
}

enum DatePhrase {
    static func range(in text: String) -> (start: Date, end: Date, label: String)? {
        let lower = text.lowercased()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        if lower.contains("yesterday") {
            return sliceDay(calendar.date(byAdding: .day, value: -1, to: today)!, part: DayPart.parse(lower), label: "yesterday")
        }
        if lower.contains("today") {
            return sliceDay(today, part: DayPart.parse(lower), label: "today")
        }
        if lower.contains("last weekend") {
            return weekend(endingBefore: today, label: "last weekend")
        }
        if lower.contains("this weekend") {
            let end = calendar.date(byAdding: .day, value: 1, to: today)!
            return weekend(endingBefore: end, label: "this weekend")
        }
        if lower.contains("weekend") {
            return weekend(endingBefore: today, label: "the weekend")
        }
        if lower.contains("last week") {
            let thisWeek = weekStart(for: today)
            let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek)!
            return (lastWeek, thisWeek, "last week")
        }
        if lower.contains("this week") {
            let end = calendar.date(byAdding: .day, value: 1, to: today)!
            return (weekStart(for: today), end, "this week")
        }
        if lower.contains("last month") {
            let comps = calendar.dateComponents([.year, .month], from: today)
            let thisMonth = calendar.date(from: comps)!
            let lastMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth)!
            return (lastMonth, thisMonth, "last month")
        }

        let names: [(Int, String)] = [
            (1, "sunday"), (2, "monday"), (3, "tuesday"), (4, "wednesday"),
            (5, "thursday"), (6, "friday"), (7, "saturday"),
        ]
        for (weekday, name) in names where lower.contains(name) {
            return namedWeekday(weekday, name: name, in: lower, today: today)
        }

        if let iso = extractISO(from: lower), let day = PhotoFormatting.isoDate(iso) {
            return sliceDay(day, part: DayPart.parse(lower), label: PhotoFormatting.shortDay.string(from: day))
        }

        return detectedRange(in: text, today: today)
    }

    private static func namedWeekday(
        _ weekday: Int,
        name: String,
        in lower: String,
        today: Date
    ) -> (start: Date, end: Date, label: String) {
        let calendar = Calendar.current
        let current = calendar.component(.weekday, from: today)
        let wantsLast = lower.contains("last \(name)")
        let startOfDay: Date
        if !wantsLast, current == weekday {
            startOfDay = today
        } else {
            var delta = current - weekday
            if delta <= 0 { delta += 7 }
            startOfDay = calendar.date(byAdding: .day, value: -delta, to: today)!
        }
        return sliceDay(startOfDay, part: DayPart.parse(lower), label: name.capitalized)
    }

    private static func weekend(
        endingBefore day: Date,
        label: String
    ) -> (start: Date, end: Date, label: String) {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: day)
        let saturday: Date
        if weekday == 7 {
            saturday = day
        } else if weekday == 1 {
            saturday = calendar.date(byAdding: .day, value: -1, to: day)!
        } else {
            var delta = weekday - 7
            if delta <= 0 { delta += 7 }
            saturday = calendar.date(byAdding: .day, value: -delta, to: day)!
        }
        let monday = calendar.date(byAdding: .day, value: 2, to: saturday)!
        return (saturday, monday, label)
    }

    private static func sliceDay(
        _ startOfDay: Date,
        part: DayPart,
        label: String
    ) -> (start: Date, end: Date, label: String) {
        let calendar = Calendar.current
        let next = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        func hour(_ value: Int) -> Date {
            calendar.date(bySettingHour: value, minute: 0, second: 0, of: startOfDay) ?? startOfDay
        }
        switch part {
        case .allDay:
            return (startOfDay, next, label)
        case .morning:
            return (startOfDay, hour(12), "\(label) morning")
        case .afternoon:
            return (hour(12), hour(17), "\(label) afternoon")
        case .evening:
            return (hour(17), next, "\(label) night")
        case .posting:
            return (startOfDay, next, label)
        }
    }

    private static func weekStart(for day: Date) -> Date {
        var calendar = Calendar.current
        calendar.firstWeekday = 1
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: day)
        return calendar.date(from: comps) ?? day
    }

    private static func detectedRange(in text: String, today: Date) -> (start: Date, end: Date, label: String)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = detector.firstMatch(in: text, options: [], range: range), let date = match.date else {
            return nil
        }
        let start = Calendar.current.startOfDay(for: date)
        if start > today { return nil }
        let span = max(match.duration, 0)
        let end: Date
        if span >= 86_400 {
            end = start.addingTimeInterval(span)
        } else {
            end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        }
        return (start, end, PhotoFormatting.shortDay.string(from: start))
    }

    private static func extractISO(from lower: String) -> String? {
        let pattern = #"\d{4}-\d{2}-\d{2}"#
        guard let range = lower.range(of: pattern, options: .regularExpression) else { return nil }
        return String(lower[range])
    }
}

extension PhotoFormatting {
    static let shortDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter
    }()
}

extension DateFormatter {
    static let weekdayName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()
}

extension ISO8601DateFormatter {
    static let day: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        formatter.timeZone = TimeZone.current
        return formatter
    }()
}
