import AppKit
import Observation
import PhotoAICore
import Synchronization

/// 侧栏的一项。
enum SidebarItem: Hashable {
    case all
    case importBatch(Int)
    case year(String)
    case month(String)
    case day(String)
    case undated
    case volume(VolumeID)
    case collection(CollectionID)

    var scope: PhotoScope {
        switch self {
        case .all: .all
        case .importBatch(let id): .importBatch(id)
        case .year(let prefix), .month(let prefix), .day(let prefix): .datePrefix(prefix)
        case .undated: .undated
        case .volume(let id): .volume(id)
        case .collection(let id): .collection(id)
        }
    }
}

/// 内容区的三种视图，在同一块区域里切换（设计稿 §6）。
enum ViewMode { case grid, single, compare }

/// 主窗口上弹出的面板。同一时间只有一个。
enum ActiveSheet: Identifiable, Equatable {
    case addToCollection([PhotoID])
    case newCollection([PhotoID])
    case renameCollection(CollectionID)
    case labelSettings
    case shortcuts

    var id: String {
        switch self {
        case .addToCollection: "add"
        case .newCollection: "new"
        case .renameCollection(let id): "rename-\(id)"
        case .labelSettings: "labels"
        case .shortcuts: "shortcuts"
        }
    }
}

/// 网格里的一天。
struct DaySection: Equatable {
    var day: String?
    var photos: [PhotoSummary]
}

/// 检测到的新卷，等用户决定“添加…”还是“忽略”。
struct PendingVolume: Identifiable, Equatable {
    var info: MountedVolumes.Info
    var id: String { info.uuid }
}

/// 一次扫描用的取消标记。卷被拔出时置位，扫描在下一批文件前停下。
final class ScanCancellation: Sendable {
    private let flag = Mutex(false)
    func cancel() { flag.withLock { $0 = true } }
    var isCancelled: Bool { flag.withLock { $0 } }
}

/// 整个窗口的状态。数据库读写放在后台，界面只拿结果。
@MainActor
@Observable
final class AppModel {
    private(set) var library: Library?
    private var reader: LibraryReader?
    private(set) var launchError: String?

    var selection: SidebarItem = .all {
        didSet {
            guard oldValue != selection else { return }
            if viewMode == .compare { viewMode = .grid }
            selectedPhotoIDs = []
            focusedPhotoID = nil
            reloadPhotos(reason: .selection)
        }
    }
    var sort: PhotoSort = .captureDateDescending {
        didSet { if oldValue != sort { reloadPhotos(reason: .resort) } }
    }
    var thumbnailSize: Double = 160

    // MARK: 选片状态

    /// 选中的照片。网格里点选、⇧ / ⌘ 点选都会改它；键盘移动时只留焦点那一张。
    var selectedPhotoIDs: Set<PhotoID> = []
    /// 焦点照片：单张视图显示的那张，键盘移动的起点。
    var focusedPhotoID: PhotoID?
    /// 键盘、全选等由模型改了选择时加一，网格据此同步选中状态并滚到焦点。
    var selectionVersion = 0
    var viewMode: ViewMode = .grid
    var focusMode = false
    var filterBarVisible = true
    /// 单张视图左上角的参数浮层（I）。
    var showInfoOverlay = false
    var showInspector = true
    var autoAdvance = false
    /// 比较视图里的焦点格。
    var compareFocus = 0
    var activeSheet: ActiveSheet?
    var toast: Toast?
    var history = EditHistory()
    var labels: [LabelRecord] = []
    var collections: [CollectionRecord] = []
    var lastCollectionID: CollectionID?
    /// 侧栏每一项各自记住的筛选条件。
    var filters: [SidebarItem: PhotoFilter] = [:]

