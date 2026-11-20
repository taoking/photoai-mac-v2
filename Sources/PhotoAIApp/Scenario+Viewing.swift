import AppKit
import PhotoAICore

/// `PHOTOAI_SCENARIO=viewing`：观看体验（计划 · M3 之后 V-1–V-4）。准备工作和 M3 一样（`Scripts/m3-test-volumes.sh`）：
/// 真实存储卡、测试映像 `PAICARDA`（卡 A）和 `PAIBACKUP`（备份盘 B）。
///
/// - V-4：所有照片记录的尺寸比例和缩略图一致（旧库启动时校正过一次）；
/// - V-1：四种背景、边框、留白，记住设置，各截一张图；
/// - V-3：单张视图停一下换上原图、后一张预先读好、快速翻页不读中间的；卷离线、文件不在时留在预览，且**不**改为历史；
/// - V-2：⌘+ / ⌘− 按档位、⌘⇧= 也算放大、⌘0 适合窗口、任意比例（捏合的结果）画面跟着变、比较视图同步。
///
/// 会删掉 `/Volumes/PAICARDA/` 上的 TST00003、推出再挂上 B；真实卡只读。结束时恢复原来的观看设置。
extension ScenarioRunner {
    func buildViewing() {
        let cardName = environment["PHOTOAI_SCENARIO_CARD"] ?? "Untitled"
        let savedStyle = model.viewerStyle
        var card: VolumeID = 0, cardA: VolumeID = 0, backup: VolumeID = 0
        var opened = Date()
        var first: PhotoID = 0

        wait("三个卷在线、启动时的重扫结束", timeout: 60) { [self] in
            model.volumes.count >= 3 && model.onlineVolumes.count >= 3 && model.scanStatus == nil
        }
        step("找到三个卷") { [self] in
            card = model.volumes.first { $0.name == cardName }?.id ?? 0
            cardA = model.volumes.first { $0.name == "PAICARDA" }?.id ?? 0
            backup = model.volumes.first { $0.name == "PAIBACKUP" }?.id ?? 0
            check(card != 0 && cardA != 0 && backup != 0, "找到真实卡「\(cardName)」、卡 A、备份盘 B")
            model.selection = .all
        }

        // MARK: V-4 照片尺寸

        step("V-4 照片尺寸的比例和缩略图一致") { [self] in
            guard let store = model.previewStore else { return check(false, "有预览目录") }
            var checked = 0, mismatched: [String] = [], widescreen = 0
            for id in model.resultIDs {
                guard let photo = model.photo(id), photo.thumbState == .ready, let width = photo.width, let height = photo.height,
                      let thumb = OriginalDecoder.pixelSize(at: store.url(for: id, size: .thumb)) else { continue }
                checked += 1
                let stored = Double(width) / Double(height), shown = Double(thumb.width) / Double(thumb.height)
                if abs(stored / shown - 1) > 0.02 { mismatched.append(photo.baseName) }
                if abs(max(stored, 1 / stored) - 16.0 / 9.0) < 0.02 { widescreen += 1 }
            }
            check(checked > 2_000 && mismatched.isEmpty,
                  "\(checked) 张照片的尺寸比例和缩略图一致（不一致 \(mismatched.count)：\(mismatched.prefix(5))）")
            check(widescreen > 1_000, "机内 16:9 裁切的照片记成 16:9（\(widescreen) 张）")
        }

        // MARK: V-1 背景、边框、留白

        step("打开真实卡第一张") { [self] in
            model.selection = .volume(card)
            model.sort = .captureDateDescending
        }
        step("单张视图") { [self] in
            first = model.resultIDs[0]
            model.openSingle(first)
        }
        for background in ViewerStyle.Background.allCases {
            step("V-1 背景：\(background.title)") { [self] in
                model.viewerStyle = ViewerStyle(background: background, framed: true, margin: background == .white ? .wide : .narrow)
            }
            step("V-1 截图：\(background.title)") { [self] in
                check(ViewerStyle.load() == model.viewerStyle, "背景「\(background.title)」记进设置，重新打开软件还是它")
                snapshot("v1-\(background.rawValue)")
            }
        }
        step("V-1 去掉边框") { [self] in
            model.viewerStyle.framed = false
            model.viewerStyle.background = .darkGray
            model.viewerStyle.margin = .narrow
        }
        step("V-1 截图：无边框") { [self] in
            check(ViewerStyle.load().framed == false, "边框开关记进设置")
            snapshot("v1-unframed")
            model.viewerStyle = ViewerStyle()
        }

        // MARK: V-3 单张视图换原图

        step("V-3 回到网格") { [self] in model.setView(.grid) }
        step("V-3 重新打开第一张") { [self] in
            check(model.sharpOriginals.isEmpty, "回到网格时放掉换上的原图")
            model.openSingle(first)
            opened = Date()
        }
        wait("V-3 换上原图", timeout: 15) { [self] in model.sharpOriginals[first] != nil }
        step("V-3 核对原图") { [self] in
            guard let sharp = model.sharpOriginals[first]?.image, let photo = model.photo(first) else { return check(false, "有原图") }
            print(String(format: "V-3 从打开到换上原图：%.0f ms（含停留 300 ms）", Date().timeIntervalSince(opened) * 1000))
            let ratio = Double(sharp.width) / Double(sharp.height)
            check(max(sharp.width, sharp.height) > PreviewSize.preview.rawValue,
                  "换上的原图 \(sharp.width)×\(sharp.height)，比 1600 预览大")
            check(abs(ratio / photo.aspectRatio - 1) < 0.02, "比例和照片一致（\(String(format: "%.3f", ratio))）")
            check(max(sharp.width, sharp.height) < max(photo.width ?? 0, photo.height ?? 0), "按屏幕尺寸解码，不解完整的 \(photo.width ?? 0) 像素")
            snapshot("v3-sharp")
        }
        wait("V-3 后一张也预先读好", timeout: 15) { [self] in
            model.sharpOriginals[model.resultIDs[1]] != nil
        }
        step("V-3 翻到下一张") { [self] in
            model.perform(.next)
            check(model.sharpOriginals[model.resultIDs[1]] != nil, "翻页后马上就是原图（不用再等）")
        }
        asyncStep("V-3 快速翻 6 张（每张 80 ms）") { [self] done in
            var left = 6
            @MainActor func turn() {
                model.perform(.next)
                left -= 1
                if left == 0 { return done() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { MainActor.assumeIsolated { turn() } }
            }
            turn()
        }
        step("V-3 快速翻页时不读中间的") { [self] in
            let near = Set(model.sharpNeighborhood(of: model.focusedPhotoID ?? 0))
            check(Set(model.sharpOriginals.keys).isSubset(of: near), "内存里只留焦点和前后各一张（\(model.sharpOriginals.count) 张）")
        }
        pause(1.5)
        step("V-3 竖拍照片") { [self] in
            // 这个窗口里竖拍照片的长边只要约 1,340 像素，1600 预览已经够，不读原图。
            guard let id = model.focusedPhotoID, let photo = model.photo(id) else { return check(false, "有焦点") }
            if photo.aspectRatio < 1 {
                check(model.sharpOriginals[id] == nil, "竖拍照片 \(photo.baseName)：屏幕上用不到比 1600 预览更大的图，不读原图")
            }
            // 停到一张横拍的上面。
            while let id = model.focusedPhotoID, (model.photo(id)?.aspectRatio ?? 1.5) < 1 { model.perform(.next) }
        }
        wait("V-3 停在横拍照片上，换上原图", timeout: 15) { [self] in model.focusedPhotoID.map { model.sharpOriginals[$0] != nil } ?? false }

        step("V-3 推出备份盘 B") { [self] in
            check(hdiutil(["detach", "-force", "/Volumes/PAIBACKUP"]), "hdiutil detach PAIBACKUP")
        }
        wait("B 离线", timeout: 20) { [self] in model.onlineVolumes[backup] == nil }
        step("V-3 打开只在 B 上的 TST00006") { [self] in model.selection = .volume(backup) }
        step("打开") { [self] in
            guard let t6 = photoID(named: "TST00006") else { return check(false, "找到 TST00006") }
            model.openSingle(t6)
        }
        pause(1.5)
        step("V-3 卷离线：留在预览") { [self] in
            guard let t6 = photoID(named: "TST00006") else { return }
            check(model.sharpOriginals[t6] == nil && model.isOffline(t6), "卷离线：一直是本机预览，信息条显示“离线”")
        }

        step("V-3 删掉卡 A 上的 TST00003") { [self] in
            model.setView(.grid)
            model.selection = .volume(cardA)
            check(removeOnCardA("TST00003.JPG") && removeOnCardA("TST00003.ARW"), "删掉 /Volumes/PAICARDA 上的 TST00003.JPG、.ARW")
        }
        step("打开 TST00003") { [self] in
            guard let t3 = photoID(named: "TST00003") else { return check(false, "找到 TST00003") }
            model.openSingle(t3)
        }
        pause(1.5)
        step("V-3 原片不在：留在预览，不改为历史") { [self] in
            guard let t3 = photoID(named: "TST00003") else { return check(false, "TST00003 还在结果里") }
            check(model.sharpOriginals[t3] == nil, "读不到原片：留在预览")
            check((try? model.reader?.unlinkedPhotoIDs().contains(t3)) == false && !model.isOffline(t3),
                  "位置没有改为历史：发现缺失仍只在重扫、导出 / 放大、清卡时（设计稿 §4.1）")
            model.setView(.grid)
        }
        step("重新挂上 B") { [self] in
            guard let dmg = environment["PHOTOAI_SCENARIO_BACKUP_DMG"] else { return check(false, "PHOTOAI_SCENARIO_BACKUP_DMG") }
            _ = hdiutil(["attach", dmg])
        }
        wait("B 重新在线", timeout: 30) { [self] in model.onlineVolumes[backup] != nil }

        // MARK: V-2 任意比例

        step("V-2 打开真实卡第一张") { [self] in
            model.selection = .volume(card)
        }
        step("单张") { [self] in model.openSingle(first) }
        pause(0.6)
        step("V-2 ⌘+ 从适合窗口到 50%") { [self] in
            check(model.fitScale > 0.1 && model.fitScale < 0.5, String(format: "适合窗口的比例 %.0f%%", model.fitScale * 100))
            press("=", keyCode: 24, flags: .command)
            check(model.zoomed && model.zoomScale == 0.5, "⌘= 放大到 50%（\(model.zoomPercent)）")
        }
        step("V-2 ⌘⇧= 也算 ⌘+") { [self] in
            check(magnifications() == [0.5], "画面按 50% 显示：\(magnifications())")
            press("+", keyCode: 24, flags: [.command, .shift])
            check(model.zoomScale == 1, "⌘+ 到 100%（\(model.zoomPercent)）")
        }
        step("V-2 ⌘+ 到 200%") { [self] in
            check(magnifications() == [1], "画面按 100% 显示：\(magnifications())")
            press("=", keyCode: 24, flags: .command)
            check(model.zoomScale == 2, "⌘+ 到 200%")
        }
        step("V-2 最大一档") { [self] in
            check(magnifications() == [2], "画面按 200% 显示：\(magnifications())")
            press("=", keyCode: 24, flags: .command)
            check(model.zoomScale == 2, "200% 再按 ⌘+ 不变")
            snapshot("v2-200")
        }
        step("V-2 任意比例（捏合的结果）") { [self] in
            model.setZoomScale(1.5)
        }
        step("V-2 核对 150%") { [self] in
            check(magnifications() == [1.5] && model.zoomPercent == "150%", "150%：画面跟着变，角上显示 \(model.zoomPercent)")
            press("-", keyCode: 27, flags: .command)
            check(model.zoomScale == 1, "⌘− 从 150% 到 100%")
        }
        step("V-2 ⌘− 到 50%") { [self] in
            press("-", keyCode: 27, flags: .command)
            check(model.zoomScale == 0.5, "⌘− 到 50%")
        }
        step("V-2 ⌘− 回到适合窗口") { [self] in
            press("-", keyCode: 27, flags: .command)
            check(!model.zoomed && model.viewMode == .single, "⌘− 回到适合窗口")
        }
        step("V-2 Z 与 ⌘0") { [self] in
            press("z", keyCode: 6)
            check(model.zoomed && model.zoomScale == 1, "Z 仍是 100%")
        }
        step("⌘0") { [self] in
            press("0", keyCode: 29, flags: .command)
            check(!model.zoomed, "⌘0 适合窗口")
        }
        step("V-2 比较两张") { [self] in
            model.setView(.grid)
            model.selectedPhotoIDs = Set(model.resultIDs.prefix(2))
            model.focusedPhotoID = model.resultIDs[0]
            model.selectionVersion += 1
            model.perform(.compare)
        }
        step("V-2 比较视图 ⌘+") { [self] in
            check(model.viewMode == .compare, "比较视图")
            press("=", keyCode: 24, flags: .command)
        }
        step("V-2 两格同步") { [self] in
            check(magnifications() == [0.5, 0.5], "两格都是 50%：\(magnifications())")
            model.setZoomScale(1.25)
        }
        step("V-2 两格同步任意比例") { [self] in
            check(magnifications() == [1.25, 1.25], "两格都是 125%：\(magnifications())")
            snapshot("v2-compare")
            model.perform(.escape)
            model.perform(.escape)
            model.viewerStyle = savedStyle
            check(model.viewMode == .grid, "Esc 两次回到网格")
        }
    }

    func photoID(named name: String) -> PhotoID? {
        model.resultIDs.first { model.photo($0)?.baseName == name }
    }

    /// 各个放大格子现在的比例（取两位小数）。
    private func magnifications() -> [CGFloat] {
        zoomViews().map { ($0.magnification * 100).rounded() / 100 }
    }

    func hdiutil(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
