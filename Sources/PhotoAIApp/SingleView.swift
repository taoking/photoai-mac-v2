import AppKit
import PhotoAICore
import SwiftUI

/// 单张视图：本机的 1600 预览（卷离线也能看）、浮在底部的信息条、胶片条（信息架构 §3.4）。
/// 信息条在鼠标不动 2 秒后淡出，打星、打标签时短暂出现。
/// 在一张照片上停 0.3 秒、原片所在卷在线时，换上按屏幕尺寸读的原图（计划 V-3）。
struct SingleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @State private var barShownAt = Date()
    @State private var barVisible = true
    /// 适合窗口时触控板捏合：手指还在时先把画面放大，松手后进入放大。
    @State private var pinch: CGFloat = 1
    @State private var pinchAnchor = UnitPoint.center

    var body: some View {
        let style = model.viewerStyle
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                style.background.color
                if let id = model.focusedPhotoID {
                    if model.zoomed {
                        ZoomedPhoto(id: id) { model.toggleZoom() }
                    } else {
                        GeometryReader { geometry in
                            PreviewImage(id: id, reportsPageTurn: true, sharpens: true)
                                .padding(style.margin.points)
                                .scaleEffect(pinch, anchor: pinchAnchor)
                                .contentShape(Rectangle())
                                .gesture(SpatialTapGesture().onEnded { value in
                                    model.clickZoom(at: zoomPoint(value.location, in: geometry.size, id: id))
                                })
                                .simultaneousGesture(MagnifyGesture()
                                    .onChanged { value in
                                        pinchAnchor = value.startAnchor
                                        pinch = max(1, value.magnification)
                                    }
                                    .onEnded { value in
                                        pinch = 1
                                        guard value.magnification > 1.05 else { return }
                                        model.zoom(
                                            to: model.fitScale * value.magnification,
                                            at: zoomPoint(value.startLocation, in: geometry.size, id: id)
                                        )
                                    })
                                .task(id: SharpRequest(id: id, size: geometry.size, margin: style.margin.points)) {
                                    let longEdge = reportFitScale(in: geometry.size, id: id)
                                    try? await Task.sleep(for: .milliseconds(300))
                                    guard !Task.isCancelled else { return }
                                    model.loadSharpOriginals(around: id, maximumPixelSize: longEdge)
                                }
                        }
                    }
                    if model.showInfoOverlay {
                        InfoOverlay(id: id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(20)
                    }
                    InfoBar(id: id)
                        .padding(.bottom, 14)
                        .opacity(barVisible ? 1 : 0)
                        .animation(.easeInOut(duration: 0.25), value: barVisible)
                }
            }
            .environment(\.colorScheme, style.background.colorScheme)
            .contentShape(Rectangle())
            .onContinuousHover { _ in pokeBar() }
            Divider()
            Filmstrip()
        }
        .onChange(of: model.marksVersion) { pokeBar() }
        .onAppear { pokeBar() }
    }

    private struct SharpRequest: Equatable {
        let id: PhotoID
        let size: CGSize
        let margin: CGFloat
    }

    /// 照片按原比例放在留白之内的区域正中，这是它画出来的位置。
    private func photoRect(in size: CGSize, id: PhotoID) -> CGRect {
        let margin = model.viewerStyle.margin.points
        let area = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
        // 按画出来的那张图的比例算（M3 之前的库里，机内 16:9 裁切的照片记的是 RAW 的 3:2）。
        let shown = model.previews.cached(id) ?? model.thumbnails.cached(id)
        let ratio = shown.map { $0.size.width / max($0.size.height, 1) } ?? CGFloat(model.photo(id)?.aspectRatio ?? 1.5)
        let width = max(0, min(area.width, area.height * ratio))
        let height = width / ratio
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }

    /// 把适合窗口的比例报给模型（⌘+ / 捏合从这里起算），返回照片在屏幕上的长边像素数（换原图解多大）。
    private func reportFitScale(in size: CGSize, id: PhotoID) -> Int {
        let rect = photoRect(in: size, id: id)
        if let photo = model.photo(id), let width = photo.width, let height = photo.height, width > 0, height > 0 {
            model.fitScale = max(rect.width, rect.height) * displayScale / CGFloat(max(width, height))
        }
        return Int((max(rect.width, rect.height) * displayScale).rounded())
    }

    /// 单击的位置换算成照片上的位置（0–1）。
    private func zoomPoint(_ location: CGPoint, in size: CGSize, id: PhotoID) -> CGPoint {
        let rect = photoRect(in: size, id: id)
        guard rect.width > 0, rect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(max((location.x - rect.minX) / rect.width, 0), 1), y: min(max((location.y - rect.minY) / rect.height, 0), 1))
    }

    private func pokeBar() {
        let now = Date()
        barShownAt = now
        barVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if barShownAt == now { barVisible = false }
        }
    }
}

