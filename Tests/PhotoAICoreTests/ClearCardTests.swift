import Foundation
import Testing
@testable import PhotoAICore

/// 清卡检查、补副本、移除卷、无卷关联照片。对应计划 · M4 验收、设计稿 §4、§5，数据模型 §6、§7。
@Suite struct ClearCardTests {
    let dateA = "2026-08-12 10:00:01"
    let dateB = "2026-08-12 10:00:02"
    let dateC = "2026-08-13 09:30:00"

    /// 一张卡（DSC00001 是 RAW + JPEG，DSC00002 只有 JPEG）和一块备份盘。
    struct Setup {
        let temp: TemporaryLibrary
        let card: FakeCard
        let backup: FakeCard
        let cardVolume: VolumeRecord
        let backupVolume: VolumeRecord
        let first: PhotoID
        let second: PhotoID

        var library: Library { temp.library }
        var reader: LibraryReader { temp.reader }

        func finder(online: [VolumeID]? = nil) -> OriginalFinder {
            let all = [cardVolume.id: card.root, backupVolume.id: backup.root]
            let mounts = online.map { ids in all.filter { ids.contains($0.key) } } ?? all
            return OriginalFinder(mounts: mounts) { mounts[$0] != nil }
        }

        func checker(online: [VolumeID]? = nil) -> ClearCardChecker {
            ClearCardChecker(library: library, finder: finder(online: online))
        }

        func backfiller() -> Backfiller {
            Backfiller(library: library, finder: finder(), scanner: temp.scanner())
        }

        func previewsReady() throws {
            try library.db.run("UPDATE photos SET thumb_state = 'ready', preview_state = 'ready';")
        }
    }

