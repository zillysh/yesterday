import Foundation
import Photos

struct PhotoQueryResult {
    var photos: [PhotoSummary]
    var asked: String
    var note: String?
}

extension PhotoLibraryService {
    /// Embedding-only search. Cosine order is preserved.
    func retrieve(_ intent: PhotoIntent) async -> PhotoQueryResult {
        let text = (intent.visual ?? intent.semantic)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return await photosForQuery(text.isEmpty ? intent.semantic : text)
    }

    func photosForQuery(_ raw: String) async -> PhotoQueryResult {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return PhotoQueryResult(photos: [], asked: raw)
        }

        _ = await PhotoEmbeddingIndex.shared.ensureReady(minCount: 1)
        // Inclusive visual search: anything that contains the concept.
        let hits = await PhotoEmbeddingIndex.shared.search(text: query, topK: 80, minScore: 0.10)
        let photos = orderedSummaries(ids: hits.map(\.id))
        return PhotoQueryResult(
            photos: photos,
            asked: query,
            note: indexingNote()
        )
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
