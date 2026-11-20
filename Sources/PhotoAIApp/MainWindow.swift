import AppKit
import PhotoAICore
import SwiftUI

/// 主窗口：侧栏 + 内容区 + 检查器 + 状态栏（设计稿 §6）。
/// 内容区的网格、单张、比较在同一块区域里切换；网格一直留在下面，切回来时滚动位置和选择都在。
struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: Binding(
            get: { model.focusMode ? .detailOnly : model.sidebarVisibility },
            set: { if !model.focusMode { model.sidebarVisibility = $0 } }
        )) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if model.viewMode == .grid {
                    TitleRow()
                    Divider()
                    if model.filterBarVisible, model.sourceCount > 0 {
                        FilterBar()
                        Divider()
                    }
                }
                ZStack {
                    if let error = model.launchError {
                        ContentUnavailableView("照片库打不开", systemImage: "exclamationmark.triangle", description: Text(error))
                    } else if model.photoCount == 0 {
                        EmptyLibraryView()
                    } else {
                        grid
                    }
                    switch model.viewMode {
                    case .grid: EmptyView()
                    case .single: SingleView()
                    case .compare: CompareView()
                    }
                }
                StatusBar()
            }
            .inspector(isPresented: Binding(
                get: { model.showInspector && !model.focusMode },
                set: { if !model.focusMode { model.showInspector = $0 } }
            )) {
                InspectorView()
                    .inspectorColumnWidth(min: 220, ideal: 260, max: 340)
            }
        }
        .toolbar(model.focusMode ? .hidden : .visible, for: .windowToolbar)
        .toolbar {
            ToolbarItem {
                Button { model.perform(.toggleFilterBar) } label: {
                    let count = model.currentFilter.activeGroupCount
                    Label(count > 0 ? "筛选 \(count)" : "筛选", systemImage: "line.3.horizontal.decrease.circle")
                        .symbolVariant(model.filterBarVisible ? .fill : .none)
                }
                .help("显示 / 隐藏筛选条（\\）")
            }
            ToolbarItem {
                Picker("排序", selection: $model.sort) {
                    Text("拍摄时间 新→旧").tag(PhotoSort.captureDateDescending)
                    Text("拍摄时间 旧→新").tag(PhotoSort.captureDateAscending)
                    Text("文件名").tag(PhotoSort.fileName)
                }
                .pickerStyle(.menu)
            }
            ToolbarItem {
                Picker("视图", selection: Binding(get: { model.viewMode }, set: { model.setView($0) })) {
                    Image(systemName: "square.grid.2x2").help("网格（⌘1）").tag(ViewMode.grid)
                    Image(systemName: "square").help("单张（⌘2、空格）").tag(ViewMode.single)
                    Image(systemName: "rectangle.split.2x1").help("比较（⌘3、C）").tag(ViewMode.compare)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Slider(value: $model.thumbnailSize, in: 100...320) { Text("缩略图大小") }
                    .frame(width: 120)
            }
            ToolbarItem {
                Button { model.perform(.export) } label: { Label("导出…", systemImage: "square.and.arrow.up") }
                    .help("导出原文件（⌘E）")
            }
            ToolbarItem {
                Button { model.showInspector.toggle() } label: { Label("检查器", systemImage: "info.circle") }
            }
        }
        .sheet(item: $model.volumeToAdd) { pending in
            AddVolumeSheet(pending: pending)
        }
        .sheet(item: $model.activeSheet) { sheet in
            switch sheet {
            case .addToCollection(let ids): AddToCollectionSheet(photoIDs: ids)
            case .newCollection(let ids): NewCollectionSheet(photoIDs: ids)
            case .renameCollection(let id): RenameCollectionSheet(collectionID: id)
            case .labelSettings: LabelSettingsSheet()
            case .shortcuts: ShortcutsSheet()
            case .export(let range): ExportSheet(range: range)
            case .exportResult(let report): ExportResultSheet(report: report)
            }
        }
        .sheet(item: $model.clearCard) { session in
            ClearCardSheet()
                .interactiveDismissDisabled(session.backfill?.running == true)
        }
        .modifier(RemovalConfirmation())
        .alert("出错了", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .overlay(alignment: .top) { NewVolumeBanner() }
        .overlay(alignment: .bottom) { ToastView() }
    }

    private var grid: some View {
        PhotoGrid(
            sections: model.sections,
            sectionsVersion: model.sectionsVersion,
            thumbnailSize: model.thumbnailSize,
            loader: model.thumbnails,
            selectionVersion: model.selectionVersion,
            selectedIDs: model.selectedPhotoIDs,
            focusedID: model.focusedPhotoID,
            marksVersion: model.marksVersion,
            changedIDs: model.changedPhotoIDs,
            marks: CellMarks(
                current: { model.photo($0) },
                position: { model.gridPositions[$0] },
                isOffline: { model.isOffline($0) },
                matches: { [filter = model.currentFilter] in filter.matches($0) },
                labelColors: model.labelColors
            ),
            onSelectionChange: { model.gridSelectionChanged($0, clicked: $1) },
            onOpen: { model.openSingle($0) },
            onColumnsChange: { model.gridColumns = $0 },
            onFirstScreenShown: { model.firstScreenShown() }
        )
    }
}

