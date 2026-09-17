import Foundation
import UIKit

/// A finished week recap you can share with friends.
struct SharedWeekRecap: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var dateRange: String
    var weekStart: Date
    /// Ordered highlight photo IDs (one lead per moment).
    var highlightIDs: [String]
    /// Moment titles aligned with highlightIDs.
    var highlightTitles: [String]
    var createdAt: Date

    /// Shareable link — opens in-app later; friends get photos via the share sheet today.
    var shareURL: URL {
        URL(string: "https://yesterday.app/recap/\(id.uuidString)")!
    }

    var shareMessage: String {
        "\(title) · \(dateRange)\n\(shareURL.absoluteString)"
    }
}

@MainActor
@Observable
final class WeekRecapStore {
    static let shared = WeekRecapStore()
    private static let key = "yesterday.weekRecaps"

    var recaps: [SharedWeekRecap] = []

    private init() {
        load()
    }

    @discardableResult
    func finish(
        week: MomentWeek,
        highlights: [(title: String, photoID: String)]
    ) -> SharedWeekRecap {
        let recap = SharedWeekRecap(
            id: UUID(),
            title: week.title,
            dateRange: week.dateRange,
            weekStart: week.weekStart,
            highlightIDs: highlights.map(\.photoID),
            highlightTitles: highlights.map(\.title),
            createdAt: Date()
        )
        recaps.insert(recap, at: 0)
        persist()
        return recap
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([SharedWeekRecap].self, from: data)
        else { return }
        recaps = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(recaps) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
