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
    var dateChips: [DateChip]
    var onRemoveChip: (UUID) -> Void
    var onDraftChange: () -> Void
    var enabled: Bool
    var onSend: () -> Void
    @State private var promptIndex = 0

    private let prompts = [
        "7th aug dog",
        "Last weekend beach",
        "june 2025",
        "Yesterday",
        "Golden hour",
        "Cute home pics",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !dateChips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(dateChips) { chip in
                            dateChipView(chip)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }

            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    if text.isEmpty && dateChips.isEmpty {
                        Text(prompts[promptIndex])
                            .foregroundStyle(.white.opacity(0.32))
                            .transition(.asymmetric(
                                insertion: .offset(y: 8).combined(with: .opacity),
                                removal: .offset(y: -8).combined(with: .opacity)
                            ))
                            .id(promptIndex)
                            .allowsHitTesting(false)
                    } else if text.isEmpty, !dateChips.isEmpty {
                        Text("Add what you see — dog, beach…")
                            .foregroundStyle(.white.opacity(0.32))
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .lineLimit(1...4)
                        .submitLabel(.send)
                        .onChange(of: text) { _, _ in
                            onDraftChange()
                        }
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
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .background(MessageTheme.composer, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(MessageTheme.background)
        .animation(.easeInOut(duration: 0.4), value: promptIndex)
        .animation(.easeOut(duration: 0.18), value: dateChips.map(\.id))
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

    private func dateChipView(_ chip: DateChip) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.caption.weight(.semibold))
            Text(chip.label)
                .font(.subheadline.weight(.medium))
            Button {
                onRemoveChip(chip.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.14), in: Capsule())
    }

    private var canSend: Bool {
        enabled && (
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !dateChips.isEmpty
        )
    }
}

struct PermissionView: View {
    @Environment(PhotoLibraryService.self) private var library

    var body: some View {
        VStack(spacing: 16) {
            Text("Yesterday needs your library")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Text("Ask for what you remember — a day, a weekend, dog, beach — then pick a set for Post.")
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
