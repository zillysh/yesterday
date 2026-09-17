import Photos
import SwiftUI
import UIKit

/// UIKit pager — horizontal swipes page; vertical swipe dismisses when not zoomed.
struct PhotoBrowserPager: UIViewControllerRepresentable {
    let photoIDs: [String]
    @Binding var currentID: String
    @Binding var isZoomed: Bool
    @Binding var dismissOffset: CGFloat
    var allowsDismissDrag: Bool = true
    var onSingleTap: () -> Void
    var onDismiss: () -> Void

    func makeUIViewController(context: Context) -> PhotoPageHostController {
        PhotoPageHostController(
            photoIDs: photoIDs,
            startID: currentID,
            allowsDismissDrag: allowsDismissDrag,
            onPageChange: { currentID = $0 },
            onZoomChange: { isZoomed = $0 },
            onSingleTap: onSingleTap,
            onDismissDrag: { dismissOffset = $0 },
            onDismiss: onDismiss
        )
    }

    func updateUIViewController(_ host: PhotoPageHostController, context: Context) {
        host.onPageChange = { currentID = $0 }
        host.onZoomChange = { isZoomed = $0 }
        host.onSingleTap = onSingleTap
        host.onDismissDrag = { dismissOffset = $0 }
        host.onDismiss = onDismiss
        host.allowsDismissDrag = allowsDismissDrag
        host.sync(photoIDs: photoIDs, currentID: currentID, isZoomed: isZoomed)
    }
}

final class PhotoPageHostController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    private let pager = UIPageViewController(
        transitionStyle: .scroll,
        navigationOrientation: .horizontal,
        options: [UIPageViewController.OptionsKey.interPageSpacing: 12]
    )

    private var photoIDs: [String]
    var onPageChange: (String) -> Void
    var onZoomChange: (Bool) -> Void
    var onSingleTap: () -> Void
    var onDismissDrag: (CGFloat) -> Void
    var onDismiss: () -> Void
    var allowsDismissDrag: Bool {
        didSet { dismissPan?.isEnabled = allowsDismissDrag }
    }

    private var currentID: String
    private var suppressSync = false
    private var dismissPan: UIPanGestureRecognizer!
    private var isDismissing = false

    init(
        photoIDs: [String],
        startID: String,
        allowsDismissDrag: Bool = true,
        onPageChange: @escaping (String) -> Void,
        onZoomChange: @escaping (Bool) -> Void,
        onSingleTap: @escaping () -> Void,
        onDismissDrag: @escaping (CGFloat) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.photoIDs = photoIDs
        self.currentID = photoIDs.contains(startID) ? startID : (photoIDs.first ?? startID)
        self.allowsDismissDrag = allowsDismissDrag
        self.onPageChange = onPageChange
        self.onZoomChange = onZoomChange
        self.onSingleTap = onSingleTap
        self.onDismissDrag = onDismissDrag
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        pager.dataSource = self
        pager.delegate = self
        addChild(pager)
        view.addSubview(pager.view)
        pager.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pager.view.topAnchor.constraint(equalTo: view.topAnchor),
            pager.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pager.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pager.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        pager.didMove(toParent: self)

        dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        dismissPan.delegate = self
        dismissPan.cancelsTouchesInView = false
        dismissPan.isEnabled = allowsDismissDrag
        view.addGestureRecognizer(dismissPan)

        setPage(for: currentID, animated: false)
        wirePagePanDependency()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        wirePagePanDependency()
    }

    func sync(photoIDs: [String], currentID: String, isZoomed: Bool) {
        let listChanged = photoIDs != self.photoIDs
        self.photoIDs = photoIDs
        if suppressSync { return }
        let target = photoIDs.contains(currentID) ? currentID : (photoIDs.first ?? currentID)
        if listChanged || target != self.currentID {
            self.currentID = target
            setPage(for: target, animated: false)
        }
        if !isDismissing {
            setScrollEnabled(!isZoomed)
        }
    }

    private func wirePagePanDependency() {
        guard allowsDismissDrag else { return }
        guard let pagePan = pageScrollView()?.panGestureRecognizer else { return }
        // Horizontal paging waits until vertical dismiss fails to begin.
        pagePan.require(toFail: dismissPan)
    }

    private var currentPage: PhotoZoomPageController? {
        pager.viewControllers?.first as? PhotoZoomPageController
    }

    private func pageScrollView() -> UIScrollView? {
        pager.view.subviews.compactMap { $0 as? UIScrollView }.first
    }

    private func setPage(for id: String, animated: Bool) {
        guard let page = makePage(for: id) else { return }
        let forward = (photoIDs.firstIndex(of: id) ?? 0) >= (photoIDs.firstIndex(of: currentID) ?? 0)
        pager.setViewControllers(
            [page],
            direction: forward ? .forward : .reverse,
            animated: animated
        )
        wirePagePanDependency()
    }

    private func makePage(for id: String) -> PhotoZoomPageController? {
        guard photoIDs.contains(id) else { return nil }
        return PhotoZoomPageController(
            photoID: id,
            onZoomChange: { [weak self] zoomed in
                self?.onZoomChange(zoomed)
                if self?.isDismissing != true {
                    self?.setScrollEnabled(!zoomed)
                }
            },
            onSingleTap: { [weak self] in self?.onSingleTap() }
        )
    }

    private func setScrollEnabled(_ enabled: Bool) {
        pageScrollView()?.isScrollEnabled = enabled
    }

    // MARK: - Vertical dismiss

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan else { return true }
        guard currentPage?.zoomScale ?? 1 <= 1.02 else { return false }
        let velocity = dismissPan.velocity(in: view)
        // Must be primarily downward.
        return velocity.y > 80 && abs(velocity.y) > abs(velocity.x) * 1.4
    }

    @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
        guard currentPage?.zoomScale ?? 1 <= 1.02 else {
            resetDismissVisuals()
            return
        }

        let translation = gesture.translation(in: view)
        let down = max(0, translation.y)

        switch gesture.state {
        case .began, .changed:
            // Don't move the page — only signal chrome fade. Close uses the zoom transition.
            isDismissing = down > 24
            if isDismissing {
                setScrollEnabled(false)
            }
            onDismissDrag(down)

        case .ended, .cancelled:
            let velocity = gesture.velocity(in: view)
            let shouldClose = down > 110 || (down > 50 && velocity.y > 850)
            if shouldClose {
                isDismissing = false
                onDismissDrag(0)
                onDismiss()
            } else {
                resetDismissVisuals()
            }

        default:
            break
        }
    }

    private func resetDismissVisuals() {
        isDismissing = false
        pager.view.transform = .identity
        pager.view.alpha = 1
        view.backgroundColor = .black
        setScrollEnabled((currentPage?.zoomScale ?? 1) <= 1.02)
        onDismissDrag(0)
    }

    // MARK: - Page data source

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard
            let page = viewController as? PhotoZoomPageController,
            let index = photoIDs.firstIndex(of: page.photoID),
            index > 0
        else { return nil }
        return makePage(for: photoIDs[index - 1])
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard
            let page = viewController as? PhotoZoomPageController,
            let index = photoIDs.firstIndex(of: page.photoID),
            index + 1 < photoIDs.count
        else { return nil }
        return makePage(for: photoIDs[index + 1])
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        guard completed,
              let page = pageViewController.viewControllers?.first as? PhotoZoomPageController
        else { return }
        suppressSync = true
        currentID = page.photoID
        onPageChange(page.photoID)
        onZoomChange(false)
        DispatchQueue.main.async { [weak self] in
            self?.suppressSync = false
        }
    }
}