    /// 当前侧栏项的全部可见照片（排好序），星级、标签等随改动更新。
    @ObservationIgnored var source: [PhotoSummary] = []
    @ObservationIgnored var sourceIndex: [PhotoID: Int] = [:]
    /// 当前结果：按筛选条件筛出的照片。打星、打标签时保持不变，点“刷新结果”或改条件才重新筛。
    @ObservationIgnored var resultIDs: [PhotoID] = []
    @ObservationIgnored var resultIndex: [PhotoID: Int] = [:]
    /// 照片在网格里的位置（分组、组内序号）。
    @ObservationIgnored var gridPositions: [PhotoID: IndexPath] = [:]
    /// 网格当前每行几格，↑ ↓ 换行用。由网格的布局告诉模型。
    @ObservationIgnored var gridColumns = 1
    /// 结果里已经不符合当前条件的张数（“刷新结果”按钮上的数字）。
    var staleCount = 0
    /// 星级、标签、标记改动后加一；`changedPhotoIDs` 是这次改了的照片，网格只重画这些格子。
    var marksVersion = 0
    @ObservationIgnored var changedPhotoIDs: Set<PhotoID> = []
    @ObservationIgnored let thumbnails = ThumbnailLoader()
    @ObservationIgnored let previews = PreviewImageLoader()
    @ObservationIgnored private var keyRouter: KeyRouter?
    @ObservationIgnored private var scenarioRunner: ScenarioRunner?

    var sections: [DaySection] = [] { didSet { sectionsVersion += 1 } }
    /// 每次换一组照片加一，网格靠它判断要不要重载，不去比较十万条数据。
    var sectionsVersion = 0
    /// 当前结果的张数。
    var photoCount = 0
    /// 当前侧栏项一共有几张（筛选之前）。
    var sourceCount = 0
    /// 焦点照片的星级、标签等变了，检查器重读详情。
    var detailVersion = 0
    /// 单张视图翻页开始的时间（PF-7 从这里计到大图画出来）。
    @ObservationIgnored var pageStarted: Date?
    private(set) var volumes: [VolumeRecord] = []
    private(set) var volumeCounts: [VolumeID: Int] = [:]
    private(set) var volumeStats: [VolumeID: VolumeStats] = [:]
    private(set) var dayCounts: [DayCount] = []
    private(set) var undatedCount = 0
    private(set) var importBatches: [ImportBatch] = []
    /// 在线的卷：卷 id → 挂载点。只看是否挂载，不检查原片。
    private(set) var onlineVolumes: [VolumeID: URL] = [:]
    /// 每张可见照片的现存位置在哪些卷上，用来在网格上标“离线”。
    private(set) var photoVolumes: [PhotoID: [VolumeID]] = [:]

    var pendingVolumes: [PendingVolume] = []
    var volumeToAdd: PendingVolume?
    var errorMessage: String?

    // 后台任务
    private(set) var scanStatus: String?
    private(set) var previewStatus: String?
    private(set) var previewsPaused = false
    private var scanQueue: [VolumeID] = []
    private var scanTask: Task<Void, Never>?
    private var scanningVolume: VolumeID?
    private var scanCancellation: ScanCancellation?
    private var previewTask: Task<Void, Never>?
    private var previewStop: ScanCancellation?
    private var pendingPreviewTotal = 0
    private var reloadGeneration = 0
    private var lastScanReload = Date.distantPast
    private var ignoredVolumeUUIDs: Set<String> = []
    private var watcher: VolumeWatcher?
    private var dataVersion: Int?

    let launchStart: Date
    private var reportedLaunch = false

    init(launchStart: Date) {
        self.launchStart = launchStart
    }

    var previewStore: PreviewStore? { library.map { PreviewStore(root: $0.paths.previews) } }

    // MARK: - 启动

    func start() {
        guard library == nil, launchError == nil else { return }
        Measurements.record("PF-1 进程启动到窗口出现", since: launchStart, count: 0)
        do {
            let library = try Library()
            self.library = library
            reader = try library.makeReader()
            dataVersion = try? library.dataVersion()
            labels = try library.reader.labels()
        } catch {
            launchError = "打不开照片库：\(error)"
            return
        }
        thumbnails.store = previewStore
        previews.store = previewStore
        keyRouter = KeyRouter(model: self)
        refreshMounts()
        reloadSidebar()
        reloadPhotos(reason: .launch)

        watcher = VolumeWatcher { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        // 启动时核对预览文件，再为在线卷续做没完成的预览。
        let library = library!
        Task.detached(priority: .utility) {
            _ = try? PreviewGenerator(library: library).verifyReadyFiles()
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (id, _) in onlineVolumes { enqueueScan(id) }
                startPreviews()
            }
        }
    }

    /// 窗口重新获得焦点：别的进程（命令行）改过库才重读。
    func windowDidBecomeKey() {
        guard let library, let version = try? library.dataVersion(), version != dataVersion else { return }
        dataVersion = version
        // 别的进程可能改了星级、标签、收藏夹：撤销记录里的“改动前”已经不可信。
        history.removeAll()
        reloadSidebar()
        reloadPhotos(reason: .external)
    }

