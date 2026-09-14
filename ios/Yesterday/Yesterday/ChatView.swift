import Photos
import PhotosUI
import SwiftUI

struct ChatView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Environment(ChatViewModel.self) private var chat
    @State private var showLimitedPicker = false

    var body: some View {
        @Bindable var chat = chat
        NavigationStack {
            Group {
                if library.canRead {
                    thread(chat: chat)
                } else {
                    PermissionView()
                }
            }
            .background(MessageTheme.background)
            .navigationTitle("Yesterday")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Yesterday")
                            .font(.headline)
                        Text(statusLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if library.isLimited {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("More Photos") { showLimitedPicker = true }
                    }
                }
            }
            .task {
                if library.canRead {
                    await library.refresh()
                }
            }
            .background {
                LimitedLibraryPresenter(isPresented: $showLimitedPicker)
            }
        }
    }

    private var statusLine: String {
        let count = library.postAlbumIDs.count
        return "\(chat.modelNote) · \(count) in Post album"
    }

    private func thread(chat: ChatViewModel) -> some View {
        @Bindable var chat = chat
        return VStack(spacing: 0) {
            if library.isLimited {
                Button {
                    showLimitedPicker = true
                } label: {
                    Text("Only seeing \(library.visibleImageCount) allowed photos. Tap to pick your real camera roll.")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color.orange)
                }
                .buttonStyle(.plain)
            }
            PostAlbumStrip()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if chat.messages.isEmpty {
                            emptyState
                        }
                        ForEach(chat.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        if chat.isSending {
                            TypingBubble()
                                .id("typing")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.messages.count) {
                    if let last = chat.messages.last?.id {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            if let saveError = chat.saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
            ComposerBar(text: $chat.draft, enabled: !chat.isSending) {
                Task { await chat.send() }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("Ask for a day, a weekend, or a group.")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("I’ll put the keepers in your Post album.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }
}

private struct TypingBubble: View {
    var body: some View {
        HStack {
            Text("…")
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(MessageTheme.incoming)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 48)
        }
    }
}

private struct LimitedLibraryPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard isPresented, controller.view.window != nil else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
        DispatchQueue.main.async {
            isPresented = false
        }
    }
}
