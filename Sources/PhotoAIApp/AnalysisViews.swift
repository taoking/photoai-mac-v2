import AppKit
import PhotoAICore
import SwiftUI

/// 人物网格：有名字的在前，然后是未命名的，按张数排（信息架构 §3.1）。点一个人看 TA 的照片。
struct PeopleView: View {
    @Environment(AppModel.self) private var model
    /// 只出现一两次的人（多是路人）默认收起来。
    @State private var showRare = false
    @State private var naming: PersonSummary?

    private static let rareLimit = 3

    var body: some View {
        let shown = model.people.filter { showRare || $0.name != nil || $0.photoCount >= Self.rareLimit }
        let rare = model.people.count - shown.count
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(rareCount: rare)
                if model.faceModelMissing {
                    ContentUnavailableView {
                        Label("没有装人脸识别模型", systemImage: "person.crop.circle.badge.questionmark")
                    } description: {
                        Text("在终端里运行 Scripts/install-face-model.sh（下载 InsightFace 的 ArcFace 模型并转成 Core ML，只在本机），然后重新打开软件。")
                    }
                } else if shown.isEmpty {
                    ContentUnavailableView(
                        "还没有人物", systemImage: "person.2",
                        description: Text("导入后在后台识别人脸，识别完的会出现在这里。")
                    )
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 160), spacing: 16)], spacing: 18) {
                        ForEach(shown) { person in
                            PersonCard(person: person)
                                .onTapGesture { model.selection = .person(person.id) }
                                .contextMenu {
                                    Button(person.name == nil ? "命名…" : "改名…") { naming = person }
                                    Button("隐藏这个人物") { model.setPersonHidden(person.id, true) }
                                }
                        }
                    }
                }
            }
            .padding(20)
        }
        .sheet(item: $naming) { person in PersonNameSheet(person: person) }
    }

    @ViewBuilder
    private func header(rareCount: Int) -> some View {
        HStack(spacing: 12) {
            Text("人物").font(.title2.bold())
            if let status = model.analysisStatus(.faces) {
                Text("识别中：\(status)").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if rareCount > 0 || showRare {
                Toggle("显示只出现一两次的（\(rareCount.formatted())）", isOn: $showRare)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }
        }
        Text("起名字的人可以在搜索框里按名字搜；给两个人起同一个名字就是合并。认错的照片在这个人的页面里选中后点“不是 TA”。")
            .font(.callout).foregroundStyle(.secondary)
    }
}

struct PersonCard: View {
    let person: PersonSummary

    var body: some View {
        VStack(spacing: 6) {
            FaceCropView(photoID: person.coverPhotoID, box: person.coverBox)
                .frame(width: 120, height: 120)
                .clipShape(Circle())
            Text(person.displayName)
                .font(.headline)
                .foregroundStyle(person.name == nil ? .secondary : .primary)
                .lineLimit(1)
            Text("\(person.photoCount.formatted()) 张").font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

/// 从 1600 预览里裁出一张脸。裁好的图按照片和位置缓存。
struct FaceCropView: View {
    @Environment(AppModel.self) private var model
    let photoID: PhotoID?
    let box: CGRect?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.tertiary)
            }
        }
        .task(id: "\(photoID ?? -1)-\(box.map { "\($0)" } ?? "")") {
            guard let photoID, let box, let store = model.previewStore else { return }
            image = await FaceCrops.shared.crop(photoID: photoID, box: box, store: store)
        }
    }
}

/// 人脸裁图的缓存。人物网格几百张，每张都要解一次 1600 预览，放后台做。
actor FaceCrops {
    static let shared = FaceCrops()
    private var cache: [String: NSImage] = [:]

    func crop(photoID: PhotoID, box: CGRect, store: PreviewStore) async -> NSImage? {
        let key = "\(photoID)-\(box)"
        if let cached = cache[key] { return cached }
        let url = store.url(for: photoID, size: .preview)
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let width = CGFloat(full.width), height = CGFloat(full.height)
            // 脸四周多留一点，正方形。
            let side = max(box.width * width, box.height * height) * 1.6
            let center = CGPoint(x: box.midX * width, y: box.midY * height)
            let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard let cropped = full.cropping(to: rect.integral) else { return nil }
            return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        }.value
        if let image { cache[key] = image }
        return image
    }
}

