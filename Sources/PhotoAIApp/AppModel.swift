import AppKit
import SwiftUI
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
    /// 人物网格（不是照片）。
    case people
    case person(PersonID)
    case place(String)
    case search(SearchQuery)

    var scope: PhotoScope {
        switch self {
        case .all: .all
        case .importBatch(let id): .importBatch(id)
        case .year(let prefix), .month(let prefix), .day(let prefix): .datePrefix(prefix)
        case .undated: .undated
        case .volume(let id): .volume(id)
        case .collection(let id): .collection(id)
        // 人物网格不列照片：空的搜索一张都不匹配。
        case .people: .search(SearchQuery(input: "", terms: []))
        case .person(let id): .person(id)
        case .place(let name): .place(name)
        case .search(let query): .search(query)
        }
    }

    /// 筛选条件按这个记：所有搜索共用一份（删掉一个搜索条件时筛选条件不丢）。
    var filterKey: SidebarItem {
        if case .search = self { return .search(SearchQuery(input: "", terms: [])) }
        return self
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
    case export(ExportRange)
    case exportResult(ExportReport)
    case namePerson(PersonSummary)
    case ratingImport(fileName: String, RatingImportPlan)

    var id: String {
        switch self {
        case .namePerson(let person): "person-\(person.id)"
        case .export: "export"
        case .exportResult: "export-result"
        case .addToCollection: "add"
        case .newCollection: "new"
        case .renameCollection(let id): "rename-\(id)"
        case .labelSettings: "labels"
        case .shortcuts: "shortcuts"
        case .ratingImport: "rating-import"
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
    private(set) var reader: LibraryReader?
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
    var focusedPhotoID: PhotoID? {
        didSet {
            guard oldValue != focusedPhotoID else { return }
            if zoomed { loadOriginalsForZoom() }
            // 换上的原图只留新焦点附近的；快速翻页时中间的那些不留。
            if !sharpOriginals.isEmpty, let id = focusedPhotoID {
                let near = sharpNeighborhood(of: id)
                sharpOriginals = sharpOriginals.filter { near.contains($0.key) }
            }
        }
    }
    /// 键盘、全选等由模型改了选择时加一，网格据此同步选中状态并滚到焦点。
    var selectionVersion = 0
    var viewMode: ViewMode = .grid
    var focusMode = false
    /// 侧栏是否显示（工具栏按钮收起 / 展开）；专注模式另外隐藏，不改这里。
    var sidebarVisibility: NavigationSplitViewVisibility = .all
    var filterBarVisible = true
    /// 单张视图左上角的参数浮层（I）。
    var showInfoOverlay = false
    var showInspector = true
    var autoAdvance = false
    /// 比较视图里的焦点格。
    var compareFocus = 0
    /// `Z` 放大到 100%（单张、比较视图）。
    var zoomed = false
    /// 放大的比例：1 是 100%（一个图像像素对一个屏幕像素）。⌘+ / ⌘− 按档位换，触控板捏合是任意比例（计划 V-2）。
    var zoomScale: CGFloat = 1
    /// 适合窗口时的比例，由视图报上来，⌘+ / ⌘− 据此决定下一档。
    @ObservationIgnored var fitScale: CGFloat = 0.3
    /// 背景、边框、留白（显示菜单，计划 V-1）。
    var viewerStyle = ViewerStyle.load() {
        didSet { if viewerStyle != oldValue { viewerStyle.save() } }
    }
    /// 单张视图适合窗口时换上的原图（计划 V-3）：按屏幕尺寸解码，只留焦点和前后各一张。
    var sharpOriginals: [PhotoID: SharpOriginal] = [:]
    @ObservationIgnored var sharpTask: Task<Void, Never>?
    /// 放大时画面中心落在照片上的哪里（0–1，左上为原点），比较视图各格共用，平移同步。
    var zoomCenter = CGPoint(x: 0.5, y: 0.5)
    /// 放大时看得见照片的多大一块（宽、高各占整张的比例，最大 1），由放大的视图报上来，导航器画框用。
    var zoomViewport = CGSize(width: 1, height: 1)
    /// 检查器直方图的缓存（按 480 缩略图算的）。
    @ObservationIgnored var histograms: [PhotoID: Histogram] = [:]
    /// 照片上显示相机的对焦框（`A`），记在本机设置里。
    var showFocusPoint = UserDefaults.standard.bool(forKey: "showFocusPoint") {
        didSet { UserDefaults.standard.set(showFocusPoint, forKey: "showFocusPoint") }
    }
    /// 查过的对焦框：值是 nil 表示这张没有。
    var focusAreas: [PhotoID: FocusArea?] = [:]
    @ObservationIgnored var focusLoading: Set<PhotoID> = []
    @ObservationIgnored var focusTask: Task<Void, Never>?
    /// 放大时各张照片的原文件读到哪一步。只留当前看的几张，解码后的原图很占内存。
    var originals: [PhotoID: OriginalState] = [:]
    /// 导出进行中：状态栏的进度。
    var exportStatus: String?
    @ObservationIgnored var exportCancellation: ScanCancellation?
    /// 上一次导出的结果（验收场景核对用）。
    @ObservationIgnored var lastExportReport: ExportReport?
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
    /// 清卡检查面板（M4）。
    var clearCard: ClearCardSession?
    /// 等用户确认的移除卷。
    var removal: RemovalRequest?
    /// 无卷关联照片窗口的内容；`orphansVersion` 变了窗口重新读。
    var orphanGroups: [OrphanGroup] = []
    var orphansVersion = 0
    /// 刚移除、还插着的卷的挂载点：拔出之前不当新卷提示。
    @ObservationIgnored var removedMounts: Set<URL> = []
    @ObservationIgnored var backfillCancellation: ScanCancellation?
    var volumeToAdd: PendingVolume?
    var errorMessage: String?

    // 后台分析与搜索（M6）
    /// 各种分析在可见照片上的进度；地点单独算（只算有坐标的照片）。
    var analysisCounts: [AnalysisKind: AnalysisCounts] = [:]
    var placeCounts = AnalysisCounts()
    var analysisRunning: Set<AnalysisKind> = []
    var placesRunning = false
    /// 用户暂停的分析，记在本机设置里，重启后仍然暂停。
    var analysisPaused: Set<AnalysisKind> = AnalysisSettings.paused {
        didSet { AnalysisSettings.paused = analysisPaused }
    }
    /// 识别地点（联网，把坐标发给 Apple），默认关闭。
    var placesEnabled = AnalysisSettings.placesEnabled {
        didSet { AnalysisSettings.placesEnabled = placesEnabled }
    }
    /// 人脸识别模型没装：人物分析不跑，人物页说明怎么装。
    var faceModelMissing = false
    var people: [PersonSummary] = []
    var places: [PlaceSummary] = []
    var searchText = ""
    /// 加一表示要把焦点放到搜索框（⌘F）。
    var searchFocusRequest = 0
    var showTaskPanel = false
    @ObservationIgnored var vocabulary = SearchVocabulary()
    @ObservationIgnored var analysisStops: [AnalysisKind: ScanCancellation] = [:]
    @ObservationIgnored var placeStop: ScanCancellation?
    @ObservationIgnored let interaction = InteractionClock()
    @ObservationIgnored var interactionMonitor: Any?
    @ObservationIgnored var lastAnalysisReload = Date.distantPast
    /// 上一轮什么都没做成（预览都读不了）时的待做张数：张数没变就不再自动开始，免得原地打转。
    @ObservationIgnored var analysisStalled: [AnalysisKind: Int] = [:]
    /// 这次启动后查过地名没有：第一次连失败过的也重试，之后只查新的网格。
    @ObservationIgnored var placesTried = false

    // 后台任务
    private(set) var scanStatus: String?
    private(set) var previewStatus: String?
    private(set) var previewsPaused = false
    private var scanQueue: [VolumeID] = []
    private var scanTask: Task<Void, Never>?
    private(set) var scanningVolume: VolumeID?
    private var scanCancellation: ScanCancellation?
    private var previewTask: Task<Void, Never>?
    private var previewStop: ScanCancellation?
    private var pendingPreviewTotal = 0
    private var reloadGeneration = 0
    private var lastScanReload = Date.distantPast
    private var ignoredVolumeUUIDs: Set<String> = []
    private var watcher: VolumeWatcher?
    var dataVersion: Int?

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
        // 启动时核对预览文件（M3 之前的库再按缩略图校正一次照片尺寸），再为在线卷续做没完成的预览。
        let library = library!
        Task.detached(priority: .utility) {
            let generator = PreviewGenerator(library: library)
            _ = try? generator.verifyReadyFiles()
            let corrected = (try? library.correctDimensionsFromThumbnails(store: generator.store)) ?? 0
            await MainActor.run { [weak self] in
                guard let self else { return }
                if corrected > 0 {
                    Measurements.emit("按缩略图校正了 \(corrected) 张照片的尺寸")
                    reloadPhotos(reason: .scan)
                }
                for (id, _) in onlineVolumes { enqueueScan(id) }
                startPreviews()
                startAnalysis()
                startFocusReading()
            }
        }
        watchInteraction()
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
                    reloadAnalysisData()
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
            // 等侧栏数据和启动时的自动重扫都到了再开始；PF-12 要等后台分析开始（`PHOTOAI_SCENARIO_DELAY` 秒）。
            let delay = Double(ProcessInfo.processInfo.environment["PHOTOAI_SCENARIO_DELAY"] ?? "") ?? 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
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
            removedMounts.remove(url.standardizedFileURL)
        }
    }

    private func offerNewVolume(_ info: MountedVolumes.Info) {
        guard !ignoredVolumeUUIDs.contains(info.uuid), !pendingVolumes.contains(where: { $0.id == info.uuid }),
              !removedMounts.contains(info.url.standardizedFileURL) else { return }
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

    /// 卷移除后：停掉它的扫描，不再算在线；还插着的话，拔出之前不当新卷提示。
    func volumeWasRemoved(_ id: VolumeID) {
        if let mount = onlineVolumes[id] { removedMounts.insert(mount.standardizedFileURL) }
        onlineVolumes[id] = nil
        if scanningVolume == id { scanCancellation?.cancel() }
        scanQueue.removeAll { $0 == id }
    }

    /// 正在扫或排着队等扫。
    func isScanning(_ id: VolumeID) -> Bool { scanningVolume == id || scanQueue.contains(id) }

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
        startFocusReading()
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
            // 预览好一批就可以分析一批。
            startAnalysis()
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
        startAnalysis()
        startFocusReading()
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
