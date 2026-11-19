import AppKit
import CryptoKit
import PhotoAICore

/// `PHOTOAI_SCENARIO=export`：M3 验收（计划 · M3）。需要三个在线的卷：
///
/// - 真实存储卡（`PHOTOAI_SCENARIO_CARD`，默认 `Untitled`）：走典型场景到导出，逐字节核对导出的文件，100% 放大读真实原图；
/// - 测试用磁盘映像 `PAICARDA`（卡 A）和 `PAIBACKUP`（备份盘 B）：TST00001 两边都有，TST00002 的 JPEG 在 B 上也有，
///   TST00003–5 只在 A，TST00006 只在 B。场景会**删掉 A 上的几张**、推出 B，验证“第一个位置读不到而第二个成功”、
///   “只剩 JPEG”、“100% 放大时发现原片不在”和“卷离线只能放大预览”。只删 `/Volumes/PAICARDA/` 下的文件。
///
/// 导出到 `PHOTOAI_EXPORT_DIR`。推出的 B 按 `PHOTOAI_SCENARIO_BACKUP_DMG` 重新挂上。
extension ScenarioRunner {
    var environment: [String: String] { ProcessInfo.processInfo.environment }

    func buildExport() {
        let output = URL(fileURLWithPath: environment["PHOTOAI_EXPORT_DIR"] ?? NSTemporaryDirectory() + "photoai-m3-export", isDirectory: true)
        let cardName = environment["PHOTOAI_SCENARIO_CARD"] ?? "Untitled"
        let collectionName = "M3 验收 · 经典"
        var card: VolumeID = 0, cardA: VolumeID = 0, backup: VolumeID = 0
        var picked: [PhotoID] = []
        var collection: CollectionID = 0

        wait("三个卷在线、启动时的重扫结束", timeout: 60) { [self] in
            model.volumes.count >= 3 && model.onlineVolumes.count >= 3 && model.scanStatus == nil
        }
        step("单卡、时间倒序") { [self] in
            card = model.volumes.first { $0.name == cardName }?.id ?? 0
            cardA = model.volumes.first { $0.name == "PAICARDA" }?.id ?? 0
            backup = model.volumes.first { $0.name == "PAIBACKUP" }?.id ?? 0
            check(card != 0 && cardA != 0 && backup != 0, "找到真实卡「\(cardName)」、卡 A、备份盘 B")
            model.selection = .volume(card)
            model.sort = .captureDateDescending
        }
        step("边看边打星、打标签") { [self] in
            check(model.photoCount >= 8, "卡上的照片显示出来（\(model.photoCount) 张）")
            model.focusOnly(model.resultIDs[0])
            model.perform(.toggleSingle)
            for index in 0..<8 {
                model.perform(.rate(index % 2 == 0 ? 5 : 3))
                if index < 6 { model.perform(.toggleLabel(slot: 0, viaOption: false)) }
                model.perform(.next)
            }
            picked = [0, 2, 4].map { model.resultIDs[$0] }
            check(picked.allSatisfy { model.photo($0)?.rating == 5 }, "第 1、3、5 张 5 星 + 经典")
            model.perform(.toggleSingle)
        }
        step("筛选 经典 + 5 星，全选，新建收藏夹") { [self] in
            var filter = PhotoFilter()
            filter.toggleLabel(model.labels[0].id)
            filter.toggleStar(5)
            model.currentFilter = filter
            check(Set(model.resultIDs) == Set(picked), "筛出 3 张（实际 \(model.photoCount)）")
            model.perform(.selectAll)
            model.createCollection(named: collectionName, adding: model.targetIDs)
        }
        step("打开收藏夹") { [self] in
            collection = model.collections.first { $0.name == collectionName }?.id ?? 0
            check(collection != 0, "新建了收藏夹「\(collectionName)」")
            model.selection = .collection(collection)
        }
        step("⌘E 的默认范围") { [self] in
            check(Set(model.resultIDs) == Set(picked), "收藏夹里是这 3 张")
            model.perform(.export)
            check(model.activeSheet == .export(.collection), "在收藏夹里按 ⌘E：范围默认是这个收藏夹")
        }
        pause(1.5)
        step("导出面板截图") { [self] in
            snapshotSheet("m3-export-sheet")
            model.activeSheet = nil
        }
        step("选中 2 张再按 ⌘E") { [self] in
            model.selectedPhotoIDs = Set(model.resultIDs.prefix(2))
            model.selectionVersion += 1
            model.perform(.export)
            check(model.activeSheet == .export(.selection), "选中多张时：范围默认是所选照片")
            model.activeSheet = nil
        }
        exportStep("导出收藏夹：两者都要、按收藏夹分子文件夹") { [self] in
            ExportRequest(photoIDs: picked, files: .both, layout: .byCollection, destination: output, collection: collection)
        } verify: { [self] report in
            check(report.exportedPhotos == 3 && report.copiedFiles == 6 && report.failures.isEmpty,
                  "导出 3 张、6 个文件（实际 \(report.exportedPhotos) 张、\(report.copiedFiles) 个，失败 \(report.failures.count)）")
            let folder = output.appendingPathComponent(collectionName)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            let expected = picked.compactMap { model.photo($0)?.baseName }.flatMap { ["\($0).ARW", "\($0).JPG"] }.sorted()
            check(names == expected, "目录「\(collectionName)」里正好是这 3 张的 ARW + JPG：\(names.joined(separator: " "))")
            let sources = (try? model.reader?.presentSources(of: picked)) ?? [:]
            var identical = 0
            var unchanged = 0
            for source in sources.values.flatMap({ $0 }) where source.volumeID == card {
                guard let mount = model.onlineVolumes[card] else { continue }
                let original = mount.appendingPathComponent(source.relativePath)
                let copy = folder.appendingPathComponent(source.fileName)
                if digest(original) != nil, digest(original) == digest(copy), modified(original) == modified(copy) { identical += 1 }
                if let mtime = scannedMTime(source.locationID), let now = modified(original), abs(now.timeIntervalSince1970 - mtime) < 0.001,
                   (try? original.resourceValues(forKeys: [.fileSizeKey]).fileSize) == source.fileSize {
                    unchanged += 1
                }
            }
            check(identical == 6, "6 个导出文件和卡上的原文件逐字节相同、修改时间相同（\(identical)）")
            check(unchanged == 6, "卡上 6 个源文件的大小、修改时间和导入时记录的一样，没有被改动（\(unchanged)）")
            check(model.activeSheet == .exportResult(report), "导出完成后显示结果")
            snapshotSheet("m3-export-result")
            model.activeSheet = nil
        }
        exportStep("再导出一次到同一个地方（中断后重试走同一条路）") { [self] in
            ExportRequest(photoIDs: picked, files: .both, layout: .byCollection, destination: output, collection: collection)
        } verify: { [self] report in
            check(report.identicalFiles == 6 && report.copiedFiles == 0 && report.renamedFiles == 0,
                  "目标里已有一样的 6 个文件：不再复制、不改名（相同 \(report.identicalFiles)，复制 \(report.copiedFiles)）")
            model.activeSheet = nil
        }

        // MARK: 100% 放大

        var zoomStarted = Date()
        step("单张视图按 Z") { [self] in
            model.openSingle(model.resultIDs[0])
            zoomStarted = Date()
            model.perform(.zoom)
            check(model.zoomed, "Z 放大到 100%")
        }
        wait("读好原图", timeout: 30) { [self] in ready(model.focusedPhotoID) != nil }
        step("核对原图") { [self] in
            guard let id = model.focusedPhotoID, let (image, source) = ready(id), let photo = model.photo(id) else {
                return check(false, "读到原图")
            }
            print(String(format: "Z 读原文件：%@，%d×%d，%.0f ms", source, image.width, image.height, Date().timeIntervalSince(zoomStarted) * 1000))
            let landscape = (photo.width ?? 0) >= (photo.height ?? 0)
            check(max(image.width, image.height) == max(photo.width ?? 0, photo.height ?? 0) && (image.width >= image.height) == landscape,
                  "原图 \(image.width)×\(image.height)：长边和照片一致、方向已转正（照片记录 \(photo.width ?? 0)×\(photo.height ?? 0)）")
            check(source.contains(".JPG"), "读的是 JPEG（长边和 RAW 一样）：\(source)")
            let centers = zoomCenters()
            check(centers.count == 1 && centers.allSatisfy { near($0, CGPoint(x: 0.5, y: 0.5)) }, "画面中心在照片中间：\(centers)")
            snapshot("m3-zoom-single")
            model.perform(.next)
        }
        wait("放大时翻页，下一张也读原图", timeout: 30) { [self] in ready(model.focusedPhotoID) != nil }
        step("翻页后") { [self] in
            check(model.zoomed, "翻页后仍是 100%")
            check(model.originals.count == 1, "只留当前这张的原图（内存）")
            model.perform(.escape)
            check(!model.zoomed && model.viewMode == .single, "Esc 先退出放大，留在单张视图")
            model.perform(.escape)
            check(model.viewMode == .grid, "再按 Esc 回到网格")
        }
        step("单击某处放大到那里") { [self] in
            model.openSingle(model.resultIDs[1])
            model.clickZoom(at: CGPoint(x: 0.25, y: 0.75))
        }
        wait("读好原图", timeout: 30) { [self] in ready(model.focusedPhotoID) != nil }
        step("核对位置") { [self] in
            // 50% 时照片边缘不会滚进画面，单击靠边时画面中心停在能到的最近位置。
            let clicked = CGPoint(x: 0.25, y: 0.75)
            let centers = zoomCenters(), expected = zoomViews().first.map { $0.reachableCenter(clicked) }
            check(centers.count == 1 && expected.map { near(centers[0], $0) } == true,
                  "画面中心在单击的位置（能到的最近处 \(expected.map { "\($0)" } ?? "?")）：\(centers)")
            check(near(model.zoomCenter, clicked), "想看的位置还是单击处，没被视图出现时的滚动改掉：\(model.zoomCenter)")
            check(model.zoomScale == AppModel.clickZoomScale, "单击放大到 50%：\(model.zoomPercent)")
            model.perform(.zoom)
            check(!model.zoomed, "再按 Z 回到适合窗口")
            model.setView(.grid)
            model.selection = .volume(card)
        }
        step("比较两张，Z 同步放大") { [self] in
            model.selectedPhotoIDs = Set(model.resultIDs.prefix(2))
            model.selectionVersion += 1
            model.perform(.compare)
            model.perform(.zoom)
            check(model.viewMode == .compare && model.zoomed, "比较视图里 Z 放大")
        }
        wait("两张都读好原图", timeout: 40) { [self] in model.compareIDs.allSatisfy { ready($0) != nil } }
        step("平移其中一格") { [self] in
            check(zoomViews().count == 2, "两个格子都是 100%")
            // 模拟拖动第一格：直接滚动它的可视区域。
            if let first = zoomViews().first {
                let clip = first.contentView
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x - 300, y: clip.bounds.origin.y - 200))
                first.reflectScrolledClipView(clip)
            }
        }
        step("另一格跟着平移") { [self] in
            let centers = zoomCenters()
            check(centers.count == 2 && near(centers[0], centers[1]) && !near(centers[0], CGPoint(x: 0.5, y: 0.5)),
                  "两格的画面中心一致，且已离开中间：\(centers)")
            snapshot("m3-zoom-compare")
            model.perform(.escape)
            model.perform(.escape)
            check(model.viewMode == .grid && !model.zoomed, "Esc 两次回到网格")
        }

        // MARK: 读不到原片

        var t1 = 0, t2 = 0, t3 = 0, t4 = 0, t6 = 0
        step("在 Finder 里删掉卡 A 上的几个文件（软件还不知道）") { [self] in
            let all = (try? model.reader?.photos(in: .all)) ?? []
            func id(_ name: String) -> PhotoID { all.first { $0.baseName == name }?.id ?? 0 }
            (t1, t2, t3, t4, t6) = (id("TST00001"), id("TST00002"), id("TST00003"), id("TST00004"), id("TST00006"))
            check([t1, t2, t3, t4, t6].allSatisfy { $0 != 0 }, "测试照片都在库里")
            let removed = ["TST00001.JPG", "TST00001.ARW", "TST00002.ARW", "TST00003.JPG", "TST00003.ARW"].filter { removeOnCardA($0) }
            check(removed.count == 5, "删掉卡 A 上的 5 个文件")
        }
        exportStep("第一个位置读不到，从备份盘 B 导出") { [self] in
            ExportRequest(photoIDs: [t1], files: .both, layout: .flat, destination: output.appendingPathComponent("第二个位置"))
        } verify: { [self] report in
            check(report.copiedFiles == 2 && report.fromOtherLocation == 2 && report.failures.isEmpty,
                  "2 个文件都从 B 导出（从其他位置 \(report.fromOtherLocation)）")
            check(report.missingLocations == 2 && report.hiddenPhotoIDs.isEmpty, "卡 A 上的 2 个位置改为历史，照片仍可见")
            check((try? model.reader?.presentLocationCount(of: t1)) == 2, "TST00001 还剩 B 上的 2 个现存位置")
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: report.destination.path)) ?? []).sorted()
            check(names == ["TST00001.ARW", "TST00001.JPG"], "导出的是 TST00001 的 ARW + JPG")
            model.activeSheet = nil
        }
        exportStep("RAW 读不到：只导出 RAW 时改导出 JPEG") { [self] in
            ExportRequest(photoIDs: [t2], files: .raw, layout: .flat, destination: output.appendingPathComponent("只剩JPEG"))
        } verify: { [self] report in
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: report.destination.path)) ?? []).sorted()
            check(names == ["TST00002.JPG"] && report.usedOtherKind == 1, "导出了 TST00002.JPG（\(names)）")
            check(report.missingLocations == 1 && report.hiddenPhotoIDs.isEmpty, "ARW 的位置改为历史，照片仍可见")
            model.activeSheet = nil
        }
        step("卡 A，单张视图打开 TST00003") { [self] in
            model.selection = .volume(cardA)
        }
        step("100% 放大时发现原片不在") { [self] in
            check(model.resultIndex[t3] != nil, "TST00003 照常显示（软件还不知道原片没了）")
            model.openSingle(t3)
            model.perform(.zoom)
        }
        wait("发现原片不在", timeout: 20) { [self] in model.resultIndex[t3] == nil }
        step("核对") { [self] in
            check((try? model.reader?.unlinkedPhotoIDs().contains(t3)) == true, "TST00003 没有其他副本，进入“无卷关联照片”")
            check(model.focusedPhotoID != t3 && model.focusedPhotoID != nil, "焦点移到相邻的照片")
            check(model.toast?.text.contains("原片已不在") == true, "提示：\(model.toast?.text ?? "")")
            model.perform(.escape)
            model.setView(.grid)
        }
        step("推出备份盘 B") { [self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["detach", "-force", "/Volumes/PAIBACKUP"]
            try? process.run()
            process.waitUntilExit()
            check(process.terminationStatus == 0, "hdiutil detach PAIBACKUP")
        }
        wait("B 离线", timeout: 20) { [self] in model.onlineVolumes[backup] == nil }
        step("B 离线时打开 TST00006") { [self] in
            model.selection = .volume(backup)
        }
        step("卷离线：只能放大预览") { [self] in
            check(model.resultIndex[t6] != nil, "离线卷上的照片照常显示")
            model.openSingle(t6)
            model.perform(.zoom)
        }
        wait("提示要插哪个卷", timeout: 10) { [self] in model.originals[t6] == .offline(volumes: ["PAIBACKUP"]) }
        step("截图") { [self] in
            check(true, "放大的是预览，提示插入「PAIBACKUP」")
            snapshot("m3-zoom-offline")
            model.perform(.escape)
            model.setView(.grid)
            model.selection = .all
        }
        step("导出面板列出需要的卷") { [self] in
            let sources = (try? model.reader?.presentSources(of: [t4, t6])) ?? [:]
            let plan = ExportPlan(photoIDs: [t4, t6], sources: sources, files: .both, online: Set(model.onlineVolumes.keys), volumeNames: model.volumeNames)
            check(plan.onlinePhotoIDs == [t4] && plan.offlinePhotoIDs == [t6], "TST00004 能导出，TST00006 只在离线卷上")
            check(plan.volumes.map { "\($0.name)·\($0.isOnline ? "在线" : "离线")·\($0.photoCount)" } == ["PAICARDA·在线·1", "PAIBACKUP·离线·1"],
                  "需要的卷：\(plan.volumes.map(\.name))")
            model.selectedPhotoIDs = [t4, t6]
            model.focusedPhotoID = t4
            model.selectionVersion += 1
            model.perform(.export)
        }
        pause(2)
        step("面板截图（离线卷）") { [self] in
            snapshotSheet("m3-export-offline")
            model.activeSheet = nil
        }
        exportStep("跳过离线卷，只导出在线的") { [self] in
            ExportRequest(photoIDs: [t4, t6], files: .jpeg, layout: .flat, destination: output.appendingPathComponent("跳过离线"))
        } verify: { [self] report in
            check(report.exportedPhotos == 1 && report.skippedOfflinePhotos == 1 && report.missingLocations == 0,
                  "导出 1 张，跳过离线的 1 张，离线卷上的位置不改")
            model.activeSheet = nil
        }
        step("重新挂上 B") { [self] in
            guard let dmg = environment["PHOTOAI_SCENARIO_BACKUP_DMG"] else { return check(false, "PHOTOAI_SCENARIO_BACKUP_DMG") }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["attach", dmg]
            process.standardOutput = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        wait("B 重新在线", timeout: 30) { [self] in model.onlineVolumes[backup] != nil }
        step("插回后") { [self] in
            let sources = (try? model.reader?.presentSources(of: [t4, t6])) ?? [:]
            let plan = ExportPlan(photoIDs: [t4, t6], sources: sources, files: .both, online: Set(model.onlineVolumes.keys), volumeNames: model.volumeNames)
            check(plan.offlinePhotoIDs.isEmpty, "插回 B 后两张都能导出")
            check((try? model.reader?.inconsistentLocationCounts().isEmpty) == true, "现存位置计数和位置表一致")
        }
    }

    // MARK: - 辅助

    func wait(_ name: String, timeout: TimeInterval, _ condition: @escaping () -> Bool) {
        asyncStep(name) { [self] done in
            let deadline = Date().addingTimeInterval(timeout)
            @MainActor func poll() {
                if condition() { return done() }
                if Date() > deadline {
                    check(false, "\(name)（\(Int(timeout)) 秒内没等到）")
                    return done()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { poll() } }
            }
            poll()
        }
    }

    /// 停一会儿（等面板在后台读完位置再截图）。
    func pause(_ seconds: TimeInterval) {
        asyncStep("等 \(seconds) 秒") { done in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done() }
        }
    }

    /// 和导出面板的“导出”按钮走同一条路：`startExport`，等结果出来再核对。
    private func exportStep(_ name: String, request: @escaping () -> ExportRequest, verify: @escaping (ExportReport) -> Void) {
        var started = false
        step(name) { [self] in
            model.lastExportReport = nil
            model.startExport(request())
            started = true
        }
        wait("\(name)：完成", timeout: 300) { [self] in started && model.lastExportReport != nil }
        step("\(name)：核对") { [self] in
            guard let report = model.lastExportReport else { return check(false, "\(name) 有结果") }
            print(String(format: "PF-9 %@：%.1f MB，%.2f 秒，%.1f MB/s", name, Double(report.bytesCopied) / 1_000_000, report.elapsed, report.megabytesPerSecond))
            verify(report)
        }
    }

    private func ready(_ id: PhotoID?) -> (CGImage, String)? {
        guard let id, case .ready(let image, let source) = model.originals[id] else { return nil }
        return (image, source)
    }

    func zoomViews() -> [ZoomScrollView] {
        guard let root = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true })?.contentView else { return [] }
        var found: [ZoomScrollView] = []
        func visit(_ view: NSView) {
            if let zoom = view as? ZoomScrollView { found.append(zoom) }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found.sorted { $0.convert(NSPoint.zero, to: nil).x < $1.convert(NSPoint.zero, to: nil).x }
    }

    private func zoomCenters() -> [CGPoint] {
        zoomViews().map(\.visibleCenter).map { CGPoint(x: ($0.x * 1000).rounded() / 1000, y: ($0.y * 1000).rounded() / 1000) }
    }

    func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.02 && abs(a.y - b.y) < 0.02 }

    private func digest(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// 导入时记下的修改时间。
    private func scannedMTime(_ locationID: Int) -> Double? {
        (try? model.reader?.scannedModificationTime(location: locationID)) ?? nil
    }

    /// 只删测试映像“卡 A”上的文件。
    func removeOnCardA(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: "/Volumes/PAICARDA/DCIM/100MSDCF").appendingPathComponent(name)
        guard url.path.hasPrefix("/Volumes/PAICARDA/") else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    private func snapshotSheet(_ name: String) {
        guard let snapshotDirectory, let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }),
              let view = sheet.contentView, let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        try? representation.representation(using: .png, properties: [:])?.write(to: snapshotDirectory.appendingPathComponent("\(name).png"))
    }
}
