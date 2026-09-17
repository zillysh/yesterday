import Foundation
import CoreLocation
import MapKit

struct LibraryMoment: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var subtitle: String
    var photoIDs: [String]
    /// Photo shown in the week highlight rail — swappable from the rest of the set.
    var coverID: String
    var sortDate: Date
    var dayLabel: String
    /// Stable key so cover swaps survive refresh.
    var clusterKey: String

    init(
        id: UUID? = nil,
        title: String,
        subtitle: String,
        photoIDs: [String],
        coverID: String? = nil,
        sortDate: Date,
        dayLabel: String = "",
        clusterKey: String = ""
    ) {
        let key = clusterKey.isEmpty ? Self.makeClusterKey(photoIDs) : clusterKey
        self.id = id ?? Self.stableID(for: key)
        self.title = title
        self.subtitle = subtitle
        self.photoIDs = photoIDs
        self.coverID = coverID ?? photoIDs.first ?? ""
        self.sortDate = sortDate
        self.dayLabel = dayLabel
        self.clusterKey = key
    }

    static func makeClusterKey(_ photoIDs: [String]) -> String {
        photoIDs.sorted().joined(separator: "|")
    }

    static func stableID(for key: String) -> UUID {
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        // Build a deterministic UUID from the hash (not random each refresh).
        let bytes = withUnsafeBytes(of: hash.bigEndian) { Data($0) }
        var uuid = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        for (index, byte) in bytes.enumerated() where index < 8 {
            withUnsafeMutableBytes(of: &uuid) { raw in
                raw[index] = byte
                raw[index + 8] = byte &+ UInt8(index)
            }
        }
        return UUID(uuid: uuid)
    }
}

/// A week frame — the highlight rail is the story.
struct MomentWeek: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var dateRange: String
    var weekStart: Date
    var moments: [LibraryMoment]

    init(
        id: UUID? = nil,
        title: String,
        dateRange: String,
        weekStart: Date,
        moments: [LibraryMoment]
    ) {
        self.id = id ?? LibraryMoment.stableID(for: "week:\(weekStart.timeIntervalSince1970)")
        self.title = title
        self.dateRange = dateRange
        self.weekStart = weekStart
        self.moments = moments
    }
}

/// Turns Camera Roll clusters into a scrollable “what you’ve been up to” recap.
@MainActor
@Observable
final class MomentsViewModel {
    var weeks: [MomentWeek] = []
    var isLoading = false
    var note: String?
    /// Quiet status under the gathering card.
    var gatherStatus: String = "Pulling from your library"
    /// A few random recent photos for the gathering preview (picked once).
    var gatherPreviewIDs: [String] = []
    /// Coarse 0…1 — updated sparingly so UI doesn’t thrash indexing.
    var gatherProgress: Double = 0

    private var lastStamp: String?
    private var refreshGeneration = 0
    /// False when we painted without a usable embedding index — allow one silent rebuild.
    private var finalizedWithEmbeddings = false

    func loadIfNeeded(library: PhotoLibraryService) async {
        await refreshIfNeeded(library: library)
    }

    func refreshIfNeeded(library: PhotoLibraryService, force: Bool = false) async {
        PhotoEmbeddingIndex.shared.startIfNeeded(library: library)
        let stamp = library.momentsContentStamp()
        let indexReady = PhotoEmbeddingIndex.shared.indexedCount >= 8

        if !force, stamp == lastStamp {
            // First open timed out before embeddings — rebuild under loading (no in-place morph).
            if !finalizedWithEmbeddings, indexReady, !weeks.isEmpty {
                weeks = []
                await refresh(library: library, stamp: stamp)
            }
            return
        }
        await refresh(library: library, stamp: stamp)
    }

    func refresh(library: PhotoLibraryService) async {
        PhotoEmbeddingIndex.shared.startIfNeeded(library: library)
        await refresh(library: library, stamp: library.momentsContentStamp())
    }

