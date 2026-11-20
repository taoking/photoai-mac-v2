import AppKit
import PhotoAICore
import SwiftUI

// MARK: - 清卡检查（信息架构 §5.3）

/// 清卡检查：按文件分三类、预览就绪、缺副本照片；补副本；移除卷。
struct ClearCardSheet: View {
    @Environment(AppModel.self) private var model
    @State private var onlyMarked = true

    var body: some View {
        if let session = model.clearCard {
            let name = model.volumeNames[session.volumeID] ?? "卷"
            VStack(alignment: .leading, spacing: 12) {
                Text("清卡检查：\(name)").font(.title3.bold())
                if let error = session.error {
                    Text(error).foregroundStyle(.red)
                } else if let report = session.report {
                    summary(report)
                    if !report.missingPhotos.isEmpty { missingGrid(report) }
                } else {
                    HStack { ProgressView().controlSize(.small); Text("正在按文件核对副本…") }
                }
                if let backfill = session.backfill, let report = session.report {
                    Divider()
                    BackfillSection(session: session, state: backfill, report: report)
                }
                Text("移除卷只影响软件里的记录：照片、星级、标签、收藏夹和预览都保留；别处一个副本都没有的照片会从常规列表隐藏，进入“无卷关联照片”。卡上的文件不会被动。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                footer(session)
            }
            .padding(20)
            .frame(width: 600)
        }
    }

    @ViewBuilder
    private func summary(_ report: ClearCardReport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(report.photoCount.formatted()) 张照片、\(report.fileCount.formatted()) 个文件（按文件核对，RAW 和 JPEG 分开）：")
            if report.vanishedCopyCount > 0 {
                Text("核对时发现 \(report.vanishedCopyCount.formatted()) 个副本已经不在，位置改为历史，按缺副本计算")
                    .foregroundStyle(.orange)
            }
            Text("✅ \(report.verifiedFileCount.formatted()) 个文件已核实：在线卷上有副本，刚确认还在")
            if report.offlineOnlyFileCount > 0 {
                let names = report.offlineCopyVolumeIDs.compactMap { model.volumeNames[$0] }.map { "「\($0)」" }.joined(separator: "、")
                Text("☑️ \(report.offlineOnlyFileCount.formatted()) 个文件只有离线记录：副本在\(names)上，按上次扫描结果，没法当场核对；插上后再检查一次")
            }
            if report.missingFileCount > 0 {
                let missing = report.missingPhotos
                // 拼起来的字符串要转成 LocalizedStringKey，`**` 才按粗体显示。
                Text(LocalizedStringKey("⚠️ **\(report.missingFileCount.formatted())** 个文件缺副本，涉及 \(missing.count.formatted()) 张照片"
                     + (report.missingRAWOnlyCount > 0 ? "（其中 \(report.missingRAWOnlyCount.formatted()) 张缺的是 RAW：别处只有 JPEG）" : "")
                     + "；其中 \(missing.filter { $0.rating > 0 }.count) 张已打星、\(missing.filter { $0.flag == .pick }.count) 张已 Pick、\(missing.filter(\.inCollection).count) 张在收藏夹里"))
            }
            if !report.previewPendingPhotoIDs.isEmpty {
                Text("⏳ \(report.previewPendingPhotoIDs.count.formatted()) 张照片的离线预览还没就绪"
                     + (report.previewFailedCount > 0 ? "（\(report.previewFailedCount) 张生成失败）" : "")
                     + "：现在移除，它们在本机只剩缩略图甚至没有预览")
            }
            if !report.problems.isEmpty {
                DisclosureGroup("\(report.problems.count) 个副本对不上，没算核实") {
                    ForEach(report.problems.prefix(50), id: \.self) { Text($0).font(.caption) }
                }
            }
            if report.canClear {
                Text("所有文件都已核实、预览都已就绪，可以清空这张卡。").bold().foregroundStyle(.green)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func missingGrid(_ report: ClearCardReport) -> some View {
        let marked = report.missingPhotos.filter(\.isMarked)
        let shown = onlyMarked && !marked.isEmpty ? marked : report.missingPhotos
        VStack(alignment: .leading, spacing: 6) {
            Toggle("只看已打星 / Pick / 在收藏夹里的（\(marked.count)）", isOn: $onlyMarked)
                .disabled(marked.isEmpty)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 4)], spacing: 4) {
                    ForEach(shown.prefix(240)) { photo in
                        MiniThumb(
                            id: photo.id,
                            rating: photo.rating,
                            flag: photo.flag,
                            inCollection: photo.inCollection,
                            note: photo.isPartial ? "缺 " + photo.missingKinds.map(\.shortName).joined(separator: "+") : nil
                        )
                        .help("\(photo.baseName) 缺 " + photo.missingKinds.map(\.shortName).joined(separator: " + "))
                    }
                }
                if shown.count > 240 {
                    Text("… 还有 \((shown.count - 240).formatted()) 张").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(height: 150)
        }
    }

    @ViewBuilder
    private func footer(_ session: ClearCardSession) -> some View {
        let report = session.report
        let online = model.onlineVolumes[session.volumeID] != nil
        let busy = session.checking || session.backfill?.running == true
        HStack {
            if let report, !report.missingPhotos.isEmpty, session.backfill == nil {
                Button("补副本到…") { model.prepareBackfill() }
                    .disabled(!online || busy)
                    .help(online ? "把缺副本的文件复制到另一个卷" : "卡没有插上，插上后才能复制")
            }
            Button("重新检查") { model.runClearCardCheck() }
                .disabled(busy)
            Spacer()
            Button("关闭") { model.clearCard = nil }
                .keyboardShortcut(.cancelAction)
                .disabled(session.backfill?.running == true)
            let canClear = report?.canClear == true
            Button(canClear ? "移除卷…" : "仍然移除卷…", role: canClear ? nil : .destructive) {
                let volume = session.volumeID
                model.clearCard = nil
                model.requestRemoval(volume, report: report)
            }
            .buttonStyle(.borderedProminent)
            .tint(canClear ? .accentColor : .red)
            .disabled(busy || report == nil)
        }
    }
}

/// 补副本：选目标卷和文件夹、复制并校验、结果。
struct BackfillSection: View {
    @Environment(AppModel.self) private var model
    let session: ClearCardSession
    let state: BackfillState
    let report: ClearCardReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("补副本").font(.headline)
            let targets = model.backfillTargets(excluding: session.volumeID)
            HStack {
                Picker("复制到", selection: Binding(
                    get: { state.target },
                    set: { id in
                        model.clearCard?.backfill?.target = id
                        model.clearCard?.backfill?.directory = targets.first { $0.id == id }?.scanRoot ?? ""
                    }
                )) {
                    ForEach(targets) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 240)
                Text(state.directory.isEmpty ? "/" : state.directory + "/")
                    .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Button("选择文件夹…") {
                    if let folder = model.chooseBackfillFolder(on: state.target) { model.clearCard?.backfill?.directory = folder }
                }
            }
            .disabled(state.running)
            Text("保留原文件名，同一张照片的文件放在一起；目标里已有同名的不同文件时整组放进“补副本-日期”子文件夹，已有的文件一字节都不动。复制后读回校验（SHA-256），再扫描这个文件夹登记副本。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if state.running, let progress = state.progress {
                ProgressView(value: Double(progress.filesDone), total: Double(max(progress.fileCount, 1))) {
                    Text("复制并校验 \(progress.filesDone.formatted()) / \(progress.fileCount.formatted()) 个文件（\(ByteCountFormatter.string(fromByteCount: Int64(progress.bytesDone), countStyle: .file))）")
                        .font(.caption)
                }
            }
            if let error = state.error { Text(error).foregroundStyle(.red).font(.callout) }
            if let result = state.report { BackfillResultView(report: result) }
            HStack {
                Spacer()
                if state.running {
                    Button("停止") { model.cancelBackfill() }
                } else if state.report == nil {
                    Button("取消") { model.clearCard?.backfill = nil }
                    Button("开始复制 \(report.missingFileCount.formatted()) 个文件") { model.startBackfill() }
                        .buttonStyle(.borderedProminent)
                        .disabled(targets.isEmpty)
                }
            }
        }
    }
}

