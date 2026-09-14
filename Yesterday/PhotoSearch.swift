import CoreLocation
import Foundation
import MapKit
import UIKit

enum QueryLexicon {
    static let stop: Set<String> = [
        "the", "a", "an", "with", "and", "or", "of", "in", "on", "at", "to", "for",
        "that", "this", "those", "these", "where", "when", "who", "my", "our", "we",
        "i", "me", "had", "have", "photos", "photo", "pics", "pic", "shots", "shot",
        "show", "find", "looking", "look", "from", "took", "take", "want", "need",
        "please", "hey", "can", "you", "me", "some", "any", "get", "hour", "like",
        "something", "around", "about", "do", "does", "did", "full", "access",
        "there", "here", "just", "really", "work", "working",
    ]

    static let dateWords: Set<String> = [
        "yesterday", "today", "weekend", "week", "month", "saturday", "sunday",
        "monday", "tuesday", "wednesday", "thursday", "friday", "last", "recent",
        "latest", "favorite", "favorites", "loved",
    ]

    static let intentWords: Set<String> = [
        "trip", "vacation", "visit", "travel", "went", "going",
        "dinner", "lunch", "breakfast", "brunch", "date",
        "cute", "cozy", "pretty", "best", "home", "house", "apartment",
        "golden", "sunset", "sunrise",
    ]

    static let aliases: [String: [String]] = [
        "beach": ["beach", "seashore", "coast", "sand", "ocean", "sea", "water", "shore"],
        "dinner": ["food", "restaurant", "meal", "plate", "dining", "table", "wine", "supper"],
        "lunch": ["food", "restaurant", "meal", "plate"],
        "breakfast": ["food", "meal", "coffee", "plate"],
        "food": ["food", "restaurant", "meal", "plate"],
        "golden": ["sunset", "sunrise", "sun", "sky", "dusk", "dawn"],
        "sunset": ["sunset", "sunrise", "sun", "sky", "dusk"],
        "sunrise": ["sunrise", "dawn", "sun", "sky"],
        "portrait": ["portrait", "person", "people", "face", "selfie"],
        "selfie": ["selfie", "portrait", "person", "face"],
        "people": ["person", "people", "crowd", "group"],
        "outdoor": ["outdoor", "nature", "sky", "landscape"],
        "indoor": ["indoor", "room", "furniture", "interior"],
        "home": ["indoor", "room", "interior", "furniture", "living"],
        "house": ["indoor", "room", "interior", "furniture"],
        "party": ["party", "people", "night", "drink"],
        "dog": ["dog", "puppy", "pet", "animal"],
        "cat": ["cat", "kitten", "pet", "animal"],
        "city": ["city", "building", "street", "urban"],
        "snow": ["snow", "winter", "cold"],
        "pool": ["pool", "water", "swim"],
        "coffee": ["coffee", "cafe", "cup"],
        "flower": ["flower", "blossom", "plant"],
        "park": ["park", "grass", "outdoor", "tree"],
        "concert": ["concert", "stage", "crowd", "music"],
        "drink": ["drink", "glass", "bar", "wine", "beer"],
        "drinks": ["drink", "glass", "bar", "wine", "beer"],
        "cute": ["portrait", "person", "face", "indoor"],
    ]

    static let metroQueries: Set<String> = [
        "dc", "d.c", "washington dc", "washington d.c.", "washington",
        "nyc", "new york", "sf", "san francisco", "la", "los angeles",
        "chi", "chicago", "philly", "philadelphia", "nola", "new orleans",
    ]

    static let placeNicknames: [String: String] = [
        "dc": "Washington DC",
        "d.c": "Washington DC",
        "nyc": "New York",
        "sf": "San Francisco",
        "la": "Los Angeles",
        "l.a": "Los Angeles",
        "chi": "Chicago",
        "philly": "Philadelphia",
        "nola": "New Orleans",
    ]