/// 单张视图底部的信息条：文件名、星级、标签、标记、位置。
struct InfoBar: View {
    @Environment(AppModel.self) private var model
    let id: PhotoID

    var body: some View {
        if let photo = model.photo(id) {
            HStack(spacing: 12) {
                Button { model.setView(.grid) } label: { Image(systemName: "square.grid.2x2") }
                    .buttonStyle(.borderless)
                    .help("回到网格（空格 / Esc）")
                Text(photo.baseName).font(.headline)
                StarRating(rating: photo.rating, size: 14) { model.setRating($0) }
                if !photo.labelIDs.isEmpty { LabelChips(ids: photo.labelIDs).font(.callout) }
                if photo.flag != .none {
                    Text(photo.flag.displayName)
                        .font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(photo.flag == .pick ? Color.green : Color.red, in: Capsule())
                        .foregroundStyle(.white)
                }
                if model.isOffline(id) {
                    Text("离线").font(.caption).foregroundStyle(.secondary)
                } else if !model.zoomed {
                    // 正在看的是换上的原图还是本机预览（计划 V-3）。
                    Text(model.sharpOriginals[id] != nil ? "原图" : "预览").font(.caption).foregroundStyle(.secondary)
                        .help("在一张照片上停一下，原片所在卷在线时换上原图；卷离线时一直是本机预览")
                }
                Text("\(((model.resultIndex[id] ?? 0) + 1).formatted()) / \(model.photoCount.formatted())")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Button(model.focusMode ? "退出专注" : "专注") { model.perform(.focusMode) }
                    .buttonStyle(.borderless)
                    .help("专注模式：隐藏侧栏、检查器、工具栏（F）")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 4)
        }
    }
}

/// 参数浮层：拍摄时间、相机、镜头、曝光（I）。
struct InfoOverlay: View {
    @Environment(AppModel.self) private var model
    let id: PhotoID
    @State private var detail: PhotoDetail?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let detail, detail.summary.id == id {
                Text(detail.summary.captureDate ?? "拍摄时间未知")
                if let camera = [detail.cameraMake, detail.cameraModel].compactMap({ $0 }).joined(separator: " ").nilIfEmpty {
                    Text(camera)
                }
                if let lens = detail.lens { Text(lens) }
                if let exposure = ExposureText.make(detail) { Text(exposure) }
            }
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .opacity(detail?.summary.id == id ? 1 : 0)
        .task(id: id) { detail = await model.loadDetail(of: id) }
    }
}

/// 一张照片的 1600 预览。先显示已经在内存里的 480 缩略图，1600 解码好后换上。
/// `sharpens`（单张视图）：模型里有换上的原图就显示原图。
struct PreviewImage: View {
    @Environment(AppModel.self) private var model
    let id: PhotoID
    /// 单张视图里翻页：大图画出来时记 PF-7。
    var reportsPageTurn = false
    var sharpens = false
    @State private var loaded: (id: PhotoID, image: NSImage)?

    var body: some View {
        let preview = loaded?.id == id ? loaded?.image : (model.previews.cached(id) ?? model.thumbnails.cached(id))
        let sharp = sharpens ? model.sharpOriginals[id]?.nsImage : nil
        Group {
            if let image = sharp ?? preview {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .viewerFrame(model.viewerStyle)
            } else if model.photo(id)?.thumbState == .ready {
                ProgressView().controlSize(.small)
            } else {
                Text("预览还没生成").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: id) {
            let target = id
            if let cached = model.previews.cached(target) {
                loaded = (target, cached)
                pageShown(target)
                return
            }
            if model.thumbnails.cached(target) == nil {
                model.thumbnails.load(target) { _ in }
            }
            model.previews.load(target) { image in
                guard let image, target == id else { return }
                loaded = (target, image)
                pageShown(target)
            }
        }
    }

    private func pageShown(_ target: PhotoID) {
        guard reportsPageTurn, let started = model.pageStarted, model.focusedPhotoID == target else { return }
        model.pageStarted = nil
        DispatchQueue.main.async { Measurements.record("PF-7 翻页", since: started, count: 1) }
    }
}

/// 胶片条：当前结果里焦点附近的一段，点一下跳过去。
struct Filmstrip: View {
    @Environment(AppModel.self) private var model
    private let height: CGFloat = 64

