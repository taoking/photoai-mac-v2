import AppKit
import PhotoAICore

/// 验收用：在真实软件里按典型场景走一遍（计划 · M2），每一步检查结果，打印 PASS / FAIL，有失败时非零退出。
///
/// - `PHOTOAI_SCENARIO=run`：单卡 → 时间倒序 → 单张视图边看边打星、打标签 → 筛选“经典 + 5 星” → 全选 → 新建收藏夹 →
///   在收藏夹里移出、撤销、补加 → 比较 → 标签设置。最后把应有的星级、标签、收藏夹写到 `PHOTOAI_SCENARIO_STATE`。
/// - `PHOTOAI_SCENARIO=verify`：重新打开软件后，核对库里的值和上一次运行写下的一致，撤销记录是空的。
/// - `PHOTOAI_SCENARIO=cull1000`：单张视图里连续打 1,000 次星（自动前进），记录 PF-6、PF-7 的分布。
///   `PHOTOAI_CULL_COUNT`、`PHOTOAI_CULL_INTERVAL_MS` 改次数和间隔（默认 1,000 次、40 ms）：间隔超过 300 ms 时
///   每张都会在后台换原图（计划 V-3），测它对打星、翻页有没有影响。
/// - `PHOTOAI_SCENARIO=export`：M3 的导出与 100% 放大，见 `Scenario+Export.swift`。
/// - `PHOTOAI_SCENARIO=viewing`：观看体验（背景、任意缩放、单张换原图、照片尺寸），见 `Scenario+Viewing.swift`。
/// - `PHOTOAI_SCENARIO=clearcard`：M4 清卡与无卷关联照片，见 `Scenario+ClearCard.swift`。
/// - `PHOTOAI_SCENARIO=cli`：M5 命令行和软件一起用，见 `Scenario+CLI.swift`。
///
/// 只用于临时的库（`PHOTOAI_LIBRARY_DIR`），会改动库里的星级、标签和收藏夹。
/// 每一步都走 `perform(_:)`，和按键走的是同一条路。
@MainActor
final class ScenarioRunner {
    let model: AppModel
    private let mode: String
    /// 每一步做完调用传进来的 `done`。普通的步骤做完后停 0.35 秒（留时间给后台读库和界面刷新）。
    private var steps: [(String, (@escaping () -> Void) -> Void)] = []
    private var failures = 0
    private var passes = 0
    let snapshotDirectory = ProcessInfo.processInfo.environment["PHOTOAI_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    private let statePath = ProcessInfo.processInfo.environment["PHOTOAI_SCENARIO_STATE"]

    init(model: AppModel, mode: String) {
        self.model = model
        self.mode = mode
    }

    func start() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.setFrame(NSRect(x: 60, y: 60, width: 1440, height: 900), display: true)
        }
        switch mode {
        case "run": buildRun()
        case "verify": buildVerify()
        case "cull1000": buildCull1000()
        case "filter": buildFilter()
        case "export": buildExport()
        case "viewing": buildViewing()
        case "clearcard": buildClearCard()
        case "cli": buildCLI()
        default:
            print("FAIL 未知的场景 \(mode)")
            exit(2)
        }
        next()
    }

    func step(_ name: String, _ body: @escaping () -> Void) {
        steps.append((name, { done in
            body()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { MainActor.assumeIsolated { done() } }
        }))
    }

    /// 自己决定什么时候结束的步骤。
    func asyncStep(_ name: String, _ body: @escaping (@escaping () -> Void) -> Void) {
        steps.append((name, body))
    }

    private func next() {
        guard !steps.isEmpty else { return finish() }
        let (_, body) = steps.removeFirst()
        body { [weak self] in self?.next() }
    }

    func check(_ condition: Bool, _ text: String) {
        if condition { passes += 1; print("PASS \(text)") } else { failures += 1; print("FAIL \(text)") }
        fflush(stdout)
    }

    private func finish() {
        print("场景 \(mode)：\(passes) 项 PASS，\(failures) 项 FAIL")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    func snapshot(_ name: String) {
        guard let snapshotDirectory else { return }
        Measurements.snapshotMainWindow(to: snapshotDirectory.appendingPathComponent("\(name).png"))
    }

    private func photo(_ index: Int) -> PhotoSummary { model.photo(model.resultIDs[index])! }

    /// 发一个真实的按键事件，经过和用户按键一样的路径（本地事件监视 → 命令表 → 菜单 / 文本框）。
    func press(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [], window: NSWindow? = nil) {
        let target = window ?? NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
        let shown = flags.contains(.capsLock) ? characters.uppercased() : characters
        for (type, eventFlags) in [(NSEvent.EventType.flagsChanged, flags), (.keyDown, flags), (.keyUp, flags)] {
            let event: NSEvent?
            if type == .flagsChanged {
                event = NSEvent.keyEvent(
                    with: .flagsChanged, location: .zero, modifierFlags: eventFlags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: target?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: 57
                )
            } else {
                event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: eventFlags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: target?.windowNumber ?? 0, context: nil, characters: shown, charactersIgnoringModifiers: shown,
                    isARepeat: false, keyCode: keyCode
                )
            }
            if let event { NSApp.sendEvent(event) }
        }
    }

    // MARK: - 典型场景

    private var firstTwenty: [PhotoID] = []
    private var collectionID: CollectionID?

    private func buildRun() {
        step("单卡、时间倒序") { [self] in
            guard let volume = model.volumes.first else { return check(false, "库里有一个卷") }
            model.selection = .volume(volume.id)
            model.sort = .captureDateDescending
        }
        step("检查来源") { [self] in
            check(model.photoCount == model.sourceCount && model.photoCount >= 40, "卷的照片全部显示（\(model.photoCount) 张）")
            let dates = model.resultIDs.prefix(40).compactMap { model.photo($0)?.captureDate }
            check(dates == dates.sorted(by: >), "按拍摄时间新→旧")
            check(model.focusedPhotoID == model.resultIDs.first, "焦点在第一张")
            firstTwenty = Array(model.resultIDs.prefix(20))
            check(firstTwenty.allSatisfy { model.photo($0)!.rating == 0 && model.photo($0)!.labelIDs.isEmpty }, "前 20 张还没打星、没有标签")
        }
        step("空格进入单张") { [self] in
            model.perform(.toggleSingle)
        }
        step("单张视图打星、打标签") { [self] in
            check(model.viewMode == .single, "空格进入单张视图")
            snapshot("m2-single")
            model.perform(.infoOverlay)
            check(model.showInfoOverlay, "I 打开参数浮层")
        }
        step("参数浮层截图") { [self] in
            snapshot("m2-single-info")
            model.perform(.infoOverlay)
            check(!model.showInfoOverlay, "再按 I 关闭参数浮层")
            // 前 10 张：5 星 + 经典；后 10 张：3 星。不开自动前进时用 → 翻页。
            for index in 0..<20 {
                model.perform(.rate(index < 10 ? 5 : 3))
                if index < 10 { model.perform(.toggleLabel(slot: 0, viaOption: false)) }
                if index == 3 { model.perform(.toggleLabel(slot: 1, viaOption: true)) }
                model.perform(.next)
            }
            check(model.focusedPhotoID == model.resultIDs[20], "→ 翻到第 21 张")
            check(firstTwenty.prefix(10).allSatisfy { model.photo($0)!.rating == 5 }, "前 10 张 5 星")
            check(firstTwenty.suffix(10).allSatisfy { model.photo($0)!.rating == 3 }, "后 10 张 3 星")
            let classic = model.labels[0].id, portrait = model.labels[1].id
            check(firstTwenty.prefix(10).allSatisfy { model.photo($0)!.labelIDs.contains(classic) }, "前 10 张有“经典”")
            check(model.photo(firstTwenty[3])!.labelIDs == [classic, portrait], "第 4 张有“经典、人像”两个标签（⌥2）")
        }
        step("自动前进") { [self] in
            // 翻过 20 张之后：胶片条里只有焦点那格有蓝框（网格在下面，以前选中那格的蓝框会透出来）。
            snapshot("m2-single-turned")
            model.setAutoAdvance(true)
            let before = model.focusedPhotoID
            model.perform(.flag(.reject))
            check(model.photo(before!)!.flag == .reject, "X 标为 Reject")
            check(model.focusedPhotoID == model.resultIDs[21], "自动前进到下一张")
            model.perform(.flag(.pick))
            check(model.focusedPhotoID == model.resultIDs[22], "P 之后也自动前进")
            let undoCount = model.history.undoStack.count
            model.perform(.rate(0))
            check(model.focusedPhotoID == model.resultIDs[23], "按下和现有相同的星级（0）也自动前进")
            check(model.history.undoStack.count == undoCount, "值没变时不产生撤销记录")
            model.setAutoAdvance(false)
            model.perform(.previous)
            model.perform(.previous)
            model.perform(.previous)
            check(model.focusedPhotoID == model.resultIDs[20], "← 回到第 21 张")
        }
        step("撤销、重做") { [self] in
            let id = model.resultIDs[21]
            check(model.photo(id)!.flag == .pick, "第 22 张是 Pick")
            model.perform(.undo)
            check(model.photo(id)!.flag == .none, "⌘Z 撤销 Pick")
            model.perform(.redo)
            check(model.photo(id)!.flag == .pick, "⇧⌘Z 重做 Pick")
        }
        step("回到网格") { [self] in
            model.perform(.toggleSingle)
            check(model.viewMode == .grid, "空格回到网格")
            check(model.selectedPhotoIDs == [model.resultIDs[20]], "网格保留单张视图的焦点和选择")
        }
        step("筛选 经典 + 5 星") { [self] in
            var filter = PhotoFilter()
            filter.toggleLabel(model.labels[0].id)
            filter.toggleStar(5)
            model.currentFilter = filter
        }
        step("检查筛选结果") { [self] in
            check(model.photoCount == 10, "经典 + ★5+：10 张（实际 \(model.photoCount)）")
            check(Set(model.resultIDs) == Set(firstTwenty.prefix(10)), "正是前 10 张")
            snapshot("m2-filtered")
            // 结果保持不变：把第一张改成 4 星，它留在原地，只是变淡。
            model.focusOnly(model.resultIDs[0])
            model.perform(.rate(4))
            check(model.photoCount == 10 && model.staleCount == 1, "打星后结果不变，1 张已不符合")
            model.refreshResult()
            check(model.photoCount == 9 && model.staleCount == 0, "刷新结果后剩 9 张")
            model.perform(.undo)
            check(model.photo(firstTwenty[0])!.rating == 5, "撤销改回 5 星")
            model.refreshResult()
            check(model.photoCount == 10, "再刷新回到 10 张")
        }
        step("全选、新建收藏夹") { [self] in
            model.perform(.selectAll)
            check(model.selectedPhotoIDs.count == 10, "⌘A 全选 10 张")
            check(model.suggestedCollectionName().hasSuffix("经典 · 5星+"), "建议的名字带上条件：\(model.suggestedCollectionName())")
            model.createCollection(named: "新疆 · 经典", adding: model.targetIDs)
        }
        step("检查收藏夹") { [self] in
            collectionID = model.collections.first { $0.name == "新疆 · 经典" }?.id
            check(collectionID != nil, "侧栏出现收藏夹“新疆 · 经典”")
            check(model.collections.first { $0.id == collectionID }?.photoCount == 10, "收藏夹 10 张")
            check(model.lastCollectionID == collectionID, "记为上一次用过的收藏夹（B）")
            model.selection = .collection(collectionID!)
        }
        step("在收藏夹里移出") { [self] in
            check(model.photoCount == 10, "收藏夹里 10 张")
            check(model.currentFilter.isEmpty, "收藏夹有自己的筛选条件（空）")
            model.selectedPhotoIDs = [model.resultIDs[0], model.resultIDs[1]]
            model.perform(.removeFromCollection)
        }
        step("检查移出") { [self] in
            check(model.photoCount == 8, "⌫ 移出 2 张后剩 8 张")
            check(model.collections.first { $0.id == collectionID }?.photoCount == 8, "侧栏计数 8")
            model.perform(.undo)
        }
        step("检查撤销移出") { [self] in
            check(model.photoCount == 10, "⌘Z 撤销移出，回到 10 张")
            check(model.history.redoTitle?.hasPrefix("移出") == true, "可以重做“移出”")
            model.perform(.redo)
        }
        step("回到卷补加") { [self] in
            check(model.photoCount == 8, "⇧⌘Z 重做移出，8 张")
            model.selection = .volume(model.volumes[0].id)
        }
        step("卷的筛选条件还在") { [self] in
            check(model.currentFilter.labels == [model.labels[0].id] && model.currentFilter.stars == [5], "回到卷，筛选条件还是“经典 + ★5+”")
            model.clearFilter()
            check(model.photoCount == model.sourceCount, "清除筛选")
            model.focusOnly(firstTwenty[10])
            model.perform(.addToLastCollection)
            model.focusOnly(firstTwenty[11])
            model.perform(.addToLastCollection)
        }
        step("检查补加") { [self] in
            check(model.collections.first { $0.id == collectionID }?.photoCount == 10, "B 补加 2 张，收藏夹 10 张")
            model.selectedPhotoIDs = [firstTwenty[12], firstTwenty[13]]
            model.focusedPhotoID = firstTwenty[12]
            model.perform(.compare)
        }
        step("比较") { [self] in
            check(model.viewMode == .compare, "C 进入比较")
            snapshot("m2-compare")
            model.perform(.next)
            check(model.compareFocus == 1, "→ 切换焦点格")
            model.perform(.pickFocusRejectOther)
            check(model.photo(firstTwenty[13])!.flag == .pick && model.photo(firstTwenty[12])!.flag == .reject, "⇧P 焦点格 Pick、另一张 Reject")
            model.perform(.rate(2))
            check(model.photo(firstTwenty[13])!.rating == 2 && model.photo(firstTwenty[12])!.rating == 3, "打星只作用于焦点格")
            model.perform(.focusMode)
            check(model.focusMode, "F 专注模式")
            model.perform(.escape)
            check(!model.focusMode && model.viewMode == .compare, "Esc 先退出专注模式")
            model.perform(.escape)
            check(model.viewMode == .grid, "再按 Esc 回到网格")
        }
        step("网格换行") { [self] in
            model.focusOnly(model.resultIDs[0])
            let columns = model.gridColumns
            model.perform(.rowDown)
            let position = model.focusedPhotoID.flatMap { model.gridPositions[$0] }
            check(columns >= 1 && position != nil, "↓ 换行（每行 \(columns) 格，到 \(position.map { "第 \($0.section + 1) 组第 \($0.item + 1) 张" } ?? "无")）")
            model.perform(.rowUp)
            check(model.focusedPhotoID == model.resultIDs[0], "↑ 回到原来那张")
        }
        step("⌫ 在收藏夹外不删除照片") { [self] in
            let count = model.photoCount
            model.perform(.removeFromCollection)
            check(model.photoCount == count, "常规列表里 ⌫ 不删除照片")
        }
        step("真实按键") { [self] in
            model.focusOnly(firstTwenty[15])
            press("2", keyCode: 19)
            check(model.photo(firstTwenty[15])!.rating == 2, "按键 2：经过键盘处理打 2 星")
            press("p", keyCode: 35, flags: .capsLock)
            check(model.photo(firstTwenty[15])!.flag == .pick, "Caps Lock 开着按 P（字符是大写）仍是 Pick，不是 ⇧P")
            check(model.focusedPhotoID == firstTwenty[16], "Caps Lock 开着：自动前进")
            press("u", keyCode: 32)
            check(model.autoAdvance == false, "松开 Caps Lock 的按键：自动前进关")
            let bar = model.filterBarVisible
            press("\\", keyCode: 42)
            check(model.filterBarVisible != bar, "按 \\ 收起 / 展开筛选条")
            press("\\", keyCode: 42)
            press("z", keyCode: 6, flags: .command)
            check(model.photo(firstTwenty[15])!.flag == .none, "U 在未标记的照片上不产生撤销记录，⌘Z 撤销的是上一步的 Pick")
            press(" ", keyCode: 49)
            check(model.viewMode == .single, "空格进入单张")
            press(" ", keyCode: 49)
            check(model.viewMode == .grid, "空格回到网格")
            model.activeSheet = .newCollection([])
        }
        step("文本框里按键让位给输入") { [self] in
            let window = NSApp.keyWindow
            let editor = window?.firstResponder as? NSTextView
            check(editor != nil, "新建收藏夹面板的名字框获得焦点")
            let rating = model.photo(model.focusedPhotoID!)!.rating
            press("1", keyCode: 18, window: window)
            press("b", keyCode: 11, window: window)
            check(editor?.string.hasSuffix("1b") == true, "在名字框里按 1、B 是输入文字（\(editor?.string ?? "")）")
            check(model.photo(model.focusedPhotoID!)!.rating == rating, "名字框里按 1 不会给照片打星")
            model.perform(.rate(rating == 5 ? 4 : 5))
            check(model.photo(model.focusedPhotoID!)!.rating == rating, "面板开着时菜单里的命令不执行")
            press("\u{1b}", keyCode: 53, window: window)
        }
        step("Esc 关掉面板") { [self] in
            check(model.activeSheet == nil, "在名字框里按 Esc 关掉面板（取消）")
            model.activeSheet = nil
        }
        step("标签设置") { [self] in
            var labels = model.labels
            labels[4].name = "夜景"
            model.saveLabels(labels)
        }
        step("检查标签设置") { [self] in
            check(model.labels.filter(\.isInUse).map(\.name) == ["经典", "人像", "风景", "人文", "夜景"], "第 5 个标签位置起名“夜景”")
            model.focusOnly(firstTwenty[19])
            model.perform(.toggleLabel(slot: 4, viaOption: true))
            check(model.photo(firstTwenty[19])!.labelIDs == [model.labels[4].id], "⌥5 打上“夜景”")
            snapshot("m2-grid")
            writeState()
        }
    }

    // MARK: - 重启后核对

    private struct State: Codable {
        var ratings: [String: Int]
        var flags: [String: String]
        var labels: [String: [String]]
        var collection: [String]
        var labelNames: [String]
    }

    private func currentState() -> State {
        let photos = firstTwenty.isEmpty ? Array(model.resultIDs.prefix(24)) : firstTwenty + model.resultIDs[20..<24]
        let names = Dictionary(uniqueKeysWithValues: model.labels.map { ($0.id, $0.name) })
        var state = State(ratings: [:], flags: [:], labels: [:], collection: [], labelNames: model.labels.map(\.name))
        for id in photos {
            guard let photo = model.photo(id) else { continue }
            state.ratings[photo.baseName] = photo.rating
            state.flags[photo.baseName] = photo.flag.rawValue
            state.labels[photo.baseName] = photo.labelIDs.compactMap { names[$0] }
        }
        if let library = model.library, let collection = model.collections.first(where: { $0.name == "新疆 · 经典" }) {
            let ids = (try? library.reader.collectionMembers(collection.id)) ?? []
            state.collection = ids.compactMap { model.photo($0)?.baseName }.sorted()
        }
        return state
    }

    private func writeState() {
        guard let statePath else { return }
        let data = try? JSONEncoder().encode(currentState())
        check((try? data?.write(to: URL(fileURLWithPath: statePath))) != nil, "写下应有的状态，供重启后核对")
    }

    private func buildVerify() {
        step("选卷") { [self] in
            model.selection = .volume(model.volumes[0].id)
            model.sort = .captureDateDescending
        }
        step("核对") { [self] in
            guard let statePath, let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
                  let expected = try? JSONDecoder().decode(State.self, from: data) else {
                return check(false, "读到上一次运行写下的状态")
            }
            let actual = currentState()
            check(actual.ratings == expected.ratings, "重启后星级一致（\(expected.ratings.count) 张）")
            check(actual.flags == expected.flags, "重启后 Pick / Reject 一致")
            check(actual.labels == expected.labels, "重启后标签一致")
            check(actual.collection == expected.collection && expected.collection.count == 10, "重启后收藏夹成员一致（\(actual.collection.count) 张）")
            check(actual.labelNames == expected.labelNames, "重启后标签设置一致")
            check(model.history.undoTitle == nil && model.history.redoTitle == nil, "撤销记录只在本次运行内：重启后为空")
            let before = model.photoCount
            model.perform(.undo)
            check(model.photoCount == before && currentState().ratings == expected.ratings, "重启后 ⌘Z 什么也不改")
        }
    }

    // MARK: - 十万条重新筛选（PF-8）

    private func buildFilter() {
        step("全部照片") { [self] in
            model.selection = .all
        }
        var filters: [(String, PhotoFilter)] = []
        var classicFive = PhotoFilter()
        classicFive.toggleLabel(1)
        classicFive.toggleStar(5)
        filters.append(("经典 + ★5", classicFive))
        var pick = PhotoFilter()
        pick.toggleFlag(.pick)
        filters.append(("Pick", pick))
        var several = PhotoFilter()
        several.toggleStar(3)
        several.toggleLabel(1)
        several.toggleLabel(2)
        several.noLabel = true
        several.toggleFlag(.pick)
        several.toggleFlag(.none)
        filters.append(("四类条件", several))
        filters.append(("清除", PhotoFilter()))
        for (name, filter) in filters {
            step("筛选 \(name)") { [self] in
                check(model.sourceCount >= 100_000, "来源是十万条（\(model.sourceCount)）")
                model.currentFilter = filter
                check(model.photoCount == model.source.filter(filter.matches).count, "\(name)：\(model.photoCount) 张")
            }
        }
    }

    // MARK: - 连续打星

    private var cullCount: Int { ProcessInfo.processInfo.environment["PHOTOAI_CULL_COUNT"].flatMap(Int.init) ?? 1_000 }
    private var cullInterval: Double { (ProcessInfo.processInfo.environment["PHOTOAI_CULL_INTERVAL_MS"].flatMap(Double.init) ?? 40) / 1000 }

    private func buildCull1000() {
        step("准备") { [self] in
            model.selection = .all
            model.sort = .captureDateDescending
        }
        asyncStep("单张视图连续打 \(cullCount) 次星") { [self] done in
            guard model.photoCount > cullCount else {
                check(false, "至少 \(cullCount + 1) 张照片")
                return done()
            }
            model.perform(.toggleSingle)
            model.setAutoAdvance(true)
            Measurements.startCollecting()
            let start = model.resultIDs.firstIndex(of: model.focusedPhotoID ?? -1) ?? 0
            rateNext(remaining: cullCount, startIndex: start, done: done)
        }
    }

    /// 默认每 40 ms 按一次（每秒 25 张，比人快得多），每次都等这一轮界面更新完再按下一次。
    private func rateNext(remaining: Int, startIndex: Int, done: @escaping () -> Void) {
        guard remaining > 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                let count = cullCount
                let ratings = model.resultIDs[startIndex..<(startIndex + count)].compactMap { model.photo($0)?.rating }
                check(ratings.count == count && ratings.allSatisfy { $0 > 0 }, "\(count) 张都打上了星")
                check(model.focusedPhotoID == model.resultIDs[startIndex + count], "自动前进了 \(count) 次")
                Measurements.report(prefix: "PF-6", label: "PF-6 打星（\(count) 次）", target: 50)
                Measurements.report(prefix: "PF-7", label: "PF-7 翻页（\(count) 次，自动前进）", target: 100)
                Measurements.report(prefix: "V-3", label: "V-3 换原图（停留之后）", target: 1_000)
                check((Measurements.percentile(prefix: "PF-6", 0.95) ?? 999) <= 50, "PF-6 95% ≤ 50 ms")
                check((Measurements.percentile(prefix: "PF-7", 0.95) ?? 999) <= 100, "PF-7 95% ≤ 100 ms")
                model.setAutoAdvance(false)
                done()
            }
            return
        }
        model.perform(.rate(remaining % 5 + 1))
        DispatchQueue.main.asyncAfter(deadline: .now() + cullInterval) { [weak self] in
            self?.rateNext(remaining: remaining - 1, startIndex: startIndex, done: done)
        }
    }
}
