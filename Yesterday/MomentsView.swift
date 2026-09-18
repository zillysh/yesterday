import SwiftUI

struct MomentsView: View {
    var isSelected = true
    @Environment(PhotoLibraryService.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = MomentsViewModel()
    @State private var openedWeek: MomentWeek?
    @State private var recapStartID = ""
    @State private var lookingAt: PhotoPeek?
    @State private var editing: HighlightEditSession?
    @State private var editingCoverID = ""
    @State private var captionMoment: LibraryMoment?
    @State private var captionDraft = ""

    private var isGathering: Bool {
        library.canRead && model.isLoading && model.weeks.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if !library.canRead {
                    PermissionView()
                } else {
                    content
                }
            }
            .background(MessageTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(isGathering ? .hidden : .automatic, for: .tabBar)
            .task(id: "\(isSelected)-\(library.libraryRevision)") {
                guard isSelected, library.canRead else { return }
                await model.refreshIfNeeded(library: library)
            }
            .onChange(of: isSelected) { _, selected in
                guard selected, library.canRead else { return }
                Task { await model.refreshIfNeeded(library: library) }
            }
            .onChange(of: scenePhase) { _, phase in
                guard isSelected, phase == .active, library.canRead else { return }
                Task { await model.refreshIfNeeded(library: library) }
            }
            .refreshable {
                guard isSelected else { return }
                await model.refreshIfNeeded(library: library, force: true)
            }
            .navigationDestination(item: $lookingAt) { peek in
                MomentsPhotoViewer(photoIDs: peek.groupIDs, startID: peek.id)
                    .navigationBarBackButtonHidden()
                    .toolbar(.hidden, for: .navigationBar)
                    .toolbar(.hidden, for: .tabBar)
            }
            .fullScreenCover(item: $openedWeek) { week in
                WeekRecapView(
                    model: model,
                    initialWeek: week,
                    initialPhotoID: recapStartID,
                    onClose: {
                        openedWeek = nil
                        recapStartID = ""
                    }
                )
            }
            .fullScreenCover(item: $editing) { session in
                HighlightEditorView(
                    title: session.title,
                    dayLabel: session.dayLabel,
                    photoIDs: session.photoIDs,
                    coverID: $editingCoverID,
                    onClose: { editing = nil }
                )
                .preferredColorScheme(.dark)
                .onChange(of: editingCoverID) { _, newCover in
                    guard !newCover.isEmpty else { return }
                    model.setCover(photoIDs: session.photoIDs, photoID: newCover)
                }
            }
            .alert(
                "Edit caption",
                isPresented: Binding(
                    get: { captionMoment != nil },
                    set: { if !$0 { captionMoment = nil } }
                )
            ) {
                TextField("Caption", text: $captionDraft)
                Button("Save") {
                    if let moment = captionMoment {
                        model.setTitle(captionDraft, for: moment)
                    }
                    captionMoment = nil
                }
                Button("Cancel", role: .cancel) {
                    captionMoment = nil
                }
            } message: {
                Text("Shown on the moment and in shared recaps.")
            }
        }
    }

    private var content: some View {
        Group {
            if isGathering {
                MomentsGatheringView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 40) {
                        Text("Moments")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.top, 4)

                        if model.weeks.isEmpty {
                            Text(model.note ?? "No moments yet.")
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.horizontal, 20)
                        } else {
                            ForEach(model.weeks) { week in
                                MomentWeekRailView(
                                    week: week,
                                    onOpenRecap: { startID in
                                        recapStartID = startID
                                        openedWeek = week
                                    },
                                    onLook: { lookingAt = $0 },
                                    onSetHighlight: { moment, photoID in
                                        model.setCover(photoIDs: moment.photoIDs, photoID: photoID)
                                    },
                                    onEditCover: { moment in
                                        editingCoverID = moment.coverID
                                        editing = HighlightEditSession(moment: moment)
                                    },
                                    onEditCaption: { moment in
                                        captionDraft = moment.title
                                        captionMoment = moment
                                    },
                                    onDelete: { moment in
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            model.deleteMoment(moment)
                                        }
                                    }
                                )
                            }
                        }
                    }
                    .padding(.bottom, 48)
                }
            }
        }
    }
}

