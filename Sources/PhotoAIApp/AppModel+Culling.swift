import AppKit
import PhotoAICore

/// 一条短暂的提示，例如“已将 63 张加入「新疆 · 经典」”。
struct Toast: Equatable, Identifiable {
    let id = UUID()
    var text: String
}

// MARK: - 结果与筛选

extension AppModel {
    /// 当前侧栏项的筛选条件。改条件立刻重新筛（PF-8）。
    var currentFilter: PhotoFilter {
        get { filters[selection.filterKey] ?? PhotoFilter() }
        set {
            guard newValue != currentFilter else { return }
            filters[selection.filterKey] = newValue
            let started = Date()
            refilter()
            DispatchQueue.main.async { [resultCount = resultIDs.count] in
                Measurements.record("PF-8 重新筛选", since: started, count: resultCount)
            }
        }
    }

    var labelNames: [LabelID: String] {
        Dictionary(uniqueKeysWithValues: labels.filter(\.isInUse).map { ($0.id, $0.name) })
    }

    /// 照片现在的星级、标签、标记（网格里的分组保存的是筛选那一刻的副本）。
    func photo(_ id: PhotoID) -> PhotoSummary? {
        sourceIndex[id].map { source[$0] }
    }

    /// 换了一组照片（切换侧栏项、排序、扫描后刷新）。
    /// `keepResult` 时不重新筛：原来在结果里的照片留着，新出现的照片按条件决定，原来被筛掉的仍然不显示。
    func setSource(_ photos: [PhotoSummary], keepResult: Bool) {
        let previousResult = keepResult ? Set(resultIDs) : nil
        let previousSource = sourceIndex
        source = photos
        sourceIndex = Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($0.element.id, $0.offset) })
        sourceCount = photos.count
        let filter = currentFilter
        if let previousResult {
            setResult(photos.filter { previousResult.contains($0.id) || (previousSource[$0.id] == nil && filter.matches($0)) })
        } else {
            setResult(photos.filter(filter.matches))
        }
    }

    /// 按当前条件重新筛（“刷新结果”、改条件）。
    func refilter() {
        let filter = currentFilter
        setResult(source.filter(filter.matches))
    }

    private func setResult(_ photos: [PhotoSummary]) {
        resultIDs = photos.map(\.id)
        resultIndex = Dictionary(uniqueKeysWithValues: resultIDs.enumerated().map { ($0.element, $0.offset) })
        let sections = Self.group(photos, by: sort)
        var positions: [PhotoID: IndexPath] = [:]
        positions.reserveCapacity(photos.count)
        for (sectionIndex, section) in sections.enumerated() {
            for (itemIndex, photo) in section.photos.enumerated() {
                positions[photo.id] = IndexPath(item: itemIndex, section: sectionIndex)
            }
        }
        gridPositions = positions
        self.sections = sections
        photoCount = photos.count
        // 选择只保留还在结果里的；什么都没选时选中第一张（原型的做法），键盘有起点。
        let kept = selectedPhotoIDs.filter { resultIndex[$0] != nil }
        var focus = focusedPhotoID.flatMap { resultIndex[$0] != nil ? $0 : nil }
        if focus == nil { focus = kept.min { resultIndex[$0]! < resultIndex[$1]! } ?? resultIDs.first }
        focusedPhotoID = focus
        selectedPhotoIDs = kept.isEmpty ? Set(focus.map { [$0] } ?? []) : kept
        if viewMode != .grid, focus == nil { viewMode = .grid }
        selectionVersion += 1
        updateStaleCount()
    }

    func updateStaleCount() {
        let filter = currentFilter
        staleCount = filter.isEmpty ? 0 : resultIDs.reduce(0) { count, id in
            count + ((photo(id).map(filter.matches) ?? true) ? 0 : 1)
        }
    }

    func clearFilter() {
        currentFilter = PhotoFilter()
    }

    /// “刷新结果”：按当前条件重新筛，已不符合的照片离开结果。
    func refreshResult() {
        let started = Date()
        refilter()
        DispatchQueue.main.async { [resultCount = resultIDs.count] in
            Measurements.record("PF-8 刷新结果", since: started, count: resultCount)
        }
    }

    var labelColors: [LabelID: NSColor] {
        Dictionary(uniqueKeysWithValues: labels.filter(\.isInUse).map { ($0.id, NSColor(hex: $0.color)) })
    }
}