    private func refresh(library: PhotoLibraryService, stamp: String) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isLoading = true
        gatherProgress = 0.08
        gatherStatus = "Pulling from your library"
        defer {
            if generation == refreshGeneration {
                isLoading = false
                gatherProgress = 1
            }
        }

        let clusters = library.recentLibraryClusters(dayCount: 90, scanLimit: 1_200, minPhotos: 2)
        guard generation == refreshGeneration else { return }

        // A couple random recent shots — not a slideshow of the whole library.
        let pool = clusters.flatMap { $0.photos.map(\.localIdentifier) }
        gatherPreviewIDs = Array(Set(pool).shuffled().prefix(5))
        gatherProgress = 0.2

        guard !clusters.isEmpty else {
            weeks = []
            note = "Not enough recent photos to build moments yet."
            lastStamp = stamp
            finalizedWithEmbeddings = true
            gatherStatus = "Nothing recent enough"
            return
        }

        // Wait for embeddings before building titles — never morph after first paint.
        gatherStatus = "Reading your photos"
        await waitForEmbeddings(generation: generation)
        guard generation == refreshGeneration else { return }
        let hadEmbeddings = PhotoEmbeddingIndex.shared.indexedCount >= 8
        gatherProgress = 0.55
        gatherStatus = "Finding moments"

        // Don't let this week's volume starve older weeks off the feed.
        let events = Self.balancedEvents(clusters, maxWeeks: 12, maxPerWeek: 6)
        var built: [LibraryMoment] = []
        built.reserveCapacity(events.count)
        var placeSources: [[PhotoSummary]] = []

        for (offset, event) in events.enumerated() {
            guard generation == refreshGeneration else { return }
            let ids = event.photos.map(\.localIdentifier)
            let sortDate = event.photos.compactMap(\.createdAt).max() ?? event.eventDay
            let timeTitle = Self.timeTitle(for: event)
            // Activity first when we have a vibe; when is always supporting context.
            var title = timeTitle
            var subtitle = "\(ids.count) photos · \(Self.dateLine(for: event))"

            if hadEmbeddings, offset < 24, let vibe = await Self.vibeTitle(for: ids) {
                title = vibe
                subtitle = "\(timeTitle) · \(ids.count) photos"
            }

            built.append(
                LibraryMoment(
                    title: title,
                    subtitle: subtitle,
                    photoIDs: ids,
                    coverID: HighlightCoverStore.cover(for: ids) ?? ids.first,
                    sortDate: sortDate,
                    dayLabel: Self.dayLabel(for: sortDate)
                )
            )
            placeSources.append(event.photos)
        }

        guard generation == refreshGeneration else { return }
        gatherProgress = 0.85
        var finalized = Self.coalesce(built)

        let placed = await Self.titlesWithPlaces(
            finalized,
            sources: Array(placeSources.prefix(10))
        )
        guard generation == refreshGeneration else { return }
        for i in finalized.indices {
            finalized[i].title = placed[i]
        }

