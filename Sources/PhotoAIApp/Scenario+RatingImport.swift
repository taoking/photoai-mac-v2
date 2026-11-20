import AppKit
import PhotoAICore

/// `PHOTOAI_SCENARIO=ratingimport`：从文件导入星级（迭代 I-2）。准备工作见 `Scripts/rating-import-test.sh`。
///
/// 用真实库里的照片写一个 `.md`（文件名、编号、带扩展名、同一张写两次、没有的编号、标题和格式不对的行），
/// 读进来先看确认面板里的数，导入后核对内存和库里的星级，`⌘Z` 整批撤销。不需要卡插着。只对库的副本用。
extension ScenarioRunner {
    func buildRatingImport() {
        var picked: [PhotoSummary] = []
        var before: [PhotoID: Int] = [:]
        var plan: RatingImportPlan?
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("photoai-rating-import-\(ProcessInfo.processInfo.processIdentifier).md")

        func number(_ photo: PhotoSummary) -> Int { Int(photo.baseName.suffix(5)) ?? -1 }
        func libraryRatings() -> [PhotoID: Int] {
            let photos = (try? model.reader?.match(picked.map { .baseName($0.baseName) }).photos) ?? []
            return Dictionary(photos.map { ($0.id, $0.rating) }, uniquingKeysWith: { a, _ in a })
        }

        wait("照片读好", timeout: 30) { [self] in model.photoCount > 0 && model.scanStatus == nil }
        step("菜单里有入口") { [self] in
            let menu = NSApp.mainMenu?.items.first { $0.title == "图库" }?.submenu
            menu?.update()
            check(menu?.items.contains { $0.title == "从文件导入星级…" } == true, "菜单“图库”里有“从文件导入星级…”")
            model.selection = .all
            model.sort = .captureDateDescending
        }
        step("写一个导入文件") { [self] in
            // 挑 4 张编号只出现一次的 DSC 照片（编号循环的同号照片另有测试）。
            let all = model.resultIDs.compactMap { model.photo($0) }
            let counts = Dictionary(grouping: all, by: number).mapValues(\.count)
            picked = Array(all.filter { $0.baseName.wholeMatch(of: #/DSC[0-9]{5}/#) != nil && counts[number($0)] == 1 && $0.hasJPEG }.prefix(4))
            check(picked.count == 4, "挑了 4 张：\(picked.map(\.baseName).joined(separator: "、"))")
            guard picked.count == 4 else { return }
            before = Dictionary(uniqueKeysWithValues: picked.map { ($0.id, $0.rating) })
            let target = picked.map { ($0.rating % 5) + 1 }   // 和原来的星级都不一样
            let text = """
            # 选片结果

            \(picked[0].baseName)  \(target[0])
            \(String(format: "%05d", number(picked[1])))\t\(target[1])
            \(picked[2].baseName).JPG   \(target[2])
            \(picked[3].baseName) \(target[3] % 5 + 1)
            \(picked[3].baseName)  \(target[3])
            DSC00000  3
            - \(picked[0].baseName) 5
            \(picked[1].baseName) 6
            """
            check((try? text.write(to: file, atomically: true, encoding: .utf8)) != nil, "写好 \(file.lastPathComponent)")
            model.prepareRatingImport(from: file)
        }
        step("确认面板") { [self] in
            guard case .ratingImport(let name, let value) = model.activeSheet else { return check(false, "弹出确认面板") }
            plan = value
            check(name == file.lastPathComponent, "弹出确认面板：从「\(name)」导入")
            check(value.changes.map(\.photo.id) == picked.map(\.id), "匹配到挑的 4 张（文件名、编号、带扩展名都认）")
            check(value.changes.map(\.rating) == picked.map { ($0.rating % 5) + 1 }, "要打的星级对（同一张写两次以后面的为准）")
            check(value.changedCount == 4, "4 张星级会变")
            check(value.conflicts.map(\.photo.id) == [picked[3].id], "同一张写了不同星级的列出来 1 张")
            check(value.unmatched.map(\.key) == ["DSC00000"], "没匹配到的：DSC00000")
            check(value.ignored.map(\.line) == [1, 9, 10], "忽略标题、列表符号、星级 6 这 3 行")
            check(model.history.undoTitle == nil, "确认之前不写库")
            check(libraryRatings() == before, "库里的星级还没变")
            snapshotSheet("rating-import-sheet")
        }
        step("导入") { [self] in
            model.activeSheet = nil
            guard let plan else { return }
            model.applyRatingImport(plan)
        }
        step("导入之后") { [self] in
            let expected = Dictionary(uniqueKeysWithValues: picked.map { ($0.id, ($0.rating % 5) + 1) })
            check(picked.allSatisfy { model.photo($0.id)?.rating == expected[$0.id] }, "界面里的星级改了")
            check(libraryRatings() == expected, "库里的星级改了")
            check(model.history.undoTitle == "导入星级", "撤销菜单是“撤销 导入星级”")
            check(model.toast?.text == "导入星级：4 张改了星级", "提示：\(model.toast?.text ?? "")")
        }
        step("撤销") { [self] in
            model.perform(.undo)
        }
        step("撤销之后") { [self] in
            check(picked.allSatisfy { model.photo($0.id)?.rating == before[$0.id] }, "界面里回到导入前")
            check(libraryRatings() == before, "库里回到导入前（整批一次撤销）")
            try? FileManager.default.removeItem(at: file)
        }
    }
}