/// 标题行：标题 · 卷在线状态 · 收录与预览进度 · 筛选摘要（筛选条收起时）· 计数 · “⋯”（信息架构 §3.0.1）。
struct TitleRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Text(model.sourceTitle).font(.headline).lineLimit(1)
            if case .volume(let id) = model.selection {
                let online = model.onlineVolumes[id] != nil
                Label(online ? "在线" : "离线", systemImage: online ? "circle.fill" : "circle")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(online ? .green : .secondary)
                    .font(.caption)
                if let stats = model.volumeStats[id] {
                    Text("已收录 \(stats.photoCount.formatted()) · 离线预览就绪 \(stats.previewReadyCount.formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                    if stats.incompleteDirectoryCount > 0 {
                        Text("\(stats.incompleteDirectoryCount) 个目录没扫完")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if stats.missingCopyCount > 0 {
                        Button("\(stats.missingCopyCount.formatted()) 张缺副本") { model.beginClearCardCheck(id) }
                            .buttonStyle(.plain)
                            .font(.caption).foregroundStyle(.orange)
                            .help("这些照片有文件别处没有副本（按记录算）。点开做清卡检查")
                    }
                }
            }
            let filter = model.currentFilter
            if !model.filterBarVisible, !filter.isEmpty {
                HStack(spacing: 4) {
                    Button("筛选：\(filter.summary(labelNames: model.labelNames))") { model.filterBarVisible = true }
                        .buttonStyle(.plain)
                        .help("展开筛选条")
                    Button { model.clearFilter() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .help("清除筛选")
                }
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
            Spacer()
            Text(model.photoCount == model.sourceCount
                 ? "\(model.photoCount.formatted()) 张"
                 : "\(model.photoCount.formatted()) / \(model.sourceCount.formatted()) 张")
                .font(.caption).foregroundStyle(.secondary)
                .monospacedDigit()
            MoreMenu()
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }
}

/// 标题行的“⋯”：卷的重新扫描、改名；收藏夹的改名、删除。
struct MoreMenu: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingDelete: CollectionRecord?

    var body: some View {
        switch model.selection {
        case .volume(let id):
            if let volume = model.volumes.first(where: { $0.id == id }) {
                Menu {
                    if let stats = model.volumeStats[id] {
                        Text("已收录 \(stats.photoCount.formatted()) · 离线预览就绪 \(stats.previewReadyCount.formatted())")
                    }
                    Text("扫描 \(volume.scanRoot.isEmpty ? "整个卷" : volume.scanRoot + "/")")
                    Divider()
                    Button("重新扫描") { model.enqueueScan(id) }
                        .disabled(model.onlineVolumes[id] == nil)
                    Divider()
                    Button("清卡检查…") { model.beginClearCardCheck(id) }
                    Button("移除卷…") { model.requestRemoval(id) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
        case .collection(let id):
            if let collection = model.collections.first(where: { $0.id == id }) {
                Menu {
                    Text("收藏夹只存引用，移出（⌫）不影响照片")
                    Divider()
                    Button("导出这个收藏夹…") { model.beginExport(.collection) }
                    Button("改名…") { model.activeSheet = .renameCollection(id) }
                    Button("删除收藏夹…") { confirmingDelete = collection }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .modifier(DeleteCollectionConfirmation(collection: $confirmingDelete))
            }
        default:
            EmptyView()
        }
    }
}

/// 删除收藏夹前确认一次：只删收藏夹，不删照片，也不能撤销。
struct DeleteCollectionConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var collection: CollectionRecord?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "删除收藏夹「\(collection?.name ?? "")」？",
            isPresented: Binding(get: { collection != nil }, set: { if !$0 { collection = nil } })
        ) {
            Button("删除收藏夹", role: .destructive) {
                if let collection { model.deleteCollection(collection.id) }
                collection = nil
            }
        } message: {
            Text("只删除这个收藏夹，里面的 \(collection?.photoCount.formatted() ?? "0") 张照片不受影响。删除后不能撤销。")
        }
    }
}

/// 短暂的提示，2 秒多后自动消失。
struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            Text(toast.text)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 3)
                .padding(.bottom, model.viewMode == .single ? 100 : 40)
                .id(toast.id)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }
}

