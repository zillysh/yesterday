import Photos
import UIKit
import Vision
import CoreLocation

/// Talks to your Camera Roll and the Post album.

struct PhotoSummary: Identifiable, Sendable, Hashable {
    var id: String { localIdentifier }
    let localIdentifier: String
    let createdAt: Date?
    let isFavorite: Bool
    let isScreenshot: Bool
    let hasLocation: Bool
    let latitude: Double?
    let longitude: Double?
    let pixelWidth: Int
    let pixelHeight: Int
    let burstIdentifier: String?

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
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
    var peopleAlbums: [AlbumSummary] = []
    var visibleImageCount: Int = 0
    var lastResultIDs: [String] = []
    var previewIDs: [String] = []
    var previewTitle: String = ""
    var labelCache: [String: [String]] = [:]
    private var producedResultsThisTurn = false

    private let imageManager = PHCachingImageManager()
    private let thumbCache = NSCache<NSString, UIImage>()

    private init() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        thumbCache.countLimit = 400
        thumbCache.totalCostLimit = 80 * 1024 * 1024
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
        peopleAlbums = fetchPeopleAlbums()
        postAlbumIDs = fetchPostAlbumIDs()
        visibleImageCount = PHAsset.fetchAssets(with: .image, options: nil).count
        PhotoEmbeddingIndex.shared.startIfNeeded(library: self)
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

    func photos(
        inCollectionID collectionID: String?,
        start: Date?,
        end: Date?,
        favoritesOnly: Bool,
        locatedOnly: Bool,
        limit: Int,
        scanCap: Int = 12_000
    ) -> [PhotoSummary] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = imagePredicate(start: start, end: end, favoritesOnly: favoritesOnly)