/// 给人物命名或改名。名字和另一个人物一样就合并。
struct PersonNameSheet: View {
    @Environment(AppModel.self) private var model
    let person: PersonSummary
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NameSheet(title: person.name == nil ? "给这个人起名字" : "给「\(person.displayName)」改名", name: $name, confirm: "好") {
                model.renamePerson(person.id, to: $0)
            }
            let others = model.people.compactMap(\.name).filter { $0 != person.name }
            if !others.isEmpty {
                Text("和已有的名字一样就合并：\(others.prefix(8).joined(separator: "、"))\(others.count > 8 ? "…" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
        .onAppear { name = person.name ?? "" }
    }
}

/// 标题行里的搜索条件：每个条件一个标签，点 ✕ 删掉（信息架构 §6）。
struct SearchChips: View {
    @Environment(AppModel.self) private var model
    let query: SearchQuery

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(query.terms.enumerated()), id: \.offset) { index, term in
                HStack(spacing: 3) {
                    Text(term.title)
                    Button { model.removeSearchTerm(at: index) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .help("删掉这个条件")
                }
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
        }
    }
}

/// 后台任务面板：每种任务的进度、失败数，可以暂停 / 继续（信息架构 §9）。
struct TaskPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("后台任务").font(.title3.bold())
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                if let status = model.scanStatus {
                    GridRow { Text("扫描"); Text(status).gridCellColumns(2) }
                }
                GridRow {
                    Text("预览")
                    Text(model.previewStatus ?? "已完成")
                    Button(model.previewsPaused ? "继续" : "暂停") { model.togglePreviewPause() }
                }
                ForEach(AnalysisKind.allCases, id: \.self) { kind in
                    GridRow {
                        Text(kind.displayName)
                        analysisText(kind)
                        if !(kind == .faces && model.faceModelMissing) {
                            Button(model.analysisPaused.contains(kind) ? "继续" : "暂停") { model.toggleAnalysisPause(kind) }
                        }
                    }
                }
                GridRow {
                    Text("地点")
                    if model.placesEnabled {
                        let counts = model.placeCounts
                        Text(counts.total == 0 ? "没有带坐标的照片"
                             : "\(counts.done.formatted()) / \(counts.total.formatted()) 张已查过\(counts.failed > 0 ? "，\(counts.failed) 张没查到（没联网或被限流，下次启动再试）" : "")")
                    } else {
                        Text("关闭（菜单“图库”里打开；要联网，会把坐标发给 Apple）").foregroundStyle(.secondary)
                    }
                    Toggle("", isOn: Binding(get: { model.placesEnabled }, set: { model.setPlacesEnabled($0) }))
                        .labelsHidden()
                }
            }
            Text("后台任务只在你不操作时进行；分析用的是本机预览，卡拔掉也能做。暂停后重新打开软件仍然暂停。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("好") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private func analysisText(_ kind: AnalysisKind) -> some View {
        if kind == .faces, model.faceModelMissing {
            Text("没有装人脸识别模型：运行 Scripts/install-face-model.sh").foregroundStyle(.orange)
        } else if let counts = model.analysisCounts[kind] {
            let state = model.analysisPaused.contains(kind) ? "已暂停 · "
                : model.analysisRunning.contains(kind) ? "进行中 · " : ""
            Text("\(state)\((counts.done + counts.failed).formatted()) / \(counts.total.formatted()) 张"
                 + (counts.failed > 0 ? "，失败 \(counts.failed)" : "")
                 + (counts.waitingForPreview > 0 ? "，\(counts.waitingForPreview.formatted()) 张等预览" : ""))
        } else {
            Text("—")
        }
    }
}
