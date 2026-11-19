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
    var loader: ThumbnailLoader
    /// 模型改了选择（键盘、全选、重新筛选）时变化；网格据此同步选中状态并滚到焦点。
    var selectionVersion: Int
    var selectedIDs: Set<PhotoID>
    var focusedID: PhotoID?
    /// 星级、标签、标记改了时变化；只重画 `changedIDs` 里的格子。
    var marksVersion: Int
    var changedIDs: Set<PhotoID>
    var marks: CellMarks
    var onSelectionChange: (Set<PhotoID>, PhotoID?) -> Void
    var onOpen: (PhotoID) -> Void
    var onColumnsChange: (Int) -> Void
    /// 第一屏的缩略图全部画出来时调用一次（PF-1 计时到这里）。
    var onFirstScreenShown: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = DayGridLayout()
        layout.onColumnsChange = { [weak coordinator = context.coordinator] columns in
            coordinator?.parent?.onColumnsChange(columns)
        }
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
        if coordinator.version != sectionsVersion {
            coordinator.version = sectionsVersion
            coordinator.sections = sections
            layout.sectionCounts = sections.map(\.photos.count)
            collectionView.reloadData()
            coordinator.restoreSelection(selectedIDs)
            if !coordinator.reportedFirstScreen, !sections.isEmpty {
                collectionView.layoutSubtreeIfNeeded()
                coordinator.trackFirstScreen()
            }
        }
        if coordinator.selectionVersion != selectionVersion {
            coordinator.selectionVersion = selectionVersion
            coordinator.restoreSelection(selectedIDs)
            coordinator.reveal(focusedID)
        }
        if coordinator.focusedID != focusedID {
            let old = coordinator.focusedID
            coordinator.focusedID = focusedID
            coordinator.refresh([old, focusedID].compactMap { $0 })
        }
        if coordinator.marksVersion != marksVersion {
            coordinator.marksVersion = marksVersion
            coordinator.refresh(changedIDs)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: PhotoGrid?
        weak var collectionView: NSCollectionView?
        var frameObserver: NSObjectProtocol?
        var sections: [DaySection] = []
        var version = -1
        var selectionVersion = -1
        var marksVersion = -1
        var focusedID: PhotoID?
        var loader: ThumbnailLoader? { parent?.loader }
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

        func indexPath(of id: PhotoID) -> IndexPath? {
            parent?.marks.position(id)
        }

        func restoreSelection(_ ids: Set<PhotoID>) {
            guard let collectionView else { return }
            let paths = Set(ids.compactMap(indexPath(of:)))
            if collectionView.selectionIndexPaths != paths { collectionView.selectionIndexPaths = paths }
        }

        /// 把焦点格滚进可见区域（上下各留一点空）。
        func reveal(_ id: PhotoID?) {
            guard let id, let collectionView, let path = indexPath(of: id),
                  let frame = collectionView.collectionViewLayout?.layoutAttributesForItem(at: path)?.frame else { return }
            collectionView.scrollToVisible(frame.insetBy(dx: 0, dy: -40))
        }

        /// 重画这些照片的格子（角标、焦点框、是否已不符合条件）。不在可见区域的格子出现时自然会按新数据画。
        func refresh(_ ids: some Collection<PhotoID>) {
            guard let collectionView, !ids.isEmpty else { return }
            let wanted = Set(ids)
            for path in collectionView.indexPathsForVisibleItems() {
                guard let photo = photo(at: path), wanted.contains(photo.id),
                      let item = collectionView.item(at: path) as? ThumbnailItem else { continue }
                item.updateMarks(current(photo), marks: marks(for: photo.id))
            }
        }

        func current(_ photo: PhotoSummary) -> PhotoSummary {
            parent?.marks.current(photo.id) ?? photo
        }

        func marks(for id: PhotoID) -> ThumbnailItem.Marks {
            guard let parent else { return ThumbnailItem.Marks() }
            let photo = parent.marks.current(id)
            return ThumbnailItem.Marks(
                offline: parent.marks.isOffline(id),
                stale: photo.map { !parent.marks.matches($0) } ?? false,
                focused: id == parent.focusedID,
                labelColors: parent.marks.labelColors
            )
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
            if let item = item as? ThumbnailItem, let photo = photo(at: indexPath), let loader {
                item.onOpen = { [weak self] id in self?.parent?.onOpen(id) }
                item.configure(current(photo), marks: marks(for: photo.id), loader: loader) { [weak self] id in
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
            let clicked = indexPaths.count == 1 ? indexPaths.first.flatMap { photo(at: $0)?.id } : nil
            parent?.onSelectionChange(selectedIDs, clicked)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            parent?.onSelectionChange(selectedIDs, nil)
        }
    }
}

// MARK: - 布局

/// 每天一个标题，下面是等大的方格。任意格子的位置都能直接算出来。
final class DayGridLayout: NSCollectionViewLayout {
    var itemSide: Double = 160
    var sectionCounts: [Int] = [] { didSet { invalidateLayout() } }
    var onColumnsChange: ((Int) -> Void)?

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
        let newColumns = max(1, Int((usable + spacing) / (CGFloat(itemSide) + spacing)))
        if newColumns != columns { onColumnsChange?(newColumns) }
        columns = newColumns
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

/// 格子上的角标与状态，来自模型（星级、标签、标记随改动变化，所以不放在分组的副本里）。
struct CellMarks {
    var current: (PhotoID) -> PhotoSummary?
    /// 照片在网格里的位置（分组、组内序号）。
    var position: (PhotoID) -> IndexPath?
    var isOffline: (PhotoID) -> Bool
    /// 照片是否符合当前筛选条件；结果保持不变时，已不符合的格子变淡。
    var matches: (PhotoSummary) -> Bool
    var labelColors: [LabelID: NSColor]
}

final class ThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailItem")

    struct Marks {
        var offline = false
        var stale = false
        var focused = false
        var labelColors: [LabelID: NSColor] = [:]
    }

    private let thumbnail = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private let placeholder = NSTextField(labelWithString: "")
    private var photoID: PhotoID?
    private var focused = false
    var onOpen: ((PhotoID) -> Void)?

    override func loadView() {
        let root = CellView()
        root.onDoubleClick = { [weak self] in
            if let self, let id = self.photoID { self.onOpen?(id) }
        }
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
            badge.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -6)
        ])
        view = root
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    private func updateSelection() {
        view.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor : NSColor.quaternaryLabelColor.cgColor
        view.layer?.borderWidth = focused && isSelected ? 2 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    func configure(_ photo: PhotoSummary, marks: Marks, loader: ThumbnailLoader, shown: @escaping (PhotoID) -> Void) {
        photoID = photo.id
        updateMarks(photo, marks: marks)
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

    /// 角标：星级、Pick / Reject、标签色点、RAW+JPG、离线（信息架构 §3.3）。
    func updateMarks(_ photo: PhotoSummary, marks: Marks) {
        focused = marks.focused
        updateSelection()
        view.alphaValue = marks.stale ? 0.4 : 1
        let text = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        func append(_ string: String, _ color: NSColor = .white) {
            if text.length > 0 { text.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: NSColor.white])) }
            text.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        }
        if photo.rating > 0 { append(String(repeating: "★", count: photo.rating), .systemYellow) }
        if photo.flag == .pick { append("Pick", .systemGreen) }
        if photo.flag == .reject { append("Reject", .systemRed) }
        let dots = photo.labelIDs.compactMap { marks.labelColors[$0] }
        if !dots.isEmpty {
            if text.length > 0 { text.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: NSColor.white])) }
            for (index, color) in dots.enumerated() {
                text.append(NSAttributedString(string: index == 0 ? "●" : " ●", attributes: [.font: font, .foregroundColor: color]))
            }
        }
        if photo.hasRaw && photo.hasJPEG { append("RAW+JPG") } else if photo.hasRaw { append("RAW") }
        if marks.offline { append("离线") }
        if text.length > 0 {
            let padded = NSMutableAttributedString(string: " ", attributes: [.font: font])
            padded.append(text)
            padded.append(NSAttributedString(string: " ", attributes: [.font: font]))
            badge.attributedStringValue = padded
        }
        badge.isHidden = text.length == 0
    }

    private func show(_ image: NSImage) {
        thumbnail.image = image
        placeholder.isHidden = true
    }
}

/// 格子的底层视图：点击都交给网格处理选择，双击另外通知。
final class CellView: NSView {
    var onDoubleClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
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