private struct MomentsGatheringView: View {
    var model: MomentsViewModel

    @State private var previewIndex = 0

    /// Locked size matching the loading mock — never follows photo aspect.
    private let cardSize = CGSize(width: 268, height: 412)

    private var progress: Double {
        min(1, max(0.08, model.gatherProgress))
    }

    private var previewIDs: [String] {
        model.gatherPreviewIDs
    }

    private var previewID: String? {
        guard !previewIDs.isEmpty else { return nil }
        return previewIDs[previewIndex % previewIDs.count]
    }

    var body: some View {
        VStack(spacing: 36) {
            Text("Your moments are loading...")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            gatheringCard
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: previewIDs.joined(separator: "|")) {
            await cyclePreviews()
        }
    }

    private var gatheringCard: some View {
        Color.clear
            .frame(width: cardSize.width, height: cardSize.height)
            .overlay {
                ZStack {
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .fill(Color.white.opacity(0.06))

                    if let previewID {
                        AssetThumbnail(
                            id: previewID,
                            targetSize: CGSize(width: 400, height: 620)
                        )
                        .id(previewID)
                        .frame(width: cardSize.width + 24, height: cardSize.height + 24)
                        .blur(radius: 24)
                        .transition(.opacity)
                    }
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .overlay {
                ZStack {
                    PerimeterProgressShape(cornerRadius: 32)
                        .stroke(Color.white.opacity(0.12), lineWidth: 3)

                    PerimeterProgressShape(cornerRadius: 32)
                        .trim(from: 0, to: progress)
                        .stroke(
                            Color.white.opacity(0.95),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                        )
                        .animation(.easeInOut(duration: 0.4), value: progress)
                }
            }
            .frame(width: cardSize.width, height: cardSize.height)
    }

    private func cyclePreviews() async {
        guard previewIDs.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled, previewIDs.count > 1 else { continue }
            withAnimation(.easeInOut(duration: 0.55)) {
                previewIndex = (previewIndex + 1) % previewIDs.count
            }
        }
    }
}

/// Rounded-rect path that starts at top-center so progress reads clockwise like a story ring.
private struct PerimeterProgressShape: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        var path = Path()

        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        return path
    }
}

/// Week as a snap-rail of tall story cards, with a clear path into curate & share.
private struct MomentWeekRailView: View {
    let week: MomentWeek
    var onOpenRecap: (String) -> Void
    var onLook: (PhotoPeek) -> Void
    var onSetHighlight: (LibraryMoment, String) -> Void
    var onEditCover: (LibraryMoment) -> Void
    var onEditCaption: (LibraryMoment) -> Void
    var onDelete: (LibraryMoment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(week.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    if week.title != week.dateRange {
                        Text(week.dateRange)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.38))
                    }
                }

                Spacer(minLength: 8)

                Button {
                    onOpenRecap(week.moments.first?.coverID ?? "")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption.weight(.semibold))
                        Text("Curate & share")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(week.moments) { moment in
                        MomentStoryCard(
                            moment: moment,
                            onLook: onLook,
                            onSetHighlight: { onSetHighlight(moment, $0) },
                            onEditCover: { onEditCover(moment) },
                            onEditCaption: { onEditCaption(moment) },
                            onDelete: { onDelete(moment) },
                            onOpenRecap: { photoID in onOpenRecap(photoID) }
                        )
                        .containerRelativeFrame(.horizontal) { length, _ in
                            length * 0.82
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 20)
            }
            .scrollTargetBehavior(.viewAligned)
            .frame(height: 460)
        }
    }
}

/// Tall full-bleed card — date badge + quiet caption; swipe up/down for shots in the set.
/// Dense bursts collapse to one page each so vertical scroll isn’t 25 near-identical frames.
private struct MomentStoryCard: View {
    let moment: LibraryMoment
    var onLook: (PhotoPeek) -> Void
    var onSetHighlight: (String) -> Void
    var onEditCover: () -> Void
    var onEditCaption: () -> Void
    var onDelete: () -> Void
    var onOpenRecap: (String) -> Void

