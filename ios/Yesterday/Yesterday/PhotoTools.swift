import Foundation
import FoundationModels

enum PhotoFormatting {
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()

    static func isoDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        if let date = iso.date(from: String(raw.prefix(10))) {
            return Calendar.current.startOfDay(for: date)
        }
        return ISO8601DateFormatter().date(from: raw)
    }

    static func lines(for photos: [PhotoSummary], cap: Int = 24) -> String {
        if photos.isEmpty { return "No matching photos." }
        let shown = photos.prefix(cap)
        let rows = shown.map { photo in
            let stamp = photo.createdAt.map { DateFormatter.isoStamp.string(from: $0) } ?? "unknown-date"
            var flags: [String] = []
            if photo.isFavorite { flags.append("favorite") }
            if photo.isScreenshot { flags.append("screenshot") }
            if photo.hasLocation { flags.append("located") }
            let extra = flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]"
            return "\(photo.localIdentifier) \(stamp)\(extra)"
        }
        let more = photos.count > cap ? "\n…and \(photos.count - cap) more" : ""
        return "\(photos.count) photos:\n" + rows.joined(separator: "\n") + more
    }
}

private extension DateFormatter {
    static let isoStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

struct SearchPhotosTool: Tool {
    let name = "searchPhotos"
    let description = "Search the Photos library by date range, favorites, or album name. Returns localIdentifiers."

    @Generable
    struct Arguments {
        @Guide(description: "Inclusive start date as YYYY-MM-DD")
        var startDateISO: String?
        @Guide(description: "Exclusive end date as YYYY-MM-DD")
        var endDateISO: String?
        @Guide(description: "If true, only favorite photos")
        var favoritesOnly: Bool?
        @Guide(description: "Existing album title to search inside")
        var albumName: String?
        @Guide(description: "Max photos to return, default 40")
        var limit: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        let photos = await PhotoLibraryService.shared.search(
            start: PhotoFormatting.isoDate(arguments.startDateISO),
            end: PhotoFormatting.isoDate(arguments.endDateISO),
            favoritesOnly: arguments.favoritesOnly ?? false,
            albumName: arguments.albumName,
            limit: max(1, arguments.limit ?? 80)
        )
        return PhotoFormatting.lines(for: photos)
    }
}

struct PhotosForDayTool: Tool {
    let name = "photosForDay"
    let description = "List photos taken on one calendar day."

    @Generable
    struct Arguments {
        @Guide(description: "Day as YYYY-MM-DD")
        var dayISO: String
        @Guide(description: "Max photos, default 80")
        var limit: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        guard let day = PhotoFormatting.isoDate(arguments.dayISO) else {
            return "Need a day as YYYY-MM-DD."
        }
        let photos = await PhotoLibraryService.shared.photos(on: day, limit: max(1, arguments.limit ?? 80))
        return "\(PhotoFormatting.day.string(from: day))\n" + PhotoFormatting.lines(for: photos)
    }
}

struct ClusterRecentTool: Tool {
    let name = "clusterRecent"
    let description = "Group recent photos by calendar day for trip or weekend reviews."

    @Generable
    struct Arguments {
        @Guide(description: "How many days back to look, default 14")
        var dayCount: Int?
        @Guide(description: "Max day groups to return, default 8")
        var maxGroups: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        let groups = await PhotoLibraryService.shared.clusterRecent(
            dayCount: max(1, arguments.dayCount ?? 14),
            maxGroups: max(1, arguments.maxGroups ?? 8)
        )
        if groups.isEmpty { return "No recent photos in the library I can see." }
        return groups.map { group in
            let ids = group.photos.prefix(12).map(\.localIdentifier).joined(separator: ", ")
            return "\(PhotoFormatting.day.string(from: group.day)): \(group.photos.count) photos. IDs: \(ids)"
        }.joined(separator: "\n")
    }
}

struct PreviewSetTool: Tool {
    let name = "previewSet"
    let description = "Show a set of photos in the chat as a selectable grid. Pass localIdentifiers from a search."

    @Generable
    struct Arguments {
        @Guide(description: "Photo localIdentifiers to show")
        var localIdentifiers: [String]
        @Guide(description: "Short label for the set, like Saturday golden hour")
        var title: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let photos = await PhotoLibraryService.shared.preview(
            ids: arguments.localIdentifiers,
            title: arguments.title
        )
        let label = arguments.title ?? "Preview"
        return "Showing \(photos.count) photos for “\(label)” in the chat grid."
    }
}

struct UpdatePostAlbumTool: Tool {
    let name = "updatePostAlbum"
    let description = "Add, remove, or replace photos in the Photos album named Post."

    @Generable
    struct Arguments {
        @Guide(description: "replace, add, or remove")
        var action: String
        @Guide(description: "Photo localIdentifiers")
        var localIdentifiers: [String]
    }

    func call(arguments: Arguments) async throws -> String {
        try await PhotoLibraryService.shared.updatePostAlbum(
            action: arguments.action,
            ids: arguments.localIdentifiers
        )
    }
}

struct ListAlbumsTool: Tool {
    let name = "listAlbums"
    let description = "List album titles and photo counts in the Photos library."

    @Generable
    struct Arguments {
        @Guide(description: "Unused; pass an empty string")
        var unused: String?
    }

    func call(arguments: Arguments) async throws -> String {
        await PhotoLibraryService.shared.listAlbumsText()
    }
}

struct ClassifyPreviewTool: Tool {
    let name = "classifyPreview"
    let description = "Run on-device scene labels on a shortlist of photo IDs. Use this to drop indoor shots, screenshots, or off-vibe frames. Never send the whole library."

    @Generable
    struct Arguments {
        @Guide(description: "Candidate localIdentifiers, max 12")
        var localIdentifiers: [String]
    }

    func call(arguments: Arguments) async throws -> String {
        await PhotoLibraryService.shared.classify(ids: arguments.localIdentifiers)
    }
}

enum PhotoToolset {
    static var all: [any Tool] {
        [
            SearchPhotosTool(),
            PhotosForDayTool(),
            ClusterRecentTool(),
            PreviewSetTool(),
            UpdatePostAlbumTool(),
            ListAlbumsTool(),
            ClassifyPreviewTool(),
        ]
    }
}