struct BackfillResultView: View {
    let report: BackfillReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(report.failures.isEmpty && report.stopReason == nil ? "补副本完成" : "补副本完成，有 \(report.failures.count) 个文件没有复制")
                .font(.subheadline.bold())
            ForEach(lines, id: \.self) { Text("· " + $0) }
            if !report.failures.isEmpty {
                List(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                    HStack(alignment: .firstTextBaseline) {
                        Text(failure.fileName).bold()
                        Text(failure.reason).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                .frame(height: min(140, CGFloat(report.failures.count) * 24 + 12))
            }
        }
        .font(.callout)
    }

    private var lines: [String] {
        var lines = ["\(report.copiedFiles.formatted()) 个文件复制并校验通过（\(ByteCountFormatter.string(fromByteCount: Int64(report.copiedBytes), countStyle: .file))）"]
        if report.identicalFiles > 0 { lines.append("\(report.identicalFiles.formatted()) 个文件目标里已有一模一样的，没有再复制") }
        if !report.subfolders.isEmpty { lines.append("目标里有同名的不同文件，放进了 " + report.subfolders.joined(separator: "、")) }
        if let stop = report.stopReason { lines.append("中途停下：\(stop)") }
        if report.vanishedSourceCount > 0 { lines.append("\(report.vanishedSourceCount) 个源文件已不在卡上，位置改为历史") }
        if report.scan != nil { lines.append("已扫描目标文件夹，登记了 \(report.registeredFiles.formatted()) 个副本") }
        return lines
    }
}

