import Foundation
import Photos

struct PhotoQueryResult {
    var photos: [PhotoSummary]
    var asked: String
    var note: String?
}

extension PhotoLibraryService {
    /// Embedding search, optionally filtered by a date chip first.
    func retrieve(_ intent: PhotoIntent) async -> PhotoQueryResult {
        let text = (intent.visual ?? intent.semantic)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return await photosForQuery(text.isEmpty ? intent.semantic : text)
    }

    func photosForQuery(_ raw: String, date: DatePhrase.Match? = nil) async -> PhotoQueryResult {
        let visual = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let asked: String = {
            if let date, !visual.isEmpty { return "\(date.label) · \(visual)" }
            if let date { return date.label }
            return visual
        }()

        // Date-only: calendar filter, newest first.
        if let date, visual.isEmpty {
            let photos = photosMatching(date: date, limit: 80)
            return PhotoQueryResult(photos: photos, asked: asked, note: indexingNote())
        }

        _ = await PhotoEmbeddingIndex.shared.ensureReady(minCount: 1)
        var hits = await PhotoEmbeddingIndex.shared.search(text: visual, topK: 80, minScore: 0.10)

        if let date {
            let allowed = Set(photosMatching(date: date, limit: 50_000).map(\.localIdentifier))
            hits = hits.filter { allowed.contains($0.id) }
            // If embed∩date is thin, fall back to date window (still useful).
            if hits.isEmpty {
                let photos = photosMatching(date: date, limit: 80)
                return PhotoQueryResult(
                    photos: photos,
                    asked: asked,
                    note: photos.isEmpty
                        ? "No photos for \(date.label)."
                        : "No strong “\(visual)” matches in \(date.label), so here are photos from that date."
                )
            }
        }

        let photos = orderedSummaries(ids: hits.map(\.id))
        return PhotoQueryResult(photos: photos, asked: asked, note: indexingNote())
    }

    func drill(currentIDs: [String], likePhotoID: String) async -> PhotoQueryResult {
        guard !currentIDs.isEmpty else {
            return PhotoQueryResult(photos: [], asked: "more like this")
        }
        let hits = await PhotoEmbeddingIndex.shared.rankLike(
            ids: currentIDs,
            referenceID: likePhotoID,
            library: self
        )
        let photos = orderedSummaries(ids: hits.map(\.id))
        return PhotoQueryResult(
            photos: photos.isEmpty ? summaries(for: currentIDs) : photos,
            asked: "more like this"
        )
    }

    private func photosMatching(date: DatePhrase.Match, limit: Int) -> [PhotoSummary] {
        switch date.constraint {
        case .absolute(let start, let end):
            return photos(
                inCollectionID: nil,
                start: start,
                end: end,
                favoritesOnly: false,
                locatedOnly: false,
                limit: limit,
                scanCap: 200_000
            )
        case .monthDay, .monthOnly:
            // No year → scan and keep matching month/day (or month) in any year.
            let pool = photos(
                inCollectionID: nil,
                start: nil,
                end: nil,
                favoritesOnly: false,
                locatedOnly: false,
                limit: min(limit * 20, 20_000),
                scanCap: 80_000
            )
            return Array(
                pool
                    .filter { photo in
                        guard let created = photo.createdAt else { return false }
                        return date.constraint.contains(created)
                    }
                    .prefix(limit)
            )
        }
    }

    private func indexingNote() -> String? {
        let index = PhotoEmbeddingIndex.shared
        guard index.isIndexing, index.indexedCount > 0 else { return nil }
        return "Searching the \(index.indexedCount.formatted()) photos indexed so far."
    }

    private func orderedSummaries(ids: [String]) -> [PhotoSummary] {
        let fetched = summaries(for: ids)
        let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.localIdentifier, $0) })
        return ids.compactMap { byID[$0] }
    }
}
