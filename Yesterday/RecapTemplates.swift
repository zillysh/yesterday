import SwiftUI
import UIKit

enum RecapTemplateKind: String, CaseIterable, Identifiable, Sendable {
    case hero
    case duo
    case grid
    case captioned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hero: return "Hero"
        case .duo: return "Duo"
        case .grid: return "Grid"
        case .captioned: return "Captioned"
        }
    }
}

struct RecapTemplateOption: Identifiable {
    let kind: RecapTemplateKind
    let image: UIImage
    /// Changes when photos are shuffled so the carousel refreshes.
    let seed: Int
    var id: String { "\(kind.id)-\(seed)" }
}

enum RecapTemplateRenderer {
    /// Shared story-card canvas so the share carousel feels consistent.
    static let canvas = CGSize(width: 1080, height: 1920)

    @MainActor
    static func makeAll(
        recap: SharedWeekRecap,
        photos: [UIImage],
        titles: [String]? = nil,
        seed: Int = 0
    ) -> [RecapTemplateOption] {
        guard !photos.isEmpty else { return [] }
        let labels = titles ?? recap.highlightTitles
        return RecapTemplateKind.allCases.compactMap { kind in
            guard let image = render(kind: kind, recap: recap, photos: photos, titles: labels) else {
                return nil
            }
            return RecapTemplateOption(kind: kind, image: image, seed: seed)
        }
    }

    /// Shuffle photos + titles together, keeping captions aligned with images.
    static func shuffled(
        photos: [UIImage],
        titles: [String]
    ) -> (photos: [UIImage], titles: [String]) {
        guard photos.count > 1 else { return (photos, titles) }
        var order = Array(photos.indices)
        order.shuffle()
        let nextPhotos = order.map { photos[$0] }
        let nextTitles = order.map { titles.indices.contains($0) ? titles[$0] : "" }
        return (nextPhotos, nextTitles)
    }

    @MainActor
    private static func render(
        kind: RecapTemplateKind,
        recap: SharedWeekRecap,
        photos: [UIImage],
        titles: [String]
    ) -> UIImage? {
        let size = canvas
        let content: AnyView
        switch kind {
        case .hero:
            content = AnyView(HeroRecapTemplate(recap: recap, photos: photos, titles: titles))
        case .duo:
            content = AnyView(DuoRecapTemplate(recap: recap, photos: photos, titles: titles))
        case .grid:
            content = AnyView(GridRecapTemplate(recap: recap, photos: photos, titles: titles))
        case .captioned:
            content = AnyView(CaptionedGridRecapTemplate(recap: recap, photos: photos, titles: titles))
        }

        let renderer = ImageRenderer(
            content: content.frame(width: size.width, height: size.height)
        )
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(size)
        return renderer.uiImage
    }
}

// MARK: - Shared pieces

private struct RecapPhoto: View {
    let image: UIImage

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipped()
    }
}

private struct RecapFooter: View {
    let title: String
    let dateRange: String
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            Text(title)
                .font(.system(size: compact ? 36 : 52, weight: .bold))
                .foregroundStyle(.white)
            Text(dateRange)
                .font(.system(size: compact ? 20 : 26, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            Text("Shared from Yesterday")
                .font(.system(size: compact ? 16 : 18, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.top, 4)
        }
    }
}

// MARK: - Templates (all 1080×1920)

/// One full-bleed frame — closest to the Cosmos card.
private struct HeroRecapTemplate: View {
    let recap: SharedWeekRecap
    let photos: [UIImage]
    let titles: [String]

