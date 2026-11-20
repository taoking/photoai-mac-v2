import Foundation
import Testing
@testable import PhotoAICore

/// 性能目标的数据层部分（计划 · 性能目标）。要先用 `photoai dev-synth <目录>` 生成十万条合成库，
/// 再设置 `PHOTOAI_PERF_LIBRARY=<目录>` 运行；没设置时跳过。结果以 `PF` 开头打印，写进验收记录。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOAI_PERF_LIBRARY"] != nil), .serialized)
struct PerformanceTests {
    var sourcePaths: LibraryPaths {
        LibraryPaths(root: URL(fileURLWithPath: ProcessInfo.processInfo.environment["PHOTOAI_PERF_LIBRARY"]!, isDirectory: true))
    }

    /// 同一个查询跑 5 次，取中位数和最大值（第一次是冷的）。
    func measure(_ label: String, _ body: () throws -> Int) rethrows -> (median: Double, max: Double) {
        var times: [Double] = []
        var count = 0
        for _ in 0..<5 {
            let start = Date()
            count = try body()
            times.append(Date().timeIntervalSince(start) * 1000)
        }
        let sorted = times.sorted()
        print(String(format: "PF %@：中位 %.1f ms，最大 %.1f ms，首次 %.1f ms，%d 条", label, sorted[2], sorted[4], times[0], count))
        return (sorted[2], sorted[4])
    }