    private struct StoryPage: Identifiable, Equatable {
        /// Stable scroll identity (first photo in the burst) — never swap this mid-scroll.
        let id: String
        var displayID: String
        let groupIDs: [String]
    }

    @State private var pageID: String?
    @State private var pages: [StoryPage] = []
    @State private var overflowCount = 0
    @State private var totalPhotoCount = 0

    private let inCardLimit = 12
    private let overflowPageID = "__overflow__"

    private var pageIDs: [String] { pages.map(\.id) }

    private var tickIDs: [String] {
        overflowCount > 0 ? pageIDs + [overflowPageID] : pageIDs
    }

    private var dayNumber: String {
        String(Calendar.current.component(.day, from: moment.sortDate))
    }

    private var monthLabel: String {
        DateFormatter.monthShort.string(from: moment.sortDate)
    }

    private var currentID: String {
        pageID ?? pageIDs.first ?? moment.coverID
    }

    private var currentIndex: Int {
        tickIDs.firstIndex(of: currentID) ?? 0
    }

    private var currentDisplayID: String {
        if currentID == overflowPageID {
            return pages.last?.displayID ?? moment.coverID
        }
        return pages.first { $0.id == currentID }?.displayID ?? currentID
    }

    private var isCurrentHighlight: Bool {
        currentDisplayID == moment.coverID
    }

    private var showsTicks: Bool {
        tickIDs.count > 1
    }

    private var isNarrowed: Bool {
        totalPhotoCount > pages.count + overflowCount
    }

    private func groupIDs(containing id: String) -> [String] {
        if let page = pages.first(where: { $0.id == id || $0.displayID == id || $0.groupIDs.contains(id) }) {
            return page.groupIDs
        }
        return moment.photoIDs
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(pages) { page in
                            AssetThumbnail(id: page.displayID, targetSize: CGSize(width: 700, height: 1000))
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onOpenRecap(page.displayID)
                                }
                                .id(page.id)
                        }

                        if overflowCount > 0 {
                            Button {
                                onOpenRecap(pages.last?.displayID ?? moment.coverID)
                            } label: {
                                ZStack {
                                    if let last = pages.last {
                                        AssetThumbnail(id: last.displayID, targetSize: CGSize(width: 700, height: 1000))
                                            .blur(radius: 18)
                                            .opacity(0.45)
                                    }
                                    Color.black.opacity(0.45)
                                    VStack(spacing: 8) {
                                        Text("+\(overflowCount)")
                                            .font(.system(size: 34, weight: .bold))
                                        Text("Open week recap")
                                            .font(.subheadline.weight(.medium))
                                            .opacity(0.75)
                                    }
                                    .foregroundStyle(.white)
                                }
                                .frame(width: geo.size.width, height: geo.size.height)
                            }
                            .buttonStyle(.plain)
                            .id(overflowPageID)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $pageID)

