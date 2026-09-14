import SwiftUI

struct RootView: View {
    @Environment(PhotoLibraryService.self) private var library

    var body: some View {
        TabView {
            ChatView()
                .tabItem {
                    Label("Chat", systemImage: "bubble.left")
                }
            PostsView()
                .tabItem {
                    Label("Posts", systemImage: "square.stack")
                }
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .onAppear {
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(MessageTheme.background)
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}

struct PostsView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Environment(SavedPostsStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if !library.canRead {
                    PermissionView()
                } else if store.posts.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .background(MessageTheme.background.ignoresSafeArea())
            .navigationTitle("Posts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(MessageTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task {
                if library.canRead {
                    store.refreshIDs()
                }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing saved yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Pick photos in Chat, save them, and the set shows up here — and as its own album in Photos.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .padding(.top, 20)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(store.posts) { post in
                    NavigationLink {
                        SavedSetView(post: post)
                    } label: {
                        HStack(alignment: .center, spacing: 14) {
                            AssetThumbnail(id: post.photoIDs.first ?? "", targetSize: CGSize(width: 240, height: 240))
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(post.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text("\(post.photoIDs.count) photos · \(DateFormatter.tripDay.string(from: post.createdAt))")
                                    .font(.footnote)
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 18)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove from Posts", role: .destructive) {
                            store.remove(post)
                        }
                    }
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
    }
}

struct SavedSetView: View {
    let post: SavedPost
    @State private var lookingAt: PhotoPeek?
    @State private var cellWidth: CGFloat = 110
    @Namespace private var photoZoom

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(post.title)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
                Text("\(post.photoIDs.count) photos")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(rows) { row in
                        switch row {
                        case .grid(let ids):
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(ids, id: \.self) { id in
                                    tile(id: id, groupIDs: ids)
                                }
                            }
                            .padding(.horizontal, 16)
                        case .strip(let ids):
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(ids.count) similar")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.4))
                                    .padding(.horizontal, 16)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(ids, id: \.self) { id in
                                            tile(id: id, groupIDs: ids, size: cellWidth)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 28)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .background {
            GeometryReader { geo in
                Color.clear.onAppear {
                    cellWidth = (geo.size.width - 32 - 20) / 3
                }
            }
        }
        .navigationDestination(item: $lookingAt) { peek in
            LookThroughView(
                messageID: UUID(),
                momentID: UUID(),
                photoIDs: peek.groupIDs,
                startID: peek.id,
                canPick: false
            )
            .navigationBarBackButtonHidden()
            .toolbar(.hidden, for: .navigationBar)
            .navigationTransition(.zoom(sourceID: peek.id, in: photoZoom))
        }
        .preferredColorScheme(.dark)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var rows: [AlbumRow] {
        var rows: [AlbumRow] = []
        var grid: [String] = []
        for group in PhotoLibraryService.shared.similarGroups(from: post.photoIDs) {
            if group.photoIDs.count == 1 {
                grid.append(group.photoIDs[0])
            } else {
                if !grid.isEmpty {
                    rows.append(.grid(grid))
                    grid = []
                }
                rows.append(.strip(group.photoIDs))
            }
        }
        if !grid.isEmpty { rows.append(.grid(grid)) }
        return rows
    }

    private func tile(id: String, groupIDs: [String], size: CGFloat? = nil) -> some View {
        Button {
            lookingAt = PhotoPeek(id: id, groupIDs: groupIDs)
        } label: {
            Group {
                if let size {
                    AssetThumbnail(id: id, targetSize: CGSize(width: 280, height: 280))
                        .frame(width: size, height: size)
                        .clipped()
                } else {
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            AssetThumbnail(id: id, targetSize: CGSize(width: 280, height: 280))
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: id, in: photoZoom)
    }
}
