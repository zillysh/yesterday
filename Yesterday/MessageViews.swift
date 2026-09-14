import SwiftUI
import UIKit

enum MessageTheme {
    static let bubbleBlue = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let incoming = Color(uiColor: .secondarySystemFill)
    static let background = Color(uiColor: .systemBackground)
}

struct MessageBubble: View {
    let message: ChatMessage
    @Environment(ChatViewModel.self) private var chat

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(message.role == .user ? MessageTheme.bubbleBlue : MessageTheme.incoming)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                if !message.photoIDs.isEmpty {
                    PhotoGridBubble(message: message)
                }
            }
            if message.role == .assistant { Spacer(minLength: 48) }
        }
    }
}

struct PhotoGridBubble: View {
    let message: ChatMessage
    @Environment(ChatViewModel.self) private var chat

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 3)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(message.photoIDs, id: \.self) { id in
                    Button {
                        chat.toggle(photo: id, in: message.id)
                    } label: {
                        AssetThumbnail(id: id, showsDate: true)
                            .frame(minWidth: 88, minHeight: 88)
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                            .opacity(message.selectedIDs.contains(id) ? 1 : 0.35)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: message.selectedIDs.contains(id) ? "checkmark.circle.fill" : "circle")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, MessageTheme.bubbleBlue)
                                    .padding(6)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack {
                Text("\(message.selectedIDs.count) kept")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if message.savedToPost {
                    Text("In Post")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MessageTheme.bubbleBlue)
                } else {
                    Button("Save to Post") {
                        Task { await chat.saveToPost(messageID: message.id) }
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(message.selectedIDs.isEmpty)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: 320, alignment: .leading)
    }
}

struct AssetThumbnail: View {
    let id: String
    var showsDate = false
    @State private var image: UIImage?
    @State private var dateLabel = ""

    var body: some View {
        ZStack {
            Color(uiColor: .tertiarySystemFill)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
            if showsDate, !dateLabel.isEmpty {
                VStack {
                    Spacer()
                    Text(dateLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity)
                        .background(.black.opacity(0.45))
                }
            }
        }
        .task(id: id) {
            dateLabel = PhotoLibraryService.shared.dateLabel(for: id)
            image = await PhotoLibraryService.shared.requestThumbnail(
                for: id,
                size: CGSize(width: 400, height: 400)
            )
        }
    }
}
