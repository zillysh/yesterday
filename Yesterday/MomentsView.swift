import SwiftUI

struct MomentsView: View {
    @Environment(PhotoLibraryService.self) private var library
    @State private var model = MomentsViewModel()
    @State private var lookingAt: PhotoPeek?

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
            .navigationTitle("Moments")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(MessageTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task {
                if library.canRead {
                    await model.loadIfNeeded(library: library)
                }
            }
            .refreshable {
                await model.refresh(library: library)
            }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                header

                if model.isLoading && model.moments.isEmpty {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if model.moments.isEmpty {
                    Text(model.note ?? "No moments yet.")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.horizontal, 20)
                } else {
                    ForEach(model.moments) { moment in
                        MomentSectionView(moment: moment) { id in
                            lookingAt = PhotoPeek(id: id, groupIDs: moment.photoIDs)
                        }
                    }
                }
            }
            .padding(.bottom, 36)
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
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A recap of what you’ve been up to.")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Your library, sectioned into moments — weekends, dinners, nights out.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

private struct MomentSectionView: View {
    let moment: LibraryMoment
    var onTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(moment.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                Text(moment.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(moment.photoIDs.prefix(24), id: \.self) { id in
                        Button {
                            onTap(id)
                        } label: {
                            AssetThumbnail(id: id, targetSize: CGSize(width: 220, height: 220))
                                .frame(width: coverWidth(for: moment), height: 168)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    if moment.photoIDs.count > 24 {
                        Text("+\(moment.photoIDs.count - 24)")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 72, height: 168)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .padding(.horizontal, 20)
            }
            .onAppear {
                PhotoLibraryService.shared.startCachingThumbnails(
                    ids: Array(moment.photoIDs.prefix(20)),
                    size: CGSize(width: 220, height: 220)
                )
            }
        }
    }

    private func coverWidth(for moment: LibraryMoment) -> CGFloat {
        moment.photoIDs.count <= 3 ? 200 : 132
    }
}
