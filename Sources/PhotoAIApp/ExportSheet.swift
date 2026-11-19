import AppKit
import PhotoAICore
import SwiftUI

/// ⌘E 导出原文件（信息架构 §7）：范围 × 文件 × 目录结构，底部列出需要哪些卷在线。
/// 卷插上、拔下时“需要的卷”随时更新；面板里用户已经做的选择（比如是否跳过离线卷）保持不变。
struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var range: ExportRange
    @State private var collectionID: CollectionID?
    @AppStorage("export.files") private var files: ExportRequest.Files = .both
    @AppStorage("export.layout") private var layout: ExportRequest.Layout = .flat
    @AppStorage("export.destination") private var destinationPath = ExportSheet.defaultDestination
    @State private var skipOffline = true
    /// 这个范围里的照片和它们的现存位置（换范围时重新读）。
    @State private var loaded: (key: LoadKey, ids: [PhotoID], sources: [PhotoID: [OriginalSource]])?
    @State private var plan: ExportPlan?

    static let defaultDestination = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("精修", isDirectory: true).path

    struct LoadKey: Hashable {
        var range: ExportRange
        var collection: CollectionID?
    }

    struct PlanKey: Hashable {
        var load: LoadKey?
        var files: ExportRequest.Files
        var online: Set<VolumeID>
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导出原文件").font(.title3.bold())
            section("范围") {
                Picker("范围", selection: $range) {
                    Text("所选照片（\(model.selectedPhotoIDs.count.formatted()) 张）").tag(ExportRange.selection)
                    Text("当前结果（\(model.photoCount.formatted()) 张）").tag(ExportRange.result)
                    Text("收藏夹").tag(ExportRange.collection)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Picker("收藏夹", selection: $collectionID) {
                    ForEach(model.collections) { Text("\($0.name)（\($0.photoCount.formatted()) 张）").tag(Optional($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
                .padding(.leading, 22)
                .disabled(range != .collection || model.collections.isEmpty)
            }
            section("文件") {
                Picker("文件", selection: $files) {
                    Text("只导出 RAW（没有 RAW 的导出 JPEG）").tag(ExportRequest.Files.raw)
                    Text("只导出 JPEG（没有 JPEG 的导出 RAW）").tag(ExportRequest.Files.jpeg)
                    Text("两者都要").tag(ExportRequest.Files.both)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            section("目录结构") {
                Picker("目录结构", selection: $layout) {
                    Text("平铺到一个文件夹").tag(ExportRequest.Layout.flat)
                    Text("按收藏夹分子文件夹").tag(ExportRequest.Layout.byCollection)
                    Text("保持原目录（卷名 / 原来的目录）").tag(ExportRequest.Layout.original)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            section("目标") {
                HStack {
                    Text(displayPath).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    Button("选择…", action: chooseDestination)
                }
                Text("只复制，不改动原文件；目标已有同名文件时自动改名，绝不覆盖。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            section("需要的卷") { volumesView }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: start)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            if collectionID == nil {
                if case .collection(let id) = model.selection { collectionID = id } else { collectionID = model.collections.first?.id }
            }
            if range == .selection, model.selectedPhotoIDs.isEmpty { range = .result }
        }
        .task(id: loadKey) {
            let key = loadKey
            loaded = nil
            plan = nil
            let ids = await model.exportPhotoIDs(key.range, collection: key.collection)
            guard let reader = model.reader else { return }
            let sources = await Task.detached(priority: .userInitiated) { (try? reader.presentSources(of: ids)) ?? [:] }.value
            guard key == loadKey else { return }
            loaded = (key, ids, sources)
        }
        .task(id: planKey) {
            guard let loaded, planKey.load == loaded.key else { return }
            let files = files, online = planKey.online, names = model.volumeNames
            plan = await Task.detached(priority: .userInitiated) {
                ExportPlan(photoIDs: loaded.ids, sources: loaded.sources, files: files, online: online, volumeNames: names)
            }.value
        }
    }

    private var loadKey: LoadKey { LoadKey(range: range, collection: range == .collection ? collectionID : nil) }
    private var planKey: PlanKey { PlanKey(load: loaded?.key, files: files, online: Set(model.onlineVolumes.keys)) }

    @ViewBuilder
    private var volumesView: some View {
        if let plan {
            if plan.volumes.isEmpty {
                Text("范围里没有照片").foregroundStyle(.secondary)
            }
            ForEach(plan.volumes) { need in
                HStack(spacing: 6) {
                    Circle().fill(need.isOnline ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                    Text("\(need.name) · \(need.photoCount.formatted()) 张")
                    if !need.isOnline { Text("离线，请插入").foregroundStyle(.orange) }
                }
            }
            if !plan.offlinePhotoIDs.isEmpty {
                Toggle(
                    "跳过离线卷上的 \(plan.offlinePhotoIDs.count.formatted()) 张，只导出在线的 \(plan.onlinePhotoIDs.count.formatted()) 张",
                    isOn: $skipOffline
                )
                if !skipOffline {
                    Text("还有照片只在离线卷上：插入列出的卷后再导出，或勾选“跳过离线卷”。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if plan.fileCount > 0 {
                Text("\(plan.fileCount.formatted()) 个文件，约 \(ByteCountFormatter.string(fromByteCount: Int64(plan.byteCount), countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在核对照片在哪些卷上…").foregroundStyle(.secondary)
            }
        }
    }

    private var confirmTitle: String {
        guard let plan else { return "导出" }
        if !plan.offlinePhotoIDs.isEmpty, !skipOffline {
            return "插入离线卷后导出 \((plan.onlinePhotoIDs.count + plan.offlinePhotoIDs.count).formatted()) 张"
        }
        return "导出 \(plan.onlinePhotoIDs.count.formatted()) 张"
    }

    private var canStart: Bool {
        guard let plan, !plan.onlinePhotoIDs.isEmpty else { return false }
        return plan.offlinePhotoIDs.isEmpty || skipOffline
    }

    private var displayPath: String {
        (destinationPath as NSString).abbreviatingWithTildeInPath
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold()).foregroundStyle(.secondary)
            content()
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: destinationPath)
        if panel.runModal() == .OK, let url = panel.url { destinationPath = url.path }
    }

    private func start() {
        guard let plan, canStart else { return }
        let request = ExportRequest(
            photoIDs: plan.onlinePhotoIDs,
            files: files,
            layout: layout,
            destination: URL(fileURLWithPath: destinationPath, isDirectory: true),
            collection: range == .collection ? collectionID : nil
        )
        dismiss()
        model.startExport(request)
    }
}

/// 导出完成：成功了多少、改名、从其他位置读、读不到的明细。
struct ExportResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: ExportReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold())
            Text("导出 \(report.exportedPhotos.formatted()) 张照片、\(report.copiedFiles.formatted()) 个文件（\(ByteCountFormatter.string(fromByteCount: Int64(report.bytesCopied), countStyle: .file))）到 \((report.destination.path as NSString).abbreviatingWithTildeInPath)")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { Text("· " + $0) }
            }
            .font(.callout)
            if !report.failures.isEmpty {
                Text("没有导出的文件（\(report.failures.count)）").font(.subheadline.bold())
                List(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.name).font(.callout.bold())
                        Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(height: min(220, CGFloat(report.failures.count) * 44 + 12))
            }
            HStack {
                Spacer()
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([report.destination]) }
                Button("好") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var title: String {
        if report.cancelled { return "导出已取消" }
        if report.stoppedBy != nil { return "导出中途停下" }
        return report.failures.isEmpty ? "导出完成" : "导出完成，有 \(report.failures.count) 个文件没有导出"
    }

    private var lines: [String] {
        var lines: [String] = []
        if let stoppedBy = report.stoppedBy { lines.append("\(stoppedBy)，后面 \(report.notAttempted.formatted()) 张没有导出") }
        if report.cancelled, report.notAttempted > 0 { lines.append("还有 \(report.notAttempted.formatted()) 张没有导出；再导出一次会跳过已经复制好的文件") }
        if report.identicalFiles > 0 { lines.append("\(report.identicalFiles.formatted()) 个文件目标里已有一模一样的，没有再复制") }
        if report.renamedFiles > 0 { lines.append("\(report.renamedFiles.formatted()) 个文件目标里已有同名的，改名为“名字 (2)”") }
        if report.fromOtherLocation > 0 { lines.append("\(report.fromOtherLocation.formatted()) 个文件的第一个位置读不到，已从其他在线副本导出") }
        if report.usedOtherKind > 0 { lines.append("\(report.usedOtherKind.formatted()) 张选的格式读不到，改导出了另一种格式") }
        if report.missingLocations > 0 {
            lines.append("\(report.missingLocations.formatted()) 个位置的原片已不在，位置改为历史"
                + (report.hiddenPhotoIDs.isEmpty ? "" : "；\(report.hiddenPhotoIDs.count) 张没有其他副本，移到“无卷关联照片”"))
        }
        if report.skippedOfflinePhotos > 0 { lines.append("跳过离线卷上的 \(report.skippedOfflinePhotos.formatted()) 张") }
        if report.skippedOfflineFiles > 0 { lines.append("\(report.skippedOfflineFiles.formatted()) 个文件只在离线卷上，没有导出") }
        if report.elapsed > 0, report.bytesCopied > 0 {
            lines.append(String(format: "用时 %.1f 秒，%.0f MB/s", report.elapsed, report.megabytesPerSecond))
        }
        return lines
    }
}