// MARK: - 命令

extension AppModel {
    func perform(_ command: PhotoCommand) {
        guard activeSheet == nil, volumeToAdd == nil, library != nil else { return }
        // 主窗口上开着面板或提示框时（比如改名框），菜单里的命令也不执行。
        if let key = NSApp.keyWindow, key.identifier?.rawValue.hasPrefix("main") != true || key.attachedSheet != nil { return }
        let started = Date()
        switch command {
        case .previous: move(-1)
        case .next: move(1)
        case .rowUp: moveRow(-1)
        case .rowDown: moveRow(1)
        case .rate(let n): setRating(n, started: started)
        case .toggleLabel(let slot, _): toggleLabel(slot: slot, started: started)
        case .clearLabels: clearLabels(started: started)
        case .flag(let flag): setFlag(flag, started: started)
        case .pickFocusRejectOther: pickFocusRejectOther(started: started)
        case .toggleSingle: setView(viewMode == .grid ? .single : .grid)
        case .compare: setView(.compare)
        case .showGrid: setView(.grid)
        case .showSingle: setView(.single)
        case .showCompare: setView(.compare)
        case .focusMode:
            if viewMode == .grid {
                show("专注模式用于单张和比较视图")
            } else {
                focusMode.toggle()
                show(focusMode ? "专注模式：F 或 Esc 退出" : "已退出专注模式")
            }
        case .escape:
            if zoomed { endZoom() } else if focusMode { focusMode = false } else { setView(.grid) }
        case .toggleFilterBar: filterBarVisible.toggle()
        case .infoOverlay: if viewMode == .single { showInfoOverlay.toggle() }
        case .zoom: toggleZoom()
        case .zoomIn: zoomIn()
        case .zoomOut: zoomOut()
        case .zoomToFit: if zoomed { endZoom() }
        case .export: beginExport()
        case .addToLastCollection:
            if let id = lastCollectionID, collections.contains(where: { $0.id == id }) {
                addToCollection(id, photoIDs: targetIDs)
            } else {
                beginAddToCollection()
            }
        case .addToCollection: beginAddToCollection()
        case .removeFromCollection: removeSelectionFromCollection()
        case .selectAll: selectAll()
        case .undo: undo()
        case .redo: redo()
        case .showShortcuts: activeSheet = .shortcuts
        case .focusSearch: searchFocusRequest += 1
        }
    }

    /// 动作作用于哪些照片：比较视图是焦点格，单张视图是当前这张，网格是选中的照片。
    var targetIDs: [PhotoID] {
        switch viewMode {
        case .compare:
            let ids = compareIDs
            return ids.indices.contains(compareFocus) ? [ids[compareFocus]] : []
        case .single:
            return focusedPhotoID.map { [$0] } ?? []
        case .grid:
            if !selectedPhotoIDs.isEmpty {
                return selectedPhotoIDs.sorted { (resultIndex[$0] ?? 0) < (resultIndex[$1] ?? 0) }
            }
            return focusedPhotoID.map { [$0] } ?? []
        }
    }

    /// 比较的照片：选中的照片按结果顺序取前 4 张。
    var compareIDs: [PhotoID] {
        Array(selectedPhotoIDs.filter { resultIndex[$0] != nil }
            .sorted { resultIndex[$0]! < resultIndex[$1]! }
            .prefix(4))
    }

    func setView(_ mode: ViewMode) {
        if mode != viewMode { endZoom() }
        switch mode {
        case .compare:
            guard compareIDs.count >= 2 else {
                show("比较需要先选中 2–4 张照片")
                return
            }
            compareFocus = 0
        case .single:
            guard focusedPhotoID != nil else { return }
        case .grid:
            focusMode = false
            dropSharpOriginals()
            selectionVersion += 1  // 回到网格时滚到焦点
        }
        viewMode = mode
        if mode == .single { prefetchAroundFocus() }
    }

