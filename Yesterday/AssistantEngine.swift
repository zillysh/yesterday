import Foundation
import FoundationModels

/// Turns what you type into an embedding photo search.

enum PhotoFormatting {
    static func isoDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        if let date = iso.date(from: String(raw.prefix(10))) {
            return Calendar.current.startOfDay(for: date)
        }
        return ISO8601DateFormatter().date(from: raw)
    }
}

struct AssistantReply: Sendable {
    let text: String
    let photoIDs: [String]
    let title: String
    var moments: [Moment] = []
    var choices: [SearchChoice] = []
}

@MainActor
final class AssistantEngine {
    private let orchestrator = ChatOrchestrator()

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
        // Do not refresh the whole library on every message — that blocked search
        // and raced the embedding index. ChatView already refreshes on appear.
        return await orchestrator.handle(userText, library: .shared, history: history)
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
    static func range(in text: String, usingDetector: Bool = true) -> (start: Date, end: Date, label: String)? {
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
        if lower.contains("this month") {
            let comps = calendar.dateComponents([.year, .month], from: today)
            let thisMonth = calendar.date(from: comps)!
            let next = calendar.date(byAdding: .month, value: 1, to: thisMonth)!
            return (thisMonth, next, "this month")
        }

        if let monthYear = monthYearRange(in: lower, today: today) {
            return monthYear
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

        if usingDetector {
            return detectedRange(in: text, today: today)
        }
        return nil
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

    private static func monthYearRange(
        in lower: String,
        today: Date
    ) -> (start: Date, end: Date, label: String)? {
        let months: [(String, Int)] = [
            ("january", 1), ("jan", 1),
            ("february", 2), ("feb", 2),
            ("march", 3), ("mar", 3),
            ("april", 4), ("apr", 4),
            ("may", 5),
            ("june", 6), ("jun", 6),
            ("july", 7), ("jul", 7),
            ("august", 8), ("aug", 8),
            ("september", 9), ("sept", 9), ("sep", 9),
            ("october", 10), ("oct", 10),
            ("november", 11), ("nov", 11),
            ("december", 12), ("dec", 12),
        ]
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: today)

        // "june 2025" / "jun 2025"
        for (name, month) in months {
            let pattern = #"\b\#(name)\s+(\d{4})\b"#
            if let match = lower.range(of: pattern, options: .regularExpression) {
                let chunk = String(lower[match])
                let yearStr = chunk.split(whereSeparator: { !$0.isNumber }).first.map(String.init)
                guard let yearStr, let year = Int(yearStr),
                      let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                      let end = calendar.date(byAdding: .month, value: 1, to: start)
                else { continue }
                let label = DateFormatter.monthYear.string(from: start)
                return (start, end, label)
            }
        }

        // Bare "june" / "in june" → most recent occurrence of that month (not future)
        for (name, month) in months {
            let pattern = #"\b\#(name)\b"#
            guard lower.range(of: pattern, options: .regularExpression) != nil else { continue }
            var year = currentYear
            var start = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
            if start > today {
                year -= 1
                start = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
            }
            let end = calendar.date(byAdding: .month, value: 1, to: start)!
            let label = DateFormatter.monthYear.string(from: start)
            return (start, end, label)
        }
        return nil
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

    static let monthYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
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