    // MARK: - 读数据

    /// `selection`、`resort`、`launch` 按条件重新筛；`scan`、`external` 保持当前结果（新出现的照片按条件加进来）。
    enum ReloadReason { case launch, selection, resort, scan, external, collectionChanged }

    func reloadPhotos(reason: ReloadReason) {
        guard let reader else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        let scope = selection.scope
        let sort = sort
        let started = Date()
        Task.detached(priority: .userInitiated) {
            let photos: [PhotoSummary]
            do {
                photos = try reader.photos(in: scope, sort: sort)
            } catch {
                await MainActor.run { [weak self] in self?.errorMessage = "读取照片失败：\(error)" }
                return
            }
            await MainActor.run { [weak self] in
                guard let self, generation == reloadGeneration else { return }
                setSource(photos, keepResult: [.scan, .external, .collectionChanged].contains(reason))
                let label = switch reason {
                case .launch: "PF-3 首次加载"
                case .selection: "PF-3 切换到 \(scope)"
                case .resort: "排序 \(sort)"
                case .scan, .external, .collectionChanged: "刷新 \(scope)"
                }
                // 下一轮主循环时网格已经按新数据重载，计时到这里。
                DispatchQueue.main.async { Measurements.record(label, since: started, count: photos.count) }
                if reason == .launch, photos.isEmpty { firstScreenShown() }
            }
        }
    }