        // Single assignment — titles are final when the feed appears.
        let visible = finalized.filter { !DismissedMomentsStore.isDismissed($0.clusterKey) }
        weeks = Self.mergeManualMoments(into: Self.weeks(from: visible))
        note = weeks.isEmpty ? "No moments yet." : nil
        lastStamp = stamp
        finalizedWithEmbeddings = hadEmbeddings
        gatherProgress = 1
        gatherStatus = "Ready"
    }

    private func waitForEmbeddings(generation: Int) async {
        _ = await PhotoEmbeddingIndex.shared.ensureReady(minCount: 1)
        // Cap wait (~8s) so gathering never hangs forever.
        for _ in 0..<24 {
            guard generation == refreshGeneration else { return }
            if PhotoEmbeddingIndex.shared.indexedCount >= 8 { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
    }

    // MARK: - Weeks

    /// Spread moments across weeks so a busy recent stretch doesn’t hide older weeks.
    private static func balancedEvents(
        _ clusters: [PhotoLibraryService.PhotoEvent],
        maxWeeks: Int,
        maxPerWeek: Int
    ) -> [PhotoLibraryService.PhotoEvent] {
        var calendar = Calendar.current
        calendar.firstWeekday = 1

        var byWeek: [Date: [PhotoLibraryService.PhotoEvent]] = [:]
        for event in clusters {
            let date = event.photos.compactMap(\.createdAt).max() ?? event.eventDay
            let start = weekStart(for: date, calendar: calendar)
            byWeek[start, default: []].append(event)
        }

        let weekStarts = byWeek.keys.sorted(by: >).prefix(maxWeeks)
        var picked: [PhotoLibraryService.PhotoEvent] = []
        picked.reserveCapacity(maxWeeks * maxPerWeek)
        for start in weekStarts {
            let weekEvents = byWeek[start] ?? []
            picked.append(contentsOf: weekEvents.prefix(maxPerWeek))
        }
        return picked.sorted {
            ($0.photos.compactMap(\.createdAt).max() ?? .distantPast)
                > ($1.photos.compactMap(\.createdAt).max() ?? .distantPast)
        }
    }

    func setCover(photoIDs: [String], photoID: String) {
        guard photoIDs.contains(photoID) else { return }
        HighlightCoverStore.setCover(photoID, for: photoIDs)
        let key = LibraryMoment.makeClusterKey(photoIDs)
        var next = weeks
        var changed = false
        for weekIndex in next.indices {
            for momentIndex in next[weekIndex].moments.indices {
                let moment = next[weekIndex].moments[momentIndex]
                if moment.clusterKey == key || moment.photoIDs == photoIDs {
                    next[weekIndex].moments[momentIndex].coverID = photoID
                    changed = true
                }
            }
        }
        if changed {
            weeks = next
        }
    }

    func deleteMoment(_ moment: LibraryMoment) {
        DismissedMomentsStore.dismiss(moment.clusterKey)
        ManualMomentsStore.remove(clusterKey: moment.clusterKey)
        let next = weeks.compactMap { week -> MomentWeek? in
            let kept = week.moments.filter { $0.id != moment.id && $0.clusterKey != moment.clusterKey }
            guard !kept.isEmpty else { return nil }
            var copy = week
            copy.moments = kept
            return copy
        }
        weeks = next
        if weeks.isEmpty {
            note = "No moments yet."
        }
    }

    /// Add a hand-picked moment into a week frame (from Curate & share).
    @discardableResult
    func addMoment(photoIDs: [String], to weekStart: Date) async -> LibraryMoment? {
        let ids = photoIDs.reduce(into: [String]()) { result, id in
            guard !id.isEmpty, !result.contains(id) else { return }
            result.append(id)
        }
        guard !ids.isEmpty else { return nil }

        let summaries = PhotoLibraryService.shared.summaries(for: ids)
        let sortDate = summaries.compactMap(\.createdAt).max()
            ?? Calendar.current.startOfDay(for: weekStart)
        let day = Self.dayLabel(for: sortDate)
        let title = await Self.vibeTitle(for: ids) ?? (day.isEmpty ? "Moment" : day)
        let cover = ids[0]
        let moment = LibraryMoment(
            title: title,
            subtitle: "\(ids.count) photos",
            photoIDs: ids,
            coverID: cover,
            sortDate: sortDate,
            dayLabel: day
        )

        var calendar = Calendar.current
        calendar.firstWeekday = 1
        let start = Self.weekStart(for: weekStart, calendar: calendar)

        ManualMomentsStore.add(
            ManualMomentRecord(
                weekStart: start.timeIntervalSince1970,
                photoIDs: ids,
                coverID: cover,
                title: title,
                sortDate: sortDate.timeIntervalSince1970
            )
        )

        var next = weeks
        if let index = next.firstIndex(where: { Calendar.current.isDate($0.weekStart, inSameDayAs: start) }) {
            // Avoid dupes if the same set is already there.
            if next[index].moments.contains(where: { $0.clusterKey == moment.clusterKey }) {
                return next[index].moments.first { $0.clusterKey == moment.clusterKey }
            }
            next[index].moments.insert(moment, at: 0)
        } else {
            next.insert(
                MomentWeek(
                    title: Self.weekTitle(for: start, calendar: calendar),
                    dateRange: Self.weekDateRange(for: start, calendar: calendar),
                    weekStart: start,
                    moments: [moment]
                ),
                at: 0
            )
        }
        weeks = next
        note = nil
        return moment
    }

    func moment(id: UUID) -> LibraryMoment? {
        for week in weeks {
            if let moment = week.moments.first(where: { $0.id == id }) {
                return moment
            }
        }
        return nil
    }

    private static func weeks(from moments: [LibraryMoment]) -> [MomentWeek] {
        var calendar = Calendar.current
        calendar.firstWeekday = 1 // Sunday-start weeks

        var buckets: [Date: [LibraryMoment]] = [:]
        for moment in moments {
            let start = weekStart(for: moment.sortDate, calendar: calendar)
            buckets[start, default: []].append(moment)
        }

        return buckets.keys.sorted(by: >).compactMap { start in
            let ordered = (buckets[start] ?? []).sorted { $0.sortDate > $1.sortDate }
            guard !ordered.isEmpty else { return nil }
            return MomentWeek(
                title: weekTitle(for: start, calendar: calendar),
                dateRange: weekDateRange(for: start, calendar: calendar),
                weekStart: start,
                moments: ordered
            )
        }
    }

    private static func mergeManualMoments(into weeks: [MomentWeek]) -> [MomentWeek] {
        let records = ManualMomentsStore.all()
        guard !records.isEmpty else { return weeks }

        var calendar = Calendar.current
        calendar.firstWeekday = 1
        var next = weeks

        for record in records {
            let start = Date(timeIntervalSince1970: record.weekStart)
            let ids = record.photoIDs.filter { !$0.isEmpty }
            guard !ids.isEmpty else { continue }
            let key = LibraryMoment.makeClusterKey(ids)
            if DismissedMomentsStore.isDismissed(key) { continue }

            let sortDate = Date(timeIntervalSince1970: record.sortDate)
            let moment = LibraryMoment(
                title: record.title,
                subtitle: "\(ids.count) photos",
                photoIDs: ids,
                coverID: ids.contains(record.coverID) ? record.coverID : ids[0],
                sortDate: sortDate,
                dayLabel: dayLabel(for: sortDate),
                clusterKey: key
            )

            if let index = next.firstIndex(where: { Calendar.current.isDate($0.weekStart, inSameDayAs: start) }) {
                if next[index].moments.contains(where: { $0.clusterKey == key }) { continue }
                next[index].moments.insert(moment, at: 0)
            } else {
                next.append(
                    MomentWeek(
                        title: weekTitle(for: start, calendar: calendar),
                        dateRange: weekDateRange(for: start, calendar: calendar),
                        weekStart: calendar.startOfDay(for: start),
                        moments: [moment]
                    )
                )
            }
        }

        return next.sorted { $0.weekStart > $1.weekStart }
    }

    private static func weekStart(for date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let delta = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -delta, to: day) ?? day
    }

    private static func weekTitle(for start: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: Date())
        let thisWeek = weekStart(for: today, calendar: calendar)
        if start == thisWeek { return "This week" }
        if let last = calendar.date(byAdding: .day, value: -7, to: thisWeek), start == last {
            return "Last week"
        }
        return weekDateRange(for: start, calendar: calendar)
    }

    private static func weekDateRange(for start: Date, calendar: Calendar) -> String {
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let a = DateFormatter.chipDayNoYear.string(from: start)
        let b = DateFormatter.chipDayNoYear.string(from: end)
        return "\(a)–\(b)"
    }

    private static func dayLabel(for date: Date) -> String {
        DateFormatter.weekdayShort.string(from: date)
    }

    private static func isPureTimeTitle(_ title: String) -> Bool {
        let t = title.lowercased()
        let exact: Set<String> = [
            "today", "yesterday", "tonight", "this morning", "this afternoon",
            "this weekend", "last weekend", "yesterday morning",
            "this weekend · morning", "this weekend · night",
        ]
        if exact.contains(t) { return true }
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        for day in weekdays {
            if t == day || t == "\(day) morning" || t == "\(day) night" { return true }
        }
        if t.contains(" at ") || t.contains(" in ") { return false }
        return false
    }

    private static func titlesWithPlaces(_ moments: [LibraryMoment], sources: [[PhotoSummary]]) async -> [String] {
        var placeByPhoto = [String: MomentPlace]()
        // Cap MapKit work so gathering can't hang on a stuck geocode.
        let deadline = Date().addingTimeInterval(6)
        for photos in sources where !photos.isEmpty {
            if Date() > deadline { break }
            guard let place = await placeLabel(for: photos) else { continue }
            for id in photos.map(\.localIdentifier) {
                placeByPhoto[id] = place
            }
        }

        return moments.map { moment in
            if moment.title == "Screenshots" { return moment.title }
            guard let place = moment.photoIDs.lazy.compactMap({ placeByPhoto[$0] }).first else {
                return moment.title
            }
            return withPlace(moment.title, place: place)
        }
    }

    // MARK: - Titles

    private static func withPlace(_ base: String, place: MomentPlace?) -> String {
        guard let place else { return base }
        let name = place.name
        if place.isVenue {
            if base.localizedCaseInsensitiveContains(name) { return base }
            return "\(base) at \(name)"
        }
        if base.localizedCaseInsensitiveContains(name) { return base }
        // “This weekend · night” → “This weekend in Brooklyn”
        if let cut = base.range(of: " · ") {
            let head = String(base[..<cut.lowerBound])
            return "\(head) in \(name)"
        }
        return "\(base) in \(name)"
    }

    private static func placeLabel(for photos: [PhotoSummary]) async -> MomentPlace? {
        guard let probe = representativeLocation(from: photos) else { return nil }
        return await PlaceLookup.shared.label(for: probe.coordinate, preferArea: probe.preferArea)
    }

    private static func representativeLocation(
        from photos: [PhotoSummary]
    ) -> (coordinate: CLLocationCoordinate2D, preferArea: Bool)? {
        let coords = photos.compactMap(\.coordinate)
        let locatedShare = Double(coords.count) / Double(max(1, photos.count))
        guard coords.count >= 2 || (coords.count == 1 && photos.count <= 5 && locatedShare >= 0.4) else {
            return nil
        }
        guard locatedShare >= 0.25 || coords.count >= 3 else { return nil }

        let lats = coords.map(\.latitude).sorted()
        let lons = coords.map(\.longitude).sorted()
        let median = CLLocationCoordinate2D(
            latitude: lats[lats.count / 2],
            longitude: lons[lons.count / 2]
        )
        let center = CLLocation(latitude: median.latitude, longitude: median.longitude)
        let radii = coords.map {
            center.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
        }
        let spread = radii.sorted()[radii.count / 2]
        // Wide day trips → city/area only, not a single restaurant pin.
        return (median, spread > 1_200)
    }

    private static func timeTitle(for event: PhotoLibraryService.PhotoEvent) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let day = calendar.startOfDay(for: event.eventDay)

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return event.stretch == .morning ? "Yesterday morning" : "Yesterday"
        }
        if day == today {
            switch event.stretch {
            case .morning: return "This morning"
            case .afternoon: return "This afternoon"
            case .evening, .lateNight: return "Tonight"
            }
        }
        if isThisWeekend(day) {
            switch event.stretch {
            case .morning: return "This weekend · morning"
            case .afternoon: return "This weekend"
            case .evening, .lateNight: return "This weekend · night"
            }
        }
        if let lastWeekend = lastWeekendRange(), day >= lastWeekend.start && day < lastWeekend.end {
            return "Last weekend"
        }

        let weekday = DateFormatter.weekdayName.string(from: day)
        switch event.stretch {
        case .morning: return "\(weekday) morning"
        case .afternoon: return weekday
        case .evening, .lateNight: return "\(weekday) night"
        }
    }

    private static func dateLine(for event: PhotoLibraryService.PhotoEvent) -> String {
        let times = event.photos.compactMap(\.createdAt).sorted()
        guard let first = times.first else {
            return DateFormatter.tripDay.string(from: event.eventDay)
        }
        if times.count == 1 {
            return DateFormatter.tripDay.string(from: first)
        }
        let last = times.last!
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return DateFormatter.tripDay.string(from: first)
        }
        return "\(DateFormatter.chipDayNoYear.string(from: first))–\(DateFormatter.chipDayNoYear.string(from: last))"
    }

    private static func isThisWeekend(_ day: Date) -> Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today) // 1 = Sun
        // Weekend = Fri night framing through Sunday: treat Sat/Sun, and Friday if today is weekend-ish.
        let dayWeekday = calendar.component(.weekday, from: day)
        if dayWeekday == 1 || dayWeekday == 7 { // Sun / Sat
            // Must be the current week's weekend (within last 2 days of "weekend window")
            let start: Date
            if weekday == 1 { // Sunday
                start = calendar.date(byAdding: .day, value: -1, to: today)!
            } else if weekday == 7 { // Saturday
                start = today
            } else if weekday == 6 { // Friday
                start = today
            } else {
                return false
            }
            return day >= start && day <= today
        }
        return false
    }

    private static func lastWeekendRange() -> (start: Date, end: Date)? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let saturday: Date
        if weekday == 7 {
            saturday = calendar.date(byAdding: .day, value: -7, to: today)!
        } else if weekday == 1 {
            saturday = calendar.date(byAdding: .day, value: -8, to: today)!
        } else {
            var delta = weekday - 7
            if delta <= 0 { delta += 7 }
            saturday = calendar.date(byAdding: .day, value: -delta - 7, to: today)!
        }
        let monday = calendar.date(byAdding: .day, value: 2, to: saturday)!
        return (saturday, monday)
    }

    /// Probe MobileCLIP for a short vibe label when the index is warm.
    private static var vibeVectors: [(label: String, vector: [Float])]?

    private static let vibeQueries: [(label: String, query: String)] = [
        ("Dinner", "dinner at a restaurant"),
        ("Brunch", "brunch food"),
        ("Coffee", "coffee shop"),
        ("Drinks", "drinks at a bar"),
        ("Beach", "beach"),
        ("Park", "park outdoors"),
        ("Party", "party with friends"),
        ("Concert", "concert"),
        ("Film photos", "film photograph"),
        ("Portraits", "portrait of a person"),
        ("Dogs", "dog"),
        ("Travel", "travel vacation trip"),
        ("City night", "city at night"),
        ("Golden hour", "golden hour sunset"),
        ("Home", "home interior cozy"),
        ("Screenshots", "phone screenshot"),
    ]

    private static func vibeCatalog() async -> [(label: String, vector: [Float])] {
        if let vibeVectors { return vibeVectors }
        var built: [(label: String, vector: [Float])] = []
        built.reserveCapacity(vibeQueries.count)
        for vibe in vibeQueries {
            if let vector = await PhotoEmbedder.shared.embedText(vibe.query) {
                built.append((vibe.label, vector))
            }
        }
        vibeVectors = built
        return built
    }

    private static func vibeTitle(for ids: [String]) async -> String? {
        let index = PhotoEmbeddingIndex.shared
        guard index.indexedCount >= 8 else { return nil }

        let catalog = await vibeCatalog()
        guard !catalog.isEmpty else { return nil }

        let sample = Array(ids.prefix(6))
        var best: (String, Float)?
        for vibe in catalog {
            let hits = await PhotoVectorStore.shared.rank(ids: sample, query: vibe.vector, minScore: 0.14)
            guard !hits.isEmpty else { continue }
            let avg = hits.prefix(4).map(\.score).reduce(0, +) / Float(min(4, hits.count))
            if best == nil || avg > best!.1 {
                best = (vibe.label, avg)
            }
        }
        guard let best, best.1 >= 0.20 else { return nil }
        if best.0 == "Screenshots", best.1 < 0.26 { return nil }
        return best.0
    }

    private static func coalesce(_ moments: [LibraryMoment]) -> [LibraryMoment] {
        guard var current = moments.first else { return [] }
        var out: [LibraryMoment] = []
        for next in moments.dropFirst() {
            let sameTitle = current.title == next.title
            let close = abs(current.sortDate.timeIntervalSince(next.sortDate)) < 36 * 3600
            if sameTitle, close, current.photoIDs.count + next.photoIDs.count <= 80 {
                let merged = current.photoIDs + next.photoIDs
                current.photoIDs = merged
                current.clusterKey = LibraryMoment.makeClusterKey(merged)
                current.coverID = HighlightCoverStore.cover(for: merged) ?? current.coverID
                if !merged.contains(current.coverID) {
                    current.coverID = merged.first ?? current.coverID
                }
                // Keep the time framing in subtitle when present.
                if current.subtitle.contains("·") {
                    let timePart = current.subtitle.split(separator: "·").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? current.title
                    current.subtitle = "\(timePart) · \(merged.count) photos"
                } else {
                    current.subtitle = "\(merged.count) photos"
                }
            } else {
                out.append(current)
                current = next
            }
        }
        out.append(current)
        return out
    }
}

