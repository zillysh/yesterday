import Foundation

/// A calendar constraint parsed from chat (absolute window or month/day without year).
struct DateChip: Identifiable, Equatable, Sendable {
    let id: UUID
    var label: String
    var matchedText: String
    var constraint: DateConstraint

    init(id: UUID = UUID(), match: DatePhrase.Match) {
        self.id = id
        self.label = match.label
        self.matchedText = match.matchedText
        self.constraint = match.constraint
    }

    var match: DatePhrase.Match {
        DatePhrase.Match(label: label, matchedText: matchedText, constraint: constraint)
    }
}

enum DateConstraint: Equatable, Sendable {
    /// Concrete window, e.g. last weekend or Aug 7, 2025.
    case absolute(start: Date, end: Date)
    /// Day+month in any year, e.g. "7th aug".
    case monthDay(month: Int, day: Int)
    /// Month in any year, e.g. "august".
    case monthOnly(month: Int)

    func contains(_ date: Date) -> Bool {
        let calendar = Calendar.current
        switch self {
        case .absolute(let start, let end):
            return date >= start && date < end
        case .monthDay(let month, let day):
            let parts = calendar.dateComponents([.month, .day], from: date)
            return parts.month == month && parts.day == day
        case .monthOnly(let month):
            return calendar.component(.month, from: date) == month
        }
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
    struct Match: Equatable, Sendable {
        var label: String
        var matchedText: String
        var constraint: DateConstraint
    }

    static func range(in text: String, usingDetector: Bool = true) -> (start: Date, end: Date, label: String)? {
        guard let match = extract(from: text, allowDetector: usingDetector),
              case .absolute(let start, let end) = match.constraint
        else { return nil }
        return (start, end, match.label)
    }

    static func extract(from text: String, allowDetector: Bool = true) -> Match? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let relatives: [(String, Match)] = [
            ("last weekend", absoluteMatch(weekend(endingBefore: today, label: "last weekend"), matched: "last weekend")),
            ("this weekend", absoluteMatch(
                weekend(
                    endingBefore: calendar.date(byAdding: .day, value: 1, to: today)!,
                    label: "this weekend"
                ),
                matched: "this weekend"
            )),
            ("past weekend", absoluteMatch(weekend(endingBefore: today, label: "last weekend"), matched: "past weekend")),
            ("last week", {
                let thisWeek = weekStart(for: today)
                let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek)!
                return absoluteMatch((lastWeek, thisWeek, "last week"), matched: "last week")
            }()),
            ("this week", absoluteMatch(
                (weekStart(for: today), calendar.date(byAdding: .day, value: 1, to: today)!, "this week"),
                matched: "this week"
            )),
            ("last month", {
                let comps = calendar.dateComponents([.year, .month], from: today)
                let thisMonth = calendar.date(from: comps)!
                let lastMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth)!
                return absoluteMatch((lastMonth, thisMonth, "last month"), matched: "last month")
            }()),
            ("this month", {
                let comps = calendar.dateComponents([.year, .month], from: today)
                let thisMonth = calendar.date(from: comps)!
                let next = calendar.date(byAdding: .month, value: 1, to: thisMonth)!
                return absoluteMatch((thisMonth, next, "this month"), matched: "this month")
            }()),
            ("yesterday", absoluteMatch(
                sliceDay(calendar.date(byAdding: .day, value: -1, to: today)!, part: .posting, label: "yesterday"),
                matched: "yesterday"
            )),
            ("today", absoluteMatch(sliceDay(today, part: .posting, label: "today"), matched: "today")),
        ]

        // Longer phrases first so "last weekend" wins over "last week" / "weekend".
        for (phrase, template) in relatives.sorted(by: { $0.0.count > $1.0.count }) {
            if let matched = slice(of: #"\b\#(phrase)\b"#, in: trimmed) {
                return Match(label: template.label, matchedText: matched, constraint: template.constraint)
            }
        }
        if !lower.contains("last weekend"),
           !lower.contains("this weekend"),
           !lower.contains("past weekend"),
           let matched = slice(of: #"\bweekend\b"#, in: trimmed)
        {
            let built = weekend(endingBefore: today, label: "the weekend")
            return Match(label: built.2, matchedText: matched, constraint: .absolute(start: built.0, end: built.1))
        }

        if let explicit = explicitDayMonth(in: trimmed, today: today) {
            return explicit
        }
        if let month = monthPhrase(in: trimmed, today: today) {
            return month
        }

        let names: [(Int, String)] = [
            (1, "sunday"), (2, "monday"), (3, "tuesday"), (4, "wednesday"),
            (5, "thursday"), (6, "friday"), (7, "saturday"),
        ]
        for (weekday, name) in names {
            for pattern in ["last \(name)", name] {
                if let matched = slice(of: #"\b\#(pattern)\b"#, in: trimmed) {
                    let built = namedWeekday(weekday, name: name, in: lower, today: today)
                    return Match(
                        label: built.2,
                        matchedText: matched,
                        constraint: .absolute(start: built.0, end: built.1)
                    )
                }
            }
        }

        if let iso = extractISO(from: lower),
           let day = PhotoFormatting.isoDate(iso),
           let matched = slice(of: NSRegularExpression.escapedPattern(for: iso), in: trimmed)
        {
            let built = sliceDay(day, part: .posting, label: DateFormatter.chipDay.string(from: day))
            return Match(label: built.2, matchedText: matched, constraint: .absolute(start: built.0, end: built.1))
        }

        guard allowDetector else { return nil }
        return detectedMatch(in: trimmed, today: today)
    }

    /// Commit a date pill when the phrase is finished.
    /// - Trailing space after the date, or
    /// - Next word started, or
    /// - Closed phrase complete at end of field (yesterday / last weekend / june 2025 / …), or
    /// - `force` on send
    static func isCompleteForChip(_ match: Match, in draft: String, force: Bool) -> Bool {
        if force { return true }
        guard let range = draft.range(of: match.matchedText, options: .caseInsensitive) else {
            return false
        }
        let after = draft[range.upperBound...]
        if after.first?.isWhitespace == true { return true }
        if after.isEmpty { return isClosedFinishedPhrase(match) }
        return false
    }

    /// Finished relatives / dated phrases — safe to pill with no trailing space.
    private static func isClosedFinishedPhrase(_ match: Match) -> Bool {
        let t = match.matchedText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let closed: Set<String> = [
            "yesterday", "today",
            "last weekend", "this weekend", "past weekend", "weekend",
            "last week", "this week",
            "last month", "this month",
        ]
        if closed.contains(t) { return true }
        // "june 2025", "7th aug 2025", "2025-08-07"
        if t.range(of: #"\d{4}"#, options: .regularExpression) != nil { return true }
        // "7th aug" / "aug 7" (day + month, no year)
        if t.range(of: #"\d{1,2}"#, options: .regularExpression) != nil,
           t.contains(where: \.isLetter)
        {
            return true
        }
        return false
    }

    private static func absoluteMatch(
        _ built: (Date, Date, String),
        matched: String
    ) -> Match {
        Match(label: built.2, matchedText: matched, constraint: .absolute(start: built.0, end: built.1))
    }

    private static func slice(of pattern: String, in text: String) -> String? {
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        return String(text[range])
    }

    private static let months: [(String, Int)] = [
        ("january", 1), ("jan", 1), ("february", 2), ("feb", 2),
        ("march", 3), ("mar", 3), ("april", 4), ("apr", 4), ("may", 5),
        ("june", 6), ("jun", 6), ("july", 7), ("jul", 7),
        ("august", 8), ("aug", 8), ("september", 9), ("sept", 9), ("sep", 9),
        ("october", 10), ("oct", 10), ("november", 11), ("nov", 11),
        ("december", 12), ("dec", 12),
    ]

    private static func explicitDayMonth(in text: String, today: Date) -> Match? {
        let calendar = Calendar.current

        // 7th aug 2025
        for (name, month) in months {
            let pattern = #"\b(\d{1,2})(?:st|nd|rd|th)?\s+\#(name)\s+(\d{4})\b"#
            if let matched = slice(of: pattern, in: text) {
                let nums = matched.split { !$0.isNumber }.compactMap { Int($0) }
                guard nums.count >= 2, let day = nums.first, let year = nums.last,
                      let start = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                      start <= today
                else { continue }
                let end = calendar.date(byAdding: .day, value: 1, to: start)!
                return Match(
                    label: DateFormatter.chipDay.string(from: start),
                    matchedText: matched,
                    constraint: .absolute(start: start, end: end)
                )
            }
        }
        // aug 7, 2025
        for (name, month) in months {
            let pattern = #"\b\#(name)\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b"#
            if let matched = slice(of: pattern, in: text) {
                let nums = matched.split { !$0.isNumber }.compactMap { Int($0) }
                guard nums.count >= 2, let day = nums.first, let year = nums.last,
                      let start = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                      start <= today
                else { continue }
                let end = calendar.date(byAdding: .day, value: 1, to: start)!
                return Match(
                    label: DateFormatter.chipDay.string(from: start),
                    matchedText: matched,
                    constraint: .absolute(start: start, end: end)
                )
            }
        }
        // 7th aug (no year) — label without year; match that month/day any year
        for (name, month) in months {
            let pattern = #"\b(\d{1,2})(?:st|nd|rd|th)?\s+\#(name)\b"#
            guard let matched = slice(of: pattern, in: text),
                  let range = text.range(of: matched, options: .caseInsensitive)
            else { continue }
            let after = text.lowercased()[range.upperBound...]
            if after.range(of: #"^\s+\d{4}\b"#, options: .regularExpression) != nil { continue }
            guard let day = matched.split(whereSeparator: { !$0.isNumber }).compactMap({ Int($0) }).first,
                  day >= 1, day <= 31
            else { continue }
            let labelDate = calendar.date(from: DateComponents(year: 2024, month: month, day: day)) ?? today
            return Match(
                label: DateFormatter.chipDayNoYear.string(from: labelDate),
                matchedText: matched,
                constraint: .monthDay(month: month, day: day)
            )
        }
        // aug 7 (no year)
        for (name, month) in months {
            let pattern = #"\b\#(name)\s+(\d{1,2})(?:st|nd|rd|th)?\b"#
            guard let matched = slice(of: pattern, in: text),
                  let range = text.range(of: matched, options: .caseInsensitive)
            else { continue }
            let after = text.lowercased()[range.upperBound...]
            if after.range(of: #"^\s*,?\s*\d{4}\b"#, options: .regularExpression) != nil { continue }
            guard let day = matched.split(whereSeparator: { !$0.isNumber }).compactMap({ Int($0) }).first,
                  day >= 1, day <= 31
            else { continue }
            let labelDate = calendar.date(from: DateComponents(year: 2024, month: month, day: day)) ?? today
            return Match(
                label: DateFormatter.chipDayNoYear.string(from: labelDate),
                matchedText: matched,
                constraint: .monthDay(month: month, day: day)
            )
        }
        return nil
    }

    private static func monthPhrase(in text: String, today: Date) -> Match? {
        let calendar = Calendar.current

        for (name, month) in months {
            let pattern = #"\b\#(name)\s+(\d{4})\b"#
            if let matched = slice(of: pattern, in: text) {
                guard let year = matched.split(whereSeparator: { !$0.isNumber }).first.flatMap({ Int($0) }),
                      let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                      let end = calendar.date(byAdding: .month, value: 1, to: start)
                else { continue }
                return Match(
                    label: DateFormatter.monthYear.string(from: start),
                    matchedText: matched,
                    constraint: .absolute(start: start, end: end)
                )
            }
        }

        for (name, month) in months {
            let pattern = #"\b\#(name)\b"#
            guard let matched = slice(of: pattern, in: text),
                  let range = text.range(of: matched, options: .caseInsensitive)
            else { continue }
            let lower = text.lowercased()
            let before = lower[..<range.lowerBound]
            if before.range(of: #"\d{1,2}(?:st|nd|rd|th)?\s+$"#, options: .regularExpression) != nil {
                continue
            }
            if lower[range.upperBound...].range(of: #"^\s+(\d{1,2})(?:st|nd|rd|th)?\b"#, options: .regularExpression) != nil {
                continue
            }
            if lower[range.upperBound...].range(of: #"^\s+\d{4}\b"#, options: .regularExpression) != nil {
                continue
            }
            let labelDate = calendar.date(from: DateComponents(year: 2024, month: month, day: 1)) ?? today
            return Match(
                label: DateFormatter.monthOnly.string(from: labelDate),
                matchedText: matched,
                constraint: .monthOnly(month: month)
            )
        }
        return nil
    }

    private static func namedWeekday(
        _ weekday: Int,
        name: String,
        in lower: String,
        today: Date
    ) -> (Date, Date, String) {
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
    ) -> (Date, Date, String) {
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
    ) -> (Date, Date, String) {
        let calendar = Calendar.current
        let next = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        func hour(_ value: Int) -> Date {
            calendar.date(bySettingHour: value, minute: 0, second: 0, of: startOfDay) ?? startOfDay
        }
        switch part {
        case .allDay, .posting:
            return (startOfDay, next, label)
        case .morning:
            return (startOfDay, hour(12), "\(label) morning")
        case .afternoon:
            return (hour(12), hour(17), "\(label) afternoon")
        case .evening:
            return (hour(17), next, "\(label) night")
        }
    }

    private static func weekStart(for day: Date) -> Date {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: day)
        return calendar.date(from: comps) ?? day
    }

    private static func detectedMatch(in text: String, today: Date) -> Match? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = detector.firstMatch(in: text, options: [], range: full),
              let date = match.date,
              let swiftRange = Range(match.range, in: text)
        else { return nil }
        let start = Calendar.current.startOfDay(for: date)
        if start > today { return nil }
        let span = max(match.duration, 0)
        let end: Date = span >= 86_400
            ? start.addingTimeInterval(span)
            : Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let hasYear = String(text[swiftRange]).range(of: #"\d{4}"#, options: .regularExpression) != nil
        if hasYear {
            return Match(
                label: DateFormatter.chipDay.string(from: start),
                matchedText: String(text[swiftRange]),
                constraint: .absolute(start: start, end: end)
            )
        }
        let month = Calendar.current.component(.month, from: start)
        let day = Calendar.current.component(.day, from: start)
        return Match(
            label: DateFormatter.chipDayNoYear.string(from: start),
            matchedText: String(text[swiftRange]),
            constraint: .monthDay(month: month, day: day)
        )
    }

    private static func extractISO(from lower: String) -> String? {
        let pattern = #"\d{4}-\d{2}-\d{2}"#
        guard let range = lower.range(of: pattern, options: .regularExpression) else { return nil }
        return String(lower[range])
    }
}