    func show(_ text: String) {
        let toast = Toast(text: text)
        self.toast = toast
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            if self?.toast?.id == toast.id { self?.toast = nil }
        }
    }

    func setAutoAdvance(_ on: Bool) {
        guard on != autoAdvance else { return }
        autoAdvance = on
        show(on ? "自动前进：开（打完自动跳下一张）" : "自动前进：关")
    }

    // MARK: 导航

    /// 只选中一张并把焦点放在它上面。
    func focusOnly(_ id: PhotoID) {
        focusedPhotoID = id
        selectedPhotoIDs = [id]
        selectionVersion += 1
    }

    func move(_ offset: Int) {
        if viewMode == .compare {
            let count = compareIDs.count
            guard count > 0 else { return }
            compareFocus = (compareFocus + offset + count) % count
            return
        }
        guard !resultIDs.isEmpty else { return }
        let current = focusedPhotoID.flatMap { resultIndex[$0] } ?? 0
        let target = min(max(current + offset, 0), resultIDs.count - 1)
        let started = Date()
        focusOnly(resultIDs[target])
        if viewMode == .single {
            pageStarted = started
            prefetchAroundFocus()
        }
    }

    /// 网格里换行：同一天里按列上下移，跨天时落到相邻那天同一列（不够就到最后一张）。
    func moveRow(_ direction: Int) {
        guard viewMode == .grid, let id = focusedPhotoID, let position = gridPositions[id] else { return }
        let columns = max(1, gridColumns)
        let column = position.item % columns
        var section = position.section
        var item = position.item + direction * columns
        if item < 0 {
            section -= 1
            guard section >= 0 else { return }
            let count = sections[section].photos.count
            let lastRowStart = (count - 1) / columns * columns
            item = min(lastRowStart + column, count - 1)
        } else if item >= sections[section].photos.count {
            // 同一天的最后一行还有更靠下的行（这一列不够长）：先到这一天的最后一张。
            let count = sections[section].photos.count
            if position.item / columns < (count - 1) / columns {
                item = count - 1
            } else {
                section += 1
                guard section < sections.count else { return }
                item = min(column, sections[section].photos.count - 1)
            }
        }
        focusOnly(sections[section].photos[item].id)
    }

    func selectAll() {
        selectedPhotoIDs = Set(resultIDs)
        selectionVersion += 1
        show("已全选 \(resultIDs.count.formatted()) 张")
    }

    /// 网格里用鼠标改了选择。`clicked` 是这次新选中的那一张（成为焦点）。
    func gridSelectionChanged(_ ids: Set<PhotoID>, clicked: PhotoID?) {
        selectedPhotoIDs = ids
        if let clicked { focusedPhotoID = clicked } else if ids.count == 1 { focusedPhotoID = ids.first }
    }

    /// 检查器里点星级：网格里先只选中这一张，免得改到别的所选照片上。
    func focusOnlyIfNeeded(_ id: PhotoID) {
        if viewMode == .grid, selectedPhotoIDs != [id] { focusOnly(id) }
    }

    /// 网格里双击：进入单张视图。
    func openSingle(_ id: PhotoID) {
        focusOnly(id)
        setView(.single)
    }

    /// 单张视图翻页时，前后几张的 1600 预览先解码好（PF-7）。
    func prefetchAroundFocus() {
        guard let id = focusedPhotoID, let index = resultIndex[id] else { return }
        let neighbors = [1, -1, 2, 3].compactMap { offset -> PhotoID? in
            let target = index + offset
            return resultIDs.indices.contains(target) ? resultIDs[target] : nil
        }
        previews.prefetch(neighbors)
    }
}

// MARK: - 改动（可撤销）

