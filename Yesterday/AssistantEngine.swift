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

    static let shortDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter
    }()
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

    func reply(
        to userText: String,
        date: DatePhrase.Match? = nil,
        history: [ChatMessage] = []
    ) async -> AssistantReply {
        await orchestrator.handle(userText, date: date, library: .shared, history: history)
    }
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

    static let chipDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    static let chipDayNoYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    static let weekdayShort: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    static let monthShort: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter
    }()

    static let monthYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    static let monthOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM"
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