final class PhotoZoomPageController: UIViewController, UIScrollViewDelegate {
    let photoID: String
    private let onZoomChange: (Bool) -> Void
    private let onSingleTap: () -> Void

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var hasLoaded = false

    var zoomScale: CGFloat { scrollView.zoomScale }

    init(
        photoID: String,
        onZoomChange: @escaping (Bool) -> Void,
        onSingleTap: @escaping () -> Void
    ) {
        self.photoID = photoID
        self.onZoomChange = onZoomChange
        self.onSingleTap = onSingleTap
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .black
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        loadImageIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutImage()
    }

    private func loadImageIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        let id = photoID
        Task { @MainActor in
            // Always aspect-fit — never show a center-cropped square placeholder.
            let screen = UIScreen.main.bounds.size
            let previewSize = CGSize(width: min(screen.width, 520), height: min(screen.height, 520))
            if let preview = await PhotoLibraryService.shared.requestDisplayImage(for: id, size: previewSize) {
                imageView.image = preview
                layoutImage()
            }
            let sharpSize = CGSize(width: screen.width * 2, height: screen.height * 2)
            if let sharp = await PhotoLibraryService.shared.requestDisplayImage(for: id, size: sharpSize) {
                imageView.image = sharp
                layoutImage()
            }
        }
    }

    private func layoutImage() {
        guard let image = imageView.image else {
            imageView.frame = .zero
            return
        }
        let bounds = scrollView.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        let imageSize = image.size
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        imageView.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )
        scrollView.contentSize = bounds.size
        if scrollView.zoomScale <= 1.02 {
            scrollView.zoomScale = 1
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        onZoomChange(scrollView.zoomScale > 1.02)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        onZoomChange(scale > 1.02)
    }

    private func centerImage() {
        let bounds = scrollView.bounds.size
        var frame = imageView.frame
        frame.origin.x = frame.size.width < bounds.width ? (bounds.width - frame.size.width) / 2 : 0
        frame.origin.y = frame.size.height < bounds.height ? (bounds.height - frame.size.height) / 2 : 0
        imageView.frame = frame
    }

    @objc private func handleSingleTap() {
        onSingleTap()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.05 {
            scrollView.setZoomScale(1, animated: true)
            onZoomChange(false)
        } else {
            let point = gesture.location(in: imageView)
            let zoom: CGFloat = 2.4
            let size = scrollView.bounds.size
            let width = size.width / zoom
            let height = size.height / zoom
            let rect = CGRect(
                x: point.x - width / 2,
                y: point.y - height / 2,
                width: width,
                height: height
            )
            scrollView.zoom(to: rect, animated: true)
            onZoomChange(true)
        }
    }
}