        let fetch: PHFetchResult<PHAsset>
        if let collectionID,
           let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [collectionID], options: nil).firstObject {
            fetch = PHAsset.fetchAssets(in: album, options: options)
        } else if let recents = cameraRoll() {
            fetch = PHAsset.fetchAssets(in: recents, options: options)
        } else {
            fetch = PHAsset.fetchAssets(with: .image, options: options)
        }

        var photos: [PhotoSummary] = []
        var scanned = 0
        fetch.enumerateObjects { asset, _, stop in
            scanned += 1
            if asset.mediaType != .image { return }
            if locatedOnly, asset.location == nil { return }
            photos.append(Self.summary(for: asset))
            if photos.count >= limit || scanned >= scanCap { stop.pointee = true }
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
        var isMorning: Bool { stretch == .morning }

        var kindName: String {
            switch stretch {
            case .morning: return "Morning"
            case .afternoon: return "Afternoon"
            case .evening, .lateNight: return "Night"
            }
        }

        var stretch: DaySlice {
            let slices = photos.compactMap(\.createdAt).map(DaySlice.of)
            guard !slices.isEmpty else { return .afternoon }
            let morning = slices.filter { $0 == .morning }.count
            let afternoon = slices.filter { $0 == .afternoon }.count
            let night = slices.filter { $0 == .evening || $0 == .lateNight }.count
            let best = max(morning, afternoon, night)
            if best == morning { return .morning }
            if best == afternoon { return .afternoon }
            return .evening
        }

        var timeRangeLabel: String {
            let times = photos.compactMap(\.createdAt).sorted()
            guard let first = times.first, let last = times.last else { return "" }
            if Calendar.current.isDate(first, inSameDayAs: last) {
                return "\(DateFormatter.clock.string(from: first)) – \(DateFormatter.clock.string(from: last))"
            }
            return "\(DateFormatter.dayClock.string(from: first)) – \(DateFormatter.dayClock.string(from: last))"
        }
    }

    func eventPhotos(on days: [Date], part: DayPart) -> [PhotoSummary] {
        let moments = eventMoments(on: days, part: part)
        let picked = moments.flatMap(\.photos)
        lastResultIDs = picked.map(\.localIdentifier)
        producedResultsThisTurn = true
        return picked
    }

    /// Groups Camera Roll shots into nights vs mornings using gaps in time.
    func eventMoments(on days: [Date], part: DayPart) -> [PhotoEvent] {
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
            case .posting, .allDay:
                return true
            case .morning:
                return event.stretch == .morning
            case .afternoon:
                return event.stretch == .afternoon
            case .evening:
                return event.stretch == .evening || event.stretch == .lateNight
            }
        }

        var picked = events.filter(matches)
        if picked.isEmpty {
            picked = events.filter { wanted.contains($0.eventDay) }
        }
        lastResultIDs = picked.flatMap(\.photos).map(\.localIdentifier)
        producedResultsThisTurn = true
        return picked
    }

    private func clusterEvents(_ photos: [PhotoSummary]) -> [PhotoEvent] {
        let sorted = photos.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        guard let first = sorted.first else { return [] }
        var groups: [[PhotoSummary]] = [[first]]
        for photo in sorted.dropFirst() {
            let previous = groups[groups.count - 1].last
            if shouldStartNewMoment(from: previous?.createdAt, to: photo.createdAt) {
                groups.append([photo])
            } else {
                groups[groups.count - 1].append(photo)
            }
        }
        return groups.map(makeEvent)
    }

    /// Morning, afternoon, and night are separate. A night can run past midnight.
    private func shouldStartNewMoment(from previous: Date?, to current: Date?) -> Bool {
        guard let previous, let current else { return false }
        if current.timeIntervalSince(previous) > 3 * 3600 { return true }
        let before = DaySlice.of(previous)
        let after = DaySlice.of(current)
        if before == after { return false }
        if isSameNight(before, after) { return false }
        return true
    }

    private func isSameNight(_ a: DaySlice, _ b: DaySlice) -> Bool {
        let night: Set<DaySlice> = [.evening, .lateNight]
        return night.contains(a) && night.contains(b)
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
        return PhotoEvent(photos: photos, eventDay: eventDay)
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

    /// Time-gap clusters across recent Camera Roll — building blocks for the Moments tab.
    func recentLibraryClusters(dayCount: Int = 60, scanLimit: Int = 1_200, minPhotos: Int = 3) -> [PhotoEvent] {
        let end = Date().addingTimeInterval(60)
        let start = Calendar.current.date(
            byAdding: .day,
            value: -dayCount,
            to: Calendar.current.startOfDay(for: Date())
        )
        let raw = search(
            start: start,
            end: end,
            favoritesOnly: false,
            albumName: nil,
            limit: scanLimit
        )
        return clusterEvents(raw)
            .filter { $0.photos.count >= minPhotos }
            .sorted { ($0.photos.compactMap(\.createdAt).max() ?? .distantPast) > ($1.photos.compactMap(\.createdAt).max() ?? .distantPast) }
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

    func createSavedAlbum(title: String, ids: [String]) async throws -> String {
        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            placeholder = request.placeholderForCreatedAssetCollection
        }
        guard let identifier = placeholder?.localIdentifier,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject
        else {
            throw PhotoLibraryError.couldNotCreateAlbum
        }
        let incoming = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        let current = PHAsset.fetchAssets(in: album, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: album, assets: current) else { return }
            request.addAssets(incoming)
        }
        await refresh()
        return identifier
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

    struct SimilarGroup: Identifiable {
        var id: String { photoIDs[0] }
        let photoIDs: [String]
    }

    /// Bursts and shots taken a few seconds apart — the same moment, not the whole night.
    func similarGroups(from ids: [String], window: TimeInterval = 8) -> [SimilarGroup] {
        let photos = summaries(for: ids)
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.localIdentifier, $0) })
        var groups: [[String]] = []
        for id in ids {
            let photo = byID[id]
            if let lastID = groups.last?.last {
                let previous = byID[lastID]
                let sameBurst = {
                    guard let a = previous?.burstIdentifier, let b = photo?.burstIdentifier, !a.isEmpty else { return false }
                    return a == b
                }()
                let closeInTime = {
                    guard let a = previous?.createdAt, let b = photo?.createdAt else { return false }
                    return abs(b.timeIntervalSince(a)) <= window
                }()
                let lastCount = groups[groups.count - 1].count
                if sameBurst || (closeInTime && lastCount < 24) {
                    groups[groups.count - 1].append(id)
                    continue
                }
            }
            groups.append([id])
        }
        return groups.map { SimilarGroup(photoIDs: $0) }
    }

    func requestThumbnail(for id: String, size: CGSize) async -> UIImage? {
        await requestImage(for: id, size: size, fit: .aspectFill, quality: .grid)
    }

    /// Fast opportunistic thumb for embedding index (not UI display).
    func requestFastThumbnail(for id: String, size: CGSize) async -> UIImage? {
        await requestImage(for: id, size: size, fit: .aspectFill, quality: .fast)
    }

    func requestDisplayImage(for id: String, size: CGSize) async -> UIImage? {
        await requestImage(for: id, size: size, fit: .aspectFit, quality: .full)
    }

    func startCachingThumbnails(ids: [String], size: CGSize) {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in assets.append(asset) }
        guard !assets.isEmpty else { return }
        let scale = UIScreen.main.scale
        let pixels = CGSize(width: max(size.width, 1) * scale, height: max(size.height, 1) * scale)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        imageManager.startCachingImages(
            for: assets,
            targetSize: pixels,
            contentMode: .aspectFill,
            options: options
        )
    }

    private enum ThumbQuality {
        case fast, grid, full
    }

    private func requestImage(
        for id: String,
        size: CGSize,
        fit: PHImageContentMode,
        quality: ThumbQuality
    ) async -> UIImage? {
        let cacheKey = "\(id)|\(Int(size.width))x\(Int(size.height))|\(quality)|\(fit.rawValue)" as NSString
        if quality != .full, let cached = thumbCache.object(forKey: cacheKey) {
            return cached
        }

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = fetch.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.version = .current
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true
        switch quality {
        case .fast:
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
        case .grid:
            // Wait for a real grid-sized decode — fastFormat looks blurry forever.
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
        case .full:
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
        }

        let scale = UIScreen.main.scale
        let maxPointEdge: CGFloat
        switch quality {
        case .fast: maxPointEdge = 180
        case .grid: maxPointEdge = 320
        case .full: maxPointEdge = 1600
        }
        let capped = CGSize(
            width: min(max(size.width, 1), maxPointEdge),
            height: min(max(size.height, 1), maxPointEdge)
        )
        let pixels = CGSize(width: capped.width * scale, height: capped.height * scale)

        let image: UIImage? = await withCheckedContinuation { continuation in
            var finished = false
            imageManager.requestImage(
                for: asset,
                targetSize: pixels,
                contentMode: fit,
                options: options
            ) { image, info in
                if (info?[PHImageCancelledKey] as? Bool) == true || info?[PHImageErrorKey] != nil {
                    guard !finished else { return }
                    finished = true
                    continuation.resume(returning: nil)
                    return
                }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                switch quality {
                case .fast:
                    // First usable frame is fine for indexing.
                    if let image {
                        guard !finished else { return }
                        finished = true
                        continuation.resume(returning: image)
                    } else if !degraded {
                        guard !finished else { return }
                        finished = true
                        continuation.resume(returning: nil)
                    }
                case .grid, .full:
                    if degraded { return }
                    guard !finished else { return }
                    finished = true
                    continuation.resume(returning: image)
                }
            }
        }

        if let image, quality != .full {
            let cost = Int(image.size.width * image.size.height * 4)
            thumbCache.setObject(image, forKey: cacheKey, cost: cost)
        }
        return image
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

    private func fetchPeopleAlbums() -> [AlbumSummary] {
        var rows: [AlbumSummary] = []
        var seen = Set<String>()
        let lists = PHCollectionList.fetchCollectionLists(with: .smartFolder, subtype: .smartFolderFaces, options: nil)
        lists.enumerateObjects { list, _, _ in
            let collections = PHCollection.fetchCollections(in: list, options: nil)
            collections.enumerateObjects { item, _, _ in
                guard let album = item as? PHAssetCollection else { return }
                let title = (album.localizedTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard title.count >= 2 else { return }
                let lowered = title.lowercased()
                if lowered == "people" || lowered == "person" { return }
                let count = PHAsset.fetchAssets(in: album, options: nil).count
                guard count > 0, seen.insert(album.localIdentifier).inserted else { return }
                rows.append(
                    AlbumSummary(
                        localIdentifier: album.localIdentifier,
                        title: title,
                        count: count
                    )
                )
            }
        }
        return rows.sorted { $0.count > $1.count }
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
            hasLocation: asset.location != nil,
            latitude: asset.location?.coordinate.latitude,
            longitude: asset.location?.coordinate.longitude,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            burstIdentifier: asset.burstIdentifier
        )
    }

    static func classify(cgImage: CGImage) async -> [String] {
        await withCheckedContinuation { continuation in
            let request = VNClassifyImageRequest { request, _ in
                let observations = (request.results as? [VNClassificationObservation] ?? [])
                    .prefix(8)
                    .filter { $0.confidence >= 0.12 }
                    .map(\.identifier)
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

enum DaySlice {
    case lateNight, morning, afternoon, evening

    static func of(_ date: Date) -> DaySlice {
        switch Calendar.current.component(.hour, from: date) {
        case 0..<6: return .lateNight
        case 6..<12: return .morning
        case 12..<18: return .afternoon
        default: return .evening
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

    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mma"
        return formatter
    }()

    static let dayClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mma"
        return formatter
    }()
}