extension FileKind {
    var shortName: String {
        switch self {
        case .raw: "RAW"
        case .jpeg: "JPEG"
        case .heif: "HEIF"
        case .tiff: "TIFF"
        case .png: "PNG"
        }
    }
}

// MARK: - 移除卷的确认

struct RemovalConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.alert(
            "移除卷「\(model.removal?.name ?? "")」？",
            isPresented: Binding(get: { model.removal != nil }, set: { if !$0 { model.removal = nil } }),
            presenting: model.removal
        ) { request in
            Button("移除卷", role: .destructive) { model.confirmRemoval(request) }
            Button("取消", role: .cancel) {}
        } message: { request in
            Text(Self.message(request))
        }
    }

    static func message(_ request: RemovalRequest) -> String {
        let impact = request.impact
        var lines = ["通常是这张卡已经清空或准备清空。"]
        if let report = request.report {
            lines.append("清卡检查：\(report.verifiedFileCount.formatted()) 个文件已核实，\(report.offlineOnlyFileCount.formatted()) 个只有离线记录，\(report.missingFileCount.formatted()) 个缺副本。")
        } else {
            lines.append("还没做清卡检查：下面按上次扫描的记录算，没有当场核对副本。")
        }
        let elsewhere = impact.photoCount - impact.orphanedCount
        lines.append("· \(elsewhere.formatted()) 张在其他卷上有副本：照常显示"
                     + (impact.partialCount > 0 ? "（其中 \(impact.partialCount.formatted()) 张只有部分文件有副本，比如缺 RAW）" : "") + "。")
        lines.append("· \(impact.orphanedCount.formatted()) 张没有其他副本：从常规列表和搜索中隐藏，进入“图库 → 无卷关联照片…”，预览、星级、标签、收藏夹都保留。")
        lines.append("卡上的文件不会被动。以后再插上这张卡会被当作新卷，没删掉的照片会对回原来的记录。")
        return lines.joined(separator: "\n")
    }
}

// MARK: - 小缩略图

