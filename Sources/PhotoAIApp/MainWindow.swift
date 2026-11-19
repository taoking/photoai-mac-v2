import AppKit
import PhotoAICore
import SwiftUI

/// 主窗口：侧栏 + 内容区 + 检查器 + 状态栏（设计稿 §6）。M1 只有网格。
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var showInspector = true

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                TitleRow()
                Divider()
                if let error = model.launchError {
                    ContentUnavailableView("照片库打不开", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if model.photoCount == 0 {
                    EmptyLibraryView()
                } else {
                    PhotoGrid(
                        sections: model.sections,
                        sectionsVersion: model.sectionsVersion,
                        thumbnailSize: model.thumbnailSize,
                        store: model.previewStore,
                        isOffline: { model.isOffline($0) },
                        onSelectionChange: { model.selectedPhotoIDs = $0 },
                        onFirstScreenShown: { model.firstScreenShown() }
                    )
                }
                StatusBar()
            }
            .inspector(isPresented: $showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 220, ideal: 260, max: 340)
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("排序", selection: $model.sort) {
                    Text("拍摄时间 新→旧").tag(PhotoSort.captureDateDescending)
                    Text("拍摄时间 旧→新").tag(PhotoSort.captureDateAscending)
                    Text("文件名").tag(PhotoSort.fileName)
                }
                .pickerStyle(.menu)
            }
            ToolbarItem {
                Slider(value: $model.thumbnailSize, in: 100...320) { Text("缩略图大小") }
                    .frame(width: 120)
            }
            ToolbarItem {
                Button { showInspector.toggle() } label: { Label("检查器", systemImage: "info.circle") }
            }
        }
        .sheet(item: $model.volumeToAdd) { pending in
            AddVolumeSheet(pending: pending)
        }
        .alert("出错了", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .overlay(alignment: .top) { NewVolumeBanner() }
    }
}

/// 标题行：标题、在线状态、收录与预览就绪进度、计数（信息架构 §3.0.1、§5.2）。
struct TitleRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.headline)
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
                }
            }
            Spacer()
            Text("\(model.photoCount.formatted()) 张").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    private var title: String {
        switch model.selection {
        case .all: "全部照片"
        case .importBatch(let id):
            model.importBatches.first { $0.id == id }.map { "导入 · \($0.volumeName)" } ?? "最近导入"
        case .year(let year): "\(year) 年"
        case .month(let month): DateLabels.month(month)
        case .day(let day): DateLabels.day(day)
        case .undated: "日期未知"
        case .volume(let id): model.volumes.first { $0.id == id }?.name ?? "卷"
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
        if model.scanStatus != nil || model.previewStatus != nil {
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
                    Spacer()
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

/// 检查器：所选照片的信息与位置。
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.selectedPhotoIDs.count == 1, let id = model.selectedPhotoIDs.first, let detail = model.detail(of: id) {
            Form {
                Section {
                    LabeledContent("文件名", value: detail.summary.baseName)
                    LabeledContent("格式", value: detail.extensions.joined(separator: " + "))
                    LabeledContent("拍摄时间", value: detail.summary.captureDate ?? "未知")
                    if let model = [detail.cameraMake, detail.cameraModel].compactMap({ $0 }).joined(separator: " ").nilIfEmpty {
                        LabeledContent("相机", value: model)
                    }
                    if let lens = detail.lens { LabeledContent("镜头", value: lens) }
                    if let exposure = exposure(detail) { LabeledContent("参数", value: exposure) }
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
        } else {
            ContentUnavailableView(
                model.selectedPhotoIDs.isEmpty ? "未选择照片" : "已选 \(model.selectedPhotoIDs.count) 张",
                systemImage: "photo"
            )
        }
    }

    private func exposure(_ detail: PhotoDetail) -> String? {
        var parts: [String] = []
        if let focal = detail.focalLength { parts.append("\(Int(focal)) mm") }
        if let aperture = detail.aperture { parts.append(String(format: "ƒ/%.1f", aperture)) }
        if let shutter = detail.shutter {
            parts.append(shutter >= 1 ? String(format: "%.1f s", shutter) : "1/\(Int((1 / shutter).rounded())) s")
        }
        if let iso = detail.iso { parts.append("ISO \(iso)") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private func label(_ state: PreviewState) -> String {
        switch state {
        case .ready: "就绪"
        case .pending: "待生成"
        case .failed: "失败"
        }
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