struct EmptyLibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.volumes.isEmpty {
            ContentUnavailableView(
                "还没有照片",
                systemImage: "sdcard",
                description: Text("插入存储卡或外置盘，按提示添加后开始扫描。")
            )
        } else {
            ContentUnavailableView("这里没有照片", systemImage: "photo.on.rectangle")
        }
    }
}

/// 状态栏：后台任务进度，没有任务时隐藏（设计稿 §6）。
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.scanStatus != nil || model.previewStatus != nil || model.exportStatus != nil || model.autoAdvance {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 16) {
                    if let scan = model.scanStatus {
                        Label(scan, systemImage: "arrow.triangle.2.circlepath")
                    }
                    if let preview = model.previewStatus {
                        Label(preview, systemImage: "photo.stack")
                        Button(model.previewsPaused ? "继续" : "暂停") { model.togglePreviewPause() }
                            .buttonStyle(.link)
                    }
                    if let export = model.exportStatus {
                        Label(export, systemImage: "square.and.arrow.up")
                        if model.exportCancellation != nil {
                            Button("取消") { model.cancelExport() }.buttonStyle(.link)
                        }
                    }
                    Spacer()
                    if model.autoAdvance {
                        Label("自动前进", systemImage: "forward.frame").foregroundStyle(Color.accentColor)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(height: 26)
            }
        }
    }
}

/// 插入没见过的卷时的提示：“添加…”或“忽略”，不点就什么都不做（信息架构 §5.1）。
struct NewVolumeBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.pendingVolumes) { pending in
                HStack(spacing: 12) {
                    Image(systemName: pending.info.hasDCIM ? "sdcard" : "externaldrive")
                    Text("检测到新卷 \(pending.info.name)\(capacity(pending.info))")
                    Spacer()
                    Button("忽略") { model.ignore(pending) }
                    Button("添加…") { model.beginAdding(pending) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 4)
            }
        }
        .frame(maxWidth: 520)
        .padding(.top, 12)
    }

    private func capacity(_ info: MountedVolumes.Info) -> String {
        guard let bytes = info.capacityBytes else { return "" }
        return "（\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))）"
    }
}