    /// `backupFiles`：备份盘“照片/”下放哪些文件（和卡上同名、同内容）。
    func makeSetup(backupFiles: [String]) async throws -> Setup {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        let backup = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC00001.ARW", date: dateA, padding: 40)
        try card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA, padding: 10)
        try card.put("DCIM/100MSDCF/DSC00002.JPG", date: dateB, padding: 10)
        let paddings = ["DSC00001.ARW": 40, "DSC00001.JPG": 10, "DSC00002.JPG": 10]
        let dates = ["DSC00001": dateA, "DSC00002": dateB]
        for name in backupFiles {
            try backup.put("照片/\(name)", date: dates[String(name.prefix(8))]!, padding: paddings[name]!)
        }
        let cardVolume = try temp.library.addVolume(uuid: "CARD-A", name: "卡 A", scanRoot: "DCIM")
        let backupVolume = try temp.library.addVolume(uuid: "DISK-B", name: "备份盘 B", scanRoot: "照片")
        try await temp.scanner().scan(volumeID: cardVolume.id, mountURL: card.root)
        try await temp.scanner().scan(volumeID: backupVolume.id, mountURL: backup.root)
        return Setup(
            temp: temp, card: card, backup: backup, cardVolume: cardVolume, backupVolume: backupVolume,
            first: try #require(try temp.photoID("DSC00001", dateA)),
            second: try #require(try temp.photoID("DSC00002", dateB))
        )
    }

    // MARK: - 清卡检查的三种情况

    @Test func allCopiesOnlineCanClearOnlyWhenPreviewsAreReady() async throws {
        let s = try await makeSetup(backupFiles: ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.JPG"])
        var report = try s.checker().check(volumeID: s.cardVolume.id)
        #expect(report.photoCount == 2 && report.fileCount == 3)
        #expect(report.verifiedFileCount == 3 && report.offlineOnlyFileCount == 0 && report.missingFileCount == 0)
        #expect(report.previewPendingPhotoIDs.count == 2)
        #expect(!report.canClear, "预览没就绪就不能清空")

        try s.previewsReady()
        report = try s.checker().check(volumeID: s.cardVolume.id)
        #expect(report.canClear)
        #expect(try s.reader.missingCopyCount(volume: s.cardVolume.id) == 0)
    }

    @Test func copiesOnlyOnOfflineVolumeAreNotVerified() async throws {
        let s = try await makeSetup(backupFiles: ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.JPG"])
        try s.previewsReady()
        // 备份盘没插上：按上次扫描结果只能算“只有离线记录”。
        let report = try s.checker(online: [s.cardVolume.id]).check(volumeID: s.cardVolume.id)
        #expect(report.offlineOnlyFileCount == 3 && report.verifiedFileCount == 0 && report.missingFileCount == 0)
        #expect(report.offlineCopyVolumeIDs == [s.backupVolume.id])
        #expect(!report.canClear)
        // 按记录算，离线卷上的副本也算有副本：标题行不提示缺副本。
        #expect(try s.reader.missingCopyCount(volume: s.cardVolume.id) == 0)
    }

    @Test func backupWithOnlyTheJpegLeavesTheRawMissing() async throws {
        let s = try await makeSetup(backupFiles: ["DSC00001.JPG", "DSC00002.JPG"])
        try s.previewsReady()
        try s.library.setRating(4, for: [s.first])
        let report = try s.checker().check(volumeID: s.cardVolume.id)
        #expect(report.verifiedFileCount == 2 && report.missingFileCount == 1)
        #expect(report.missingPhotos.map(\.id) == [s.first])
        let missing = try #require(report.missingPhotos.first)
        #expect(missing.missingKinds == [.raw] && missing.isPartial && missing.isMarked)
        #expect(report.missingRAWOnlyCount == 1)
        #expect(!report.canClear, "照片还在别处、但 RAW 只在卡上：不能清空")
        #expect(try s.reader.missingCopyCount(volume: s.cardVolume.id) == 1)
        #expect(try s.reader.removalImpact(volume: s.cardVolume.id) == {
            var impact = RemovalImpact()
            impact.photoCount = 2
            impact.partialCount = 1
            return impact
        }())
    }

    @Test func copyFoundGoneDuringTheCheckBecomesHistorical() async throws {
        let s = try await makeSetup(backupFiles: ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.JPG"])
        try s.previewsReady()
        // 在 Finder 里删掉了备份盘上的一份；软件还不知道。
        try s.backup.remove("照片/DSC00002.JPG")
        #expect(try s.reader.presentLocationCount(of: s.second) == 2)
        let report = try s.checker().check(volumeID: s.cardVolume.id)
        #expect(report.vanishedCopyCount == 1)
        #expect(report.missingPhotos.map(\.id) == [s.second])
        #expect(!report.missingPhotos[0].isPartial)
        #expect(try s.reader.presentLocationCount(of: s.second) == 1, "当场核对发现不在的副本改为历史")
        #expect(try s.temp.expectConsistentCounts())
    }

    @Test func copyWithDifferentSizeOnDiskIsNotVerifiedAndKept() async throws {
        let s = try await makeSetup(backupFiles: ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.JPG"])
        try s.previewsReady()
        // 备份盘上的文件被改过（大小变了），还没重扫。
        try Data("被改过".utf8).write(to: s.backup.url("照片/DSC00002.JPG"))
        let report = try s.checker().check(volumeID: s.cardVolume.id)
        #expect(report.missingPhotos.map(\.id) == [s.second])
        #expect(report.problems.count == 1)
        #expect(report.vanishedCopyCount == 0)
        #expect(try s.reader.presentLocationCount(of: s.second) == 2, "对不上只报告，位置不动")
    }

    @Test func checkOnEmptyCopyListDoesNotTouchUnrelatedVolumes() async throws {
        let s = try await makeSetup(backupFiles: [])
        let report = try s.checker().check(volumeID: s.cardVolume.id)
        #expect(report.missingFileCount == 3 && report.missingPhotos.count == 2)
        #expect(try s.reader.removalImpact(volume: s.cardVolume.id).orphanedCount == 2)
    }

    // MARK: - 补副本

    @Test func backfillCopiesVerifiesAndRegistersOnTheSamePhotos() async throws {
        let s = try await makeSetup(backupFiles: ["DSC00001.JPG"])
        try s.previewsReady()
        try s.library.setRating(5, for: [s.first, s.second])
        let photoCount = try s.reader.visiblePhotoCount()
        let sourceBytes = try Data(contentsOf: s.card.url("DCIM/100MSDCF/DSC00001.ARW"))
        let sourceDate = try s.card.url("DCIM/100MSDCF/DSC00001.ARW").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let check = try s.checker().check(volumeID: s.cardVolume.id)
        #expect(check.missingFileCount == 2)
        let report = try await s.backfiller().run(check.missingPhotos, from: s.cardVolume.id, to: s.backupVolume.id, directory: "照片/补")
        #expect(report.copiedFiles == 2 && report.failures.isEmpty && report.stopReason == nil)
        #expect(report.subfolders.isEmpty)
        #expect(report.registeredFiles == 2)
        #expect(try Data(contentsOf: s.backup.url("照片/补/DSC00001.ARW")) == sourceBytes)
        let copied = s.backup.url("照片/补/DSC00001.ARW")
        #expect(try copied.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == sourceDate)
        // 没有残留的临时文件。
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.backup.url("照片/补").path).sorted() == ["DSC00001.ARW", "DSC00002.JPG"])

        // 挂到原来的照片上：照片总数、评分不变。
        #expect(try s.reader.visiblePhotoCount() == photoCount)
        #expect(try s.reader.rating(of: s.first) == 5 && s.reader.rating(of: s.second) == 5)
        #expect(try s.reader.presentLocationCount(of: s.first) == 4)
        #expect(try s.temp.expectConsistentCounts())
        let after = try s.checker().check(volumeID: s.cardVolume.id)
        #expect(after.canClear)
    }

    @Test func backfillToTargetWithSameNameDifferentPhotoUsesSubfolder() async throws {
        let s = try await makeSetup(backupFiles: [])
        // 备份盘目标目录里已有一张同名、不同拍摄时间的照片（编号循环）。
        try s.backup.put("照片/DSC00002.JPG", date: dateC, padding: 3)
        try await s.temp.scanner().scan(volumeID: s.backupVolume.id, mountURL: s.backup.root)
        let other = try #require(try s.temp.photoID("DSC00002", dateC))
        try s.library.setRating(2, for: [other])
        try s.library.setRating(5, for: [s.second])
        let oldBytes = try Data(contentsOf: s.backup.url("照片/DSC00002.JPG"))
        let photoCount = try s.reader.visiblePhotoCount()

        let check = try s.checker().check(volumeID: s.cardVolume.id)
        let report = try await s.backfiller().run(check.missingPhotos, from: s.cardVolume.id, to: s.backupVolume.id, directory: "照片")
        let subfolder = "照片/" + Backfiller.subfolderPrefix + Backfiller.dateFormatter.string(from: Date())
        #expect(report.subfolders == [subfolder])
        #expect(report.copiedFiles == 3 && report.registeredFiles == 3)
        // DSC00001 没冲突，放在目标目录；DSC00002 整组换到子目录，不改文件名。
        #expect(FileManager.default.fileExists(atPath: s.backup.url("照片/DSC00001.ARW").path))
        #expect(FileManager.default.fileExists(atPath: s.backup.url("\(subfolder)/DSC00002.JPG").path))
        #expect(try Data(contentsOf: s.backup.url("照片/DSC00002.JPG")) == oldBytes, "目标上已有的文件一字节都不动")

        #expect(try s.reader.visiblePhotoCount() == photoCount)
        #expect(try s.reader.presentLocationCount(of: s.second) == 2, "原照片获得第二个位置")
        #expect(try s.reader.presentLocationCount(of: other) == 1)
        #expect(try s.reader.rating(of: s.second) == 5 && s.reader.rating(of: other) == 2)
        #expect(try s.temp.expectConsistentCounts())
    }

    @Test func backfillSkipsIdenticalFilesLeftByAnEarlierRun() async throws {
        let s = try await makeSetup(backupFiles: [])
        // 上次补到一半：文件已经复制过去，但还没扫描登记。
        try FileManager.default.createDirectory(at: s.backup.url("照片"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: s.card.url("DCIM/100MSDCF/DSC00002.JPG"), to: s.backup.url("照片/DSC00002.JPG"))
        let check = try s.checker().check(volumeID: s.cardVolume.id)
        #expect(check.missingFileCount == 3)
        let report = try await s.backfiller().run(check.missingPhotos, from: s.cardVolume.id, to: s.backupVolume.id, directory: "照片")
        #expect(report.copiedFiles == 2 && report.identicalFiles == 1 && report.subfolders.isEmpty)
        #expect(report.registeredFiles == 3)
        #expect(try s.checker().check(volumeID: s.cardVolume.id).missingFileCount == 0)
    }

    @Test func backfillReportsSourceDeletedAndMarksItHistorical() async throws {
        let s = try await makeSetup(backupFiles: ["DSC00001.ARW", "DSC00001.JPG"])
        let check = try s.checker().check(volumeID: s.cardVolume.id)
        #expect(check.missingPhotos.map(\.id) == [s.second])
        try s.card.remove("DCIM/100MSDCF/DSC00002.JPG")
        let report = try await s.backfiller().run(check.missingPhotos, from: s.cardVolume.id, to: s.backupVolume.id, directory: "照片")
        #expect(report.copiedFiles == 0 && report.registeredFiles == 0)
        #expect(report.failures.map(\.fileName) == ["DSC00002.JPG"])
        #expect(report.vanishedSourceCount == 1)
        #expect(try s.reader.unlinkedPhotoIDs() == [s.second], "源位置改为历史，没有别的副本就进入无卷关联照片")
        #expect(!FileManager.default.fileExists(atPath: s.backup.url("照片/DSC00002.JPG").path))
    }

    @Test func backfillRefusesFoldersOutsideTheScanRoot() async throws {
        let s = try await makeSetup(backupFiles: [])
        let check = try s.checker().check(volumeID: s.cardVolume.id)
        await #expect(throws: BackfillError.self) {
            try await s.backfiller().run(check.missingPhotos, from: s.cardVolume.id, to: s.backupVolume.id, directory: "别处")
        }
        await #expect(throws: BackfillError.sameVolume) {
            try await s.backfiller().run(check.missingPhotos, from: s.cardVolume.id, to: s.cardVolume.id, directory: "DCIM")
        }
    }

    @Test func backfillStopsWhenTheTargetDiskIsFull() async throws {
        let s = try await makeSetup(backupFiles: [])
        // 一个 2 MB 的磁盘映像当目标盘，卡上放一个 3 MB 的文件。
        try s.card.put("DCIM/100MSDCF/DSC00003.JPG", date: dateC, padding: 3_000_000)
        try await s.temp.scanner().scan(volumeID: s.cardVolume.id, mountURL: s.card.root)
        let image = try TinyDiskImage(megabytes: 2)
        defer { image.detach() }
        try FileManager.default.createDirectory(at: image.mount.appendingPathComponent("照片"), withIntermediateDirectories: true)
        let small = try s.library.addVolume(uuid: "TINY", name: "小盘", scanRoot: "照片")
        let finder = OriginalFinder(mounts: [s.cardVolume.id: s.card.root, small.id: image.mount]) { _ in true }
        let check = try ClearCardChecker(library: s.library, finder: finder).check(volumeID: s.cardVolume.id)
        #expect(check.missingPhotos.count == 3)
        let report = try await Backfiller(library: s.library, finder: finder, scanner: s.temp.scanner())
            .run(check.missingPhotos, from: s.cardVolume.id, to: small.id, directory: "照片")
        #expect(report.stopReason == "目标盘空间不够")
        #expect(report.copiedFiles == 3, "写满之前的照片照常复制：\(report)")
        #expect(report.failures.map(\.fileName) == ["DSC00003.JPG"])
        #expect(report.registeredFiles == 3)
        let left = try FileManager.default.contentsOfDirectory(atPath: image.mount.appendingPathComponent("照片").path)
        #expect(!left.contains { $0.hasSuffix(".photoai-part") }, "临时文件删掉了：\(left)")
        #expect(!left.contains("DSC00003.JPG"))
    }

    // MARK: - 移除卷与无卷关联照片

    @Test func removingKeepsMarksPreviewsAndCollectionsAndListsOrphansByVolume() async throws {
        let s = try await makeSetup(backupFiles: ["DSC00001.JPG"])
        try s.library.setRating(3, for: [s.second])
        try s.library.setFlag(.pick, for: [s.second])
        let collection = try s.library.createCollection(name: "精选")
        _ = try s.library.addPhotos([s.second], to: collection)
        #expect(try s.reader.removalImpact(volume: s.cardVolume.id).orphanedCount == 1)

        try s.library.removeVolume(s.cardVolume.id)
        #expect(try s.reader.photos(in: .all).map(\.id) == [s.first], "DSC00001 的 JPEG 在备份盘上，照常显示")
        #expect(try s.reader.photos(in: .collection(collection)).isEmpty, "收藏夹里也不显示无卷关联照片")
        #expect(try s.reader.allCollectionMembers(collection) == [s.second], "但收藏夹的成员还在")
        let groups = try s.reader.orphanGroups()
        #expect(groups.map(\.id) == [s.cardVolume.id])
        #expect(groups[0].volumeStatus == .removed && groups[0].removedAt != nil)
        let orphan = try #require(groups[0].photos.first)
        #expect(orphan.id == s.second && orphan.rating == 3 && orphan.flag == .pick && orphan.inCollection)
        #expect(try s.reader.orphanCount() == 1)
    }

    @Test func deletingOrphansRechecksAndCleansUp() async throws {
        let s = try await makeSetup(backupFiles: [])
        let store = PreviewStore(root: s.library.paths.previews)
        for id in [s.first, s.second] {
            for size in PreviewSize.allCases {
                let url = store.url(for: id, size: size)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("预览".utf8).write(to: url)
            }
        }
        try s.library.setRating(5, for: [s.first])
        try s.library.removeVolume(s.cardVolume.id)
        let listed = try s.reader.orphanGroups().flatMap(\.photos).map(\.id)
        #expect(Set(listed) == [s.first, s.second])

        // 打开窗口之后、确认删除之前：DSC00001 在备份盘上被扫到（找回）。
        try s.backup.put("照片/DSC00001.JPG", date: dateA, padding: 10)
        try await s.temp.scanner().scan(volumeID: s.backupVolume.id, mountURL: s.backup.root)

        let result = try s.library.deleteOrphans(listed, previews: store)
        #expect(result.deleted == [s.second])
        #expect(result.kept == [s.first], "期间被重扫找回的照片不删")
        #expect(try s.reader.rating(of: s.first) == 5)
        #expect(FileManager.default.fileExists(atPath: store.url(for: s.first, size: .thumb).path))
        #expect(!FileManager.default.fileExists(atPath: store.url(for: s.second, size: .thumb).path))
        #expect(!FileManager.default.fileExists(atPath: store.url(for: s.second, size: .preview).path))
        #expect(try s.reader.orphanCount() == 0)
        // 卡 A 还有 DSC00001 的历史位置，卷的记录留着。
        #expect(result.removedVolumes.isEmpty)
        #expect(try s.reader.volume(id: s.cardVolume.id) != nil)
        #expect(try s.temp.expectConsistentCounts())
    }

    @Test func deletingTheLastOrphansOfARemovedVolumeDropsTheVolume() async throws {
        let s = try await makeSetup(backupFiles: [])
        try s.library.removeVolume(s.cardVolume.id)
        let result = try s.library.deleteOrphans([s.first, s.second])
        #expect(result.deleted.count == 2)
        #expect(result.removedVolumes == [s.cardVolume.id])
        #expect(try s.reader.volume(id: s.cardVolume.id) == nil)
        #expect(try s.reader.importBatches().isEmpty)
        #expect(try s.reader.volumes(includeRemoved: true).map(\.id) == [s.backupVolume.id])
    }

    @Test func deletedPhotoIsImportedAgainAsNewWhenScannedAgain() async throws {
        let s = try await makeSetup(backupFiles: [])
        try s.library.setRating(4, for: [s.second])
        try s.library.removeVolume(s.cardVolume.id)
        _ = try s.library.deleteOrphans([s.second])
        // 不做忽略名单：卡重新插上（新卷），删掉的照片作为新照片导入，评分不会回来。
        let again = try s.library.addVolume(uuid: "CARD-A", name: "卡 A", scanRoot: "DCIM")
        let summary = try await s.temp.scanner().scan(volumeID: again.id, mountURL: s.card.root)
        #expect(summary.newPhotos == 1)
        // SQLite 可能把删掉的最大编号再分给新照片，所以软件删除后要清掉这些编号的撤销记录和缓存（AppModel）。
        let reimported = try #require(try s.temp.photoID("DSC00002", dateB))
        #expect(try s.reader.rating(of: reimported) == 0)
        #expect(try s.reader.presentLocationCount(of: s.first) == 2, "没删的 DSC00001 对回原记录")
    }

    // MARK: - 只扫一棵子树

    @Test func subtreeScanOnlyConcludesInsideTheSubtree() async throws {
        let s = try await makeSetup(backupFiles: ["DSC00001.JPG"])
        try s.backup.put("照片/2026/DSC00009.JPG", date: dateC)
        try s.backup.put("照片/补/DSC00002.JPG", date: dateB, padding: 10)
        let before = try s.reader.volume(id: s.backupVolume.id)?.lastScannedAt
        // 照片/2026 不在子树里：既不登记新文件，也不被记为没扫完。
        let summary = try await s.temp.scanner().scan(volumeID: s.backupVolume.id, mountURL: s.backup.root, subtree: "照片/补")
        #expect(summary.added == 1 && summary.incompleteDirectories.isEmpty)
        #expect(try s.temp.photoID("DSC00009", dateC) == nil)
        #expect(try s.reader.scanDirectoryStates(volume: s.backupVolume.id).values.allSatisfy { $0 == "complete" })
        #expect(try s.reader.volume(id: s.backupVolume.id)?.lastScannedAt == before)
        await #expect(throws: ScanError.self) {
            try await s.temp.scanner().scan(volumeID: s.backupVolume.id, mountURL: s.backup.root, subtree: "别处")
        }
    }
}

/// 一个很小的 HFS+ 磁盘映像，测“目标盘写满”。挂在临时目录下，不出现在 Finder 里。
struct TinyDiskImage {
    let file: URL
    let mount: URL

    init(megabytes: Int) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("photoai-tiny-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        file = base.appendingPathComponent("tiny.dmg")
        mount = base.appendingPathComponent("mnt")
        try Self.hdiutil(["create", "-size", "\(megabytes)m", "-fs", "HFS+", "-volname", "PAITINY", "-ov", file.path])
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try Self.hdiutil(["attach", "-nobrowse", "-mountpoint", mount.path, file.path])
    }

    func detach() {
        try? Self.hdiutil(["detach", "-force", mount.path])
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    static func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "hdiutil \(arguments.first ?? "") 失败"])
        }
    }
}
