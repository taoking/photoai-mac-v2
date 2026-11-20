import AppKit
import PhotoAICore
import Synchronization

/// 后台分析的本机设置：暂停了哪些、地点开没开。
enum AnalysisSettings {
    static var paused: Set<AnalysisKind> {
        get { Set((UserDefaults.standard.stringArray(forKey: "analysisPaused") ?? []).compactMap(AnalysisKind.init)) }
        set { UserDefaults.standard.set(newValue.map(\.rawValue).sorted(), forKey: "analysisPaused") }
    }

    static var placesEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "placesEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "placesEnabled") }
    }
}

/// 用户最后一次操作（按键、点击、滚动、捏合）的时间。后台分析看到用户在操作就先停一停（交互优先）。
final class InteractionClock: Sendable {
    private let last = Mutex(Date.distantPast)
    /// 操作后这么久之内不做分析。
    static let quietPeriod: TimeInterval = 0.6

    func touch() { last.withLock { $0 = Date() } }
    var isBusy: Bool { last.withLock { Date().timeIntervalSince($0) < Self.quietPeriod } }
}

// MARK: - 后台分析

extension AppModel {
    func watchInteraction() {
        guard interactionMonitor == nil else { return }
        let clock = interaction
        interactionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .magnify]
        ) { event in
            clock.touch()
            return event
        }
    }

    /// 没暂停、没在跑、有活要做的分析开始跑。扫描、预览进展后都会调一次，重复调用没关系。
    func startAnalysis() {
        guard let library, ProcessInfo.processInfo.environment["PHOTOAI_ANALYSIS"] != "off" else { return }
        for kind in AnalysisKind.allCases where !analysisPaused.contains(kind) && analysisStops[kind] == nil {
            if kind == .faces, faceModelMissing { continue }
            if let counts = analysisCounts[kind], counts.pending == 0 || analysisStalled[kind] == counts.pending { continue }
            let stop = ScanCancellation()
            analysisStops[kind] = stop
            analysisRunning.insert(kind)
            Measurements.emit("分析开始：\(kind.displayName)")
            let clock = interaction
            // PF-12 的最坏情况：`PHOTOAI_ANALYSIS_YIELD=off` 时用户操作也不让。
            let yields = ProcessInfo.processInfo.environment["PHOTOAI_ANALYSIS_YIELD"] != "off"
            let started = Date()
            Task.detached(priority: .background) { [weak self] in
                let result: Result<AnalysisRunner.Progress, Error> = await Result(asyncCatching: {
                    let work: AnalysisRunner.Work
                    switch kind {
                    case .ocr: work = .ocr(TextRecognizer())
                    case .faces:
                        guard let embedder = try? FaceEmbedder() else { throw FaceModelMissing() }
                        work = .faces(FaceAnalyzer(embedder: embedder), FaceClusterer())
                    }
                    return try await AnalysisRunner(library: library, work: work).run(
                        shouldStop: { stop.isCancelled },
                        shouldYield: { yields && clock.isBusy }
                    ) { _ in
                        Task { @MainActor in self?.analysisProgressed(kind) }
                    }
                })
                await MainActor.run { self?.analysisFinished(kind, result: result, started: started) }
            }
        }
        if placesEnabled, placeStop == nil, !placesTried || placeCounts.pending > 0 { startPlaces() }
    }

    private func analysisProgressed(_ kind: AnalysisKind) {
        // 进度和人物网格最多两秒刷新一次。
        guard Date().timeIntervalSince(lastAnalysisReload) > 2 else { return }
        lastAnalysisReload = Date()
        reloadAnalysisData()
    }

    private func analysisFinished(_ kind: AnalysisKind, result: Result<AnalysisRunner.Progress, Error>, started: Date) {
        analysisStops[kind] = nil
        analysisRunning.remove(kind)
        switch result {
        case .success(let progress):
            if progress.done + progress.failed == 0 {
                analysisStalled[kind] = (try? reader?.analysisCounts(kind))?.pending
            }
            Measurements.emit(
                "分析 \(kind.displayName)：完成 \(progress.done) 张、失败 \(progress.failed) 张、读不了预览 \(progress.skipped) 张，用时 \(String(format: "%.1f", Date().timeIntervalSince(started))) 秒"
            )
        case .failure(let error as FaceModelMissing):
            _ = error
            faceModelMissing = true
        case .failure(let error):
            errorMessage = "\(kind.displayName) 分析出错：\(error)"
        }
        reloadAnalysisData()
    }

    func toggleAnalysisPause(_ kind: AnalysisKind) {
        if analysisPaused.contains(kind) {
            analysisPaused.remove(kind)
            startAnalysis()
        } else {
            analysisPaused.insert(kind)
            analysisStops[kind]?.cancel()
        }
    }

    func setPlacesEnabled(_ enabled: Bool) {
        placesEnabled = enabled
        if enabled { startPlaces() } else { placeStop?.cancel() }
        reloadAnalysisData()
    }

    private func startPlaces() {
        guard let library, placesEnabled, placeStop == nil else { return }
        let stop = ScanCancellation()
        placeStop = stop
        placesTried = true
        placesRunning = true
        Task.detached(priority: .background) { [weak self] in
            let result = await Result(asyncCatching: {
                try await PlaceRunner(library: library).run(shouldStop: { stop.isCancelled }) { _ in
                    Task { @MainActor in self?.analysisProgressed(.ocr) }
                }
            })
            await MainActor.run { [weak self] in
                guard let self else { return }
                placeStop = nil
                placesRunning = false
                if case .success(let progress) = result {
                    Measurements.emit("地点：找到 \(progress.found) 个网格、没有地名 \(progress.none) 个、失败 \(progress.failed) 个")
                }
                reloadAnalysisData()
            }
        }
    }

    /// 重读分析进度、人物、地点、搜索词表。
    func reloadAnalysisData() {
        guard let reader else { return }
        Task.detached(priority: .utility) { [weak self] in
            var counts: [AnalysisKind: AnalysisCounts] = [:]
            for kind in AnalysisKind.allCases { counts[kind] = try? reader.analysisCounts(kind) }
            let placeCounts = (try? reader.placeCounts()) ?? AnalysisCounts()
            let people = (try? reader.people()) ?? []
            let places = (try? reader.places()) ?? []
            let vocabulary = (try? reader.searchVocabulary()) ?? SearchVocabulary()
            await MainActor.run { [weak self] in
                guard let self else { return }
                analysisCounts = counts
                self.placeCounts = placeCounts
                if self.people != people { self.people = people }
                if self.places != places { self.places = places }
                self.vocabulary = vocabulary
                // 预览生成、扫描之后可能有新的活：没在跑的接着跑。
                startAnalysis()
            }
        }
    }

    /// 状态栏的一项：没在跑、也没有待做的就不显示。
    func analysisStatus(_ kind: AnalysisKind) -> String? {
        guard let counts = analysisCounts[kind] else { return nil }
        let finished = counts.done + counts.failed
        let total = counts.total
        if kind == .faces, faceModelMissing { return nil }
        if analysisPaused.contains(kind) {
            return counts.pending > 0 ? "\(kind.displayName)已暂停 \(finished.formatted()) / \(total.formatted())" : nil
        }
        guard analysisRunning.contains(kind) || counts.pending > 0 else { return nil }
        return "\(kind.displayName) \(finished.formatted()) / \(total.formatted())"
    }

    var placeStatus: String? {
        guard placesEnabled, placesRunning else { return nil }
        return "地点 \((placeCounts.done + placeCounts.failed).formatted()) / \(placeCounts.total.formatted())"
    }
}