/// 清卡检查、无卷关联照片窗口里的小缩略图，带星级、Pick、收藏夹标记。
struct MiniThumb: View {
    @Environment(AppModel.self) private var model
    let id: PhotoID
    var rating = 0
    var flag = Flag.none
    var inCollection = false
    var note: String?
    var isSelected = false
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image = image ?? model.thumbnails.cached(id) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 3) {
                if rating > 0 { Text(String(repeating: "★", count: rating)).foregroundStyle(.yellow) }
                if flag == .pick { Text("P").foregroundStyle(.green) }
                if inCollection { Image(systemName: "folder.fill").foregroundStyle(.white) }
                if let note { Text(note).foregroundStyle(.orange) }
            }
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(.black.opacity(rating > 0 || flag == .pick || inCollection || note != nil ? 0.55 : 0))
        }
        .frame(height: 60)
        .frame(minWidth: 60)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3))
        .task(id: id) {
            guard image == nil, model.thumbnails.cached(id) == nil else { return }
            model.thumbnails.load(id) { image = $0 }
        }
    }
}

// MARK: - 无卷关联照片（信息架构 §8）

/// 单独的窗口：按曾经所在的卷分组，标出已打星、Pick、在收藏夹里的；单张、多选或整组删除。
struct OrphansWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<PhotoID> = []
    @State private var confirming = false
    @State private var resultText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("这些照片所在的卷都已移除，或者重扫、读原片时文件已经不在。它们不出现在常规列表、搜索和收藏夹里，但预览、星级、标签都还在。在这里删除会真正删掉照片记录和预览，**卡和盘上的文件不受影响**；以后再扫到同一张照片，会作为新照片导入。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
            Divider()
            if model.orphanGroups.isEmpty {
                ContentUnavailableView("没有无卷关联的照片", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(model.orphanGroups) { group in groupView(group) }
                    }
                    .padding(16)
                }
            }
            Divider()
            HStack {
                Text(resultText ?? (selected.isEmpty ? "未选择" : "已选 \(selected.count.formatted()) 张"))
                    .foregroundStyle(.secondary)
                Spacer()
                if !selected.isEmpty { Button("取消选择") { selected = [] } }
                Button("删除所选…", role: .destructive) { confirming = true }
                    .disabled(selected.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { model.reloadOrphans() }
        .onChange(of: model.orphansVersion) { model.reloadOrphans() }
        .onChange(of: model.orphanGroups) {
            let present = Set(model.orphanGroups.flatMap(\.photos).map(\.id))
            selected.formIntersection(present)
        }
        .confirmationDialog("删除 \(selected.count.formatted()) 张照片的记录和预览？", isPresented: $confirming) {
            Button("删除 \(selected.count.formatted()) 张", role: .destructive) {
                guard let result = model.deleteOrphans(Array(selected)) else { return }
                selected = []
                resultText = "已删除 \(result.deleted.count.formatted()) 张照片的记录和预览"
                    + (result.kept.isEmpty ? "" : "；\(result.kept.count) 张期间已被重扫找回，没有删")
            }
        } message: {
            Text("删除后无法撤销。卡和盘上的源文件不受影响。")
        }
    }

    @ViewBuilder
    private func groupView(_ group: OrphanGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.volumeName).font(.headline)
                Text(subtitle(group)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("全选本组") { selected.formUnion(group.photos.map(\.id)) }
                    .controlSize(.small)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 4)], spacing: 4) {
                ForEach(group.photos) { photo in
                    MiniThumb(
                        id: photo.id, rating: photo.rating, flag: photo.flag,
                        inCollection: photo.inCollection, isSelected: selected.contains(photo.id)
                    )
                    .help("\(photo.baseName) · \(photo.captureDate ?? "拍摄时间未知")")
                    .onTapGesture { toggle(photo.id) }
                }
            }
        }
    }

    private func subtitle(_ group: OrphanGroup) -> String {
        let photos = group.photos
        let when = group.volumeStatus == .removed
            ? (group.removedAt.map { "移除于 " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "已移除")
            : "还在用：重扫或读原片时文件已经不在"
        return "\(when) · \(photos.count.formatted()) 张 · 其中 \(photos.filter { $0.rating > 0 }.count) 张已打星、"
            + "\(photos.filter { $0.flag == .pick }.count) 张 Pick、\(photos.filter(\.inCollection).count) 张在收藏夹里"
    }

    /// 单击只选这一张；按住 ⌘ 或 ⇧ 单击加选 / 取消。
    private func toggle(_ id: PhotoID) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        } else {
            selected = selected == [id] ? [] : [id]
        }
    }
}
