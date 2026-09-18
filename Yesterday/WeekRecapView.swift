import SwiftUI
import UIKit

/// Immersive week recap — fullscreen photos, editable highlights on the bottom, finish & share.
struct WeekRecapView: View {
    var model: MomentsViewModel
    /// Snapshot at open — survives refresh so the recap never goes blank.
    let initialWeek: MomentWeek
    /// Prefer landing on this highlight cover (from the tapped story card).
    var initialPhotoID: String = ""
    var onClose: () -> Void

    @State private var currentID: String = ""
    @State private var pageZoomed = false
    @State private var dismissOffset: CGFloat = 0
    @State private var chromeVisible = true
    @State private var swappingMomentID: UUID?
    @State private var swapCoverDraft = ""
    @State private var sharingRecap: SharedWeekRecap?
    @State private var shareTemplates: [RecapTemplateOption] = []
    @State private var sharePhotos: [UIImage] = []
    @State private var isPreparingShare = false
    @State private var confirmRemove = false
    @State private var isAddingMoment = false
    @State private var isCreatingMoment = false
    @State private var editingCaptionMoment: LibraryMoment?
    @State private var captionDraft = ""

    /// Prefer live model data (covers / deletes); never resurrect a deleted week from the open snapshot.
    private var week: MomentWeek {
        if let live = model.weeks.first(where: {
            Calendar.current.isDate($0.weekStart, inSameDayAs: initialWeek.weekStart)
        }) {
            return live
        }
        var shell = initialWeek
        shell.moments = []
        return shell
    }

    private var moments: [LibraryMoment] {
        week.moments
    }

    /// One lead photo per highlight — swipe only between these.
    private var highlightPhotoIDs: [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for moment in moments where !moment.coverID.isEmpty {
            if seen.insert(moment.coverID).inserted {
                ids.append(moment.coverID)
            }
        }
        return ids
    }

    private var activeMoment: LibraryMoment? {
        moments.first { $0.coverID == currentID }
            ?? moments.first { $0.photoIDs.contains(currentID) }
    }

    private var resolvedStartID: String {
        if !initialPhotoID.isEmpty {
            if highlightPhotoIDs.contains(initialPhotoID) {
                return initialPhotoID
            }
            if let moment = moments.first(where: {
                $0.coverID == initialPhotoID || $0.photoIDs.contains(initialPhotoID)
            }) {
                return moment.coverID
            }
        }
        return highlightPhotoIDs.first ?? ""
    }

    var body: some View {
        Group {
            if highlightPhotoIDs.isEmpty {
                missing
            } else {
                recapBody
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if currentID.isEmpty || !highlightPhotoIDs.contains(currentID) {
                currentID = resolvedStartID
            }
        }
        .onChange(of: highlightPhotoIDs) { _, ids in
            if currentID.isEmpty || !ids.contains(currentID) {
                currentID = ids.first ?? ""
            }
        }
        .fullScreenCover(item: swapSessionBinding) { session in
            HighlightEditorView(
                title: session.title,
                dayLabel: session.dayLabel,
                photoIDs: session.photoIDs,
                coverID: $swapCoverDraft,
                onClose: { swappingMomentID = nil }
            )
            .preferredColorScheme(.dark)
            .onChange(of: swapCoverDraft) { _, newCover in
                guard !newCover.isEmpty else { return }
                model.setCover(photoIDs: session.photoIDs, photoID: newCover)
                currentID = newCover
            }
        }
        .sheet(item: $sharingRecap) { recap in
            RecapShareSheet(
                recap: recap,
                photos: sharePhotos,
                templates: shareTemplates
            ) {
                sharingRecap = nil
                shareTemplates = []
                sharePhotos = []
            }
            .presentationDetents([.large])
        }
        .confirmationDialog("Remove this moment?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                removeActiveFromRecap()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It’ll be removed from this week and won’t come back when you reopen.")
        }
        .sheet(isPresented: $isAddingMoment) {
            AddMomentPickerSheet(
                weekStart: week.weekStart,
                dateRange: week.dateRange,
                usedPhotoIDs: Set(moments.flatMap(\.photoIDs)),
                isCreating: $isCreatingMoment,
                onCancel: { isAddingMoment = false },
                onAdd: { ids in
                    Task { await addMoment(photoIDs: ids) }
                }
            )
            .presentationDetents([.large])
            .preferredColorScheme(.dark)
        }
        .alert(
            "Edit caption",
            isPresented: Binding(
                get: { editingCaptionMoment != nil },
                set: { if !$0 { editingCaptionMoment = nil } }
            )
        ) {
            TextField("Caption", text: $captionDraft)
            Button("Save") {
                if let moment = editingCaptionMoment {
                    model.setTitle(captionDraft, for: moment)
                }
                editingCaptionMoment = nil
            }
            Button("Cancel", role: .cancel) {
                editingCaptionMoment = nil
            }
        } message: {
            Text("This shows on the highlight and in shared templates.")
        }
    }

