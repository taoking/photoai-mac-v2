import AppKit
import ImageIO
import PhotoAICore
import SwiftUI

/// 网格：按天分组，每张一格，缩略图按原比例完整显示（信息架构 §3.3）。
///
/// 用 NSCollectionView 和自己写的布局：格子大小一致，任意位置的格子都能直接算出来，
/// 十万张也不用一次算完所有格子的位置。
struct PhotoGrid: NSViewRepresentable {
    var sections: [DaySection]
    var sectionsVersion: Int
    var thumbnailSize: Double
    var store: PreviewStore?
    var isOffline: (PhotoID) -> Bool
    var onSelectionChange: (Set<PhotoID>) -> Void
    /// 第一屏的缩略图全部画出来时调用一次（PF-1 计时到这里）。
    var onFirstScreenShown: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = DayGridLayout()
        let collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.identifier)
        collectionView.register(
            DayHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: DayHeaderView.identifier
        )
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        context.coordinator.collectionView = collectionView
        // 窗口、侧栏、检查器改变宽度时重新排列格子。
        scrollView.contentView.postsFrameChangedNotifications = true
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak layout] _ in
            MainActor.assumeIsolated { layout?.widthMayHaveChanged() }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let collectionView = coordinator.collectionView,
              let layout = collectionView.collectionViewLayout as? DayGridLayout else { return }
        if layout.itemSide != thumbnailSize {
            layout.itemSide = thumbnailSize
            layout.invalidateLayout()
        }
        if coordinator.loader.store?.root != store?.root { coordinator.loader.store = store }
        if coordinator.version != sectionsVersion {
            coordinator.version = sectionsVersion
            coordinator.sections = sections
            layout.sectionCounts = sections.map(\.photos.count)
            let selected = coordinator.selectedIDs
            collectionView.reloadData()
            coordinator.restoreSelection(selected)
            if !coordinator.reportedFirstScreen, !sections.isEmpty {
                collectionView.layoutSubtreeIfNeeded()
                coordinator.trackFirstScreen()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: PhotoGrid?
        weak var collectionView: NSCollectionView?
        var frameObserver: NSObjectProtocol?
        var sections: [DaySection] = []
        var version = -1
        let loader = ThumbnailLoader()
        var reportedFirstScreen = false
        private var firstScreenWaiting: Set<PhotoID>?

        /// 记下第一屏有哪些缩略图要等。窗口刚出现时格子可能还没排好，就等下一轮再看。
        func trackFirstScreen(attempt: Int = 0) {
            guard let collectionView, !reportedFirstScreen, firstScreenWaiting == nil else { return }
            let visible = collectionView.indexPathsForVisibleItems().compactMap { photo(at: $0) }
            if visible.isEmpty, attempt < 200 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
                    self?.trackFirstScreen(attempt: attempt + 1)
                }
                return
            }
            firstScreenWaiting = Set(visible.filter { $0.thumbState == .ready }.map(\.id))
            firstScreenWaiting?.subtract(shownBeforeTracking)
            if Measurements.isEnabled {
                Measurements.emit("PF-1 第一屏要等 \(firstScreenWaiting?.count ?? 0) 张缩略图（可见格子 \(visible.count) 个）")
            }
            checkFirstScreen()
        }

        private var shownBeforeTracking: Set<PhotoID> = []

        func thumbnailShown(_ id: PhotoID) {
            guard firstScreenWaiting != nil else {
                if !reportedFirstScreen { shownBeforeTracking.insert(id) }
                return
            }
            firstScreenWaiting?.remove(id)
            checkFirstScreen()
        }

        private func checkFirstScreen() {
            guard !reportedFirstScreen, let waiting = firstScreenWaiting, waiting.isEmpty else { return }
            reportedFirstScreen = true
            firstScreenWaiting = nil
            // 等这一轮画完再报。
            DispatchQueue.main.async { [parent] in parent?.onFirstScreenShown?() }
            if ProcessInfo.processInfo.environment["PHOTOAI_SCROLL_TEST"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.runScrollTest() }
            }
        }

        var selectedIDs: Set<PhotoID> {
            Set(collectionView?.selectionIndexPaths.compactMap { photo(at: $0)?.id } ?? [])
        }

        func photo(at indexPath: IndexPath) -> PhotoSummary? {
            guard indexPath.section < sections.count, indexPath.item < sections[indexPath.section].photos.count else { return nil }
            return sections[indexPath.section].photos[indexPath.item]
        }

        func restoreSelection(_ ids: Set<PhotoID>) {
            guard !ids.isEmpty, let collectionView else { return }
            var paths: Set<IndexPath> = []
            for (sectionIndex, section) in sections.enumerated() {
                for (itemIndex, photo) in section.photos.enumerated() where ids.contains(photo.id) {
                    paths.insert(IndexPath(item: itemIndex, section: sectionIndex))
                }
            }
            collectionView.selectionIndexPaths = paths
        }

        /// PF-2 的替代测量：每 1/60 秒向下滚 `scrollStep` 点，量主线程上每一帧的滚动、排版和绘制用时。
        /// 缩略图在后台解码，不算在内。这不是 Instruments，只是可重复的近似值。
        private var scrollDurations: [Double] = []
        private var scrollTimer: Timer?
        private let scrollStep: CGFloat = 150
        private let scrollFrames = 600

        private func runScrollTest() {
            scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrollTick() }
            }
        }

        private func scrollTick() {
            guard let collectionView, let clip = collectionView.enclosingScrollView?.contentView else { return }
            let start = CACurrentMediaTime()
            var origin = clip.bounds.origin
            origin.y = min(origin.y + scrollStep, max(0, collectionView.frame.height - clip.bounds.height))
            clip.scroll(to: origin)
            collectionView.enclosingScrollView?.reflectScrolledClipView(clip)
            collectionView.layoutSubtreeIfNeeded()
            collectionView.enclosingScrollView?.displayIfNeeded()
            scrollDurations.append((CACurrentMediaTime() - start) * 1000)
            guard scrollDurations.count >= scrollFrames else { return }
            scrollTimer?.invalidate()
            let sorted = scrollDurations.sorted()
            let over = scrollDurations.filter { $0 > 16 }.count
            Measurements.emit(String(
                format: "PF-2 滚动 %d 帧（每帧 %.0f 点，约 %.0f 点/秒）：主线程中位 %.2f ms，95%% %.2f ms，最大 %.2f ms，超过 16 ms 的帧 %d 个，滚到 %.0f 点",
                scrollFrames, scrollStep, scrollStep * 60, sorted[sorted.count / 2], sorted[sorted.count * 95 / 100],
                sorted.last ?? 0, over, clip.bounds.origin.y
            ))
            exit(0)
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            sections[section].photos.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: ThumbnailItem.identifier, for: indexPath)
            if let item = item as? ThumbnailItem, let photo = photo(at: indexPath) {
                item.configure(photo, offline: parent?.isOffline(photo.id) ?? false, loader: loader) { [weak self] id in
                    self?.thumbnailShown(id)
                }
            }
            return item
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
            at indexPath: IndexPath
        ) -> NSView {
            let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: DayHeaderView.identifier, for: indexPath)
            if let header = view as? DayHeaderView, indexPath.section < sections.count {
                let section = sections[indexPath.section]
                header.label.stringValue = DayHeaderView.title(day: section.day, count: section.photos.count)
            }
            return view
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            parent?.onSelectionChange(selectedIDs)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            parent?.onSelectionChange(selectedIDs)
        }
    }
}