// MARK: - Highlight cover persistence

enum HighlightCoverStore {
    private static let defaultsKey = "moments.highlightCovers"

    static func cover(for photoIDs: [String]) -> String? {
        let key = LibraryMoment.makeClusterKey(photoIDs)
        guard let map = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] else {
            return nil
        }
        guard let cover = map[storageKey(for: key)], photoIDs.contains(cover) else { return nil }
        return cover
    }

    static func setCover(_ photoID: String, for photoIDs: [String]) {
        let key = LibraryMoment.makeClusterKey(photoIDs)
        var map = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        map[storageKey(for: key)] = photoID
        // Cap growth — keep newest 200 overrides.
        if map.count > 200 {
            map = Dictionary(uniqueKeysWithValues: map.suffix(200))
        }
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }

    private static func storageKey(for clusterKey: String) -> String {
        // Short stable fingerprint so UserDefaults keys stay small.
        var hash: UInt64 = 5381
        for byte in clusterKey.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}

// MARK: - Manual moments (added during curate)

struct ManualMomentRecord: Codable, Equatable, Sendable {
    var weekStart: TimeInterval
    var photoIDs: [String]
    var coverID: String
    var title: String
    var sortDate: TimeInterval
}

enum ManualMomentsStore {
    private static let defaultsKey = "moments.manualMoments"