/// 添加卷：起名，选扫描的文件夹。存储卡默认 `DCIM`，外置盘手动选。
struct AddVolumeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pending: PendingVolume
    @State private var name = ""
    @State private var scanRoot: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加卷").font(.title3.bold())
            Form {
                TextField("名字", text: $name)
                LabeledContent("扫描的文件夹") {
                    HStack {
                        Text(scanRoot.map { $0.isEmpty ? "整个卷" : $0 } ?? "未选择")
                            .foregroundStyle(scanRoot == nil ? .secondary : .primary)
                        Button("选择…") { choose() }
                    }
                }
            }
            Text("只读取，不会改动、移动或删除卷上的任何文件。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加并扫描") {
                    model.addVolume(pending, name: name.trimmingCharacters(in: .whitespaces), scanRoot: scanRoot ?? "")
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || scanRoot == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            name = pending.info.name
            if pending.info.hasDCIM { scanRoot = "DCIM" }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = pending.info.url
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = pending.info.url.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == root || path.hasPrefix(root + "/") else {
            model.errorMessage = "请选择 \(pending.info.name) 里面的文件夹。"
            return
        }
        scanRoot = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// 检查器：所选照片的星级、标签、标记、收藏夹、信息与位置；比较视图里是焦点格。
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    private var shownID: PhotoID? {
        switch model.viewMode {
        case .compare:
            let ids = model.compareIDs
            return ids.indices.contains(model.compareFocus) ? ids[model.compareFocus] : nil
        case .single:
            return model.focusedPhotoID
        case .grid:
            return model.selectedPhotoIDs.count == 1 ? model.selectedPhotoIDs.first : nil
        }
    }

    /// 详情在后台读，不在界面线程上查库。星级、标签、标记用模型里的当前值，详情只管文件、位置、收藏夹。
    @State private var loaded: (id: PhotoID, version: Int, detail: PhotoDetail)?

    var body: some View {
        content
            .task(id: DetailKey(id: shownID, version: model.detailVersion &+ model.sectionsVersion)) {
                guard let id = shownID else { return }
                let version = model.detailVersion &+ model.sectionsVersion
                if let detail = await model.loadDetail(of: id) { loaded = (id, version, detail) }
            }
    }

    private struct DetailKey: Hashable {
        var id: PhotoID?
        var version: Int
    }

    @ViewBuilder
    private var content: some View {
        if let id = shownID, let detail = loaded?.id == id ? loaded?.detail : nil {
            let photo = model.photo(id) ?? detail.summary
            Form {
                Section {
                    LabeledContent("文件名", value: detail.summary.baseName)
                    LabeledContent("星级") {
                        StarRating(rating: photo.rating) { model.focusOnlyIfNeeded(id); model.setRating($0) }
                    }
                    LabeledContent("标记", value: photo.flag.displayName)
                    if !photo.labelIDs.isEmpty {
                        LabeledContent("标签") {
                            LabelChips(ids: photo.labelIDs)
                        }
                    }
                    if !detail.collectionNames.isEmpty {
                        LabeledContent("收藏夹", value: detail.collectionNames.joined(separator: "、"))
                    }
                }
                Section {
                    LabeledContent("格式", value: detail.extensions.joined(separator: " + "))
                    LabeledContent("拍摄时间", value: detail.summary.captureDate ?? "未知")
                    if let model = [detail.cameraMake, detail.cameraModel].compactMap({ $0 }).joined(separator: " ").nilIfEmpty {
                        LabeledContent("相机", value: model)
                    }
                    if let lens = detail.lens { LabeledContent("镜头", value: lens) }
                    if let exposure = ExposureText.make(detail) { LabeledContent("参数", value: exposure) }
                    if let width = detail.summary.width, let height = detail.summary.height {
                        LabeledContent("尺寸", value: "\(width) × \(height)")
                    }
                }
                Section("现在在") {
                    ForEach(Array(detail.locations.enumerated()), id: \.offset) { _, location in
                        let online = model.onlineVolumes[location.volumeID] != nil
                        VStack(alignment: .leading, spacing: 2) {
                            Label(location.volumeName, systemImage: online && location.isPresent ? "circle.fill" : "circle")
                                .foregroundStyle(location.isPresent ? .primary : .secondary)
                            Text(location.isPresent ? location.relativePath : "历史位置 · \(location.relativePath)")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                Section("预览") {
                    LabeledContent("480", value: label(detail.summary.thumbState))
                    LabeledContent("1600", value: label(detail.previewState))
                }
            }
            .formStyle(.grouped)
        } else if model.selectedPhotoIDs.count > 1, model.viewMode == .grid {
            MultipleSelectionSummary()
        } else if shownID != nil {
            Color.clear
        } else {
            ContentUnavailableView("未选择照片", systemImage: "photo")
        }
    }

    private func label(_ state: PreviewState) -> String {
        switch state {
        case .ready: "就绪"
        case .pending: "待生成"
        case .failed: "失败"
        }
    }
}

/// 多选时：张数、星级分布、各标签的张数。
struct MultipleSelectionSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let photos = model.selectedPhotoIDs.compactMap { model.photo($0) }
        Form {
            Section {
                LabeledContent("已选", value: "\(photos.count.formatted()) 张")
                LabeledContent("已打星", value: "\(photos.filter { $0.rating > 0 }.count.formatted()) 张")
                LabeledContent("Pick / Reject", value: "\(photos.filter { $0.flag == .pick }.count) / \(photos.filter { $0.flag == .reject }.count)")
            }
            Section("标签") {
                ForEach(model.labels.filter(\.isInUse)) { label in
                    let count = photos.filter { $0.labelIDs.contains(label.id) }.count
                    if count > 0 {
                        LabeledContent { Text("\(count) 张") } label: { LabelChips(ids: [label.id]) }
                    }
                }
            }
            Section {
                Text("打星、打标签、标记作用于全部所选照片。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// 可以点的五颗星；点当前星级清除。
struct StarRating: View {
    var rating: Int
    var size: CGFloat = 13
    var onSet: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { n in
                Image(systemName: n <= rating ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(n <= rating ? Color.yellow : Color.secondary)
                    .onTapGesture { onSet(rating == n ? 0 : n) }
            }
        }
    }
}

/// 标签的色点和名字。
struct LabelChips: View {
    @Environment(AppModel.self) private var model
    var ids: [LabelID]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ids, id: \.self) { id in
                if let label = model.labels.first(where: { $0.id == id }) {
                    HStack(spacing: 3) {
                        Circle().fill(Color(nsColor: NSColor(hex: label.color))).frame(width: 8, height: 8)
                        Text(label.name)
                    }
                }
            }
        }
    }
}

enum ExposureText {
    static func make(_ detail: PhotoDetail) -> String? {
        var parts: [String] = []
        if let focal = detail.focalLength { parts.append("\(Int(focal)) mm") }
        if let aperture = detail.aperture { parts.append(String(format: "ƒ/%.1f", aperture)) }
        if let shutter = detail.shutter {
            parts.append(shutter >= 1 ? String(format: "%.1f s", shutter) : "1/\(Int((1 / shutter).rounded())) s")
        }
        if let iso = detail.iso { parts.append("ISO \(iso)") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }
}

extension NSColor {
    /// `#rrggbb`
    convenience init(hex: String) {
        let value = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x8b8d98
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum DateLabels {
    static func month(_ prefix: String) -> String {
        let parts = prefix.split(separator: "-")
        guard parts.count == 2, let month = Int(parts[1]) else { return prefix }
        return "\(parts[0]) 年 \(month) 月"
    }

    static func day(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let date = Int(parts[2]) else { return day }
        return "\(parts[0]) 年 \(month) 月 \(date) 日"
    }
}