// MARK: - 布局

/// 每天一个标题，下面是等大的方格。任意格子的位置都能直接算出来。
final class DayGridLayout: NSCollectionViewLayout {
    var itemSide: Double = 160
    var sectionCounts: [Int] = [] { didSet { invalidateLayout() } }

    let spacing: CGFloat = 6
    let inset: CGFloat = 14
    let headerHeight: CGFloat = 32
    let sectionGap: CGFloat = 10

    private var columns = 1
    private var cell: CGFloat = 160
    private var sectionStarts: [CGFloat] = []
    private var contentHeight: CGFloat = 0
    private var width: CGFloat = 0

    private var visibleWidth: CGFloat {
        collectionView?.enclosingScrollView?.contentView.bounds.width ?? collectionView?.bounds.width ?? 800
    }

    func widthMayHaveChanged() {
        if visibleWidth != width { invalidateLayout() }
    }

    override func prepare() {
        super.prepare()
        width = visibleWidth
        let usable = max(1, width - inset * 2)
        columns = max(1, Int((usable + spacing) / (CGFloat(itemSide) + spacing)))
        cell = (usable - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        sectionStarts.removeAll(keepingCapacity: true)
        var y: CGFloat = 4
        for count in sectionCounts {
            sectionStarts.append(y)
            y += sectionHeight(count)
        }
        contentHeight = y + inset
    }

    private func sectionHeight(_ count: Int) -> CGFloat {
        let rows = (count + columns - 1) / columns
        return headerHeight + CGFloat(rows) * (cell + spacing) + sectionGap
    }

    override var collectionViewContentSize: NSSize { NSSize(width: width, height: contentHeight) }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        visibleWidth != width
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section < sectionStarts.count else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = frameForItem(indexPath.item, in: indexPath.section)
        return attributes
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section < sectionStarts.count else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forSupplementaryViewOfKind: elementKind, with: indexPath)
        attributes.frame = NSRect(x: inset, y: sectionStarts[indexPath.section], width: width - inset * 2, height: headerHeight)
        return attributes
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard !sectionStarts.isEmpty else { return [] }
        var result: [NSCollectionViewLayoutAttributes] = []
        // 二分找到第一个和可见区域相交的分组。
        var low = 0
        var high = sectionStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if sectionStarts[mid] <= rect.minY { low = mid } else { high = mid - 1 }
        }
        var section = low
        while section < sectionStarts.count, sectionStarts[section] < rect.maxY {
            let start = sectionStarts[section]
            let headerFrame = NSRect(x: inset, y: start, width: width - inset * 2, height: headerHeight)
            if headerFrame.intersects(rect) {
                let header = NSCollectionViewLayoutAttributes(
                    forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                    with: IndexPath(item: 0, section: section)
                )
                header.frame = headerFrame
                result.append(header)
            }
            let count = sectionCounts[section]
            let rowHeight = cell + spacing
            let top = start + headerHeight
            let firstRow = max(0, Int((rect.minY - top) / rowHeight))
            let lastRow = min((count - 1) / columns, Int((rect.maxY - top) / rowHeight))
            if count > 0, firstRow <= lastRow {
                for row in firstRow...lastRow {
                    for column in 0..<columns {
                        let item = row * columns + column
                        guard item < count else { break }
                        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: item, section: section))
                        attributes.frame = frameForItem(item, in: section)
                        result.append(attributes)
                    }
                }
            }
            section += 1
        }
        return result
    }

    private func frameForItem(_ item: Int, in section: Int) -> NSRect {
        let row = item / columns
        let column = item % columns
        return NSRect(
            x: inset + CGFloat(column) * (cell + spacing),
            y: sectionStarts[section] + headerHeight + CGFloat(row) * (cell + spacing),
            width: cell,
            height: cell
        )
    }
}