    static func all() -> [ManualMomentRecord] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([ManualMomentRecord].self, from: data)
        else { return [] }
        return decoded
    }

    static func add(_ record: ManualMomentRecord) {
        var records = all()
        let key = LibraryMoment.makeClusterKey(record.photoIDs)
        records.removeAll { LibraryMoment.makeClusterKey($0.photoIDs) == key }
        records.insert(record, at: 0)
        if records.count > 80 {
            records = Array(records.prefix(80))
        }
        save(records)
    }

    static func remove(clusterKey: String) {
        var records = all()
        records.removeAll { LibraryMoment.makeClusterKey($0.photoIDs) == clusterKey }
        save(records)
    }

    private static func save(_ records: [ManualMomentRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

enum DismissedMomentsStore {
    private static let defaultsKey = "moments.dismissedClusters"

    static func isDismissed(_ clusterKey: String) -> Bool {
        dismissedKeys().contains(storageKey(for: clusterKey))
    }

    static func dismiss(_ clusterKey: String) {
        var keys = dismissedKeys()
        keys.insert(storageKey(for: clusterKey))
        // Cap growth.
        if keys.count > 400 {
            keys = Set(keys.suffix(400))
        }
        UserDefaults.standard.set(Array(keys), forKey: defaultsKey)
    }

    private static func dismissedKeys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }

    private static func storageKey(for clusterKey: String) -> String {
        var hash: UInt64 = 5381
        for byte in clusterKey.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}

// MARK: - Place lookup

private struct MomentPlace: Sendable, Equatable {
    let name: String
    let isVenue: Bool
}

private actor PlaceLookup {
    static let shared = PlaceLookup()

    private var cache: [String: MomentPlace] = [:]

    func label(for coordinate: CLLocationCoordinate2D, preferArea: Bool) async -> MomentPlace? {
        let key = gridKey(coordinate) + (preferArea ? ":a" : ":v")
        if let hit = cache[key] { return hit }
        guard let resolved = await reverseGeocode(coordinate, preferArea: preferArea) else {
            return nil
        }
        cache[key] = resolved
        return resolved
    }

    private func gridKey(_ c: CLLocationCoordinate2D) -> String {
        // ~400–500m buckets so neighboring photos share a lookup.
        let lat = Int((c.latitude * 250).rounded())
        let lon = Int((c.longitude * 250).rounded())
        return "\(lat):\(lon)"
    }

    private func reverseGeocode(
        _ coordinate: CLLocationCoordinate2D,
        preferArea: Bool
    ) async -> MomentPlace? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        let items: [MKMapItem]
        do {
            items = try await request.mapItems
        } catch {
            return nil
        }
        guard let item = items.first else { return nil }

        let reps = item.addressRepresentations
        let city = clean(reps?.cityName)
        let rawName = clean(item.name)

        if !preferArea, let rawName, looksLikeVenue(rawName, city: city, item: item) {
            return MomentPlace(name: shortenVenue(rawName), isVenue: true)
        }
        if let city {
            return MomentPlace(name: city, isVenue: false)
        }
        if let rawName, !looksLikeStreetAddress(rawName) {
            return MomentPlace(name: shortenVenue(rawName), isVenue: false)
        }
        return nil
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func looksLikeVenue(_ name: String, city: String?, item: MKMapItem) -> Bool {
        if item.pointOfInterestCategory != nil { return true }
        if looksLikeStreetAddress(name) { return false }
        if let city, name.caseInsensitiveCompare(city) == .orderedSame { return false }
        // Residential reverse-geocode often returns the street as `name`.
        if name.range(of: #"^\d"#, options: .regularExpression) != nil { return false }
        if name.count > 42 { return false }
        return true
    }

    private func looksLikeStreetAddress(_ name: String) -> Bool {
        if name.range(of: #"^\d+\s"#, options: .regularExpression) != nil { return true }
        let streetHints = [" St", " Street", " Ave", " Avenue", " Rd", " Road", " Blvd", " Lane", " Ln", " Dr", " Drive", " Way", " Ct", " Court"]
        return streetHints.contains { name.localizedCaseInsensitiveContains($0) } && name.contains(" ")
    }

    private func shortenVenue(_ name: String) -> String {
        var s = name
        for suffix in [" LLC", " Inc.", " Inc", " Restaurant", " Café", " Cafe"] {
            if s.hasSuffix(suffix) {
                s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        if s.count > 28 {
            let idx = s.index(s.startIndex, offsetBy: 28)
            if let space = s[..<idx].lastIndex(of: " ") {
                s = String(s[..<space])
            }
        }
        return s
    }
}