    /// PF-3（卷、日期）：切换侧栏项的查询部分，≤ 200 ms。PF-1 的数据部分也在这里。
    @Test func sidebarQueries() throws {
        let library = try Library(paths: sourcePaths)
        let reader = try library.makeReader()
        #expect(try reader.visiblePhotoCount() >= 100_000)
        let volumes = try reader.volumes()
        let month = try #require(try reader.dayCounts().dropFirst(200).first?.day.prefix(7))
        let day = try #require(try reader.dayCounts().dropFirst(300).first?.day)

        var results: [(Double, Double)] = []
        results.append(try measure("全部照片") { try reader.photos(in: .all).count })
        results.append(try measure("卷 \(volumes[0].name)") { try reader.photos(in: .volume(volumes[0].id)).count })
        results.append(try measure("卷 \(volumes[4].name)") { try reader.photos(in: .volume(volumes[4].id)).count })
        results.append(try measure("月 \(month)") { try reader.photos(in: .datePrefix(String(month))).count })
        results.append(try measure("日 \(day)") { try reader.photos(in: .datePrefix(day)).count })
        results.append(try measure("文件名排序") { try reader.photos(in: .all, sort: .fileName).count })
        for (median, _) in results { #expect(median <= 200) }

        // 侧栏本身的数据（启动时读一次，扫描后刷新）。
        _ = try measure("时间树") { try reader.dayCounts().count }
        _ = try measure("各卷张数") { try reader.photoCountsByVolume().count }
        _ = try measure("各卷收录与预览就绪") { try volumes.map { try reader.volumeStats($0.id) }.count }
        _ = try measure("照片所在卷（离线标记）") { try reader.photoVolumes().count }
    }

    /// M6 搜索：认条件加查询，和切换侧栏项一样按 PF-3 的 ≤ 200 ms 要求；后台分析的进度、搜索词表、人物网格也测一下。
    @Test func searchQueries() throws {
        let reader = try Library(paths: sourcePaths).makeReader()
        let vocabulary = try reader.searchVocabulary()
        for text in ["2025-08", "8月12日", "DSC0100", "1926-1950", "A7R5", "门票", "2025-08 DSC0", "\"出口 B\""] {
            let (median, _) = try measure("搜索 \(text)") {
                try reader.photos(in: .search(SearchParser.parse(text, vocabulary: vocabulary))).count
            }
            #expect(median <= 200)
        }
        _ = try measure("搜索词表") { try reader.searchVocabulary().cameras.count }
        _ = try measure("分析进度（OCR）") { try reader.analysisCounts(.ocr).total }
        _ = try measure("人物网格") { try reader.people().count }
    }

    /// PF-3（收藏夹）：切换到收藏夹的查询，≤ 200 ms。
    @Test func collectionQueries() throws {
        let reader = try Library(paths: sourcePaths).makeReader()
        let collections = try reader.collections()
        #expect(collections.count >= 3)
        for collection in collections {
            let (median, _) = try measure("收藏夹 \(collection.name)") { try reader.photos(in: .collection(collection.id)).count }
            #expect(median <= 200)
        }
        _ = try measure("收藏夹列表与张数") { try reader.collections().count }
        _ = try measure("所有照片的标签") { try reader.photoLabels().count }
    }

    /// PF-8：对 10 万条重新筛选，≤ 100 ms。筛选在内存里做，不查数据库。
    @Test func refilterHundredThousand() throws {
        let reader = try Library(paths: sourcePaths).makeReader()
        let photos = try reader.photos(in: .all)
        var filters: [(String, PhotoFilter)] = []
        var classicFive = PhotoFilter()
        classicFive.toggleLabel(1)
        classicFive.toggleStar(5)
        filters.append(("经典 + ★5", classicFive))
        var several = PhotoFilter()
        several.toggleStar(3)
        several.toggleLabel(1)
        several.toggleLabel(2)
        several.noLabel = true
        several.toggleFlag(.pick)
        several.toggleFlag(.none)
        several.toggleKind(.rawPlusJPEG)
        filters.append(("四类条件都有", several))
        for (name, filter) in filters {
            let (median, maximum) = measure("筛选 \(name)") { photos.filter(filter.matches).count }
            #expect(median <= 100)
            #expect(maximum <= 100)
        }
    }

    /// 合成库的数据库复制一份到临时库（会改库的测量用）。
    /// 复制到临时库旁边一个没被打开过的目录：盖掉已经打开的数据库文件会让那个连接读到坏的 WAL。
    func copyOfSyntheticLibrary() throws -> (TemporaryLibrary, Library) {
        let temp = try TemporaryLibrary()
        let paths = LibraryPaths(root: temp.root.appendingPathComponent("perf-copy", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        for suffix in ["", "-wal"] {
            let source = URL(fileURLWithPath: sourcePaths.database.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: paths.database.path + suffix))
            }
        }
        return (temp, try Library(paths: paths))
    }

    /// PF-10：移除一个含 1 万张以上照片的卷，≤ 1 秒。合成库每个卷约 16,700 张。
    @Test func removeVolumeWithTenThousandPhotos() throws {
        // 临时库一释放就会删掉整个目录，测量期间要留着。
        let (scratch, library) = try copyOfSyntheticLibrary()
        defer { withExtendedLifetime(scratch) {} }
        let volume = try #require(try library.reader.volumes().first)
        let count = try library.reader.volumeStats(volume.id).photoCount
        #expect(count >= 10_000)
        let impactStart = Date()
        let impact = try library.reader.removalImpact(volume: volume.id)
        let impactTime = Date().timeIntervalSince(impactStart)
        let start = Date()
        try library.removeVolume(volume.id)
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "PF-10 移除卷 %@（%d 张，其中 %d 张进入无卷关联）：%.0f ms；确认框的影响统计 %.0f ms",
                     volume.name, count, impact.orphanedCount, elapsed * 1000, impactTime * 1000))
        #expect(elapsed <= 1)
        #expect(try library.reader.orphanCount() == impact.orphanedCount)
        #expect(try library.reader.inconsistentLocationCounts().isEmpty)
    }

    /// PF-11：清卡检查 1 万张、在线副本在 SSD 上，≤ 10 秒。
    /// 十万条库的副本里加一张 1 万组 RAW + JPEG 的卡和一块全部有副本的备份盘（都在本机 SSD 上），每个文件都要当场确认。
    @Test func clearCardCheckTenThousandPhotos() async throws {
        // 临时库一释放就会删掉整个目录，测量期间要留着。
        let (scratch, library) = try copyOfSyntheticLibrary()
        defer { withExtendedLifetime(scratch) {} }
        let card = try FakeCard(), backup = try FakeCard()
        for index in 0..<10_000 {
            let date = String(format: "2027-02-%02d %02d:%02d:%02d", 1 + index / 3600 % 28, index / 60 % 60, index % 60, index % 60)
            for ext in ["ARW", "JPG"] {
                let name = String(format: "PF11_%05d.%@", index, ext)
                try card.put("DCIM/\(100 + index / 1000)MSDCF/\(name)", date: date)
                try backup.put("照片/\(100 + index / 1000)/\(name)", date: date)
            }
        }
        let cardVolume = try library.addVolume(uuid: "PF11-CARD", name: "PF-11 卡", scanRoot: "DCIM")
        let backupVolume = try library.addVolume(uuid: "PF11-BACKUP", name: "PF-11 备份盘", scanRoot: "照片")
        let scanner = VolumeScanner(library: library, metadataReader: FakeMetadataReader())
        try await scanner.scan(volumeID: cardVolume.id, mountURL: card.root)
        try await scanner.scan(volumeID: backupVolume.id, mountURL: backup.root)

        let finder = OriginalFinder(mounts: [cardVolume.id: card.root, backupVolume.id: backup.root]) { _ in true }
        let start = Date()
        let report = try ClearCardChecker(library: library, finder: finder).check(volumeID: cardVolume.id)
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "PF-11 清卡检查 %d 张、%d 个文件（十万条库，副本在本机 SSD）：%.0f ms，已核实 %d",
                     report.photoCount, report.fileCount, elapsed * 1000, report.verifiedFileCount))
        #expect(report.photoCount == 10_000 && report.verifiedFileCount == 20_000)
        #expect(elapsed <= 10)
    }

    /// PF-4：已知的卡插上后自动重扫 1,000 张未变化的照片，≤ 3 秒。
    /// 在合成库的副本里加一张 1,000 个文件的卡（放在本机 SSD 上），先导入，再计时重扫。
    @Test func rescanThousandUnchangedFiles() async throws {
        let temp = try TemporaryLibrary()
        let paths = temp.library.paths
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: sourcePaths.database.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.removeItem(atPath: paths.database.path + suffix)
                try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: paths.database.path + suffix))
            }
        }
        let library = try Library(paths: paths)
        let card = try FakeCard()
        for index in 0..<1_000 {
            let folder = 100 + index / 250
            try card.put(String(format: "DCIM/%dMSDCF/PF4_%05d.ARW", folder, index),
                         date: String(format: "2027-01-01 10:%02d:%02d", index / 60 % 60, index % 60))
        }
        let volume = try library.addVolume(uuid: "PF4-CARD", name: "PF-4 卡", scanRoot: "DCIM")
        let scanner = VolumeScanner(library: library, metadataReader: FakeMetadataReader())
        let first = try await scanner.scan(volumeID: volume.id, mountURL: card.root)
        #expect(first.newPhotos == 1_000)

        let start = Date()
        let rescan = try await VolumeScanner(library: library).scan(volumeID: volume.id, mountURL: card.root)
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "PF-4 重扫 1,000 张未变化（十万条库，本机 SSD）：%.0f ms，未变 %d，完整 %@", elapsed * 1000, rescan.unchanged, rescan.isComplete ? "是" : "否"))
        #expect(rescan.unchanged == 1_000)
        #expect(elapsed <= 3)
    }
}
