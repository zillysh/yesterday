import Foundation
import FoundationModels

/// Turns what you type into a photo search. Dates go straight to Photos.

struct AssistantReply: Sendable {
    let text: String
    let photoIDs: [String]
    let title: String
    var moments: [Moment] = []
    var choices: [SearchChoice] = []
}

@MainActor
final class AssistantEngine {
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
        _ = history
        await PhotoLibraryService.shared.refresh()
        PhotoLibraryService.shared.beginTurn()
        return await HeuristicAssistant.reply(to: userText)
    }
}

enum HeuristicAssistant {
    @MainActor
    static func reply(to userText: String) async -> AssistantReply {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let library = PhotoLibraryService.shared

        if looksLikeSave(lower) {
            let ids = library.lastResultIDs
            if ids.isEmpty {
                return AssistantReply(text: "Pick a set first — try Recents, yesterday, or type what you’re looking for.", photoIDs: [], title: "")
            }
            return AssistantReply(
                text: "These \(ids.count) stay selected. Open the stack and save the ones you want to Post.",
                photoIDs: ids,
                title: "Post"
            )
        }

        if looksLikeAccess(lower) {
            if library.isLimited {
                return AssistantReply(
                    text: "Not fully — Photos is on Limited. Tap More Photos and choose Keep All Photos so trips and places can show up.",
                    photoIDs: [],
                    title: ""
                )
            }
            if library.canRead {
                return AssistantReply(
                    text: "Yes — full Camera Roll access. Type a trip, a person from Photos, or a day.",
                    photoIDs: [],
                    title: ""
                )
            }
            return AssistantReply(text: "Photos access is off. Allow Photos in Settings.", photoIDs: [], title: "")
        }

        if looksLikeListAlbums(lower) {
            return AssistantReply(text: library.listAlbumsText(), photoIDs: [], title: "")
        }

        let result = await library.photosForQuery(text)
        return photosReply(
            result.photos,
            asked: result.asked,
            extra: result.note,
            choices: result.choices
        )
    }

    @MainActor
    private static func photosReply(
        _ photos: [PhotoSummary],
        asked: String,
        extra: String? = nil,
        choices: [SearchChoice] = []
    ) -> AssistantReply {
        if !choices.isEmpty {
            return AssistantReply(
                text: extra ?? "Which one?",
                photoIDs: [],
                title: asked,
                moments: [],
                choices: choices
            )
        }
        _ = PhotoLibraryService.shared.preview(ids: photos.map(\.localIdentifier), title: asked)
        let preview = PhotoLibraryService.shared.consumePreview()
        if photos.isEmpty {
            let message = extra ?? PhotoLibraryService.shared.accessNote() ?? "If Photos access is limited, tap More Photos."
            let text = extra == nil
                ? "Nothing for \(asked) in Camera Roll. \(message)"
                : extra ?? message
            return AssistantReply(text: text, photoIDs: [], title: asked)
        }
        var text = "Hey, here are \(photos.count) photos from \(asked)."
        if let extra, !extra.isEmpty {
            text = extra
        }
        if let note = PhotoLibraryService.shared.accessNote() {
            text += "\n\(note)"
        }
        let ids = preview.ids
        let moment = Moment(
            title: asked,
            subtitle: "\(ids.count) photos",
            photoIDs: ids,
            selectedIDs: []
        )
        return AssistantReply(text: text, photoIDs: ids, title: asked, moments: ids.isEmpty ? [] : [moment])
    }

    private static func looksLikeSave(_ lower: String) -> Bool {
        lower.contains("save") || lower.contains("add to post") || lower.contains("put in post")
            || lower.contains("that's the set") || lower.contains("thats the set")
            || lower.contains("use these")
    }

    private static func looksLikeListAlbums(_ lower: String) -> Bool {
        lower.contains("album") && (lower.contains("list") || lower.contains("what") || lower.contains("show"))
    }

    private static func looksLikeAccess(_ lower: String) -> Bool {
        (lower.contains("access") || lower.contains("permission"))
            && (lower.contains("photo") || lower.contains("full") || lower.contains("library"))
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

    static let albumRange: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    static let tripDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
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
