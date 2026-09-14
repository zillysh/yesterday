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
            .background(MessageTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Yesterday")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                if library.isLimited {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("More Photos") { showLimitedPicker = true }
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .toolbarBackground(MessageTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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

    private func thread(chat: ChatViewModel) -> some View {
        @Bindable var chat = chat
        return VStack(spacing: 0) {
            if library.isLimited {
                Button {
                    showLimitedPicker = true
                } label: {
                    Text("Only seeing \(library.visibleImageCount) allowed photos. Tap for your real camera roll.")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color.orange)
                }
                .buttonStyle(.plain)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if chat.messages.isEmpty {
                            emptyState
                        }
                        ForEach(chat.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        if chat.isSending {
                            Text("Looking through your camera roll…")
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.55))
                                .id("typing")
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
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
        VStack(alignment: .leading, spacing: 14) {
            Text("What are you looking for?")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Type what you remember, or tap one of these.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.45))
            SuggestionChipRow(enabled: true) { preset in
                Task { await chat.sendPreset(preset) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 28)
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
