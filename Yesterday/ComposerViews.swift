import SwiftUI

struct SuggestionChipRow: View {
    var enabled: Bool
    var onPick: (String) -> Void

    private let chips: [(label: String, query: String)] = [
        ("Recents", "recent photos"),
        ("Yesterday", "yesterday"),
        ("Last weekend", "last weekend"),
        ("This weekend", "this weekend"),
        ("Favorites", "favorite photos"),
        ("Home", "cute home pics"),
        ("Golden hour", "golden hour"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips, id: \.label) { chip in
                    Button(chip.label) { onPick(chip.query) }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.1), in: Capsule())
                        .foregroundStyle(.white.opacity(0.9))
                        .disabled(!enabled)
                }
            }
        }
    }
}

struct ComposerBar: View {
    @Binding var text: String
    var enabled: Bool
    var onSend: () -> Void
    @State private var promptIndex = 0

    private let prompts = [
        "Trip to DC",
        "Yesterday",
        "Dinner last Saturday",
        "Golden hour",
        "Cute home pics",
        "Last weekend",
        "Someone you named in Photos",
    ]

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(prompts[promptIndex])
                        .foregroundStyle(.white.opacity(0.32))
                        .transition(.asymmetric(
                            insertion: .offset(y: 8).combined(with: .opacity),
                            removal: .offset(y: -8).combined(with: .opacity)
                        ))
                        .id(promptIndex)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .lineLimit(1...4)
                    .submitLabel(.send)
                    .onSubmit {
                        if canSend { onSend() }
                    }
            }
            .clipped()

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(canSend ? .white : .white.opacity(0.28))
            }
            .disabled(!canSend)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(MessageTheme.composer, in: Capsule())
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(MessageTheme.background)
        .animation(.easeInOut(duration: 0.4), value: promptIndex)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.6))
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        promptIndex = (promptIndex + 1) % prompts.count
                    }
                }
            }
        }
    }

    private var canSend: Bool {
        enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct PermissionView: View {
    @Environment(PhotoLibraryService.self) private var library

    var body: some View {
        VStack(spacing: 16) {
            Text("Yesterday needs your library")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Text("Ask for what you remember — a person you’ve named in Photos, a city, dinner, home — then pick a set for Post.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Allow Photos") {
                Task { await library.requestAccess() }
            }
            .buttonStyle(.borderedProminent)
            if library.authorization == .denied {
                Text("Enable Photos for Yesterday in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MessageTheme.background)
    }
}