                LinearGradient(
                    colors: [.clear, .clear, .black.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                if showsTicks {
                    HStack {
                        Spacer(minLength: 0)
                        VStack(spacing: 5) {
                            ForEach(Array(tickIDs.indices), id: \.self) { index in
                                Capsule()
                                    .fill(index == currentIndex ? Color.white : Color.white.opacity(0.28))
                                    .frame(width: 3, height: index == currentIndex ? 18 : 8)
                            }
                        }
                        .padding(.trailing, 10)
                    }
                    .allowsHitTesting(false)
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        dateBadge
                        Spacer(minLength: 8)
                        Menu {
                            Button("Look through") {
                                let start = currentDisplayID
                                onLook(PhotoPeek(id: start, groupIDs: groupIDs(containing: start)))
                            }
                            if currentID != overflowPageID, !isCurrentHighlight {
                                Button("Set as highlight") {
                                    onSetHighlight(currentDisplayID)
                                }
                            }
                            Button("Choose highlight…") {
                                onEditCover()
                            }
                            Button("Edit caption") {
                                onEditCaption()
                            }
                            Button("Curate & share week") {
                                onOpenRecap(currentDisplayID)
                            }
                            Divider()
                            Button("Delete moment", role: .destructive) {
                                onDelete()
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.body.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(.black.opacity(0.35), in: Circle())
                        }
                    }

                    Spacer(minLength: 0)

                    HStack(alignment: .bottom, spacing: 10) {
                        Button(action: onEditCaption) {
                            Text(moment.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Spacer(minLength: 8)

                        if pages.count > 1 || overflowCount > 0 || isNarrowed {
                            pageLabel
                        }
                    }
                }
                .padding(16)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onLongPressGesture(minimumDuration: 0.45) {
            guard currentID != overflowPageID, !isCurrentHighlight else { return }
            onSetHighlight(currentDisplayID)
        }
        .sensoryFeedback(.selection, trigger: currentID)
        .onAppear {
            rebuildPages(resetPosition: pageID == nil)
        }
        .onChange(of: moment.photoIDs) { _, _ in
            rebuildPages(resetPosition: false)
        }
        .onChange(of: moment.coverID) { _, cover in
            applyCover(cover)
        }
    }

    private var pageLabel: some View {
        let label: String = {
            if currentID == overflowPageID {
                return "\(totalPhotoCount) photos"
            }
            if isNarrowed || overflowCount > 0 {
                return "\(currentIndex + 1)/\(pages.count) · \(totalPhotoCount)"
            }
            return "\(currentIndex + 1)/\(pages.count)"
        }()

        return Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.55))
    }

    private var dateBadge: some View {
        VStack(spacing: 1) {
            Text(dayNumber)
                .font(.system(size: 18, weight: .bold))
            Text(monthLabel)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
        }
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// PhotoKit fetch once — never during scroll.
    private func rebuildPages(resetPosition: Bool) {
        totalPhotoCount = moment.photoIDs.count
        let groups = PhotoLibraryService.shared.similarGroups(from: moment.photoIDs, window: 12)
        let built: [StoryPage] = groups.map { group in
            let stable = group.photoIDs[0]
            let display = group.photoIDs.contains(moment.coverID) ? moment.coverID : stable
            return StoryPage(id: stable, displayID: display, groupIDs: group.photoIDs)
        }
        overflowCount = max(0, built.count - inCardLimit)
        pages = Array(built.prefix(inCardLimit))

        if resetPosition || pageID == nil || !(pageIDs + [overflowPageID]).contains(pageID ?? "") {
            pageID = pages.first?.id ?? moment.coverID
        }

        PhotoLibraryService.shared.startCachingThumbnails(
            ids: Array(pages.prefix(6).map(\.displayID)),
            size: CGSize(width: 700, height: 1000)
        )
    }

    /// Keep scroll identities stable — only swap which frame is shown for the lead burst.
    private func applyCover(_ cover: String) {
        guard !cover.isEmpty else { return }
        for index in pages.indices {
            if pages[index].groupIDs.contains(cover) {
                pages[index].displayID = cover
            } else if pages[index].displayID == cover {
                pages[index].displayID = pages[index].id
            }
        }
    }
}

/// Cover picker used by week recap (and anywhere else that swaps a lead photo).
struct HighlightEditorView: View {
    let title: String
    let dayLabel: String
    let photoIDs: [String]
    @Binding var coverID: String
    var onClose: () -> Void

    @State private var lookingAt: PhotoPeek?
    @State private var sections: [ShotSection] = []

    private struct ShotSection: Identifiable {
        let id: String
        let title: String?
        let photoIDs: [String]
    }

    private func rebuildSections() {
        let groups = PhotoLibraryService.shared.similarGroups(from: photoIDs, window: 12)
        let hasMulti = groups.contains { $0.photoIDs.count > 1 }
        guard hasMulti else {
            sections = [ShotSection(id: "all", title: nil, photoIDs: photoIDs)]
            return
        }

        // Lead’s burst first, then the rest in time order.
        var ordered = groups
        if !coverID.isEmpty,
           let index = ordered.firstIndex(where: { $0.photoIDs.contains(coverID) }),
           index > 0 {
            let lead = ordered.remove(at: index)
            ordered.insert(lead, at: 0)
        }

        var result: [ShotSection] = []
        var singles: [String] = []

        func flushSingles() {
            guard !singles.isEmpty else { return }
            result.append(
                ShotSection(
                    id: "singles-\(singles[0])",
                    title: result.isEmpty ? nil : "Also",
                    photoIDs: singles
                )
            )
            singles = []
        }

        for group in ordered {
            if group.photoIDs.count == 1 {
                singles.append(group.photoIDs[0])
                continue
            }
            flushSingles()
            result.append(
                ShotSection(
                    id: group.photoIDs[0],
                    title: sectionTitle(for: group.photoIDs),
                    photoIDs: group.photoIDs
                )
            )
        }
        flushSingles()
        sections = result
    }

    private var columnCount: Int {
        photoIDs.count <= 4 ? 2 : 3
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                        Text("Tap a photo to use as this highlight")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .padding(.horizontal, 20)

                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            if let title = section.title {
                                Text(title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.4))
                                    .padding(.horizontal, 20)
                            }

                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(section.photoIDs, id: \.self) { id in
                                    coverTile(id: id)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(MessageTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done", action: onClose)
                        .fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Look through") {
                        lookingAt = PhotoPeek(id: coverID, groupIDs: photoIDs)
                    }
                    .fontWeight(.semibold)
                    .disabled(photoIDs.isEmpty)
                }
            }
            .toolbarBackground(MessageTheme.background, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(item: $lookingAt) { peek in
                MomentsPhotoViewer(photoIDs: peek.groupIDs, startID: peek.id)
                    .navigationBarBackButtonHidden()
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        .sensoryFeedback(.selection, trigger: coverID)
        .onAppear {
            rebuildSections()
            PhotoLibraryService.shared.startCachingThumbnails(
                ids: Array(photoIDs.prefix(60)),
                size: CGSize(width: 400, height: 400)
            )
        }
    }

    private func coverTile(id: String) -> some View {
        let isCover = id == coverID
        return Button {
            coverID = id
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    AssetThumbnail(id: id, targetSize: CGSize(width: 400, height: 400))
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(isCover ? Color.white : Color.clear, lineWidth: 3)
                }
                .overlay(alignment: .bottomTrailing) {
                    if isCover {
                        Text("Lead")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.white, in: Capsule())
                            .padding(10)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(for ids: [String]) -> String {
        let times = PhotoLibraryService.shared.summaries(for: ids).compactMap(\.createdAt).sorted()
        if let first = times.first {
            return "\(ids.count) similar · \(first.formatted(date: .omitted, time: .shortened))"
        }
        return "\(ids.count) similar"
    }
}

struct MomentsPhotoViewer: View {
    let photoIDs: [String]
    let startID: String
    @Environment(\.dismiss) private var dismiss
    @State private var current: String
    @State private var pageZoomed = false
    @State private var dismissOffset: CGFloat = 0

    init(photoIDs: [String], startID: String) {
        self.photoIDs = photoIDs
        self.startID = startID
        _current = State(initialValue: photoIDs.contains(startID) ? startID : (photoIDs.first ?? startID))
    }

    var body: some View {
        let progress = min(1, max(0, dismissOffset / 280))

        ZStack {
            Color.black.opacity(1 - progress * 0.55)
                .ignoresSafeArea()

            PhotoBrowserPager(
                photoIDs: photoIDs,
                currentID: $current,
                isZoomed: $pageZoomed,
                dismissOffset: $dismissOffset,
                onSingleTap: {},
                onDismiss: { dismiss() }
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if photoIDs.count > 1, let index = photoIDs.firstIndex(of: current) {
                        Text("\(index + 1) of \(photoIDs.count)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
            .opacity(progress < 0.05 ? 1 : 0)
        }
        .preferredColorScheme(.dark)
    }
}