    var body: some View {
        let ids = window
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(ids, id: \.self) { id in
                        FilmstripCell(id: id, height: height, isFocused: id == model.focusedPhotoID)
                            .id(id)
                            .onTapGesture {
                                model.focusOnly(id)
                                model.prefetchAroundFocus()
                            }
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: height + 14)
            // 不透明：网格一直在单张视图下面，透明的话网格里选中那格的蓝框会从胶片条的空隙透出来。
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear { if let id = model.focusedPhotoID { proxy.scrollTo(id, anchor: .center) } }
            .onChange(of: model.focusedPhotoID) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// 只放焦点前后各 60 张，十万张的结果也不用一次排版。
    private var window: [PhotoID] {
        guard let id = model.focusedPhotoID, let index = model.resultIndex[id] else { return [] }
        let lower = max(0, index - 60), upper = min(model.resultIDs.count, index + 61)
        return Array(model.resultIDs[lower..<upper])
    }
}

struct FilmstripCell: View {
    @Environment(AppModel.self) private var model
    let id: PhotoID
    let height: CGFloat
    let isFocused: Bool
    @State private var image: NSImage?

    var body: some View {
        let photo = model.photo(id)
        let width = height * CGFloat(photo?.aspectRatio ?? 1.5)
        ZStack(alignment: .bottomLeading) {
            if let image = image ?? model.thumbnails.cached(id) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.15)
            }
            if let rating = photo?.rating, rating > 0 {
                Text(String(repeating: "★", count: rating))
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow)
                    .padding(2)
                    .background(.black.opacity(0.5))
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(isFocused ? Color.accentColor : .clear, lineWidth: 3))
        .opacity(isFocused ? 1 : 0.75)
        .task(id: id) {
            guard image == nil, model.thumbnails.cached(id) == nil, photo?.thumbState == .ready else { return }
            model.thumbnails.load(id) { image = $0 }
        }
    }
}

/// 比较视图：选中的 2–4 张并排，打星和标记作用于蓝框（信息架构 §3.5）。
struct CompareView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ids = model.compareIDs
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.setView(.grid) } label: { Image(systemName: "square.grid.2x2") }
                    .buttonStyle(.borderless)
                Text("比较 \(ids.count) 张").font(.headline)
                Text("← → 切换焦点 · 打星、标签、标记作用于蓝框" + (ids.count == 2 ? " · ⇧P 蓝框 Pick、另一张 Reject" : "") + " · Z 同步放大 · F 专注")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
            GeometryReader { geometry in
                let rows: CGFloat = ids.count > 2 ? 2 : 1
                let cellHeight = (geometry.size.height - 8 * (rows - 1) - 16) / rows
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                        CompareCell(id: id, isFocused: index == model.compareFocus)
                            .frame(height: cellHeight)
                            .onTapGesture { model.compareFocus = index }
                    }
                }
                .padding(8)
            }
        }
        .background(model.viewerStyle.background.color)
        .environment(\.colorScheme, model.viewerStyle.background.colorScheme)
    }
}

struct CompareCell: View {
    @Environment(AppModel.self) private var model
    let id: PhotoID
    let isFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.zoomed {
                ZoomedPhoto(id: id, noteAtBottom: true) { if let index = model.compareIDs.firstIndex(of: id) { model.compareFocus = index } }
                    .padding(2)
            } else {
                PreviewImage(id: id).padding(6)
            }
            if let photo = model.photo(id) {
                HStack(spacing: 6) {
                    Text(photo.baseName).font(.caption.bold())
                    if photo.rating > 0 { Text(String(repeating: "★", count: photo.rating)).foregroundStyle(.yellow) }
                    if photo.flag != .none { Text(photo.flag.displayName).foregroundStyle(photo.flag == .pick ? .green : .red) }
                    LabelChips(ids: photo.labelIDs)
                }
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(8)
            }
        }
        .background(Color.black.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isFocused ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isFocused ? 3 : 1))
        .contentShape(Rectangle())
    }
}