extension AppModel {
    func setRating(_ rating: Int, started: Date = Date()) {
        let ids = targetIDs
        guard !ids.isEmpty else { return }
        let before = Dictionary(uniqueKeysWithValues: ids.compactMap { id in photo(id).map { (id, $0.rating) } })
        let after = Dictionary(uniqueKeysWithValues: before.keys.map { ($0, rating) })
        commit(.rating(before: before, after: after), title: rating == 0 ? "清除星级" : "★\(rating)", started: started)
    }

    func setFlag(_ flag: Flag, started: Date = Date()) {
        let ids = targetIDs
        guard !ids.isEmpty else { return }
        let before = Dictionary(uniqueKeysWithValues: ids.compactMap { id in photo(id).map { (id, $0.flag) } })
        let after = Dictionary(uniqueKeysWithValues: before.keys.map { ($0, flag) })
        let title = switch flag {
        case .pick: "Pick"
        case .reject: "Reject"
        case .none: "清除标记"
        }
        commit(.flag(before: before, after: after), title: title, started: started)
    }

    /// 切换一个标签：所选照片都有这个标签时去掉，否则给没有的加上（原型的做法）。
    func toggleLabel(slot: Int, started: Date = Date()) {
        guard labels.indices.contains(slot), labels[slot].isInUse else {
            show("这个标签位置还没有名字：在“图库 → 标签设置…”里定义")
            return
        }
        let label = labels[slot]
        let ids = targetIDs.filter { photo($0) != nil }
        guard !ids.isEmpty else { return }
        let allHave = ids.allSatisfy { photo($0)!.labelIDs.contains(label.id) }
        let edit: CullingEdit = allHave
            ? .labels(added: [], removed: Set(ids.map { PhotoLabel($0, label.id) }))
            : .labels(added: Set(ids.filter { !photo($0)!.labelIDs.contains(label.id) }.map { PhotoLabel($0, label.id) }), removed: [])
        commit(edit, title: "\(allHave ? "去掉" : "加上")标签「\(label.name)」", started: started)
    }

    func clearLabels(started: Date = Date()) {
        let removed = targetIDs.flatMap { id in (photo(id)?.labelIDs ?? []).map { PhotoLabel(id, $0) } }
        guard !removed.isEmpty else { return }
        commit(.labels(added: [], removed: Set(removed)), title: "清除所有标签", started: started)
    }

    /// 两张比较时：焦点格 Pick、另一张 Reject。
    func pickFocusRejectOther(started: Date) {
        let ids = compareIDs
        guard viewMode == .compare, ids.count == 2 else { return setFlag(.pick, started: started) }
        let winner = ids[compareFocus], loser = ids[1 - compareFocus]
        guard let first = photo(winner), let second = photo(loser) else { return }
        commit(
            .flag(before: [winner: first.flag, loser: second.flag], after: [winner: .pick, loser: .reject]),
            title: "\(first.baseName) Pick、\(second.baseName) Reject",
            started: started,
            advance: false
        )
    }

    /// 写库成功后才改内存里的状态；写入失败时界面不变并报错（数据模型 §8）。
    /// 值本来就是这样（比如已经 3 星又按 3）时不写库、不进撤销，但照样提示和自动前进：选片时按键就是确认这一张。
    func commit(_ edit: CullingEdit, title: String, started: Date = Date(), advance: Bool = true) {
        guard let library, !edit.photoIDs.isEmpty else { return }
        if !edit.isEmpty {
            do {
                try library.apply(edit)
            } catch {
                errorMessage = "保存失败，改动没有生效：\(error)"
                return
            }
            history.record(edit, title: title)
            applyToMemory(edit)
        }
        let count = edit.photoIDs.count
        show(count > 1 ? "\(title)（\(count) 张）" : title)
        DispatchQueue.main.async { Measurements.record("PF-6 \(title)", since: started, count: count) }
        if advance, autoAdvance, count == 1, viewMode != .compare, edit.isMarkEdit {
            move(1)
        }
    }

