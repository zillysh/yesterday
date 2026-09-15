import Accelerate
import Foundation

struct EmbeddingHit: Sendable {
    var id: String
    var score: Float
}

/// On-device vector DB: L2-normalized float vectors + localIdentifiers.
actor PhotoVectorStore {
    static let shared = PhotoVectorStore()

    private var ids: [String] = []
    private var modified: [Double] = []
    private var matrix: [Float] = [] // row-major, each row L2-normalized
    private var dim: Int = 512
    private var dirty = false

    private var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YesterdayEmbeddings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private var metaURL: URL { folder.appendingPathComponent("meta.json") }
    private var vectorsURL: URL { folder.appendingPathComponent("vectors.bin") }

    var count: Int { ids.count }
    var dimension: Int { dim }
    var isEmpty: Bool { ids.isEmpty }

    func load() {
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: data)
        else { return }
        dim = meta.dim
        ids = meta.ids
        modified = meta.modified
        guard let raw = try? Data(contentsOf: vectorsURL) else {
            ids = []
            modified = []
            return
        }
        let expected = ids.count * dim * MemoryLayout<Float>.size
        guard raw.count == expected else {
            ids = []
            modified = []
            matrix = []
            return
        }
        matrix = raw.withUnsafeBytes { ptr in
            Array(ptr.bindMemory(to: Float.self))
        }
    }

    func saveIfNeeded() {
        guard dirty else { return }
        let meta = Meta(dim: dim, ids: ids, modified: modified)
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: metaURL, options: .atomic)
        let byteCount = matrix.count * MemoryLayout<Float>.size
        matrix.withUnsafeBufferPointer { ptr in
            let data = Data(bytes: ptr.baseAddress!, count: byteCount)
            try? data.write(to: vectorsURL, options: .atomic)
        }
        dirty = false
    }

    func knownModification(for id: String) -> Double? {
        guard let idx = ids.firstIndex(of: id) else { return nil }
        return modified[idx]
    }

    func upsert(id: String, vector: [Float], modifiedAt: Double) {
        guard !vector.isEmpty else { return }
        if dim != vector.count, ids.isEmpty {
            dim = vector.count
        }
        guard vector.count == dim else { return }

        if let idx = ids.firstIndex(of: id) {
            let start = idx * dim
            for i in 0..<dim {
                matrix[start + i] = vector[i]
            }
            modified[idx] = modifiedAt
        } else {
            ids.append(id)
            modified.append(modifiedAt)
            matrix.append(contentsOf: vector)
        }
        dirty = true
    }

    func removeMissing(keeping present: Set<String>) {
        var keepIdx: [Int] = []
        keepIdx.reserveCapacity(ids.count)
        for (i, id) in ids.enumerated() where present.contains(id) {
            keepIdx.append(i)
        }
        guard keepIdx.count != ids.count else { return }
        var newIDs: [String] = []
        var newMod: [Double] = []
        var newMatrix: [Float] = []
        newIDs.reserveCapacity(keepIdx.count)
        newMod.reserveCapacity(keepIdx.count)
        newMatrix.reserveCapacity(keepIdx.count * dim)
        for i in keepIdx {
            newIDs.append(ids[i])
            newMod.append(modified[i])
            let start = i * dim
            newMatrix.append(contentsOf: matrix[start..<(start + dim)])
        }
        ids = newIDs
        modified = newMod
        matrix = newMatrix
        dirty = true
    }

    /// Cosine similarity = dot product (vectors are L2-normalized).
    func search(query: [Float], topK: Int, minScore: Float = 0.15) -> [EmbeddingHit] {
        guard !ids.isEmpty, query.count == dim, topK > 0 else { return [] }
        var scores = [Float](repeating: 0, count: ids.count)
        query.withUnsafeBufferPointer { qPtr in
            guard let qBase = qPtr.baseAddress else { return }
            matrix.withUnsafeBufferPointer { mPtr in
                guard let mBase = mPtr.baseAddress else { return }
                for i in 0..<ids.count {
                    var score: Float = 0
                    vDSP_dotpr(qBase, 1, mBase.advanced(by: i * dim), 1, &score, vDSP_Length(dim))
                    scores[i] = score
                }
            }
        }

        let k = min(topK, ids.count)
        var indices = Array(0..<ids.count)
        indices.sort { scores[$0] > scores[$1] }
        var hits: [EmbeddingHit] = []
        hits.reserveCapacity(k)
        for i in indices.prefix(k) {
            let score = scores[i]
            if score < minScore { break }
            hits.append(EmbeddingHit(id: ids[i], score: score))
        }
        return hits
    }

    /// Re-rank a candidate ID set by cosine to the query.
    func rank(ids candidateIDs: [String], query: [Float], minScore: Float = 0.12) -> [EmbeddingHit] {
        guard !candidateIDs.isEmpty, query.count == dim else {
            return candidateIDs.map { EmbeddingHit(id: $0, score: 0) }
        }
        let lookup = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        var hits: [EmbeddingHit] = []
        hits.reserveCapacity(candidateIDs.count)
        query.withUnsafeBufferPointer { qPtr in
            guard let qBase = qPtr.baseAddress else { return }
            matrix.withUnsafeBufferPointer { mPtr in
                guard let mBase = mPtr.baseAddress else { return }
                for id in candidateIDs {
                    guard let idx = lookup[id] else {
                        hits.append(EmbeddingHit(id: id, score: 0))
                        continue
                    }
                    var score: Float = 0
                    vDSP_dotpr(qBase, 1, mBase.advanced(by: idx * dim), 1, &score, vDSP_Length(dim))
                    if score >= minScore {
                        hits.append(EmbeddingHit(id: id, score: score))
                    }
                }
            }
        }
        hits.sort { $0.score > $1.score }
        return hits
    }

    private struct Meta: Codable {
        var dim: Int
        var ids: [String]
        var modified: [Double]
    }
}