    func reloadSidebar() {
        guard let reader else { return }
        Task.detached(priority: .userInitiated) {
            do {
                let volumes = try reader.volumes()
                let counts = try reader.photoCountsByVolume()
                var stats: [VolumeID: VolumeStats] = [:]
                for volume in volumes { stats[volume.id] = try reader.volumeStats(volume.id) }
                let days = try reader.dayCounts()
                let undated = try reader.undatedCount()
                let batches = try reader.importBatches()
                let photoVolumes = try reader.photoVolumes()
                let collections = try reader.collections()
                let labels = try reader.labels()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.volumes = volumes
                    volumeCounts = counts
                    volumeStats = stats
                    dayCounts = days
                    undatedCount = undated
                    importBatches = batches
                    self.photoVolumes = photoVolumes
                    self.collections = collections
                    self.labels = labels
                    if Measurements.isEnabled {
                        Measurements.emit("侧栏：卷 \(volumes.count) 个，日期 \(days.count) 天，导入批次 \(batches.count) 个")
                    }
                }
            } catch {
                await MainActor.run { [weak self] in self?.errorMessage = "读取侧栏失败：\(error)" }
            }
        }
    }

    nonisolated static func group<S: Sequence<PhotoSummary>>(_ photos: S, by sort: PhotoSort) -> [DaySection] {
        guard sort != .fileName else {
            let all = Array(photos)
            return all.isEmpty ? [] : [DaySection(day: nil, photos: all)]
        }
        var sections: [DaySection] = []
        for photo in photos {
            let day = photo.day
            if sections.last?.day == day, !sections.isEmpty {
                sections[sections.count - 1].photos.append(photo)
            } else {
                sections.append(DaySection(day: day, photos: [photo]))
            }
        }
        return sections
    }

    /// 第一屏缩略图画完（或库是空的）。PF-1 计时到这里。
    func firstScreenShown() {
        guard !reportedLaunch else { return }
        reportedLaunch = true
        Measurements.recordLaunch(since: launchStart, count: photoCount)
        if ProcessInfo.processInfo.environment["PHOTOAI_SWITCH_TEST"] == "1" { runSwitchTest() }
        if let scenario = ProcessInfo.processInfo.environment["PHOTOAI_SCENARIO"] {
            // 等侧栏数据和启动时的自动重扫都到了再开始。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                scenarioRunner = ScenarioRunner(model: self, mode: scenario)
                scenarioRunner?.start()
            }
        }
    }

    /// PF-3：依次切到每个卷、一个月、一天，再回到全部照片，每步之间停 0.6 秒。
    private func runSwitchTest() {
        // 侧栏数据和网格并行加载，可能还没到。
        guard !volumes.isEmpty else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.runSwitchTest() }
            return
        }
        let month = dayCounts.dropFirst(200).first.map { String($0.day.prefix(7)) }
        let day = dayCounts.dropFirst(300).first?.day
        var steps: [SidebarItem] = volumes.map { .volume($0.id) }
        Measurements.emit("PF-3 切换测试：卷 \(volumes.count) 个，日期 \(dayCounts.count) 天，收藏夹 \(collections.count) 个")
        if let month { steps.append(.month(month)) }
        if let day { steps.append(.day(day)) }
        steps += collections.map { .collection($0.id) }
        steps.append(.all)
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 * Double(index + 1)) { [weak self] in
                self?.selection = step
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 * Double(steps.count + 2)) { exit(0) }
    }

    func isOffline(_ photo: PhotoID) -> Bool {
        guard let volumes = photoVolumes[photo] else { return false }
        return !volumes.contains { onlineVolumes[$0] != nil }
    }

    func loadDetail(of photo: PhotoID) async -> PhotoDetail? {
        guard let reader else { return nil }
        return await Task.detached(priority: .userInitiated) { try? reader.detail(of: photo) }.value
    }

    // MARK: - 卷

    private func refreshMounts() {
        guard let reader else { return }
        var online: [VolumeID: URL] = [:]
        for info in MountedVolumes.list() {
            if let volume = try? reader.activeVolume(uuid: info.uuid) {
                online[volume.id] = info.url
            } else if !info.isInternal || info.hasDCIM {
                offerNewVolume(info)
            }
        }
        onlineVolumes = online
    }

    private func handle(_ event: VolumeWatcher.Event) {
        guard let library, let reader else { return }
        switch event {
        case .mounted(let url):
            guard let info = MountedVolumes.info(for: url) else { return }
            if let volume = try? reader.activeVolume(uuid: info.uuid) {
                onlineVolumes[volume.id] = info.url
                try? library.markVolumeSeen(volume.id)
                enqueueScan(volume.id)
            } else {
                offerNewVolume(info)
            }
        case .unmounted(let url):
            for (id, mount) in onlineVolumes where mount.standardizedFileURL == url.standardizedFileURL {
                onlineVolumes[id] = nil
                if scanningVolume == id { scanCancellation?.cancel() }
                scanQueue.removeAll { $0 == id }
            }
            pendingVolumes.removeAll { $0.info.url.standardizedFileURL == url.standardizedFileURL }
        }
    }

    private func offerNewVolume(_ info: MountedVolumes.Info) {
        guard !ignoredVolumeUUIDs.contains(info.uuid), !pendingVolumes.contains(where: { $0.id == info.uuid }) else { return }
        pendingVolumes.append(PendingVolume(info: info))
        if Measurements.isEnabled { Measurements.emit("检测到新卷 \(info.name)，等用户选择“添加…”或“忽略”") }
    }

    func ignore(_ pending: PendingVolume) {
        ignoredVolumeUUIDs.insert(pending.id)
        pendingVolumes.removeAll { $0.id == pending.id }
    }

    func beginAdding(_ pending: PendingVolume) {
        pendingVolumes.removeAll { $0.id == pending.id }
        volumeToAdd = pending
    }

    func addVolume(_ pending: PendingVolume, name: String, scanRoot: String) {
        guard let library else { return }
        do {
            let volume = try library.addVolume(
                uuid: pending.info.uuid,
                name: name,
                scanRoot: scanRoot,
                capacityBytes: pending.info.capacityBytes,
                filesystem: pending.info.filesystem
            )
            onlineVolumes[volume.id] = pending.info.url
            reloadSidebar()
            selection = .volume(volume.id)
            enqueueScan(volume.id)
        } catch {
            errorMessage = "添加卷失败：\(error)"
        }
    }

    func rename(_ volume: VolumeID, to name: String) {
        do {
            try library?.renameVolume(volume, to: name)
            reloadSidebar()
        } catch {
            errorMessage = "改名失败：\(error)"
        }
    }

    // MARK: - 扫描

    func enqueueScan(_ volume: VolumeID) {
        guard onlineVolumes[volume] != nil, scanningVolume != volume, !scanQueue.contains(volume) else { return }
        scanQueue.append(volume)
        runNextScan()
    }

    private func runNextScan() {
        guard scanTask == nil, let library, !scanQueue.isEmpty else { return }
        let volumeID = scanQueue.removeFirst()
        guard let mount = onlineVolumes[volumeID] else { return runNextScan() }
        let name = volumes.first { $0.id == volumeID }?.name ?? "卷"
        let cancellation = ScanCancellation()
        scanningVolume = volumeID
        scanCancellation = cancellation
        scanStatus = "扫描 \(name)…"
        let started = Date()
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let scanner = VolumeScanner(library: library)
            let result: Result<ScanSummary, Error> = await Result(asyncCatching: {
                try await scanner.scan(volumeID: volumeID, mountURL: mount, isCancelled: { cancellation.isCancelled }) { summary in
                    Task { @MainActor in self?.scanProgressed(name: name, summary) }
                }
            })
            await MainActor.run { self?.scanFinished(name: name, result: result, started: started) }
        }
    }

    private func scanProgressed(name: String, _ summary: ScanSummary) {
        scanStatus = "扫描 \(name)：已处理 \(summary.filesSeen.formatted()) 个文件，新增 \(summary.newPhotos.formatted()) 张"
        // 网格边扫边出现，但最多一秒刷新一次。
        if Date().timeIntervalSince(lastScanReload) > 1 {
            lastScanReload = Date()
            reloadPhotos(reason: .scan)
            reloadSidebar()
        }
    }

    private func scanFinished(name: String, result: Result<ScanSummary, Error>, started: Date) {
        scanTask = nil
        scanningVolume = nil
        scanCancellation = nil
        switch result {
        case .success(let summary):
            Measurements.recordScan(name: name, since: started, summary: summary)
            if summary.isComplete {
                scanStatus = nil
            } else {
                scanStatus = "\(name) 有 \(summary.incompleteDirectories.count) 个目录没扫完，下次插上自动续扫"
            }
        case .failure(let error):
            scanStatus = nil
            errorMessage = "扫描 \(name) 失败：\(error)"
        }
        dataVersion = try? library?.dataVersion()
        reloadPhotos(reason: .scan)
        reloadSidebar()
        startPreviews()
        runNextScan()
    }

    // MARK: - 预览

    func startPreviews() {
        guard previewTask == nil, !previewsPaused, let library, !onlineVolumes.isEmpty else { return }
        let mounts = onlineVolumes
        previewMounts = mounts
        let stop = ScanCancellation()
        previewStop = stop
        pendingPreviewTotal = (try? reader?.pendingPreviewCount()) ?? 0
        guard pendingPreviewTotal > 0 else { return }
        let total = pendingPreviewTotal
        let started = Date()
        previewStatus = "预览 0 / \(total.formatted())"
        previewTask = Task.detached(priority: .utility) { [weak self] in
            let runner = PreviewRunner(generator: PreviewGenerator(library: library))
            let result = await Result(asyncCatching: {
                try await runner.run(mountURLs: mounts, shouldStop: { stop.isCancelled }) { progress in
                    Task { @MainActor in self?.previewProgressed(progress, total: total) }
                }
            })
            await MainActor.run { self?.previewsFinished(result, started: started) }
        }
    }

    private var lastPreviewReload = Date.distantPast
    /// 这一轮预览用的在线卷。跑的过程中又插上别的卷，结束后要再跑一轮。
    private var previewMounts: [VolumeID: URL] = [:]

    private func previewProgressed(_ progress: PreviewRunner.Progress, total: Int) {
        previewStatus = "预览 \(progress.ready.formatted()) / \(total.formatted())"
        if Date().timeIntervalSince(lastPreviewReload) > 2 {
            lastPreviewReload = Date()
            reloadPhotos(reason: .scan)
        }
    }

    private func previewsFinished(_ result: Result<PreviewRunner.Progress, Error>, started: Date) {
        previewTask = nil
        previewStop = nil
        switch result {
        case .success(let progress):
            Measurements.recordPreviews(since: started, progress: progress)
            if let writeError = progress.writeError {
                previewsPaused = true
                previewStatus = "预览已暂停：\(writeError)"
            } else if previewsPaused {
                previewStatus = "预览已暂停"
            } else {
                previewStatus = nil
            }
        case .failure(let error):
            previewStatus = nil
            errorMessage = "生成预览失败：\(error)"
        }
        reloadPhotos(reason: .scan)
        reloadSidebar()
        if !previewsPaused, Set(onlineVolumes.keys) != Set(previewMounts.keys) {
            startPreviews()
        }
    }

    func togglePreviewPause() {
        if previewsPaused {
            previewsPaused = false
            previewStatus = nil
            startPreviews()
        } else {
            previewsPaused = true
            previewStop?.cancel()
            previewStatus = "预览已暂停"
        }
    }
}

extension Result where Failure == Error {
    init(asyncCatching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
