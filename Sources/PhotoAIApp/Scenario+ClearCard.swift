import AppKit
import CryptoKit
import PhotoAICore

/// `PHOTOAI_SCENARIO=clearcard`：清卡与无卷关联照片（计划 · M4）。准备工作和 M3 一样（`Scripts/m3-test-volumes.sh`）：
/// 真实存储卡、测试映像 `PAICARDA`（卡 A：TST00001–5 的 RAW + JPEG）和 `PAIBACKUP`（备份盘 B：TST00001 两种、TST00002 的 JPEG、TST00006）。
///
/// - 真实卡：只做清卡检查（只读），再在库的副本里移除，进入无卷关联照片后删掉 3 张；
/// - 卡 A：三类核对（B 在线 / B 离线）→ 补副本到 B（B 上先放一张同名不同的 TST00003.JPG）→ 移除 → 推出再插上，照片对回原记录。
///
/// 会在 B 上写文件、推出再挂上 A 和 B；真实卡只读。
extension ScenarioRunner {
    func buildClearCard() {
        let cardName = environment["PHOTOAI_SCENARIO_CARD"] ?? "Untitled"
        let backupDMG = environment["PHOTOAI_SCENARIO_BACKUP_DMG"]
        let cardDMG = backupDMG.map { ($0 as NSString).deletingLastPathComponent + "/card-a.dmg" }
        let target = "备份"
        var card: VolumeID = 0, cardA: VolumeID = 0, backup: VolumeID = 0
        var started = Date()
        var conflictBytes = Data()
        var photoTotal = 0
        var t3: PhotoID = 0, t1: PhotoID = 0
        var realCardPhotos = 0

        wait("三个卷在线、启动时的重扫结束", timeout: 60) { [self] in
            model.volumes.count >= 3 && model.onlineVolumes.count >= 3 && model.scanStatus == nil
        }
        step("找到三个卷") { [self] in
            card = model.volumes.first { $0.name == cardName }?.id ?? 0
            cardA = model.volumes.first { $0.name == "PAICARDA" }?.id ?? 0
            backup = model.volumes.first { $0.name == "PAIBACKUP" }?.id ?? 0
            check(card != 0 && cardA != 0 && backup != 0, "找到真实卡「\(cardName)」、卡 A、备份盘 B")
            check(cardDMG.map { FileManager.default.fileExists(atPath: $0) } == true, "有卡 A 的映像（PHOTOAI_SCENARIO_BACKUP_DMG 旁边的 card-a.dmg）")
            model.selection = .volume(cardA)
        }
        wait("卡 A 的照片和卷信息读好", timeout: 10) { [self] in model.photoCount == 5 && model.volumeStats[cardA] != nil }
        step("标题行“N 张缺副本”，给 TST00003 打 4 星") { [self] in
            check(model.volumeStats[cardA]?.missingCopyCount == 4, "卡 A：4 张缺副本（TST00002 缺 RAW、TST00003–5 别处都没有）：\(model.volumeStats[cardA]?.missingCopyCount ?? -1)")
            t3 = photoID(named: "TST00003") ?? 0
            t1 = photoID(named: "TST00001") ?? 0
            check(t3 != 0 && t1 != 0, "找到 TST00001、TST00003")
            model.focusOnly(t3)
            model.setRating(4)
            snapshot("m4-title-row")
        }

        // MARK: 真实卡：只读核对

        step("真实卡清卡检查") { [self] in
            started = Date()
            model.beginClearCardCheck(card)
        }
        wait("核对完", timeout: 120) { [self] in model.clearCard?.checking == false }
        step("真实卡的结果") { [self] in
            guard let report = model.clearCard?.report else { return check(false, "真实卡有检查结果：\(model.clearCard?.error ?? "")") }
            realCardPhotos = report.photoCount
            let elapsed = Date().timeIntervalSince(started)
            check(report.photoCount >= 2_000 && report.fileCount == report.verifiedFileCount + report.offlineOnlyFileCount + report.missingFileCount,
                  String(format: "真实卡 %d 张、%d 个文件：已核实 %d、只有离线记录 %d、缺副本 %d（%d 张），预览没就绪 %d；用时 %.2f 秒",
                         report.photoCount, report.fileCount, report.verifiedFileCount, report.offlineOnlyFileCount, report.missingFileCount,
                         report.missingPhotos.count, report.previewPendingPhotoIDs.count, elapsed))
            check(!report.canClear, "真实卡没有副本：不显示“可以清空”")
            check(elapsed <= 10, "PF-11 范围内（≤ 10 秒）")
            snapshotSheet("m4-check-real-card")
            model.clearCard = nil
        }

        // MARK: 卡 A 的三类核对

        step("卡 A 清卡检查（B 在线）") { [self] in model.beginClearCardCheck(cardA) }
        wait("核对完", timeout: 30) { [self] in model.clearCard?.checking == false }
        step("B 在线时的三类") { [self] in
            guard let report = model.clearCard?.report else { return check(false, "卡 A 有检查结果") }
            check(report.photoCount == 5 && report.fileCount == 10, "5 张照片、10 个文件")
            check(report.verifiedFileCount == 3 && report.offlineOnlyFileCount == 0 && report.missingFileCount == 7,
                  "已核实 3（TST00001 两个、TST00002 的 JPEG）、缺副本 7：\(report.verifiedFileCount) / \(report.offlineOnlyFileCount) / \(report.missingFileCount)")
            check(report.missingPhotos.count == 4 && report.missingRAWOnlyCount == 1, "缺副本涉及 4 张，其中 1 张只缺 RAW")
            check(report.missingPhotos.first { $0.id == t3 }?.isMarked == true, "TST00003 标为已打星")
            check(!report.canClear, "不显示“可以清空”")
            snapshotSheet("m4-check-card-a")
            model.clearCard = nil
        }
        step("推出 B") { [self] in check(hdiutil(["detach", "-force", "/Volumes/PAIBACKUP"]), "hdiutil detach PAIBACKUP") }
        wait("B 离线", timeout: 20) { [self] in model.onlineVolumes[backup] == nil }
        step("卡 A 清卡检查（B 离线）") { [self] in model.beginClearCardCheck(cardA) }
        wait("核对完", timeout: 30) { [self] in model.clearCard?.checking == false }
        step("B 离线时的三类") { [self] in
            guard let report = model.clearCard?.report else { return check(false, "卡 A 有检查结果") }
            check(report.verifiedFileCount == 0 && report.offlineOnlyFileCount == 3 && report.missingFileCount == 7,
                  "B 上的 3 个文件只有离线记录：\(report.verifiedFileCount) / \(report.offlineOnlyFileCount) / \(report.missingFileCount)")
            check(report.offlineCopyVolumeIDs == [backup], "列出副本在「PAIBACKUP」上")
            check(report.vanishedCopyCount == 0 && (try? model.reader?.presentLocationCount(of: t1)) == 4, "离线卷上的副本不改为历史")
            model.clearCard = nil
        }
        step("挂回 B") { [self] in
            guard let backupDMG else { return check(false, "PHOTOAI_SCENARIO_BACKUP_DMG") }
            check(hdiutil(["attach", backupDMG]), "hdiutil attach B")
        }
        wait("B 重新在线、重扫完", timeout: 30) { [self] in model.onlineVolumes[backup] != nil && !model.isScanning(backup) }

        // MARK: 补副本

        step("B 的目标目录里放一张同名、不同拍摄时间的 TST00003.JPG") { [self] in
            let from = URL(fileURLWithPath: "/Volumes/PAIBACKUP/\(target)/TST00006.JPG")
            let to = URL(fileURLWithPath: "/Volumes/PAIBACKUP/\(target)/TST00003.JPG")
            check((try? FileManager.default.copyItem(at: from, to: to)) != nil, "复制 TST00006.JPG 为 TST00003.JPG")
            conflictBytes = (try? Data(contentsOf: to)) ?? Data()
            model.enqueueScan(backup)
        }
        wait("B 重扫完", timeout: 30) { [self] in !model.isScanning(backup) }
        step("记下照片总数") { [self] in
            photoTotal = (try? model.reader?.visiblePhotoCount()) ?? 0
            check(photoTotal > 0, "可见照片 \(photoTotal) 张（B 上那张同名不同的照片是另一张）")
            model.beginClearCardCheck(cardA)
        }
        wait("核对完", timeout: 30) { [self] in model.clearCard?.checking == false }
        step("补副本到 B 的「\(target)」") { [self] in
            model.prepareBackfill()
            model.clearCard?.backfill?.target = backup
            model.clearCard?.backfill?.directory = target
            started = Date()
            model.startBackfill()
            check(model.clearCard?.backfill?.running == true, "开始复制")
        }
        wait("复制、校验、登记完", timeout: 180) { [self] in
            model.clearCard?.backfill?.running == false && model.clearCard?.checking == false
        }
        step("补副本的结果") { [self] in
            guard let result = model.clearCard?.backfill?.report else {
                return check(false, "有补副本结果：\(model.clearCard?.backfill?.error ?? "")")
            }
            let elapsed = Date().timeIntervalSince(started)
            let subfolder = "\(target)/\(Backfiller.subfolderPrefix)\(Backfiller.dateFormatter.string(from: Date()))"
            check(result.copiedFiles == 7 && result.failures.isEmpty && result.stopReason == nil,
                  String(format: "复制并校验 %d 个文件（%.0f MB），用时 %.1f 秒", result.copiedFiles, Double(result.copiedBytes) / 1e6, elapsed))
            check(result.subfolders == [subfolder], "TST00003 整组放进了 \(subfolder)：\(result.subfolders)")
            check(result.registeredFiles == 7, "扫描目标目录后登记了 7 个副本")
            check((try? Data(contentsOf: URL(fileURLWithPath: "/Volumes/PAIBACKUP/\(target)/TST00003.JPG"))) == conflictBytes,
                  "B 上原来那张 TST00003.JPG 一字节没动")
            for name in ["TST00003.JPG", "TST00003.ARW"] {
                let copied = digest("/Volumes/PAIBACKUP/\(subfolder)/\(name)")
                check(copied != nil && copied == digest("/Volumes/PAICARDA/DCIM/100MSDCF/\(name)"), "\(subfolder)/\(name) 和卡 A 上的逐字节相同")
            }
            check(digest("/Volumes/PAIBACKUP/\(target)/TST00002.ARW") == digest("/Volumes/PAICARDA/DCIM/100MSDCF/TST00002.ARW"),
                  "只缺的 RAW（TST00002.ARW）补到了目标目录，和 JPEG 放在一起")
            check((try? model.reader?.visiblePhotoCount()) == photoTotal, "照片总数不变（副本挂到原来的照片上）")
            check((try? model.reader?.rating(of: t3)) == 4, "TST00003 还是 4 星")
            if let report = model.clearCard?.report {
                check(report.verifiedFileCount == 10 && report.missingFileCount == 0, "补完自动再核对：10 个文件全部已核实")
                check(report.canClear == report.previewPendingPhotoIDs.isEmpty,
                      "预览\(report.previewPendingPhotoIDs.isEmpty ? "都已就绪：显示“可以清空”" : "还有 \(report.previewPendingPhotoIDs.count) 张没就绪：不显示“可以清空”")")
            }
            check(model.volumeStats[cardA]?.missingCopyCount == 0, "标题行不再提示缺副本")
            snapshotSheet("m4-backfill")
        }

        // MARK: 移除、重新插上

        step("移除卡 A") { [self] in
            let report = model.clearCard?.report
            model.clearCard = nil
            model.requestRemoval(cardA, report: report)
            guard let request = model.removal else { return check(false, "弹出移除确认") }
            check(request.impact.photoCount == 5 && request.impact.orphanedCount == 0, "确认框：5 张都在其他卷上有副本")
            let message = RemovalConfirmation.message(request)
            check(message.contains("10 个文件已核实，0 个只有离线记录，0 个缺副本"), "确认框里重复三类数量")
            model.removal = nil
            model.confirmRemoval(request)
        }
        pause(1)
        step("移除之后") { [self] in
            check(!model.volumes.contains { $0.id == cardA }, "卡 A 不在侧栏里")
            check(model.selection == .all, "回到全部照片")
            check((try? model.reader?.visiblePhotoCount()) == photoTotal, "照片都有副本，照常显示")
            check((try? model.reader?.orphanCount()) == 0, "没有照片进入无卷关联")
            check(!model.pendingVolumes.contains { $0.info.name == "PAICARDA" }, "卡 A 还插着：拔出之前不当新卷提示")
            check((try? model.reader?.rating(of: t3)) == 4, "评分保留")
        }
        step("推出卡 A") { [self] in check(hdiutil(["detach", "-force", "/Volumes/PAICARDA"]), "hdiutil detach PAICARDA") }
        pause(2)
        step("插回卡 A") { [self] in check(cardDMG.map { hdiutil(["attach", $0]) } == true, "hdiutil attach 卡 A") }
        wait("提示检测到新卷", timeout: 30) { [self] in model.pendingVolumes.contains { $0.info.name == "PAICARDA" } }
        step("添加为新卷") { [self] in
            guard let pending = model.pendingVolumes.first(where: { $0.info.name == "PAICARDA" }) else { return }
            model.beginAdding(pending)
            model.volumeToAdd = nil
            model.addVolume(pending, name: "PAICARDA", scanRoot: "DCIM")
        }
        wait("扫描完", timeout: 60) { [self] in
            model.volumes.contains { $0.name == "PAICARDA" } && model.scanStatus == nil
        }
        step("照片对回原记录") { [self] in
            guard let again = model.volumes.first(where: { $0.name == "PAICARDA" }) else { return check(false, "卡 A 重新加进来") }
            check(again.id != cardA, "重新插上算新卷（新记录 \(again.id)，旧的 \(cardA)）")
            check(model.volumeCounts[again.id] == 5, "新卷上 5 张")
            check((try? model.reader?.visiblePhotoCount()) == photoTotal, "没有多出照片：对回原来的记录")
            check((try? model.reader?.rating(of: t3)) == 4, "TST00003 还是 4 星")
            check((try? model.reader?.presentLocationCount(of: t1)) == 4, "TST00001：卡 A 两个 + B 两个现存位置")
            check((try? model.reader?.inconsistentLocationCounts().isEmpty) == true, "现存位置数和位置表一致")
        }

        // MARK: 无卷关联照片

        step("在库的副本里移除真实卡") { [self] in
            model.requestRemoval(card)
            guard let request = model.removal else { return check(false, "弹出移除确认") }
            check(request.impact.photoCount == realCardPhotos, "确认框：\(request.impact.photoCount) 张，其中 \(request.impact.orphanedCount) 张没有其他副本")
            check(RemovalConfirmation.message(request).contains("还没做清卡检查"), "没做清卡检查时确认框里说明按记录算")
            model.removal = nil
            started = Date()
            model.confirmRemoval(request)
            let elapsed = Date().timeIntervalSince(started)
            check(elapsed <= 1, String(format: "PF-10 移除真实卡（%d 张）：%.0f ms", realCardPhotos, elapsed * 1000))
        }
        step("打开“图库 → 无卷关联照片…”") { [self] in
            check(clickMenu("图库", "无卷关联照片…"), "菜单里有“无卷关联照片…”")
        }
        wait("窗口里列出真实卡的照片", timeout: 20) { [self] in
            model.orphanGroups.first { $0.id == card }?.photos.count == realCardPhotos
        }
        pause(1.5)
        step("无卷关联照片窗口") { [self] in
            check(NSApp.windows.contains { $0.title == "无卷关联照片" && $0.isVisible }, "单独的窗口")
            let group = model.orphanGroups.first { $0.id == card }
            check(group?.volumeStatus == .removed && group?.removedAt != nil, "按曾经所在的卷分组，写着移除时间")
            snapshotWindow("无卷关联照片", "m4-orphans")
        }
        step("删除 3 张") { [self] in
            guard let group = model.orphanGroups.first(where: { $0.id == card }) else { return }
            let ids = Array(group.photos.prefix(3).map(\.id))
            let store = model.previewStore
            check(ids.allSatisfy { id in store.map { FileManager.default.fileExists(atPath: $0.url(for: id, size: .thumb).path) } == true },
                  "删除前预览在")
            guard let result = model.deleteOrphans(ids) else { return check(false, "删除成功") }
            check(result.deleted.sorted() == ids.sorted() && result.kept.isEmpty, "删掉 3 张")
            check(ids.allSatisfy { id in store.map { !FileManager.default.fileExists(atPath: $0.url(for: id, size: .thumb).path) } == true },
                  "缩略图和预览一起删掉")
            check((try? model.reader?.orphanCount()) == realCardPhotos - 3, "还剩 \(realCardPhotos - 3) 张无卷关联")
            check(FileManager.default.fileExists(atPath: "/Volumes/\(cardName)/DCIM"), "真实卡上的文件没动（只读）")
        }
        wait("窗口刷新", timeout: 10) { [self] in
            model.orphanGroups.first { $0.id == card }?.photos.count == realCardPhotos - 3
        }
        step("关闭窗口") { NSApp.windows.first { $0.title == "无卷关联照片" }?.close() }
    }

    private func digest(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 点菜单项，和用户点菜单走同一条路。
    private func clickMenu(_ menuTitle: String, _ itemTitle: String) -> Bool {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == menuTitle })?.submenu else { return false }
        menu.update()
        guard let index = menu.items.firstIndex(where: { $0.title == itemTitle }) else { return false }
        menu.performActionForItem(at: index)
        return true
    }

    private func snapshotWindow(_ title: String, _ name: String) {
        guard let snapshotDirectory, let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }),
              let view = window.contentView, let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        try? representation.representation(using: .png, properties: [:])?.write(to: snapshotDirectory.appendingPathComponent("\(name).png"))
    }
}