    func undo() {
        guard let library else { return }
        do {
            guard let entry = try history.undo({ try library.apply($0) }) else { return show("没有可撤销的操作") }
            applyToMemory(entry.edit.inverse)
            show("撤销：\(entry.title)")
        } catch {
            errorMessage = "撤销失败：\(error)"
        }
    }

    func redo() {
        guard let library else { return }
        do {
            guard let entry = try history.redo({ try library.apply($0) }) else { return show("没有可重做的操作") }
            applyToMemory(entry.edit)
            show("重做：\(entry.title)")
        } catch {
            errorMessage = "重做失败：\(error)"
        }
    }

    /// 把已经写进库的改动同步到内存：星级、标记、标签改格子上的角标；收藏夹成员变了就刷新侧栏，
    /// 当前看的正是这个收藏夹时重新读一次（移出的照片从结果里消失）。
    private func applyToMemory(_ edit: CullingEdit) {
        switch edit {
        case .rating(_, let after):
            for (id, rating) in after { if let index = sourceIndex[id] { source[index].rating = rating } }
        case .flag(_, let after):
            for (id, flag) in after { if let index = sourceIndex[id] { source[index].flag = flag } }
        case .labels(let added, let removed):
            let order = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0.sortOrder) })
            for item in removed {
                if let index = sourceIndex[item.photoID] { source[index].labelIDs.removeAll { $0 == item.labelID } }
            }
            for item in added {
                guard let index = sourceIndex[item.photoID], !source[index].labelIDs.contains(item.labelID) else { continue }
                source[index].labelIDs.append(item.labelID)
                source[index].labelIDs.sort { (order[$0] ?? 0) < (order[$1] ?? 0) }
            }
        case .membership(let collection, _, _):
            reloadSidebar()
            if selection == .collection(collection) { reloadPhotos(reason: .collectionChanged) }
            return
        }
        changedPhotoIDs = edit.photoIDs
        marksVersion += 1
        updateStaleCount()
        if let focusedPhotoID, edit.photoIDs.contains(focusedPhotoID) { detailVersion += 1 }
    }
}

extension CullingEdit {
    /// 星级、标记、标签（自动前进只对这些生效）。
    var isMarkEdit: Bool {
        if case .membership = self { return false }
        return true
    }
}

// MARK: - 收藏夹

extension AppModel {
    var lastCollectionName: String? {
        lastCollectionID.flatMap { id in collections.first { $0.id == id }?.name }
    }

    func beginAddToCollection() {
        let ids = targetIDs
        guard !ids.isEmpty else { return show("先选中照片") }
        activeSheet = .addToCollection(ids)
    }

    func beginNewCollection(adding ids: [PhotoID]) {
        activeSheet = .newCollection(ids)
    }

    func addToCollection(_ collection: CollectionID, photoIDs ids: [PhotoID]) {
        guard let library, !ids.isEmpty, let record = collections.first(where: { $0.id == collection }) else { return }
        do {
            let existing = try library.reader.members(of: collection, among: ids)
            var seen = Set<PhotoID>()
            let added = ids.filter { !existing.contains($0) && seen.insert($0).inserted }
            lastCollectionID = collection
            commit(.membership(collection: collection, added: added, removed: []), title: "加入「\(record.name)」")
            let already = ids.count - added.count
            show("已将 \(ids.count.formatted()) 张加入「\(record.name)」" + (already > 0 ? "（其中 \(already) 张原本就在）" : "") + "；之后按 B 继续加入这里")
            if added.isEmpty { reloadSidebar() }
        } catch {
            errorMessage = "加入收藏夹失败：\(error)"
        }
    }

    /// 新建收藏夹并加入照片。新建本身不进撤销，加入可以撤销。
    func createCollection(named name: String, adding ids: [PhotoID]) {
        guard let library else { return }
        do {
            let id = try library.createCollection(name: name)
            collections.append(CollectionRecord(id: id, name: name, createdAt: Date(), lastUsedAt: nil, photoCount: 0))
            lastCollectionID = id
            if ids.isEmpty {
                show("已新建「\(name)」")
                reloadSidebar()
            } else {
                addToCollection(id, photoIDs: ids)
            }
        } catch {
            errorMessage = "新建收藏夹失败：\(error)"
        }
    }

