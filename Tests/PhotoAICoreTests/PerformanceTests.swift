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
