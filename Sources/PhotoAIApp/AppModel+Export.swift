import AppKit
import PhotoAICore

/// 导出面板的范围（信息架构 §7）。
enum ExportRange: Hashable {
    case selection, result, collection
}

/// 放大时一张照片的原文件读到哪一步。
enum OriginalState: Equatable {
    case loading(UUID)
    /// 读好了。`source` 是读的哪个文件，如 `DSC01926.JPG（卡 A）`。
    case ready(CGImage, source: String)
    /// 现存位置都在离线卷上：只能放大预览。
    case offline(volumes: [String])
    /// 在线位置都读不到。
    case unavailable(String)

    static func == (lhs: OriginalState, rhs: OriginalState) -> Bool {
        switch (lhs, rhs) {
        case (.loading(let a), .loading(let b)): a == b
        case (.ready(let a, let x), .ready(let b, let y)): a === b && x == y
        case (.offline(let a), .offline(let b)): a == b
        case (.unavailable(let a), .unavailable(let b)): a == b
        default: false
        }
    }
}

// MARK: - 读原文件

extension AppModel {
    /// 读原文件用：只认挂在原来挂载点、卷 UUID 没变的卷。
    func makeFinder() -> OriginalFinder {
        let uuids = Dictionary(uniqueKeysWithValues: volumes.map { ($0.id, $0.volumeUUID) })
        return OriginalFinder(mounts: onlineVolumes, volumeUUIDs: uuids)
    }

    var volumeNames: [VolumeID: String] {
        Dictionary(uniqueKeysWithValues: volumes.map { ($0.id, $0.name) })
    }

    /// 读原文件时发现这些位置已经不在（设计稿 §4.1）：改为历史，刷新网格和侧栏。
    /// 因此没有现存位置的照片离开结果；焦点在它上面时先移到相邻的照片。
    func locationsWentMissing(_ locationIDs: [Int], volumeName: String?) {
        guard let library, !locationIDs.isEmpty else { return }
        do {
            let hidden = try library.markLocationsMissing(locationIDs)
            handleHidden(hidden)
            let place = volumeName.map { "「\($0)」" } ?? "卷"
            show("原片已不在\(place)上：位置改为历史" + (hidden.isEmpty ? "" : "；\(hidden.count) 张没有其他副本，移到“无卷关联照片”"))
        } catch {
            errorMessage = "记录原片缺失失败：\(error)"
        }
    }

    func handleHidden(_ hidden: [PhotoID]) {
        let gone = Set(hidden)
        if let focus = focusedPhotoID, gone.contains(focus), let index = resultIndex[focus] {
            let remaining = resultIDs.filter { !gone.contains($0) }
            if remaining.isEmpty {
                setView(.grid)
            } else {
                focusOnly(remaining[min(index, remaining.count - 1)])
            }
        }
        reloadPhotos(reason: .scan)
        reloadSidebar()
    }
}

// MARK: - 放大到 100%

extension AppModel {
    /// `Z`：单张、比较视图放大到 100%，再按一次回到适合窗口（放大到别的比例时也回到适合窗口）。`center` 是放大到哪里（0–1），不给就放大中间。
    func toggleZoom(at center: CGPoint? = nil) {
        guard viewMode != .grid else { return show("放大用于单张和比较视图") }
        if zoomed {
            endZoom()
        } else {
            zoom(to: 1, at: center)
        }
    }

    func endZoom() {
        zoomed = false
        originals = [:]
    }

    /// 平移时更新共用的中心；变化很小时不写，免得几个格子互相触发。
    func setZoomCenter(_ point: CGPoint) {
        if abs(point.x - zoomCenter.x) > 0.0005 || abs(point.y - zoomCenter.y) > 0.0005 { zoomCenter = point }
    }

    func setZoomViewport(_ viewport: CGSize) {
        if abs(viewport.width - zoomViewport.width) > 0.002 || abs(viewport.height - zoomViewport.height) > 0.002 { zoomViewport = viewport }
    }

    /// 放大时要看的照片：单张是焦点，比较是各格。
    var zoomIDs: [PhotoID] {
        viewMode == .compare ? compareIDs : focusedPhotoID.map { [$0] } ?? []
    }

    func loadOriginalsForZoom() {
        let ids = zoomIDs
        originals = originals.filter { ids.contains($0.key) }
        for id in ids where originals[id] == nil { loadOriginal(id) }
    }