    static func tokens(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && $0 != "." }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { $0.count > 1 && !stop.contains($0) }
    }

    static func sceneKeywords(in text: String, dropping extra: Set<String> = []) -> [String] {
        let tokens = tokens(in: text).filter { !dateWords.contains($0) && !extra.contains($0) }
        var set = Set<String>()
        for token in tokens {
            if let mapped = aliases[token] {
                mapped.forEach { set.insert($0) }
                set.insert(token)
            }
        }
        return Array(set)
    }

    static func wantsGoldenHour(_ tokens: [String]) -> Bool {
        tokens.contains("golden") || tokens.contains("sunset") || tokens.contains("sunrise")
    }

    static func wantsHome(_ tokens: [String]) -> Bool {
        tokens.contains("home") || tokens.contains("house") || tokens.contains("apartment")
    }

    static func wantsTrip(_ tokens: [String]) -> Bool {
        tokens.contains("trip") || tokens.contains("vacation") || tokens.contains("visit") || tokens.contains("travel")
    }

    static func containsWord(_ word: String, in text: String) -> Bool {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

struct PhotoQueryResult {
    var photos: [PhotoSummary]
    var asked: String
    var note: String?
    var choices: [SearchChoice] = []
}

private enum PlaceKind {
    case poi, city, metro, country
}

private struct PlaceHit {
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: CLLocationDistance
    var latitudeDelta: Double?
    var longitudeDelta: Double?
    var kind: PlaceKind
}

extension PhotoLibraryService {
    private static var placeCache: [String: PlaceHit] = [:]

    func photosForQuery(_ raw: String) async -> PhotoQueryResult {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let range = DatePhrase.range(in: text)
        let tokens = QueryLexicon.tokens(in: text)
        let favoritesOnly = lower.contains("favorite") || lower.contains("loved")
        let wantsRecent = lower.contains("recent") || lower.contains("latest")
        let wantsHome = QueryLexicon.wantsHome(tokens)
        let wantsTrip = QueryLexicon.wantsTrip(tokens)
        let golden = QueryLexicon.wantsGoldenHour(tokens)

        let people = matchingPeople(in: lower)
        let album = matchingUserAlbum(in: lower)
        let personNames = Set(people.map { $0.title.lowercased() })
        let placeQuery = placeQuery(from: text, tokens: tokens, personNames: personNames, albumTitle: album?.title)
        let place = await resolvePlace(placeQuery, preferCity: wantsTrip)
        let scene = QueryLexicon.sceneKeywords(
            in: text,
            dropping: personNames.union(placeQuery.map { Set(QueryLexicon.tokens(in: $0)) } ?? [])
        )

        let targeted = !people.isEmpty || album != nil || place != nil || wantsHome || golden
        let start: Date?
        let end: Date?
        if let range {
            start = range.start
            end = range.end
        } else if wantsRecent, !targeted {
            start = Calendar.current.date(byAdding: .day, value: -14, to: Date())
            end = Date().addingTimeInterval(60)
        } else if targeted {
            start = nil
            end = nil
        } else if scene.isEmpty {
            start = Calendar.current.date(byAdding: .day, value: -21, to: Date())
            end = Date().addingTimeInterval(60)
        } else {
            start = Calendar.current.date(byAdding: .day, value: -180, to: Date())
            end = Date().addingTimeInterval(60)
        }

        let collectionID = people.first?.localIdentifier ?? album?.localIdentifier
        let fetchLimit = 8_000
        var candidates: [PhotoSummary]
        if let place, people.isEmpty, album == nil {
            if let latDelta = place.latitudeDelta, let lonDelta = place.longitudeDelta {
                candidates = photosInRegion(
                    latitude: place.latitude,
                    longitude: place.longitude,
                    latitudeDelta: latDelta,
                    longitudeDelta: lonDelta,
                    start: start,
                    end: end,
                    favoritesOnly: favoritesOnly,
                    limit: fetchLimit
                )
            } else {
                candidates = photosNear(
                    latitude: place.latitude,
                    longitude: place.longitude,
                    radius: place.radius,
                    start: start,
                    end: end,
                    favoritesOnly: favoritesOnly,
                    limit: fetchLimit,
                    scanCap: 200_000
                )
            }
            if candidates.isEmpty, let query = placeQuery {
                let placeWords = QueryLexicon.tokens(in: query)
                if let named = albums.first(where: { album in
                    let title = album.title.lowercased()
                    return placeWords.contains { title.contains($0) }
                }) {
                    candidates = photos(
                        inCollectionID: named.localIdentifier,
                        start: start,
                        end: end,
                        favoritesOnly: favoritesOnly,
                        locatedOnly: false,
                        limit: fetchLimit,
                        scanCap: 200_000
                    )
                }
            }
        } else {
            let loose = scene.isEmpty && people.isEmpty && album == nil && range == nil && !favoritesOnly
            candidates = photos(
                inCollectionID: collectionID,
                start: start,
                end: end,
                favoritesOnly: favoritesOnly,
                locatedOnly: wantsHome && place == nil,
                limit: loose ? 200 : fetchLimit,
                scanCap: 80_000
            )
            if let place {
                candidates = candidates.filter { photo in
                    guard let meters = distanceMeters(from: photo, latitude: place.latitude, longitude: place.longitude) else {
                        return false
                    }
                    return meters <= place.radius
                }
            }
        }

        if wantsHome, let home = homePin {
            let radius: CLLocationDistance = place == nil ? 450 : 450
            candidates = candidates.filter { photo in
                guard let meters = distanceMeters(from: photo, latitude: home.latitude, longitude: home.longitude) else {
                    return false
                }
                return meters <= radius
            }
        }

        if golden {
            candidates = candidates.filter { photo in
                guard let date = photo.createdAt else { return false }
                let hour = Calendar.current.component(.hour, from: date)
                return (5...8).contains(hour) || (16...19).contains(hour)
            }
        }

        let asked: String
        if let range {
            asked = range.label
        } else if let person = people.first {
            asked = person.title
        } else if let place {
            asked = place.name
        } else if wantsHome {
            asked = "home"
        } else if favoritesOnly {
            asked = "favorites"
        } else if wantsRecent {
            asked = "recent shots"
        } else {
            asked = text
        }

        guard !candidates.isEmpty else {
            var note: String?
            if place != nil {
                note = "No shots near \(place?.name ?? "that place") with a location pin. If Location was off when you shot, try the dates of the trip."
            } else if !people.isEmpty {
                note = "No photos in the \(people[0].title) album from Photos."
            } else if wantsHome, homePin == nil {
                note = "I couldn’t tell which shots are home yet. Name a city, a person from Photos, or a day."
            }
            return PhotoQueryResult(photos: [], asked: asked, note: note)
        }

        if let place, range == nil {
            if let split = await disambiguate(candidates, place: place, asked: asked) {
                return split
            }
        }

        let needsVision = !scene.isEmpty && place == nil && people.isEmpty && !wantsHome
        if !needsVision {
            let note: String?
            if people.isEmpty, place == nil, album == nil, !wantsHome, !golden, range == nil, !wantsRecent, !favoritesOnly {
                note = "Here are recent shots. Try a person from Photos, a city, dinner, home, or a day."
            } else {
                note = nil
            }
            return PhotoQueryResult(photos: candidates, asked: asked, note: note)
        }

        let ranked = await rankByScene(candidates.prefix(400), keywords: scene, tokens: tokens)
        if ranked.isEmpty {
            return PhotoQueryResult(
                photos: candidates,
                asked: asked,
                note: "I couldn’t clearly match “\(text)”, so here are shots from that time instead."
            )
        }
        return PhotoQueryResult(photos: ranked, asked: asked, note: nil)
    }

    private func disambiguate(
        _ photos: [PhotoSummary],
        place: PlaceHit,
        asked: String
    ) async -> PhotoQueryResult? {
        let trips = timeTrips(in: photos, gapDays: place.kind == .country ? 18 : 10)
        if trips.count > 1 {
            var choices: [SearchChoice] = []
            for trip in trips.prefix(7) {
                let name = await clusterName(trip, fallback: asked)
                choices.append(
                    SearchChoice(
                        label: "\(name) · \(dateSpan(trip)) · \(trip.count)",
                        photoIDs: trip.map(\.localIdentifier)
                    )
                )
            }
            choices.append(
                SearchChoice(
                    label: "All \(asked) · \(photos.count)",
                    photoIDs: photos.map(\.localIdentifier)
                )
            )
            return PhotoQueryResult(
                photos: [],
                asked: asked,
                note: "I see \(trips.count) trips to \(asked). Which one?",
                choices: choices
            )
        }

        let cell: Double
        switch place.kind {
        case .country: cell = 0.45
        case .metro: cell = 0.11
        case .city: cell = 0.08
        case .poi: return nil
        }
        let areas = geoClusters(in: photos, cell: cell).filter { $0.count >= 6 }
        var named: [(String, [PhotoSummary])] = []
        var seen = Set<String>()
        for area in areas.prefix(8) {
            let name = await clusterName(area, fallback: asked)
            let key = name.lowercased()
            if seen.insert(key).inserted {
                named.append((name, area))
            } else if let index = named.firstIndex(where: { $0.0.lowercased() == key }) {
                named[index].1.append(contentsOf: area)
            }
        }
        named = named.filter { $0.1.count >= 6 }
        guard named.count > 1 else { return nil }

        var choices = named.map { name, group in
            SearchChoice(
                label: "\(name) · \(dateSpan(group)) · \(group.count)",
                photoIDs: group.map(\.localIdentifier)
            )
        }
        choices.append(
            SearchChoice(
                label: "All \(asked) · \(photos.count)",
                photoIDs: photos.map(\.localIdentifier)
            )
        )
        return PhotoQueryResult(
            photos: [],
            asked: asked,
            note: "A few places around \(asked). Which area?",
            choices: choices
        )
    }

    private func timeTrips(in photos: [PhotoSummary], gapDays: Int) -> [[PhotoSummary]] {
        let ordered = photos.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        guard let first = ordered.first else { return [] }
        var trips: [[PhotoSummary]] = [[first]]
        let gap = TimeInterval(gapDays * 86_400)
        for photo in ordered.dropFirst() {
            let previous = trips[trips.count - 1].last?.createdAt ?? photo.createdAt
            if let previous, let date = photo.createdAt, date.timeIntervalSince(previous) > gap {
                trips.append([photo])
            } else {
                trips[trips.count - 1].append(photo)
            }
        }
        return trips.filter { $0.count >= 4 }
    }

    private func geoClusters(in photos: [PhotoSummary], cell: Double) -> [[PhotoSummary]] {
        var buckets: [String: [PhotoSummary]] = [:]
        for photo in photos {
            guard let lat = photo.latitude, let lon = photo.longitude else { continue }
            let key = "\(Int((lat / cell).rounded())):\(Int((lon / cell).rounded()))"
            buckets[key, default: []].append(photo)
        }
        return buckets.values.sorted { $0.count > $1.count }
    }

    private func clusterName(_ photos: [PhotoSummary], fallback: String) async -> String {
        let located = photos.filter { $0.latitude != nil }
        guard !located.isEmpty else { return fallback }
        let lat = located.compactMap(\.latitude).reduce(0, +) / Double(located.count)
        let lon = located.compactMap(\.longitude).reduce(0, +) / Double(located.count)
        let name = await placeName(latitude: lat, longitude: lon)
        return name == "There" ? fallback : name
    }

    private func dateSpan(_ photos: [PhotoSummary]) -> String {
        let dates = photos.compactMap(\.createdAt).sorted()
        guard let first = dates.first, let last = dates.last else { return "" }
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return DateFormatter.tripDay.string(from: first)
        }
        return "\(DateFormatter.tripDay.string(from: first))–\(DateFormatter.tripDay.string(from: last))"
    }

    private func matchingPeople(in lower: String) -> [AlbumSummary] {
        peopleAlbums
            .filter { person in
                person.title.count >= 2 && QueryLexicon.containsWord(person.title, in: lower)
            }
            .sorted { $0.title.count > $1.title.count }
    }

    private func matchingUserAlbum(in lower: String) -> AlbumSummary? {
        albums
            .filter { album in
                album.title.count >= 3
                    && album.title.lowercased() != PhotoLibraryService.postAlbumTitle.lowercased()
                    && lower.contains(album.title.lowercased())
            }
            .max(by: { $0.title.count < $1.title.count })
    }

    private func placeQuery(
        from text: String,
        tokens: [String],
        personNames: Set<String>,
        albumTitle: String?
    ) -> String? {
        let lower = text.lowercased()
        let patterns = [
            #"\b(?:trip|vacation|visit|travel)(?:\s+to)?\s+(.+)$"#,
            #"\b(?:in|at|near|around|to)\s+(.+)$"#,
        ]
        for pattern in patterns {
            if let match = lower.range(of: pattern, options: .regularExpression) {
                var slice = String(lower[match])
                slice = slice.replacingOccurrences(
                    of: #"^(trip|vacation|visit|travel|in|at|near|around|to)\s+"#,
                    with: "",
                    options: .regularExpression
                )
                let cleaned = QueryLexicon.tokens(in: slice)
                    .filter { !personNames.contains($0) && !QueryLexicon.intentWords.contains($0) && !QueryLexicon.dateWords.contains($0) }
                if let nickname = cleaned.first.flatMap({ QueryLexicon.placeNicknames[$0] }) {
                    return nickname
                }
                if !cleaned.isEmpty, cleaned.contains(where: { QueryLexicon.aliases[$0] == nil }) {
                    return cleaned.joined(separator: " ")
                }
            }
        }

        let leftover = tokens.filter { token in
            !QueryLexicon.dateWords.contains(token)
                && !QueryLexicon.intentWords.contains(token)
                && !personNames.contains(token)
                && QueryLexicon.aliases[token] == nil
                && token != albumTitle?.lowercased()
        }
        if let first = leftover.first, let nickname = QueryLexicon.placeNicknames[first] {
            return nickname
        }
        if leftover.isEmpty { return nil }
        if leftover.count == 1, QueryLexicon.placeNicknames[leftover[0]] != nil {
            return leftover[0]
        }
        return nil
    }

    private func resolvePlace(_ query: String?, preferCity: Bool) async -> PlaceHit? {
        guard var query, !query.isEmpty else { return nil }
        let original = query.lowercased()
        query = QueryLexicon.placeNicknames[original] ?? query
        let key = query.lowercased()
        if let cached = Self.placeCache[key] { return cached }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = preferCity ? [.address] : [.address, .pointOfInterest]

        do {
            var response = try await MKLocalSearch(request: request).start()
            if response.mapItems.isEmpty, preferCity {
                request.resultTypes = [.address, .pointOfInterest]
                response = try await MKLocalSearch(request: request).start()
            }
            let items = response.mapItems
            guard let item = pickMapItem(items, query: query, preferCity: preferCity) else { return nil }
            let coord = item.placemark.coordinate
            guard coord.latitude != 0 || coord.longitude != 0 else { return nil }

            let region = response.boundingRegion
            let isPOI = item.pointOfInterestCategory != nil && !preferCity
            let looksCountry = region.span.latitudeDelta > 6
                || (item.placemark.country?.localizedCaseInsensitiveCompare(query) == .orderedSame
                    && item.placemark.locality == nil)
            let looksMetro = QueryLexicon.metroQueries.contains(original)
                || QueryLexicon.metroQueries.contains(key)

            let kind: PlaceKind
            if isPOI { kind = .poi }
            else if looksCountry { kind = .country }
            else if looksMetro { kind = .metro }
            else { kind = .city }

            var latDelta = region.span.latitudeDelta
            var lonDelta = region.span.longitudeDelta
            var radius: CLLocationDistance
            switch kind {
            case .poi:
                radius = 800
                latDelta = 0
                lonDelta = 0
            case .city:
                radius = 35_000
                if latDelta < 0.15 {
                    latDelta = 0.45
                    lonDelta = 0.45
                }
            case .metro:
                radius = 140_000
                latDelta = max(latDelta, 1.2)
                lonDelta = max(lonDelta, 1.2)
            case .country:
                radius = 0
                latDelta = max(latDelta * 1.08, 8)
                lonDelta = max(lonDelta * 1.08, 8)
            }

            let hit = PlaceHit(
                name: item.name ?? item.placemark.locality ?? item.placemark.country ?? query,
                latitude: coord.latitude,
                longitude: coord.longitude,
                radius: radius,
                latitudeDelta: latDelta > 0.02 ? latDelta : nil,
                longitudeDelta: lonDelta > 0.02 ? lonDelta : nil,
                kind: kind
            )
            Self.placeCache[key] = hit
            return hit
        } catch {
            return nil
        }
    }

    private func pickMapItem(_ items: [MKMapItem], query: String, preferCity: Bool) -> MKMapItem? {
        let lowered = query.lowercased()
        if preferCity || QueryLexicon.placeNicknames.values.contains(where: { $0.lowercased() == lowered }) {
            if let dc = items.first(where: {
                let text = "\($0.name ?? "") \($0.placemark.administrativeArea ?? "") \($0.placemark.locality ?? "")".lowercased()
                return text.contains("district of columbia")
                    || text.contains("washington") && (text.contains("dc") || text.contains("d.c"))
            }) {
                return dc
            }
        }
        if preferCity {
            return items.first { $0.pointOfInterestCategory == nil } ?? items.first
        }
        return items.first
    }

    private func rankByScene(
        _ photos: ArraySlice<PhotoSummary>,
        keywords: [String],
        tokens: [String]
    ) async -> [PhotoSummary] {
        let toScore = Array(photos)
        var scored: [(PhotoSummary, Double)] = []
        await withTaskGroup(of: (PhotoSummary, Double).self) { group in
            var next = 0
            func enqueue() {
                guard next < toScore.count else { return }
                let photo = toScore[next]
                next += 1
                group.addTask { @MainActor in
                    let labels = await self.sceneLabels(for: photo.localIdentifier)
                    let value = self.score(photo: photo, labels: labels, keywords: keywords, tokens: tokens)
                    return (photo, value)
                }
            }
            for _ in 0..<min(8, toScore.count) { enqueue() }
            for await (photo, value) in group {
                if value >= 0.6 { scored.append((photo, value)) }
                enqueue()
            }
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    func sceneLabels(for id: String) async -> [String] {
        if let cached = labelCache[id] { return cached }
        guard let image = await requestThumbnail(for: id, size: CGSize(width: 280, height: 280)),
              let cgImage = image.cgImage
        else {
            labelCache[id] = []
            return []
        }
        let labels = await Self.classify(cgImage: cgImage).filter { $0 != "unlabeled" && $0 != "classification failed" }
        labelCache[id] = labels
        return labels
    }

    private func score(photo: PhotoSummary, labels: [String], keywords: [String], tokens: [String]) -> Double {
        let hay = labels.joined(separator: " ").lowercased()
        var value = 0.0
        for word in keywords where hay.contains(word) {
            value += 1.5
        }
        for token in tokens where hay.contains(token) {
            value += 0.6
        }
        if QueryLexicon.wantsGoldenHour(tokens), let date = photo.createdAt {
            let hour = Calendar.current.component(.hour, from: date)
            if (5...8).contains(hour) || (16...19).contains(hour) { value += 2 }
        }
        if photo.isFavorite { value += 0.4 }
        return value
    }
}
