import Foundation
import Observation
import Photos

struct SavedPost: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var albumID: String
    var title: String
    var photoIDs: [String]
    var createdAt: Date
}

@MainActor
@Observable
final class SavedPostsStore {
    static let shared = SavedPostsStore()
    private static let key = "yesterday.savedPosts"

    var posts: [SavedPost] = []

    private init() {
        load()
    }

    func add(title: String, albumID: String, photoIDs: [String]) {
        let post = SavedPost(
            id: UUID(),
            albumID: albumID,
            title: title,
            photoIDs: photoIDs,
            createdAt: Date()
        )
        posts.insert(post, at: 0)
        persist()
    }

    func remove(_ post: SavedPost) {
        posts.removeAll { $0.id == post.id }
        persist()
    }

    func refreshIDs() {
        posts = posts.compactMap { post in
            let fetch = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [post.albumID],
                options: nil
            )
            guard let album = fetch.firstObject else { return post }
            let assets = PHAsset.fetchAssets(in: album, options: nil)
            var ids: [String] = []
            assets.enumerateObjects { asset, _, _ in
                if asset.mediaType == .image {
                    ids.append(asset.localIdentifier)
                }
            }
            var updated = post
            if !ids.isEmpty { updated.photoIDs = ids }
            return updated
        }
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([SavedPost].self, from: data)
        else { return }
        posts = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(posts) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