    var body: some View {
        ZStack {
            Color.black
            RecapPhoto(image: photos[0])

            LinearGradient(
                colors: [.black.opacity(0.15), .clear, .black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 0) {
                Text("YESTERDAY")
                    .font(.system(size: 20, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 72)
                    .padding(.horizontal, 56)

                Spacer()

                if let label = titles.first, !label.isEmpty {
                    Text(label)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.18), in: Capsule())
                        .padding(.horizontal, 56)
                        .padding(.bottom, 18)
                }

                RecapFooter(title: recap.title, dateRange: recap.dateRange)
                    .padding(.horizontal, 56)
                    .padding(.bottom, 88)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Two stacked frames with a clean gutter.
private struct DuoRecapTemplate: View {
    let recap: SharedWeekRecap
    let photos: [UIImage]
    let titles: [String]

    var body: some View {
        let a = photos[0]
        let b = photos.count > 1 ? photos[1] : photos[0]

        ZStack {
            Color.black
            VStack(spacing: 10) {
                RecapPhoto(image: a)
                RecapPhoto(image: b)
            }
            .padding(10)

            VStack {
                Spacer()
                RecapFooter(title: recap.title, dateRange: recap.dateRange, compact: true)
                    .padding(40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.88)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
    }
}

/// Fixed 2×2 mosaic with equal cells — no runaway fill.
private struct GridRecapTemplate: View {
    let recap: SharedWeekRecap
    let photos: [UIImage]
    let titles: [String]

    var body: some View {
        let shots = (0..<4).map { photos[min($0, photos.count - 1)] }

        ZStack {
            Color.black

            VStack(spacing: 0) {
                GeometryReader { geo in
                    let gap: CGFloat = 8
                    let cellW = (geo.size.width - gap) / 2
                    let cellH = (geo.size.height - gap) / 2

                    ZStack(alignment: .topLeading) {
                        cell(shots[0], width: cellW, height: cellH)
                        cell(shots[1], width: cellW, height: cellH)
                            .offset(x: cellW + gap)
                        cell(shots[2], width: cellW, height: cellH)
                            .offset(y: cellH + gap)
                        cell(shots[3], width: cellW, height: cellH)
                            .offset(x: cellW + gap, y: cellH + gap)
                    }
                }
                .padding(10)
                .frame(maxHeight: .infinity)

                RecapFooter(title: recap.title, dateRange: recap.dateRange, compact: true)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 72)
                    .padding(.top, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func cell(_ image: UIImage, width: CGFloat, height: CGFloat) -> some View {
        RecapPhoto(image: image)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 2×2 grid with a context caption on each photo — what the moment was.
private struct CaptionedGridRecapTemplate: View {
    let recap: SharedWeekRecap
    let photos: [UIImage]
    let titles: [String]

    var body: some View {
        let count = min(4, max(photos.count, 1))
        let shots = (0..<count).map { photos[min($0, photos.count - 1)] }
        let labels = (0..<count).map { titles.indices.contains($0) ? titles[$0] : "" }

        ZStack {
            Color.black

            VStack(spacing: 0) {
                GeometryReader { geo in
                    let gap: CGFloat = 10
                    let cols = count == 1 ? 1 : 2
                    let rows = Int(ceil(Double(count) / Double(cols)))
                    let cellW = (geo.size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
                    let cellH = (geo.size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)

                    ZStack(alignment: .topLeading) {
                        ForEach(0..<count, id: \.self) { index in
                            let col = index % cols
                            let row = index / cols
                            captionedCell(
                                image: shots[index],
                                caption: labels[index],
                                width: cellW,
                                height: cellH
                            )
                            .offset(
                                x: CGFloat(col) * (cellW + gap),
                                y: CGFloat(row) * (cellH + gap)
                            )
                        }
                    }
                }
                .padding(12)
                .frame(maxHeight: .infinity)

                RecapFooter(title: recap.title, dateRange: recap.dateRange, compact: true)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 72)
                    .padding(.top, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func captionedCell(
        image: UIImage,
        caption: String,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack(alignment: .bottomLeading) {
            RecapPhoto(image: image)

            LinearGradient(
                colors: [.clear, .black.opacity(0.72)],
                startPoint: .center,
                endPoint: .bottom
            )

            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
