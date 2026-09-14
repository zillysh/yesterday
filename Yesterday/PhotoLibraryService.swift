import Photos
import UIKit
import Vision

struct PhotoSummary: Identifiable, Sendable, Hashable {
    var id: String { localIdentifier }
    let localIdentifier: String
    let createdAt: Date?
    let isFavorite: Bool
    let isScreenshot: Bool
    let hasLocation: Bool
}

struct AlbumSummary: Identifiable, Sendable, Hashable {
    var id: String { localIdentifier }
    let localIdentifier: String
    let title: String
    let count: Int
}

struct DayGroup: Sendable, Hashable {
    let day: Date
    let photos: [PhotoSummary]
}

@MainActor
@Observable
final class PhotoLibraryService: @unchecked Sendable {
    static let shared = PhotoLibraryService()
    static let postAlbumTitle = "Post"

    var authorization: PHAuthorizationStatus
    var postAlbumIDs: [String] = []
    var albums: [AlbumSummary] = []
    var visibleImageCount: Int = 0
    var lastResultIDs: [String] = []
    var previewIDs: [String] = []
    var previewTitle: String = ""
    private var producedResultsThisTurn = false

    private let imageManager = PHCachingImageManager()

    private init() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    var isLimited: Bool { authorization == .limited }
    var canRead: Bool { authorization == .authorized || authorization == .limited }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if canRead {
            await refresh()
        }
    }

    func refresh() async {
        guard canRead else { return }
        albums = fetchAlbums()
        postAlbumIDs = fetchPostAlbumIDs()
        visibleImageCount = PHAsset.fetchAssets(with: .image, options: nil).count
    }

    func search(
        start: Date?,
        end: Date?,
        favoritesOnly: Bool,
        albumName: String?,
        limit: Int,
        includeScreenshots: Bool = false
    ) -> [PhotoSummary] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.wantsIncrementalChangeDetails = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = imagePredicate(start: start, end: end, favoritesOnly: favoritesOnly)

        let fetch: PHFetchResult<PHAsset>
        if let albumName, !albumName.isEmpty, let album = albumNamed(albumName) {
            fetch = PHAsset.fetchAssets(in: album, options: options)
        } else if let recents = cameraRoll() {
            fetch = PHAsset.fetchAssets(in: recents, options: options)
        } else {
            fetch = PHAsset.fetchAssets(with: .image, options: options)
        }

        var photos: [PhotoSummary] = []
        fetch.enumerateObjects { asset, _, stop in
            if asset.mediaType != .image { return }
            if !includeScreenshots, asset.mediaSubtypes.contains(.photoScreenshot) { return }
            if let start, let created = asset.creationDate, created < start { return }
            if let end, let created = asset.creationDate, created >= end { return }
            if favoritesOnly, !asset.isFavorite { return }
            photos.append(Self.summary(for: asset))
            if photos.count >= limit { stop.pointee = true }
        }
        lastResultIDs = photos.map(\.localIdentifier)
        producedResultsThisTurn = true
        return photos
    }

    func photos(on day: Date, limit: Int = 80) -> [PhotoSummary] {
        let start = Calendar.current.startOfDay(for: day)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else {
            return []
        }
        return search(start: start, end: end, favoritesOnly: false, albumName: nil, limit: limit)
    }

    struct PhotoEvent {
        var photos: [PhotoSummary]
        var eventDay: Date
        var isMorning: Bool
    }

    func eventPhotos(on days: [Date], part: DayPart) -> [PhotoSummary] {
        let calendar = Calendar.current
        let uniqueDays = Array(Set(days.map { calendar.startOfDay(for: $0) })).sorted()
        guard let firstDay = uniqueDays.first, let lastDay = uniqueDays.last else { return [] }

        let windowStart = calendar.date(byAdding: .hour, value: -14, to: firstDay) ?? firstDay
        let windowEnd = calendar.date(byAdding: .hour, value: 38, to: lastDay) ?? lastDay
        let raw = search(
            start: windowStart,
            end: windowEnd,
            favoritesOnly: false,
            albumName: nil,
            limit: 500
        )
        let events = clusterEvents(raw)
        let wanted = Set(uniqueDays)

        func matches(_ event: PhotoEvent) -> Bool {
            guard wanted.contains(event.eventDay) else { return false }
            switch part {
            case .posting:
                return !event.isMorning
            case .morning:
                return event.isMorning
            case .afternoon:
                return event.photos.contains { hour(of: $0, in: 12..<17) }
            case .evening:
                return event.photos.contains { hour(of: $0, in: 17..<24) || hour(of: $0, in: 0..<6) }
            case .allDay:
                return true
            }
        }

        var picked = events.filter(matches).flatMap(\.photos)
        if picked.isEmpty, part == .posting {
            picked = events.filter { wanted.contains($0.eventDay) }.flatMap(\.photos)
        }
        picked.sort { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        lastResultIDs = picked.map(\.localIdentifier)
        producedResultsThisTurn = true
        return picked
    }

    private func clusterEvents(_ photos: [PhotoSummary]) -> [PhotoEvent] {
        let sorted = photos.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        guard let first = sorted.first else { return [] }
        let gap: TimeInterval = 4.5 * 3600
        var groups: [[PhotoSummary]] = [[first]]
        for photo in sorted.dropFirst() {
            let previous = groups[groups.count - 1].last
            let delta = (photo.createdAt ?? .distantPast).timeIntervalSince(previous?.createdAt ?? .distantPast)
            if delta > gap {
                groups.append([photo])
            } else {
                groups[groups.count - 1].append(photo)
            }
        }
        return groups.map(makeEvent)
    }

    private func makeEvent(_ photos: [PhotoSummary]) -> PhotoEvent {
        let calendar = Calendar.current
        let times = photos.compactMap(\.createdAt)
        let eventDay: Date
        if let evening = times.filter({ calendar.component(.hour, from: $0) >= 16 }).min() {
            eventDay = calendar.startOfDay(for: evening)
        } else if !times.isEmpty, times.allSatisfy({ calendar.component(.hour, from: $0) < 6 }),
                  let earliest = times.min(),
                  let previous = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: earliest)) {
            eventDay = previous
        } else {
            eventDay = calendar.startOfDay(for: times.min() ?? Date())
        }
        let hours = times.map { calendar.component(.hour, from: $0) }
        let isMorning = hours.allSatisfy { $0 < 13 } && !hours.contains(where: { $0 >= 16 })
        return PhotoEvent(photos: photos, eventDay: eventDay, isMorning: isMorning)
    }

    private func hour(of photo: PhotoSummary, in range: Range<Int>) -> Bool {
        guard let date = photo.createdAt else { return false }
        return range.contains(Calendar.current.component(.hour, from: date))
    }

    func clusterRecent(dayCount: Int, maxGroups: Int) -> [DayGroup] {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -dayCount, to: Calendar.current.startOfDay(for: end))
        let photos = search(start: start, end: end, favoritesOnly: false, albumName: nil, limit: 400)
        let grouped = Dictionary(grouping: photos) { photo in
            Calendar.current.startOfDay(for: photo.createdAt ?? end)
        }
        let groups = grouped.keys.sorted(by: >).prefix(maxGroups).map { day in
            DayGroup(day: day, photos: (grouped[day] ?? []).sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) })
        }
        lastResultIDs = groups.first?.photos.map(\.localIdentifier) ?? []
        producedResultsThisTurn = true
        return Array(groups)
    }

    func beginTurn() {
        previewIDs = []
        previewTitle = ""
        producedResultsThisTurn = false
    }

    func preview(ids: [String], title: String?) -> [PhotoSummary] {
        let photos = summaries(for: ids)
        previewIDs = photos.map(\.localIdentifier)
        previewTitle = title ?? ""
        lastResultIDs = previewIDs
        producedResultsThisTurn = true
        return photos
    }

    func consumePreview() -> (title: String, ids: [String]) {
        let ids = previewIDs.isEmpty && producedResultsThisTurn ? lastResultIDs : previewIDs
        let snapshot = (previewTitle, ids)
        previewIDs = []
        previewTitle = ""
        producedResultsThisTurn = false
        return snapshot
    }

    func listAlbumsText() -> String {
        albums = fetchAlbums()
        if albums.isEmpty { return "No albums in the library I can see." }
        return albums.map { "\($0.title) (\($0.count))" }.joined(separator: "\n")
    }

    func updatePostAlbum(action: String, ids: [String]) async throws -> String {
        let album = try await ensurePostAlbum()
        let incoming = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        let current = PHAsset.fetchAssets(in: album, options: nil)

        try await PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: album, assets: current) else { return }
            switch action.lowercased() {
            case "add":
                request.addAssets(incoming)
            case "remove":
                request.removeAssets(incoming)
            default:
                if current.count > 0 {
                    request.removeAssets(current)
                }
                request.addAssets(incoming)
            }
        }

        await refresh()
        let count = postAlbumIDs.count
        return "Post album now has \(count) photo\(count == 1 ? "" : "s")."
    }

    func summaries(for ids: [String]) -> [PhotoSummary] {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var photos: [PhotoSummary] = []
        var seen = Set<String>()
        fetch.enumerateObjects { asset, _, _ in
            if seen.insert(asset.localIdentifier).inserted {
                photos.append(Self.summary(for: asset))
            }
        }
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        return photos.sorted { (order[$0.localIdentifier] ?? 0) < (order[$1.localIdentifier] ?? 0) }
    }

    func requestThumbnail(for id: String, size: CGSize) async -> UIImage? {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = fetch.firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.version = .current
        options.isNetworkAccessAllowed = true
        let scale = UIScreen.main.scale
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        return await withCheckedContinuation { continuation in
            var finished = false
            imageManager.requestImage(
                for: asset,
                targetSize: pixels,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                guard !finished else { return }
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    finished = true
                    continuation.resume(returning: nil)
                    return
                }
                finished = true
                continuation.resume(returning: image)
            }
        }
    }

    func classify(ids: [String]) async -> String {
        let sample = Array(ids.prefix(12))
        var lines: [String] = []
        for id in sample {
            guard let image = await requestThumbnail(for: id, size: CGSize(width: 360, height: 360)),
                  let cgImage = image.cgImage
            else {
                lines.append("\(id.prefix(8)): (could not load)")
                continue
            }
            let labels = await Self.classify(cgImage: cgImage)
            let summary = summaries(for: [id]).first
            let time = summary?.createdAt.map { DateFormatter.shortTime.string(from: $0) } ?? "?"
            lines.append("\(id) @ \(time): \(labels.joined(separator: ", "))")
        }
        return lines.isEmpty ? "No photos to classify." : lines.joined(separator: "\n")
    }

    func libraryContext() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        let access = isLimited ? "limited photo access" : "full photo access"
        return """
        Today is \(formatter.string(from: Date())).
        Library access: \(access).
        Post is the output album (\(postAlbumIDs.count) photos) — do not treat it as the search result.
        Other albums: \(albums.prefix(12).map(\.title).joined(separator: ", ")).
        """
    }

    private func fetchAlbums() -> [AlbumSummary] {
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var rows: [AlbumSummary] = []
        result.enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            rows.append(
                AlbumSummary(
                    localIdentifier: collection.localIdentifier,
                    title: collection.localizedTitle ?? "Untitled",
                    count: count
                )
            )
        }
        return rows.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func fetchPostAlbumIDs() -> [String] {
        guard let album = albumNamed(Self.postAlbumTitle) else { return [] }
        let fetch = PHAsset.fetchAssets(in: album, options: nil)
        var ids: [String] = []
        fetch.enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
        }
        return ids
    }

    private func cameraRoll() -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumUserLibrary,
            options: nil
        ).firstObject
    }

    func dateLabel(for id: String) -> String {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let date = fetch.firstObject?.creationDate else { return "" }
        return DateFormatter.shortStamp.string(from: date)
    }

    func accessNote() -> String? {
        guard isLimited else { return nil }
        return "I can only see \(visibleImageCount) photo\(visibleImageCount == 1 ? "" : "s") you allowed — tap More Photos and choose Keep All Photos for the real camera roll."
    }

    private func albumNamed(_ title: String) -> PHAssetCollection? {
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var match: PHAssetCollection?
        result.enumerateObjects { collection, _, stop in
            if collection.localizedTitle?.caseInsensitiveCompare(title) == .orderedSame {
                match = collection
                stop.pointee = true
            }
        }
        return match
    }

    private func ensurePostAlbum() async throws -> PHAssetCollection {
        if let existing = albumNamed(Self.postAlbumTitle) {
            return existing
        }
        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: Self.postAlbumTitle)
            placeholder = request.placeholderForCreatedAssetCollection
        }
        guard let identifier = placeholder?.localIdentifier,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject
        else {
            throw PhotoLibraryError.couldNotCreateAlbum
        }
        return album
    }

    private func imagePredicate(start: Date?, end: Date?, favoritesOnly: Bool) -> NSPredicate {
        var parts: [NSPredicate] = [NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)]
        if let start {
            parts.append(NSPredicate(format: "creationDate >= %@", start as NSDate))
        }
        if let end {
            parts.append(NSPredicate(format: "creationDate < %@", end as NSDate))
        }
        if favoritesOnly {
            parts.append(NSPredicate(format: "favorite == YES"))
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    private static func summary(for asset: PHAsset) -> PhotoSummary {
        PhotoSummary(
            localIdentifier: asset.localIdentifier,
            createdAt: asset.creationDate,
            isFavorite: asset.isFavorite,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            hasLocation: asset.location != nil
        )
    }

    private static func classify(cgImage: CGImage) async -> [String] {
        await withCheckedContinuation { continuation in
            let request = VNClassifyImageRequest { request, _ in
                let observations = (request.results as? [VNClassificationObservation] ?? [])
                    .prefix(4)
                    .filter { $0.confidence >= 0.2 }
                    .map { "\($0.identifier) \(Int($0.confidence * 100))%" }
                continuation.resume(returning: observations.isEmpty ? ["unlabeled"] : Array(observations))
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: ["classification failed"])
            }
        }
    }
}

enum PhotoLibraryError: LocalizedError {
    case couldNotCreateAlbum

    var errorDescription: String? {
        "Could not create the Post album."
    }
}

private extension DateFormatter {
    static let shortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    static let shortStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mma"
        return formatter
    }()
}
