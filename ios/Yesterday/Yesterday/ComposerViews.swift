import SwiftUI

struct ComposerBar: View {
    @Binding var text: String
    var enabled: Bool
    var onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend ? MessageTheme.bubbleBlue : Color.secondary.opacity(0.4))
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct PostAlbumStrip: View {
    @Environment(PhotoLibraryService.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(library.postAlbumIDs.isEmpty ? "Post album is empty" : "\(library.postAlbumIDs.count) in Post")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    if library.postAlbumIDs.isEmpty {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemFill))
                            .frame(width: 44, height: 44)
                    } else {
                        ForEach(library.postAlbumIDs, id: \.self) { id in
                            AssetThumbnail(id: id)
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

struct PermissionView: View {
    @Environment(PhotoLibraryService.self) private var library

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(MessageTheme.bubbleBlue)
            Text("Yesterday needs your library")
                .font(.title2.weight(.semibold))
            Text("Chat to group days and keepers. I’ll write the set into an album named Post for Instagram.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Allow Photos") {
                Task { await library.requestAccess() }
            }
            .buttonStyle(.borderedProminent)
            if library.authorization == .denied {
                Text("Enable Photos for Yesterday in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