    func renameCollection(_ id: CollectionID, to name: String) {
        do {
            try library?.renameCollection(id, to: name)
            reloadSidebar()
        } catch {
            errorMessage = "改名失败：\(error)"
        }
    }

    /// 删收藏夹不删照片。删除不进撤销（确认框里说明）。
    func deleteCollection(_ id: CollectionID) {
        do {
            try library?.deleteCollection(id)
            history.forget(collection: id)
            if lastCollectionID == id { lastCollectionID = nil }
            if selection == .collection(id) { selection = .all }
            collections.removeAll { $0.id == id }
            reloadSidebar()
        } catch {
            errorMessage = "删除收藏夹失败：\(error)"
        }
    }

    /// ⌫：在收藏夹里把所选照片移出（照片本身不受影响）；其他地方提示没有删除。
    func removeSelectionFromCollection() {
        guard case .collection(let id) = selection, let record = collections.first(where: { $0.id == id }) else {
            show("常规列表里没有删除照片：照片会在所在的卷被移除后进入“无卷关联照片”")
            return
        }
        let ids = targetIDs
        guard !ids.isEmpty else { return }
        // 移出后焦点落到原位置的下一张。
        let nextFocus = ids.compactMap { resultIndex[$0] }.min().flatMap { index -> PhotoID? in
            let remaining = resultIDs.filter { !ids.contains($0) }
            return remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
        }
        commit(.membership(collection: id, added: [], removed: ids), title: "移出「\(record.name)」")
        show("已从「\(record.name)」移出 \(ids.count) 张；照片本身不受影响（⌘Z 撤销）")
        if let nextFocus { focusOnly(nextFocus) }
    }

    /// 新建收藏夹时建议的名字：来源 + 标签 + 星级，如“Untitled · 经典 · 5星+”。
    func suggestedCollectionName() -> String {
        var parts: [String] = [sourceTitle]
        let filter = currentFilter
        parts += labels.filter { filter.labels.contains($0.id) }.map(\.name)
        if !filter.stars.isEmpty {
            switch filter.starMode {
            case .atLeast: parts.append("\(filter.stars.min() ?? 0)星+")
            case .exactly: parts.append(filter.stars.sorted().map { "\($0)星" }.joined(separator: "/"))
            }
        }
        return parts.joined(separator: " · ")
    }

    var sourceTitle: String {
        switch selection {
        case .all: "全部照片"
        case .importBatch(let id):
            importBatches.first { $0.id == id }.map { "导入 · \($0.volumeName)" } ?? "最近导入"
        case .year(let year): "\(year) 年"
        case .month(let month): DateLabels.month(month)
        case .day(let day): DateLabels.day(day)
        case .undated: "日期未知"
        case .volume(let id): volumes.first { $0.id == id }?.name ?? "卷"
        case .collection(let id): collections.first { $0.id == id }?.name ?? "收藏夹"
        case .people: "人物"
        case .person(let id): people.first { $0.id == id }?.displayName ?? "人物"
        case .place(let name): name
        case .search: "搜索结果"
        }
    }
}

// MARK: - 标签设置

extension AppModel {
    /// 保存标签设置。名字删掉的位置：从所有照片上去掉这个标签，撤销记录里和它有关的也去掉。
    func saveLabels(_ edited: [LabelRecord]) {
        guard let library else { return }
        do {
            for label in edited {
                guard let old = labels.first(where: { $0.id == label.id }), old != label else { continue }
                try library.updateLabel(label.id, name: label.name, color: label.color)
                if !label.isInUse {
                    history.forget(label: label.id)
                    for key in filters.keys { filters[key]?.labels.remove(label.id) }
                }
            }
            labels = try library.reader.labels()
            reloadPhotos(reason: .external)
        } catch {
            errorMessage = "保存标签失败：\(error)"
        }
    }
}