// MARK: - 格子

final class ThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailItem")

    private let thumbnail = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private let placeholder = NSTextField(labelWithString: "")
    private var photoID: PhotoID?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 4
        thumbnail.imageScaling = .scaleProportionallyDown
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .systemFont(ofSize: 10, weight: .medium)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.drawsBackground = true
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        badge.translatesAutoresizingMaskIntoConstraints = false
        placeholder.font = .systemFont(ofSize: 11)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(thumbnail)
        root.addSubview(placeholder)
        root.addSubview(badge)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            thumbnail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            thumbnail.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            thumbnail.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
            placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -8),
            badge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            badge.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6)
        ])
        view = root
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    private func updateSelection() {
        view.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor : NSColor.quaternaryLabelColor.cgColor
    }

    func configure(_ photo: PhotoSummary, offline: Bool, loader: ThumbnailLoader, shown: @escaping (PhotoID) -> Void) {
        photoID = photo.id
        updateSelection()
        var marks: [String] = []
        if photo.rating > 0 { marks.append(String(repeating: "★", count: photo.rating)) }
        if photo.flag == .pick { marks.append("Pick") }
        if photo.flag == .reject { marks.append("✕") }
        if photo.hasRaw && photo.hasJPEG { marks.append("RAW+JPG") } else if photo.hasRaw { marks.append("RAW") }
        if offline { marks.append("离线") }
        badge.stringValue = marks.isEmpty ? "" : " " + marks.joined(separator: " · ") + " "
        badge.isHidden = marks.isEmpty
        view.toolTip = photo.baseName

        thumbnail.image = nil
        placeholder.stringValue = photo.baseName
        placeholder.isHidden = false
        guard photo.thumbState == .ready else { return }
        let id = photo.id
        if let image = loader.cached(id) {
            show(image)
            shown(id)
            return
        }
        loader.load(id) { [weak self] image in
            guard let self, self.photoID == id, let image else { return }
            self.show(image)
            self.view.displayIfNeeded()
            shown(id)
        }
    }

    private func show(_ image: NSImage) {
        thumbnail.image = image
        placeholder.isHidden = true
    }
}

final class DayHeaderView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("DayHeaderView")
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let display: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 · EEEE"
        return formatter
    }()

    static func title(day: String?, count: Int) -> String {
        guard let day, let date = parser.date(from: day) else {
            return day == nil ? "\(count.formatted()) 张" : "\(day!) · \(count.formatted()) 张"
        }
        return "\(display.string(from: date)) · \(count.formatted()) 张"
    }
}

// MARK: - 缩略图加载

/// 从本机预览目录读 480 缩略图，后台解码，主线程只拿解码好的图。
@MainActor
final class ThumbnailLoader {
    var store: PreviewStore?
    private let cache = NSCache<NSNumber, NSImage>()
    private var waiting: [PhotoID: [(NSImage?) -> Void]] = [:]
    private let queue = DispatchQueue(label: "thumbnails", qos: .userInitiated, attributes: .concurrent)

    init() { cache.countLimit = 3_000 }

    func cached(_ id: PhotoID) -> NSImage? { cache.object(forKey: NSNumber(value: id)) }

    func load(_ id: PhotoID, completion: @escaping (NSImage?) -> Void) {
        guard let store else { return completion(nil) }
        if waiting[id] != nil {
            waiting[id]?.append(completion)
            return
        }
        waiting[id] = [completion]
        let url = store.url(for: id, size: .thumb)
        queue.async {
            let decoded = Self.decode(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let image = decoded.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                    if let image { self.cache.setObject(image, forKey: NSNumber(value: id)) }
                    let callbacks = self.waiting.removeValue(forKey: id) ?? []
                    for callback in callbacks { callback(image) }
                }
            }
        }
    }

    nonisolated private static func decode(_ url: URL) -> CGImage? {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}
