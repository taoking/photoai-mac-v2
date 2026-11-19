import AppKit
import Foundation
import PhotoAICore

/// 清卡检查面板的状态：检查结果，以及补副本（如果开始了）。
struct ClearCardSession: Identifiable {
    let volumeID: VolumeID
    var id: VolumeID { volumeID }
    var report: ClearCardReport?
    var checking = true
    var error: String?
    var backfill: BackfillState?
}

struct BackfillState {
    var target: VolumeID
    /// 相对目标卷根目录。
    var directory: String
    var running = false
    var progress: BackfillProgress?
    var report: BackfillReport?
    var error: String?
}

/// 移除卷之前的确认：影响按记录算；从清卡检查来的，再重复一遍三类数量（设计稿 §5.4）。
struct RemovalRequest: Identifiable {
    let volumeID: VolumeID
    let name: String
    let impact: RemovalImpact
    let report: ClearCardReport?
    var id: VolumeID { volumeID }
}

// MARK: - 清卡检查与补副本（计划 · M4）

extension AppModel {
    func beginClearCardCheck(_ volume: VolumeID) {
        clearCard = ClearCardSession(volumeID: volume)
        runClearCardCheck()
    }

    /// 按文件核对一遍。在线卷上的副本当场确认，发现不在的改为历史。
    func runClearCardCheck() {
        guard let library, let volume = clearCard?.volumeID else { return }
        clearCard?.checking = true
        clearCard?.error = nil
        let checker = ClearCardChecker(library: library, finder: makeFinder())
        let started = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try checker.check(volumeID: volume) }
            await MainActor.run {
                guard let self, self.clearCard?.volumeID == volume else { return }
                self.clearCard?.checking = false
                switch result {
                case .success(let report):
                    self.clearCard?.report = report
                    Measurements.record("清卡检查 \(report.photoCount) 张、\(report.fileCount) 个文件", since: started, count: 1)
                    if report.vanishedCopyCount > 0 {
                        self.reloadPhotos(reason: .scan)
                        self.reloadSidebar()
                    }
                case .failure(let error):
                    self.clearCard?.error = "清卡检查失败：\(error)"
                }
            }
        }
    }

    /// 补副本可选的目标：在线、在用、不是这张卡。
    func backfillTargets(excluding volume: VolumeID) -> [VolumeRecord] {
        volumes.filter { $0.id != volume && onlineVolumes[$0.id] != nil }
    }

    func prepareBackfill() {
        guard let session = clearCard else { return }
        guard let target = backfillTargets(excluding: session.volumeID).first else {
            return show("没有其他在线的卷可以复制过去：先插上备份盘")
        }
        clearCard?.backfill = BackfillState(target: target.id, directory: target.scanRoot)
    }

    func startBackfill() {
        guard let library, let session = clearCard, let report = session.report, var state = session.backfill, !state.running else { return }
        guard onlineVolumes[session.volumeID] != nil else { return show("卡没有插上，插上后才能复制") }
        guard !isScanning(state.target) else { return show("目标卷正在扫描，扫完再补副本") }
        let source = session.volumeID, target = state.target, directory = state.directory
        let cancellation = ScanCancellation()
        backfillCancellation = cancellation
        state.running = true
        state.report = nil
        state.error = nil
        state.progress = BackfillProgress(filesDone: 0, fileCount: report.missingFileCount, bytesDone: 0)
        clearCard?.backfill = state
        let backfiller = Backfiller(library: library, finder: makeFinder(), scanner: VolumeScanner(library: library))
        let photos = report.missingPhotos
        Task.detached(priority: .utility) { [weak self] in
            let result = await Result(asyncCatching: {
                try await backfiller.run(photos, from: source, to: target, directory: directory, isCancelled: { cancellation.isCancelled }) { progress in
                    Task { @MainActor in
                        guard self?.clearCard?.backfill?.running == true else { return }
                        self?.clearCard?.backfill?.progress = progress
                    }
                }
            })
            await MainActor.run { self?.backfillFinished(result, source: source) }
        }
    }

    func cancelBackfill() { backfillCancellation?.cancel() }

    private func backfillFinished(_ result: Result<BackfillReport, Error>, source: VolumeID) {
        backfillCancellation = nil
        reloadPhotos(reason: .scan)
        reloadSidebar()
        guard clearCard?.volumeID == source else { return }
        clearCard?.backfill?.running = false
        switch result {
        case .success(let report):
            clearCard?.backfill?.report = report
            // 补完再核对一遍：登记好的副本这次算已核实。
            runClearCardCheck()
        case .failure(let error):
            clearCard?.backfill?.error = "\(error)"
        }
    }

    /// 让用户在目标卷上选一个文件夹，必须在这个卷的扫描文件夹之内。返回相对卷根目录的路径。
    func chooseBackfillFolder(on target: VolumeID) -> String? {
        guard let mount = onlineVolumes[target], let volume = volumes.first(where: { $0.id == target }) else { return nil }
        let root = volume.scanRoot.isEmpty ? mount : mount.appendingPathComponent(volume.scanRoot, isDirectory: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = root
        panel.prompt = "选择"
        panel.message = "补副本放到「\(volume.name)」的哪个文件夹（要在扫描文件夹「\(volume.scanRoot.isEmpty ? "整个卷" : volume.scanRoot)」里）"
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else { return nil }
        let base = mount.standardizedFileURL.path
        guard url.path == base || url.path.hasPrefix(base + "/") else {
            show("要选「\(volume.name)」上的文件夹")
            return nil
        }
        let relative = String(url.path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard volume.scanRoot.isEmpty || relative == volume.scanRoot || relative.hasPrefix(volume.scanRoot + "/") else {
            show("要在扫描文件夹「\(volume.scanRoot)」里面选，不然以后重扫看不到这些副本")
            return nil
        }
        return relative
    }
}

// MARK: - 移除卷

extension AppModel {
    /// 先按记录算出影响，再弹确认框。
    func requestRemoval(_ volume: VolumeID, report: ClearCardReport? = nil) {
        guard let reader, let record = volumes.first(where: { $0.id == volume }) else { return }
        do {
            removal = RemovalRequest(volumeID: volume, name: record.name, impact: try reader.removalImpact(volume: volume), report: report)
        } catch {
            errorMessage = "读取卷的照片失败：\(error)"
        }
    }

    func confirmRemoval(_ request: RemovalRequest) {
        guard let library else { return }
        if clearCard?.volumeID == request.volumeID {
            cancelBackfill()
            clearCard = nil
        }
        let started = Date()
        do {
            try library.removeVolume(request.volumeID)
        } catch {
            errorMessage = "移除卷失败：\(error)"
            return
        }
        Measurements.record("PF-10 移除卷 \(request.impact.photoCount) 张", since: started, count: 1)
        volumeWasRemoved(request.volumeID)
        if selection == .volume(request.volumeID) { selection = .all }
        reloadPhotos(reason: .scan)
        reloadSidebar()
        orphansVersion += 1
        show("已移除「\(request.name)」" + (request.impact.orphanedCount > 0
            ? "；\(request.impact.orphanedCount.formatted()) 张照片进入“无卷关联照片”"
            : "；照片在其他卷上都有副本，照常显示"))
    }
}

// MARK: - 无卷关联照片

extension AppModel {
    func reloadOrphans() {
        guard let reader else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let groups = (try? reader.orphanGroups()) ?? []
            await MainActor.run { self?.orphanGroups = groups }
        }
    }

    /// 删除照片记录和预览。删除事务里重新核对，期间被重扫找回的照片不删。
    func deleteOrphans(_ ids: [PhotoID]) -> OrphanDeletion? {
        guard let library else { return nil }
        do {
            let result = try library.deleteOrphans(ids, previews: previewStore)
            let deleted = Set(result.deleted)
            history.forget(photos: deleted)
            thumbnails.forget(deleted)
            previews.forget(deleted)
            reloadOrphans()
            reloadSidebar()
            if !result.kept.isEmpty { reloadPhotos(reason: .scan) }
            return result
        } catch {
            errorMessage = "删除失败：\(error)"
            return nil
        }
    }
}
