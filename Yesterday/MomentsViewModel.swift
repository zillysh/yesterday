import Foundation
import CoreLocation
import MapKit

struct LibraryMoment: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var subtitle: String
    var photoIDs: [String]
    var sortDate: Date

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        photoIDs: [String],
        sortDate: Date
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.photoIDs = photoIDs
        self.sortDate = sortDate
    }
}

/// Turns Camera Roll clusters into a scrollable “what you’ve been up to” recap.
@MainActor
@Observable
final class MomentsViewModel {
    var moments: [LibraryMoment] = []
    var isLoading = false
    var note: String?

    private var loaded = false

    func loadIfNeeded(library: PhotoLibraryService) async {
        guard !loaded, !isLoading else { return }
        await refresh(library: library)
    }

    func refresh(library: PhotoLibraryService) async {
        isLoading = true
        defer { isLoading = false }

        let clusters = library.recentLibraryClusters(dayCount: 75, scanLimit: 1_400, minPhotos: 3)
        guard !clusters.isEmpty else {
            moments = []
            note = "Not enough recent photos to build moments yet."
            loaded = true
            return
        }

        var built: [LibraryMoment] = []
        built.reserveCapacity(min(clusters.count, 40))
        var placeSources: [[PhotoSummary]] = []
        placeSources.reserveCapacity(min(clusters.count, 40))

        for event in clusters.prefix(40) {
            let ids = event.photos.map(\.localIdentifier)
            let sortDate = event.photos.compactMap(\.createdAt).max() ?? event.eventDay
            let timeTitle = Self.timeTitle(for: event)
            var title = timeTitle
            var subtitle = "\(ids.count) photos · \(Self.dateLine(for: event))"
            var skipPlace = false

            if let vibe = await Self.vibeTitle(for: ids) {
                // “Dinner at Mala” / “Film photos” on top of the time framing.
                title = vibe
                subtitle = "\(timeTitle) · \(ids.count) photos"
                skipPlace = vibe == "Screenshots"
            }

            built.append(
                LibraryMoment(
                    title: title,
                    subtitle: subtitle,
                    photoIDs: ids,
                    sortDate: sortDate
                )
            )
            placeSources.append(skipPlace ? [] : event.photos)
        }

        // Show the recap immediately, then weave in places as geocodes land.
        moments = Self.coalesce(built)
        note = nil
        loaded = true
        isLoading = false

        let placed = await Self.titlesWithPlaces(moments, sources: placeSources)
        if placed != moments.map(\.title) {
            for i in moments.indices {
                moments[i].title = placed[i]
            }
        }
    }

    private static func titlesWithPlaces(_ moments: [LibraryMoment], sources: [[PhotoSummary]]) async -> [String] {
        var placeByPhoto = [String: MomentPlace]()
        await withTaskGroup(of: ([String], MomentPlace)?.self) { group in
            for photos in sources where !photos.isEmpty {
                group.addTask {
                    guard let place = await placeLabel(for: photos) else { return nil }
                    return (photos.map(\.localIdentifier), place)
                }
            }
            for await hit in group {
                guard let hit else { continue }
                for id in hit.0 {
                    placeByPhoto[id] = hit.1
                }
            }
        }

        return moments.map { moment in
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
    private static func vibeTitle(for ids: [String]) async -> String? {
        let index = PhotoEmbeddingIndex.shared
        guard index.indexedCount > 20 else { return nil }

        let sample = Array(ids.prefix(8))
        let vibes: [(label: String, query: String)] = [
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

        var best: (String, Float)?
        for vibe in vibes {
            let hits = await index.rank(ids: sample, text: vibe.query, minScore: 0.16)
            guard !hits.isEmpty else { continue }
            let avg = hits.prefix(4).map(\.score).reduce(0, +) / Float(min(4, hits.count))
            if best == nil || avg > best!.1 {
                best = (vibe.label, avg)
            }
        }
        guard let best, best.1 >= 0.22 else { return nil }
        // Screenshots only if clearly dominant.
        if best.0 == "Screenshots", best.1 < 0.28 { return nil }
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