    private var swapSessionBinding: Binding<HighlightEditSession?> {
        Binding(
            get: {
                guard let id = swappingMomentID,
                      let moment = moments.first(where: { $0.id == id })
                else { return nil }
                return HighlightEditSession(moment: moment)
            },
            set: { newValue in
                swappingMomentID = newValue?.id
            }
        )
    }

    private var missing: some View {
        VStack(spacing: 16) {
            Text("This week isn’t available")
                .font(.headline)
                .foregroundStyle(.white)
            Button("Close", action: onClose)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }

    private var recapBody: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)

            ZStack(alignment: .bottom) {
                PhotoBrowserPager(
                    photoIDs: highlightPhotoIDs,
                    currentID: $currentID,
                    isZoomed: $pageZoomed,
                    dismissOffset: $dismissOffset,
                    allowsDismissDrag: false,
                    onSingleTap: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            chromeVisible.toggle()
                        }
                    },
                    onDismiss: {}
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

                if chromeVisible && !pageZoomed, let moment = activeMoment {
                    captionBanner(moment)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if chromeVisible && !pageZoomed {
                bottomChrome
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color.black.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.15), value: chromeVisible)
        .animation(.easeInOut(duration: 0.15), value: pageZoomed)
        .statusBarHidden(!(chromeVisible && !pageZoomed))
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(week.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(week.dateRange)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer(minLength: 0)
        }
    }

    /// Caption rides in a soft pill at the foot of the photo — tap to rewrite.
    private func captionBanner(_ moment: LibraryMoment) -> some View {
        Button {
            beginEditCaption(moment)
        } label: {
            Text(moment.title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var bottomChrome: some View {
        VStack(spacing: 14) {
            highlightStrip

            Button {
                Task { await finishAndShare() }
            } label: {
                HStack(spacing: 8) {
                    if isPreparingShare {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                    }
                    Text(isPreparingShare ? "Preparing…" : "Finish recap & share")
                        .font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.white, in: Capsule())
                .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .disabled(isPreparingShare || moments.isEmpty)
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 16)
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    private var highlightStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("Highlights")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 8)
                if let moment = activeMoment {
                    Button {
                        swapCoverDraft = moment.coverID
                        swappingMomentID = moment.id
                    } label: {
                        Text("Change photo")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        confirmRemove = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(moments) { moment in
                        highlightChip(moment)
                    }
                    addMomentChip
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var addMomentChip: some View {
        Button {
            isAddingMoment = true
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(width: 64, height: 86)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }

                Text("Add")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 64)
            }
        }
        .buttonStyle(.plain)
        .disabled(isCreatingMoment)
    }

    private func highlightChip(_ moment: LibraryMoment) -> some View {
        let selected = activeMoment?.id == moment.id

        return Button {
            currentID = moment.coverID
        } label: {
            VStack(spacing: 6) {
                AssetThumbnail(
                    id: moment.coverID,
                    targetSize: CGSize(width: 180, height: 240)
                )
                .id(moment.coverID)
                .frame(width: 64, height: 86)
                .clipped()
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Color.white : Color.clear, lineWidth: 2.5)
                }

                Text(moment.dayLabel.isEmpty ? moment.title : moment.dayLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(selected ? 0.9 : 0.45))
                    .lineLimit(1)
                    .frame(width: 64)
            }
        }
        .buttonStyle(.plain)
    }

    private func beginEditCaption(_ moment: LibraryMoment) {
        captionDraft = moment.title
        editingCaptionMoment = moment
    }

    private func removeActiveFromRecap() {
        guard let moment = activeMoment else { return }
        let remaining = moments.filter { $0.id != moment.id }
        withAnimation(.easeOut(duration: 0.2)) {
            model.deleteMoment(moment)
            if let next = remaining.first {
                currentID = next.coverID
            }
        }
        if remaining.isEmpty {
            onClose()
        }
    }

    @MainActor
    private func addMoment(photoIDs: [String]) async {
        guard !photoIDs.isEmpty else { return }
        isCreatingMoment = true
        // Close the sheet immediately so add never feels hung.
        isAddingMoment = false
        defer { isCreatingMoment = false }
        if let moment = await model.addMoment(photoIDs: photoIDs, to: week.weekStart) {
            currentID = moment.coverID
        }
    }

    @MainActor
    private func finishAndShare() async {
        isPreparingShare = true
        defer { isPreparingShare = false }

        let highlights = moments.map { (title: $0.title, photoID: $0.coverID) }
        let recap = WeekRecapStore.shared.finish(week: week, highlights: highlights)

        var images: [UIImage] = []
        images.reserveCapacity(recap.highlightIDs.count)
        for id in recap.highlightIDs where !id.isEmpty {
            if let image = await PhotoLibraryService.shared.requestDisplayImage(
                for: id,
                size: CGSize(width: 1400, height: 1800)
            ) {
                images.append(image)
            }
        }

        shareTemplates = RecapTemplateRenderer.makeAll(recap: recap, photos: images)
        sharePhotos = images
        sharingRecap = recap
    }
}