struct FaceModelMissing: Error {}

// MARK: - 搜索

extension AppModel {
    /// 搜索框回车：认出条件，切到搜索结果。新的搜索从空的筛选条件开始。
    func submitSearch() {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let query = SearchParser.parse(text, vocabulary: vocabulary)
        searchText = ""
        filters[SidebarItem.search(query).filterKey] = nil
        selection = .search(query)
    }

    /// 删掉一个搜索条件；都删完了回到全部照片。
    func removeSearchTerm(at index: Int) {
        guard case .search(var query) = selection, query.terms.indices.contains(index) else { return }
        query.terms.remove(at: index)
        selection = query.terms.isEmpty ? .all : .search(query)
    }
}

// MARK: - 人物

extension AppModel {
    func renamePerson(_ id: PersonID, to name: String) {
        guard let library else { return }
        do {
            let result = try library.renamePerson(id, to: name)
            if result != id, selection == .person(id) { selection = .person(result) }
            if result != id { show("已并入「\(name)」") }
            afterPeopleChanged()
        } catch {
            errorMessage = "改名失败：\(error)"
        }
    }

    func setPersonHidden(_ id: PersonID, _ hidden: Bool) {
        do {
            try library?.setPersonHidden(id, hidden)
            if hidden, selection == .person(id) { selection = .people }
            afterPeopleChanged()
        } catch {
            errorMessage = "改人物失败：\(error)"
        }
    }

    /// “不是 TA”：把所选照片从当前人物里拿出来。
    func removeSelectionFromPerson() {
        guard case .person(let id) = selection, let library else { return }
        let photos = Array(selectedPhotoIDs.isEmpty ? (focusedPhotoID.map { [$0] } ?? []) : selectedPhotoIDs)
        guard !photos.isEmpty else { return }
        do {
            let count = try library.removeFromPerson(photos, person: id)
            // 拿出来的脸马上重新归一次（可能归给别人）。
            try library.assignPendingFaces()
            show("已从这个人物里拿出 \(count) 张脸")
            afterPeopleChanged()
        } catch {
            errorMessage = "操作失败：\(error)"
        }
    }

    private func afterPeopleChanged() {
        dataVersion = try? library?.dataVersion()
        reloadAnalysisData()
        reloadPhotos(reason: .collectionChanged)
        detailVersion += 1
    }

    func loadRecognition(of photo: PhotoID) async -> PhotoRecognition? {
        guard let reader else { return nil }
        return await Task.detached(priority: .userInitiated) {
            PhotoRecognition(
                faces: (try? reader.faces(in: photo)) ?? [],
                place: try? reader.place(of: photo),
                text: try? reader.ocrText(of: photo)
            )
        }.value
    }
}

/// 检查器里“识别”一节：人物、地点、OCR 文字。
struct PhotoRecognition: Equatable {
    var faces: [FaceRecord]
    var place: PlaceInfo?
    var text: String?
}
