import Foundation
import Photos
import UIKit

/// Background indexer: Camera Roll thumbs → MobileCLIP embeddings → local vector store.
@MainActor
@Observable
final class PhotoEmbeddingIndex {
    static let shared = PhotoEmbeddingIndex()

    private(set) var isIndexing = false
    private(set) var indexedCount = 0
    private(set) var totalCount = 0
    private(set) var isReady = false
    private(set) var lastError: String?

    /// Screenshot localIdentifiers — mild rank penalty, still searchable.
    private var screenshotIDs = Set<String>()

    private var started = false
    private var indexTask: Task<Void, Never>?
    private let thumbSize = CGSize(width: 256, height: 256)

    private var screenshotURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YesterdayEmbeddings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("screenshots.json")
    }

    private init() {}

    func startIfNeeded(library: PhotoLibraryService) {
        guard !started else { return }
        started = true
        indexTask = Task(priority: .utility) {
            await bootstrap(library: library)
        }
    }

    /// Returns as soon as anything is indexed. Only blocks (≤5s) when count is 0.
    @discardableResult
    func ensureReady(minCount: Int) async -> Bool {
        startIfNeeded(library: .shared)
        await PhotoEmbedder.shared.prepare()
        guard await PhotoEmbedder.shared.isReady else {
            lastError = "MobileCLIP models missing from the app bundle."
            return false
        }
        if indexedCount > 0 { return true }

        for _ in 0..<10 {
            if indexedCount > 0 { return true }
            if let lastError { return false }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return indexedCount > 0
    }

    func search(text: String, topK: Int = 80, minScore: Float = 0.10) async -> [EmbeddingHit] {
        guard indexedCount > 0 else { return [] }
        // Broad prompts so "dog with people" / "park with friends" still rank in.
        let prompts = [
            text,
            "a photo of \(text)",
            "a photo of a \(text)",
            "\(text) in a photo",
            "people with \(text)",
        ]
        var merged: [String: EmbeddingHit] = [:]
        for prompt in prompts {
            guard let query = await PhotoEmbedder.shared.embedText(prompt) else { continue }
            var hits = await PhotoVectorStore.shared.search(
                query: query,
                topK: min(max(topK * 2, 120), 200),
                minScore: minScore
            )
            hits = penalizeScreenshots(hits)
            for hit in hits {
                if let existing = merged[hit.id] {
                    if hit.score > existing.score { merged[hit.id] = hit }
                } else {
                    merged[hit.id] = hit
                }
            }
        }
        let ranked = merged.values.sorted { $0.score > $1.score }
        // Soft tail trim only — keep inclusive matches (dog+people, park+friends).
        return softTrim(ranked, topK: topK, floor: minScore)
    }

    /// Drop only the obvious junk cliff at the end; keep mid-score "contains X" hits.
    private func softTrim(_ hits: [EmbeddingHit], topK: Int, floor: Float) -> [EmbeddingHit] {
        let candidates = Array(hits.filter { $0.score >= floor }.prefix(topK))
        guard candidates.count > 8, let top = candidates.first?.score, top > 0 else {
            return candidates
        }

        // Cut only on a late, sharp drop (junk after the inclusive set).
        var bestDrop: Float = 0
        var elbow = candidates.count
        let start = max(6, candidates.count / 4)
        for i in start..<candidates.count {
            let drop = candidates[i - 1].score - candidates[i].score
            if drop > bestDrop {
                bestDrop = drop
                elbow = i
            }
        }

        // Require a steep cliff (≥15% of top) late in the list.
        if bestDrop >= top * 0.15, elbow >= 8 {
            return Array(candidates.prefix(elbow))
        }
        return candidates
    }

    func rank(ids: [String], text: String, minScore: Float = 0.08) async -> [EmbeddingHit] {
        guard indexedCount > 0, !ids.isEmpty else {
            return ids.map { EmbeddingHit(id: $0, score: 0) }
        }
        let prompt = "a photo of \(text)"
        let query: [Float]
        if let embedded = await PhotoEmbedder.shared.embedText(prompt) {
            query = embedded
        } else if let embedded = await PhotoEmbedder.shared.embedText(text) {
            query = embedded
        } else {
            return ids.map { EmbeddingHit(id: $0, score: 0) }
        }
        var hits = await PhotoVectorStore.shared.rank(ids: ids, query: query, minScore: minScore)
        hits = penalizeScreenshots(hits)
        return hits
    }

    /// Drill: rank current set by similarity to a reference photo's embedding.
    func rankLike(ids: [String], referenceID: String, library: PhotoLibraryService) async -> [EmbeddingHit] {
        guard let image = await library.requestFastThumbnail(for: referenceID, size: thumbSize),
              let vector = await PhotoEmbedder.shared.embedImage(image)
        else {
            return ids.map { EmbeddingHit(id: $0, score: 0) }
        }
        var hits = await PhotoVectorStore.shared.rank(ids: ids, query: vector, minScore: 0.0)
        hits = penalizeScreenshots(hits)
        // Keep reference first if present
        hits.removeAll { $0.id == referenceID }
        hits.insert(EmbeddingHit(id: referenceID, score: 1), at: 0)
        return hits
    }

    private func penalizeScreenshots(_ hits: [EmbeddingHit]) -> [EmbeddingHit] {
        hits
            .map { hit in
                var h = hit
                if screenshotIDs.contains(h.id) { h.score *= 0.85 }
                return h
            }
            .sorted { $0.score > $1.score }
    }

    private func bootstrap(library: PhotoLibraryService) async {
        guard library.canRead else {
            started = false
            return
        }
        await PhotoVectorStore.shared.load()
        loadScreenshots()
        indexedCount = await PhotoVectorStore.shared.count
        isReady = indexedCount > 0

        await PhotoEmbedder.shared.prepare()
        guard await PhotoEmbedder.shared.isReady else {
            lastError = "MobileCLIP models or tokenizer missing from the app bundle."
            return
        }

        await indexLibrary(library: library)
    }

    private func indexLibrary(library: PhotoLibraryService) async {
        guard !isIndexing else { return }
        isIndexing = true
        defer { isIndexing = false }

        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        let fetch: PHFetchResult<PHAsset>
        if let roll = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumUserLibrary,
            options: nil
        ).firstObject {
            fetch = PHAsset.fetchAssets(in: roll, options: options)
        } else {
            fetch = PHAsset.fetchAssets(with: .image, options: options)
        }

        totalCount = fetch.count
        var present = Set<String>()
        present.reserveCapacity(fetch.count)
        var nextScreenshots = Set<String>()

        var batch = 0
        for index in 0..<fetch.count {
            if Task.isCancelled { break }
            let asset = fetch.object(at: index)
            let id = asset.localIdentifier
            present.insert(id)

            let isShot = asset.mediaSubtypes.contains(.photoScreenshot)
            if isShot { nextScreenshots.insert(id) }

            let modifiedAt = (asset.modificationDate ?? asset.creationDate ?? .distantPast)
                .timeIntervalSince1970
            if let known = await PhotoVectorStore.shared.knownModification(for: id),
               abs(known - modifiedAt) < 0.5
            {
                continue
            }

            guard let image = await library.requestFastThumbnail(for: id, size: thumbSize) else {
                continue
            }
            guard let vector = await PhotoEmbedder.shared.embedImage(image) else { continue }
            await PhotoVectorStore.shared.upsert(id: id, vector: vector, modifiedAt: modifiedAt)

            batch += 1
            indexedCount = await PhotoVectorStore.shared.count
            isReady = indexedCount > 0

            if batch % 10 == 0 {
                await PhotoVectorStore.shared.saveIfNeeded()
                await Task.yield()
            }
            // Keep scroll/chat responsive while the library indexes.
            if batch % 25 == 0 {
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
        }

        screenshotIDs = nextScreenshots
        saveScreenshots()
        await PhotoVectorStore.shared.removeMissing(keeping: present)
        await PhotoVectorStore.shared.saveIfNeeded()
        indexedCount = await PhotoVectorStore.shared.count
        isReady = indexedCount > 0
    }

    private func loadScreenshots() {
        guard let data = try? Data(contentsOf: screenshotURL),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        screenshotIDs = Set(ids)
    }

    private func saveScreenshots() {
        let ids = Array(screenshotIDs)
        guard let data = try? JSONEncoder().encode(ids) else { return }
        try? data.write(to: screenshotURL, options: .atomic)
    }
}