// MARK: - Share

private struct RecapShareSheet: View {
    let recap: SharedWeekRecap
    let photos: [UIImage]
    let templates: [RecapTemplateOption]
    var onDone: () -> Void

    @State private var pageID: String = ""
    @State private var livePhotos: [UIImage] = []
    @State private var liveTitles: [String] = []
    @State private var liveTemplates: [RecapTemplateOption] = []
    @State private var shuffleSeed = 0
    @State private var isShuffling = false

    private var selected: RecapTemplateOption? {
        liveTemplates.first { $0.id == pageID } ?? liveTemplates.first
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if liveTemplates.isEmpty {
                    Text("Couldn’t build templates from these highlights.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(24)
                } else {
                    VStack(spacing: 0) {
                        Text(recap.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.top, 8)

                        Text(recap.dateRange)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.top, 2)

                        TabView(selection: $pageID) {
                            ForEach(liveTemplates) { option in
                                Image(uiImage: option.image)
                                    .resizable()
                                    .scaledToFit()
                                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                                    .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                                    .padding(.horizontal, 28)
                                    .padding(.vertical, 18)
                                    .tag(option.id)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .always))
                        .frame(maxHeight: .infinity)

                        if let selected {
                            Text(selected.kind.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.bottom, 18)
                        }

                        shareActions
                            .padding(.horizontal, 20)
                            .padding(.bottom, 28)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        shuffle()
                    } label: {
                        if isShuffling {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Label("Shuffle", systemImage: "shuffle")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .disabled(isShuffling || livePhotos.count < 2)
                    .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDone)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .onAppear {
                if liveTemplates.isEmpty {
                    livePhotos = photos
                    liveTitles = recap.highlightTitles
                    liveTemplates = templates
                }
                if pageID.isEmpty {
                    pageID = liveTemplates.first?.id ?? ""
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var shareActions: some View {
        HStack(spacing: 0) {
            actionButton(title: "Copy link", systemImage: "link") {
                UIPasteboard.general.string = recap.shareURL.absoluteString
            }
            actionButton(title: "Save", systemImage: "arrow.down.to.line") {
                guard let image = selected?.image else { return }
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            }
            SharePayloadButton(items: shareItems) {
                actionLabel(title: "Share", systemImage: "square.and.arrow.up")
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var shareItems: [Any] {
        var items: [Any] = [recap.shareMessage]
        if let image = selected?.image {
            items.append(image)
        }
        return items
    }

    private func actionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func actionLabel(title: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Color.white.opacity(0.12), in: Circle())
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
    }

    @MainActor
    private func shuffle() {
        guard livePhotos.count > 1 else { return }
        isShuffling = true
        defer { isShuffling = false }

        let previousKind = selected?.kind
        let mixed = RecapTemplateRenderer.shuffled(photos: livePhotos, titles: liveTitles)
        shuffleSeed += 1
        livePhotos = mixed.photos
        liveTitles = mixed.titles
        liveTemplates = RecapTemplateRenderer.makeAll(
            recap: recap,
            photos: livePhotos,
            titles: liveTitles,
            seed: shuffleSeed
        )
        if let previousKind,
           let match = liveTemplates.first(where: { $0.kind == previousKind }) {
            pageID = match.id
        } else {
            pageID = liveTemplates.first?.id ?? ""
        }
    }
}

private struct SharePayloadButton<Label: View>: View {
    let items: [Any]
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button {
            present()
        } label: {
            label()
        }
        .buttonStyle(.plain)
    }

    private func present() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController
        else { return }
        var presenter = root
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = activity.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.maxY - 40,
                width: 1,
                height: 1
            )
        }
        presenter.present(activity, animated: true)
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? {
        windows.first { $0.isKeyWindow } ?? windows.first
    }
}

/// Week-only picker, sectioned by day. Thumbnails are loaded into a dictionary so cell
/// identity can’t drift from what’s on screen.
private struct AddMomentPickerSheet: View {
    let weekStart: Date
    let dateRange: String
    let usedPhotoIDs: Set<String>
    @Binding var isCreating: Bool
    var onCancel: () -> Void
    var onAdd: ([String]) -> Void

    private struct DaySection: Identifiable {
        let id: Date
        let label: String
        let photoIDs: [String]
    }

    @State private var sections: [DaySection] = []
    @State private var thumbnails: [String: UIImage] = [:]
    @State private var selectedOrder: [String] = []
    @State private var didLoad = false
    @State private var loadError: String?

    private let gap: CGFloat = 3
    private let columns = 3

    private var weekEnd: Date {
        Calendar.current.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
    }

    private var selectedSet: Set<String> { Set(selectedOrder) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if !didLoad {
                    ProgressView()
                        .tint(.white)
                } else if let loadError {
                    Text(loadError)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(24)
                } else if sections.isEmpty {
                    Text("No photos from \(dateRange).")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(24)
                } else {
                    VStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 20, pinnedViews: []) {
                                ForEach(sections) { section in
                                    Text(section.label)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .padding(.horizontal, 16)

                                    photoGrid(section.photoIDs)
                                        .padding(.horizontal, 2)
                                }
                            }
                            .padding(.bottom, selectedOrder.isEmpty ? 24 : 120)
                        }

                        if !selectedOrder.isEmpty {
                            selectionDock
                        }
                    }
                }
            }
            .navigationTitle("Add moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onAdd(selectedOrder)
                    } label: {
                        if isCreating {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Text(selectedOrder.isEmpty ? "Add" : "Add \(selectedOrder.count)")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(selectedOrder.isEmpty || isCreating)
                    .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sensoryFeedback(.selection, trigger: selectedOrder.count)
            .task { await loadWeekPhotos() }
        }
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gap), count: columns)
    }

    private func photoGrid(_ ids: [String]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: gap) {
            ForEach(ids, id: \.self) { id in
                photoCell(id)
            }
        }
    }

    private func photoCell(_ id: String) -> some View {
        let isOn = selectedSet.contains(id)
        let orderIndex = selectedOrder.firstIndex(of: id)
        let alreadyUsed = usedPhotoIDs.contains(id)

        return Button {
            toggle(id)
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Group {
                        if let image = thumbnails[id] {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color.white.opacity(0.08)
                        }
                    }
                }
                .overlay {
                    if isOn {
                        Color.black.opacity(0.28)
                    } else if alreadyUsed {
                        Color.black.opacity(0.35)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    ZStack {
                        Circle()
                            .fill(isOn ? Color.white : Color.black.opacity(0.35))
                            .frame(width: 24, height: 24)
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 1.5)
                            .frame(width: 24, height: 24)
                        if let orderIndex {
                            Text("\(orderIndex + 1)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.black)
                        }
                    }
                    .padding(6)
                }
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var selectionDock: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.12))
            HStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(selectedOrder, id: \.self) { id in
                            ZStack(alignment: .topTrailing) {
                                Group {
                                    if let image = thumbnails[id] {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        Color.white.opacity(0.1)
                                    }
                                }
                                .frame(width: 52, height: 52)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                Button {
                                    selectedOrder.removeAll { $0 == id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.7))
                                }
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.leading, 4)
                }

                Button {
                    onAdd(selectedOrder)
                } label: {
                    Group {
                        if isCreating {
                            ProgressView().controlSize(.small).tint(.black)
                        } else {
                            Text("Add \(selectedOrder.count)")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isCreating)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black)
        }
    }

    private func toggle(_ id: String) {
        if let index = selectedOrder.firstIndex(of: id) {
            selectedOrder.remove(at: index)
        } else {
            selectedOrder.append(id)
        }
    }

    @MainActor
    private func loadWeekPhotos() async {
        let photos = PhotoLibraryService.shared.search(
            start: weekStart,
            end: weekEnd,
            favoritesOnly: false,
            albumName: nil,
            limit: 300,
            includeScreenshots: true
        )

        let calendar = Calendar.current
        var buckets: [Date: [(id: String, date: Date?)]] = [:]

        for photo in photos {
            let day = calendar.startOfDay(for: photo.createdAt ?? weekStart)
            buckets[day, default: []].append((photo.localIdentifier, photo.createdAt))
        }

        // Newest day first (Sun → Mon), newest photos first within each day.
        sections = (0..<7).reversed().compactMap { offset -> DaySection? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: weekStart))
            else { return nil }
            let dayStart = calendar.startOfDay(for: day)
            guard var items = buckets[dayStart], !items.isEmpty else { return nil }
            items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            return DaySection(
                id: dayStart,
                label: daySectionLabel(dayStart),
                photoIDs: items.map(\.id)
            )
        }

        didLoad = true

        let allIDs = sections.flatMap(\.photoIDs)
        PhotoLibraryService.shared.startCachingThumbnails(
            ids: Array(allIDs.prefix(60)),
            size: CGSize(width: 240, height: 240)
        )

        // Load thumbs in small concurrent batches so the sheet doesn’t freeze.
        let batchSize = 12
        var index = 0
        while index < allIDs.count {
            if Task.isCancelled { return }
            let batch = Array(allIDs[index..<min(index + batchSize, allIDs.count)])
            await withTaskGroup(of: (String, UIImage?).self) { group in
                for id in batch {
                    group.addTask {
                        let image = await PhotoLibraryService.shared.requestThumbnail(
                            for: id,
                            size: CGSize(width: 240, height: 240)
                        )
                        return (id, image)
                    }
                }
                for await (id, image) in group {
                    if let image {
                        thumbnails[id] = image
                    }
                }
            }
            index += batchSize
        }
    }

    private func daySectionLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let weekday = DateFormatter.weekdayShort.string(from: day)
        let date = DateFormatter.chipDayNoYear.string(from: day)
        return "\(weekday) · \(date)"
    }
}

struct HighlightEditSession: Identifiable {
    let id: UUID
    let title: String
    let dayLabel: String
    let photoIDs: [String]

    init(moment: LibraryMoment) {
        id = moment.id
        title = moment.title
        dayLabel = moment.dayLabel
        photoIDs = moment.photoIDs
    }
}
