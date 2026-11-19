import AppKit
import PhotoAICore
import SwiftUI

/// 放大的一张照片：原文件读好之前先放大已有的图（单张视图换上的原图，或者 1600 预览，会糊），读好后换上原图。
/// 顶部一行说明比例和正在看的是什么：原文件、正在读取，或者卷离线只能放大预览。
struct ZoomedPhoto: View {
    @Environment(AppModel.self) private var model
    let id: PhotoID
    /// 说明放在上面还是下面：比较视图的格子上面是名字。
    var noteAtBottom = false
    /// 单击（没有拖动）：单张视图回到适合窗口，比较视图切换焦点格。
    let onClick: () -> Void

    var body: some View {
        let state = model.originals[id]
        let photo = model.photo(id)
        let placeholder = model.previews.cached(id) ?? model.thumbnails.cached(id)
        let image: CGImage? = if case .ready(let original, _) = state {
            original
        } else {
            model.sharpOriginals[id]?.image ?? placeholder?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let pixelSize: CGSize = if case .ready(let original, _) = state {
            CGSize(width: original.width, height: original.height)
        } else if let width = photo?.width, let height = photo?.height, width > 0, height > 0 {
            // 读原图之前先放大预览：按照片的长边、预览的比例（16:9 的 JPEG 生成的预览也是 16:9），免得拉变形。
            Self.size(longEdge: max(width, height), like: image) ?? CGSize(width: width, height: height)
        } else {
            CGSize(width: image?.width ?? 1600, height: image?.height ?? 1067)
        }
        ZStack(alignment: noteAtBottom ? .bottom : .top) {
            ZoomedImage(
                image: image,
                pixelSize: pixelSize,
                center: model.zoomCenter,
                scale: model.zoomScale,
                onPan: { model.setZoomCenter($0) },
                onScale: { model.setZoomScale($0) },
                onFitScale: { model.fitScale = $0 },
                onPinchedToFit: { model.endZoom() },
                onClick: onClick
            )
            Text(note(state))
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                .padding(noteAtBottom ? .bottom : .top, 10)
                .allowsHitTesting(false)
        }
    }

    static func size(longEdge: Int, like image: CGImage?) -> CGSize? {
        guard let image, image.width > 0, image.height > 0 else { return nil }
        let scale = CGFloat(longEdge) / CGFloat(max(image.width, image.height))
        return CGSize(width: (CGFloat(image.width) * scale).rounded(), height: (CGFloat(image.height) * scale).rounded())
    }

    private func note(_ state: OriginalState?) -> String {
        let percent = model.zoomPercent
        return switch state {
        case .ready(_, let source): "\(percent) · \(source)"
        case .offline(let volumes):
            "\(percent) · 卷离线：只能放大预览；看原图请插入" + volumes.map { "「\($0)」" }.joined(separator: "或")
        case .unavailable(let reason): "\(percent) · \(reason)"
        case .loading, nil: "\(percent) · 正在读取原文件…"
        }
    }
}

/// 按比例显示：`scale` 为 1 时一个图像像素对一个屏幕像素（Retina 屏上按 backing scale 换算）。
/// 拖动、滚动平移；触控板捏合缩放，捏到适合窗口以下就回到适合窗口。
struct ZoomedImage: NSViewRepresentable {
    let image: CGImage?
    let pixelSize: CGSize
    let center: CGPoint
    let scale: CGFloat
    let onPan: (CGPoint) -> Void
    let onScale: (CGFloat) -> Void
    let onFitScale: (CGFloat) -> Void
    let onPinchedToFit: () -> Void
    let onClick: () -> Void

    func makeNSView(context: Context) -> ZoomScrollView {
        ZoomScrollView()
    }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        view.onPan = onPan
        view.onScale = onScale
        view.onFitScale = onFitScale
        view.onPinchedToFit = onPinchedToFit
        view.onClick = onClick
        view.update(image: image, pixelSize: pixelSize, center: center, scale: scale)
    }
}

/// 画布按一比一的大小摆（像素 ÷ backing scale），比例交给 NSScrollView 的 magnification，捏合由它处理。
final class ZoomScrollView: NSScrollView {
    var onPan: ((CGPoint) -> Void)?
    var onScale: ((CGFloat) -> Void)?
    var onFitScale: ((CGFloat) -> Void)?
    var onPinchedToFit: (() -> Void)?
    var onClick: (() -> Void)?
    private let canvas = ZoomCanvas()
    private var pixelSize = CGSize(width: 1, height: 1)
    private var wantedCenter = CGPoint(x: 0.5, y: 0.5)
    private var wantedScale: CGFloat = 1
    private var fitScale: CGFloat = 0
    /// 正在捏合：这时不按模型里的比例去改，免得和手指打架。
    private var inLiveMagnify = false
    private var image: CGImage?
    /// 程序自己在滚动：不回报中心，免得几个格子互相推。
    private var applyingCenter = false

