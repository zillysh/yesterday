import SwiftUI
import UIKit

enum MessageTheme {
    static let background = Color.black
    static let userBubble = Color(red: 0.22, green: 0.22, blue: 0.24)
    static let composer = Color(red: 0.20, green: 0.20, blue: 0.22)
    static let bubbleBlue = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let incoming = Color(red: 0.22, green: 0.22, blue: 0.24)
}

struct MessageBubble: View {
    let message: ChatMessage
    @Environment(ChatViewModel.self) private var chat

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 14) {
            if !message.text.isEmpty {
                if message.role == .user {
                    HStack {
                        Spacer(minLength: 48)
                        Text(message.text)
                            .font(.body)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(MessageTheme.userBubble, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                } else {
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !message.choices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(message.choices) { choice in
                        Button {
                            chat.pickChoice(choice)
                        } label: {
                            Text(choice.label)
                                .font(.subheadline)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.white.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !message.moments.isEmpty {
                ForEach(message.moments) { moment in
                    PhotoStackRow(messageID: message.id, moment: moment)
                }
            } else if !message.photoIDs.isEmpty {
                PhotoStackRow(
                    messageID: message.id,
                    moment: Moment(
                        title: "",
                        subtitle: "",
                        photoIDs: message.photoIDs,
                        selectedIDs: Array(message.selectedIDs),
                        savedToPost: message.savedToPost
                    )
                )
            }
        }
    }
}

struct PhotoStackRow: View {
    let messageID: UUID
    let moment: Moment
    @Environment(ChatViewModel.self) private var chat
    @State private var showAlbum = false

    private var live: Moment {
        chat.messages.first { $0.id == messageID }?.moments.first { $0.id == moment.id } ?? moment
    }

    private var stackIDs: [String] {
        Array(live.photoIDs.prefix(3))
    }

    var body: some View {
        Button {
            showAlbum = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                PhotoFan(ids: stackIDs)
                if live.savedToPost {
                    Label("Saved to Posts", systemImage: "checkmark")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $showAlbum) {
            AlbumPickerView(messageID: messageID, momentID: moment.id)
        }
    }
}

/// Overlapping rounded photos, like the ChatGPT stack.
struct PhotoFan: View {
    let ids: [String]

    var body: some View {
        let shown = Array(ids.prefix(3))
        ZStack {
            ForEach(Array(shown.enumerated()), id: \.element) { index, id in
                let offset = fanOffset(index: index, count: shown.count)
                AssetThumbnail(id: id, targetSize: CGSize(width: 220, height: 220))
                    .frame(width: 168, height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 6)
                    .rotationEffect(.degrees(offset.angle))
                    .offset(x: offset.x, y: offset.y)
                    .zIndex(Double(index))
            }
        }
        .frame(width: 200, height: 200)
    }

    private func fanOffset(index: Int, count: Int) -> (angle: Double, x: CGFloat, y: CGFloat) {
        if count == 1 { return (0, 0, 0) }
        if count == 2 {
            return index == 0 ? (-11, -10, 8) : (8, 12, -4)
        }
        switch index {
        case 0: return (-14, -16, 10)
        case 1: return (3, 0, 2)
        default: return (12, 16, -8)
        }
    }
}

struct AlbumPickerView: View {
    let messageID: UUID
    let momentID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(ChatViewModel.self) private var chat
    @State private var lookingAt: PhotoPeek?
    @State private var cellWidth: CGFloat = 110
    @Namespace private var photoZoom

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        NavigationStack {
            picker
                .navigationBarBackButtonHidden()
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(item: $lookingAt) { peek in
                    LookThroughView(
                        messageID: messageID,
                        momentID: momentID,
                        photoIDs: peek.groupIDs,
                        startID: peek.id
                    )
                    .navigationBarBackButtonHidden()
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationTransition(.zoom(sourceID: peek.id, in: photoZoom))
                }
        }
    }

    private var picker: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Close") { dismiss() }
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
                Text("\(photoIDs.count) photos")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)
            .onAppear {
                PhotoLibraryService.shared.startCachingThumbnails(
                    ids: Array(photoIDs.prefix(90)),
                    size: CGSize(width: 200, height: 200)
                )
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(albumRows) { row in
                        switch row {
                        case .grid(let ids):
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(ids, id: \.self) { id in
                                    albumTile(id: id, groupIDs: ids)
                                }
                            }
                            .padding(.horizontal, 16)
                        case .strip(let ids):
                            similarStrip(ids)
                        }
                    }
                }
                .padding(.bottom, selectedIDs.isEmpty ? 24 : 8)
            }

            if !selectedIDs.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your post")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.45))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(selectedIDs, id: \.self) { id in
                                Button {
                                    lookingAt = PhotoPeek(id: id, groupIDs: groupIDs(containing: id))
                                } label: {
                                    AssetThumbnail(id: id, targetSize: CGSize(width: 220, height: 220))
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Button {
                        Task {
                            await chat.saveToPost(messageID: messageID, momentID: momentID)
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                            Text(selectedIDs.count == 1 ? "Save 1 photo to Post" : "Save \(selectedIDs.count) photos to Post")
                        }
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .background(MessageTheme.background)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .background {
            GeometryReader { geo in
                Color.clear.onAppear {
                    cellWidth = (geo.size.width - 32 - 20) / 3
                }
                .onChange(of: geo.size.width) { _, width in
                    cellWidth = (width - 32 - 20) / 3
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var headline: String {
        let title = moment?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Photos" : title
    }

    private var moment: Moment? {
        chat.messages.first { $0.id == messageID }?.moments.first { $0.id == momentID }
    }

    private var photoIDs: [String] {
        moment?.photoIDs ?? []
    }

    private var selectedIDs: [String] {
        moment?.selectedIDs ?? []
    }

    private var albumRows: [AlbumRow] {
        var rows: [AlbumRow] = []
        var grid: [String] = []
        for group in PhotoLibraryService.shared.similarGroups(from: photoIDs) {
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

    private func groupIDs(containing id: String) -> [String] {
        PhotoLibraryService.shared.similarGroups(from: photoIDs)
            .first { $0.photoIDs.contains(id) }?
            .photoIDs ?? photoIDs
    }

    private func similarStrip(_ ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(ids.count) similar")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ids, id: \.self) { id in
                        albumTile(id: id, groupIDs: ids, size: cellWidth)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func albumTile(id: String, groupIDs: [String], size: CGFloat? = nil) -> some View {
        let picked = selectedIDs.contains(id)
        return ZStack(alignment: .topTrailing) {
            Button {
                lookingAt = PhotoPeek(id: id, groupIDs: groupIDs)
            } label: {
                Group {
                    if let size {
                        AssetThumbnail(id: id, targetSize: CGSize(width: 220, height: 220))
                            .frame(width: size, height: size)
                            .clipped()
                    } else {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                AssetThumbnail(id: id, targetSize: CGSize(width: 220, height: 220))
                            }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(picked ? Color.white : Color.clear, lineWidth: 2)
                }
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: id, in: photoZoom)

            Button {
                chat.toggle(photo: id, in: messageID, momentID: momentID)
            } label: {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(picked ? .black : .white.opacity(0.9), picked ? .white : .clear)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
    }
}

enum AlbumRow: Identifiable {
    case grid([String])
    case strip([String])

    var id: String {
        switch self {
        case .grid(let ids): return "g-\(ids.first ?? "")-\(ids.count)"
        case .strip(let ids): return "s-\(ids.first ?? "")-\(ids.count)"
        }
    }
}

struct PhotoPeek: Identifiable, Hashable {
    let id: String
    var groupIDs: [String]
}

struct LookThroughView: View {
    let messageID: UUID
    let momentID: UUID
    let photoIDs: [String]
    let startID: String
    var canPick = true
    var onCurrentChange: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(ChatViewModel.self) private var chat
    @State private var current: String
    @State private var pageZoomed = false
    @State private var chromeVisible = true
    @State private var caption = ""
    @State private var dismissOffset: CGFloat = 0

    init(
        messageID: UUID,
        momentID: UUID,
        photoIDs: [String],
        startID: String,
        canPick: Bool = true,
        onCurrentChange: ((String) -> Void)? = nil
    ) {
        self.messageID = messageID
        self.momentID = momentID
        self.photoIDs = photoIDs
        self.startID = startID
        self.canPick = canPick
        self.onCurrentChange = onCurrentChange
        _current = State(initialValue: startID)
    }

    var body: some View {
        let progress = min(1, max(0, dismissOffset / 280))
        let showChrome = chromeVisible && !pageZoomed && progress < 0.05

        ZStack {
            Color.black.opacity(1 - progress * 0.55)
                .ignoresSafeArea()

            PhotoBrowserPager(
                photoIDs: photoIDs,
                currentID: $current,
                isZoomed: $pageZoomed,
                dismissOffset: $dismissOffset,
                onSingleTap: toggleChrome,
                onDismiss: { dismiss() }
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topChrome
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                Spacer(minLength: 0)
                bottomChrome
            }
            .opacity(showChrome ? 1 : 0)
            .allowsHitTesting(showChrome)
            .animation(.easeInOut(duration: 0.15), value: showChrome)
        }
        .background(Color.black.opacity(1 - progress * 0.35).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(!showChrome)
        .onAppear {
            onCurrentChange?(current)
            refreshCaption()
            prefetchNeighbors()
        }
        .onChange(of: current) {
            pageZoomed = false
            dismissOffset = 0
            onCurrentChange?(current)
            refreshCaption()
            prefetchNeighbors()
        }
    }

    private var topChrome: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center) {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                if photoIDs.count > 1 {
                    Text(positionLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }

            if !caption.isEmpty {
                Text(caption)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var bottomChrome: some View {
        VStack(spacing: 14) {
            if photoIDs.count > 1 {
                photoStrip
            }

            if canPick {
                addToPostButton
                    .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 12)
        .padding(.top, 16)
        .frame(maxWidth: .infinity)
    }

    private var photoStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 5) {
                    ForEach(photoIDs, id: \.self) { id in
                        Button {
                            current = id
                        } label: {
                            AssetThumbnail(id: id, targetSize: CGSize(width: 96, height: 96))
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(current == id ? Color.white : Color.clear, lineWidth: 2)
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    if selectedIDs.contains(id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption2)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.black, Color(red: 0.32, green: 0.82, blue: 0.45))
                                            .padding(2)
                                    }
                                }
                                .opacity(current == id ? 1 : 0.4)
                        }
                        .buttonStyle(.plain)
                        .id(id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: current) { _, id in
                proxy.scrollTo(id, anchor: .center)
            }
            .onAppear {
                proxy.scrollTo(current, anchor: .center)
            }
        }
        .frame(height: 52)
    }

    private var addToPostButton: some View {
        Button {
            chat.toggle(photo: current, in: messageID, momentID: momentID)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "plus")
                    .font(.body.weight(.semibold))
                VStack(spacing: 2) {
                    Text(isSelected ? "Added to your post" : "Add to post")
                        .font(.body.weight(.semibold))
                    if isSelected {
                        Text(selectedCount == 1 ? "Tap to remove" : "\(selectedCount) picked · tap to remove")
                            .font(.caption)
                            .opacity(0.7)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, isSelected ? 12 : 14)
            .background(
                isSelected ? Color(red: 0.32, green: 0.82, blue: 0.45) : Color.white,
                in: Capsule()
            )
            .foregroundStyle(.black)
        }
        .animation(.easeOut(duration: 0.2), value: isSelected)
        .sensoryFeedback(isSelected ? .success : .impact(weight: .light), trigger: isSelected)
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.15)) {
            chromeVisible.toggle()
        }
    }

    private func refreshCaption() {
        caption = PhotoLibraryService.shared.viewerCaption(for: current)
    }

    private func prefetchNeighbors() {
        guard let index = photoIDs.firstIndex(of: current) else { return }
        var ids = [current]
        if index > 0 { ids.append(photoIDs[index - 1]) }
        if index + 1 < photoIDs.count { ids.append(photoIDs[index + 1]) }
        PhotoLibraryService.shared.startCachingThumbnails(
            ids: ids,
            size: CGSize(width: 900, height: 900)
        )
    }

    private var selectedIDs: [String] {
        chat.messages
            .first { $0.id == messageID }?
            .moments.first { $0.id == momentID }?
            .selectedIDs ?? []
    }

    private var selectedCount: Int { selectedIDs.count }

    private var isSelected: Bool {
        selectedIDs.contains(current)
    }

    private var positionLabel: String {
        guard let index = photoIDs.firstIndex(of: current) else { return "" }
        return "\(index + 1) of \(photoIDs.count)"
    }
}

struct AssetThumbnail: View {
    let id: String
    var showsDate = false
    var fills = true
    var targetSize = CGSize(width: 400, height: 400)
    @State private var image: UIImage?
    @State private var dateLabel = ""
    @State private var loadedForID: String = ""

    var body: some View {
        ZStack {
            Color(uiColor: .tertiarySystemFill)
            if let image, loadedForID == id {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fills ? .fill : .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
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
        .onChange(of: id) { _, _ in
            image = nil
            loadedForID = ""
            dateLabel = ""
        }
        .task(id: "\(id)-\(Int(targetSize.width))-\(fills)") {
            let requested = id
            image = nil
            loadedForID = ""
            dateLabel = PhotoLibraryService.shared.dateLabel(for: requested)
            if fills {
                let fast = await PhotoLibraryService.shared.requestFastThumbnail(
                    for: requested,
                    size: CGSize(width: min(targetSize.width, 120), height: min(targetSize.height, 120))
                )
                if Task.isCancelled || requested != id { return }
                image = fast
                loadedForID = requested
                if let sharp = await PhotoLibraryService.shared.requestThumbnail(for: requested, size: targetSize) {
                    if Task.isCancelled || requested != id { return }
                    image = sharp
                    loadedForID = requested
                }
            } else {
                // Preserve full frame — no center-crop for fit thumbnails.
                if let fitted = await PhotoLibraryService.shared.requestDisplayImage(for: requested, size: targetSize) {
                    if Task.isCancelled || requested != id { return }
                    image = fitted
                    loadedForID = requested
                }
            }
        }
    }
}