    /// 依次尝试照片的在线位置，取像素最大的文件完整解码。卷都离线时只能放大预览，并提示要插哪个卷。
    private func loadOriginal(_ id: PhotoID) {
        guard let reader else { return }
        let token = UUID()
        originals[id] = .loading(token)
        let finder = makeFinder()
        let names = volumeNames
        let started = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            let sources = (try? reader.presentSources(of: [id]))?[id] ?? []
            let online = sources.filter { finder.mounts[$0.volumeID] != nil }
            var state: OriginalState
            var missing: [Int] = []
            var missingVolume: String?
            if online.isEmpty {
                var seen: [String] = []
                for source in sources { if let name = names[source.volumeID], !seen.contains(name) { seen.append(name) } }
                state = sources.isEmpty ? .unavailable("没有现存原片：只能放大预览") : .offline(volumes: seen)
            } else {
                let lookup = finder.lookupForViewing(online)
                missing = lookup.missingLocationIDs
                missingVolume = online.first { missing.contains($0.locationID) }.flatMap { names[$0.volumeID] }
                if let found = lookup.found, let image = OriginalDecoder.decode(found.url) {
                    state = .ready(image, source: "\(found.source.fileName)（\(names[found.source.volumeID] ?? "卷")）")
                } else if lookup.found != nil {
                    state = .unavailable("原文件解码失败：只能放大预览")
                } else {
                    state = .unavailable("所有在线位置都读不到原片：只能放大预览")
                }
            }
            let finalState = state
            await MainActor.run { [weak self] in
                guard let self else { return }
                if originals[id] == .loading(token) {
                    originals[id] = finalState
                    if case .ready(let image, let source) = finalState {
                        Measurements.record("Z 读原文件 \(source) \(image.width)×\(image.height)", since: started, count: 1)
                    }
                }
                if !missing.isEmpty { locationsWentMissing(missing, volumeName: missingVolume) }
            }
        }
    }
}

// MARK: - 导出

extension AppModel {
    func beginExport(_ range: ExportRange? = nil) {
        guard exportCancellation == nil else { return show("正在导出，完成后再开始新的导出") }
        let range = range ?? {
            if selectedPhotoIDs.count > 1 { return .selection }
            if case .collection = selection { return .collection }
            return .result
        }()
        activeSheet = .export(range)
    }

    /// 范围里的照片。所选照片按结果里的顺序；收藏夹只取可见的成员。
    func exportPhotoIDs(_ range: ExportRange, collection: CollectionID?) async -> [PhotoID] {
        switch range {
        case .selection:
            return selectedPhotoIDs.filter { resultIndex[$0] != nil }.sorted { resultIndex[$0]! < resultIndex[$1]! }
        case .result:
            return resultIDs
        case .collection:
            guard let reader, let collection else { return [] }
            return await Task.detached(priority: .userInitiated) { (try? reader.collectionMembers(collection)) ?? [] }.value
        }
    }

    func startExport(_ request: ExportRequest) {
        guard let library, exportCancellation == nil else { return }
        let cancellation = ScanCancellation()
        exportCancellation = cancellation
        let total = request.photoIDs.count
        exportStatus = "导出 0 / \(total.formatted()) 张"
        let exporter = Exporter(library: library, finder: makeFinder())
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result(catching: {
                try exporter.run(request, isCancelled: { cancellation.isCancelled }) { progress in
                    Task { @MainActor in self?.exportProgressed(progress) }
                }
            })
            await MainActor.run { self?.exportFinished(result, request: request) }
        }
    }

    private func exportProgressed(_ progress: ExportProgress) {
        guard exportCancellation != nil else { return }
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(progress.bytesCopied), countStyle: .file)
        exportStatus = "导出 \(progress.photosDone.formatted()) / \(progress.photoTotal.formatted()) 张 · \(bytes)"
    }

    func cancelExport() {
        exportCancellation?.cancel()
        exportStatus = "正在取消导出…"
    }

    private func exportFinished(_ result: Result<ExportReport, Error>, request: ExportRequest) {
        exportCancellation = nil
        exportStatus = nil
        switch result {
        case .success(let report):
            Measurements.emit(String(
                format: "PF-9 导出：%d 张、%d 个文件、%.1f MB，%.2f 秒，%.1f MB/s",
                report.exportedPhotos, report.copiedFiles, Double(report.bytesCopied) / 1_000_000, report.elapsed, report.megabytesPerSecond
            ))
            if report.missingLocations > 0 { handleHidden(report.hiddenPhotoIDs) }
            if activeSheet == nil {
                activeSheet = .exportResult(report)
            } else {
                show("导出完成：\(report.exportedPhotos.formatted()) 张")
            }
            lastExportReport = report
        case .failure(let error):
            errorMessage = "导出失败：\(error)"
        }
    }
}