    init() {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        documentView = canvas
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = false
        contentView.drawsBackground = false
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView
        )
        allowsMagnification = true
        maxMagnification = AppModel.maximumZoom
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveMagnifyStarted), name: NSScrollView.willStartLiveMagnifyNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveMagnifyEnded), name: NSScrollView.didEndLiveMagnifyNotification, object: self
        )
        canvas.onClick = { [weak self] in self?.onClick?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    func update(image: CGImage?, pixelSize: CGSize, center: CGPoint, scale: CGFloat) {
        if image !== self.image {
            self.image = image
            canvas.image = image
        }
        wantedCenter = center
        let scaleChanged = abs(scale - wantedScale) > 0.001
        wantedScale = scale
        if pixelSize != self.pixelSize {
            self.pixelSize = pixelSize
            resizeCanvas()
        } else if scaleChanged {
            applyScale()
        } else if distance(currentCenter, center) > 0.001 {
            scroll(to: center)
        }
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private func resizeCanvas() {
        canvas.setFrameSize(NSSize(width: pixelSize.width / backingScale, height: pixelSize.height / backingScale))
        updateFitScale()
        applyScale()
    }

    private func applyScale() {
        guard !inLiveMagnify else { return }
        applyingCenter = true
        if abs(magnification - wantedScale) > 0.001 { magnification = wantedScale }
        applyingCenter = false
        scroll(to: wantedCenter)
    }

    /// 整张照片正好放进可视区域的比例。捏合最小到这里，再往小捏就回到适合窗口。
    private func updateFitScale() {
        let size = canvas.frame.size
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        guard abs(fit - fitScale) > 0.0001 else { return }
        fitScale = fit
        minMagnification = min(fit, AppModel.zoomSteps[0])
        onFitScale?(fit)
    }

    @objc private func liveMagnifyStarted() { inLiveMagnify = true }

    @objc private func liveMagnifyEnded() {
        inLiveMagnify = false
        if magnification <= fitScale * 1.02 {
            onPinchedToFit?()
        } else {
            wantedScale = magnification
            onScale?(magnification)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resizeCanvas()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resizeCanvas()
    }

    override func layout() {
        super.layout()
        // 窗口大小变了，画面中心不动。
        updateFitScale()
        scroll(to: wantedCenter)
    }

    /// 现在画面中心在照片上的位置（验收场景核对同步用）。
    var visibleCenter: CGPoint { currentCenter }

    private var currentCenter: CGPoint {
        let bounds = contentView.bounds
        let size = canvas.frame.size
        guard size.width > 0, size.height > 0 else { return wantedCenter }
        return CGPoint(x: clamp(bounds.midX / size.width), y: clamp(bounds.midY / size.height))
    }

    private func scroll(to center: CGPoint) {
        let bounds = contentView.bounds
        let size = canvas.frame.size
        let origin = NSPoint(x: center.x * size.width - bounds.width / 2, y: center.y * size.height - bounds.height / 2)
        applyingCenter = true
        contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: origin, size: bounds.size)).origin)
        reflectScrolledClipView(contentView)
        applyingCenter = false
    }

    @objc private func boundsChanged() {
        guard !applyingCenter else { return }
        wantedCenter = currentCenter
        onPan?(wantedCenter)
        // 捏合中：比例随时报上去，比较视图的其他格跟着变，角上的比例也跟着变。
        if inLiveMagnify, abs(magnification - wantedScale) > 0.001 {
            wantedScale = magnification
            onScale?(magnification)
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { max(abs(a.x - b.x), abs(a.y - b.y)) }
}

/// 放原图的那一层。按住拖动平移；没拖动就松开算单击。
/// 图放在子图层里由 GPU 缩放。上屏走 `updateLayer`，不给这一层分配位图；
/// 截图（`cacheDisplay`）不画图层内容，会改调 `draw(_:)`，那时另外画一次。
final class ZoomCanvas: NSView {
    var onClick: (() -> Void)?
    var image: CGImage? {
        didSet { imageLayer.contents = image; needsDisplay = true }
    }
    private let imageLayer = CALayer()
    private var dragStart: NSPoint?
    private var dragged = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        imageLayer.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds)
        context.restoreGState()
    }

    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let clip = enclosingScrollView?.contentView else { return }
        let point = event.locationInWindow
        let delta = NSPoint(x: point.x - start.x, y: point.y - start.y)
        if abs(delta.x) + abs(delta.y) > 2 { dragged = true }
        guard dragged else { return }
        NSCursor.closedHand.set()
        // 窗口坐标 y 向上，画布是翻转的：往下拖，画面跟着往下走。放大后画布上的一点对应屏幕上的 magnification 点。
        let magnification = enclosingScrollView?.magnification ?? 1
        let origin = NSPoint(x: clip.bounds.origin.x - delta.x / magnification, y: clip.bounds.origin.y + delta.y / magnification)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
        dragStart = point
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if !dragged { onClick?() }
        NSCursor.openHand.set()
    }
}

/// 照片比可视区域小的那一边居中。
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}
