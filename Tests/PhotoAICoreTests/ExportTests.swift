import CryptoKit
import Foundation
import Testing
@testable import PhotoAICore

/// 导出（计划 · M3 验收）：源文件不变、不覆盖、同名改名、依次尝试在线位置、读不到的位置改为历史、离线跳过、中断后重试。
@Suite struct ExportTests {
    let dateA = "2026-08-12 10:00:01"
    let dateB = "2026-08-12 10:00:02"
    let dateC = "2026-08-13 09:30:00"

    /// 一张卡：DSC00001 是 RAW + JPEG，DSC00002 只有 JPEG，DSC00003 只有 RAW。
    struct Setup {
        let temp: TemporaryLibrary
        let card: FakeCard
        let volume: VolumeRecord
        let output: URL

        func finder(_ extra: [VolumeID: URL] = [:], mounted: @escaping @Sendable (VolumeID) -> Bool = { _ in true }) -> OriginalFinder {
            OriginalFinder(mounts: [volume.id: card.root].merging(extra) { $1 }, isStillMounted: mounted)
        }

        func export(
            _ ids: [PhotoID]? = nil,
            files: ExportRequest.Files = .both,
            layout: ExportRequest.Layout = .flat,
            collection: CollectionID? = nil,
            finder: OriginalFinder? = nil,
            isCancelled: @escaping @Sendable () -> Bool = { false }
        ) throws -> ExportReport {
            let ids = try ids ?? temp.reader.photos(in: .all).map(\.id)
            let request = ExportRequest(photoIDs: ids, files: files, layout: layout, destination: output, collection: collection)
            return try Exporter(library: temp.library, finder: finder ?? self.finder()).run(request, isCancelled: isCancelled)
        }

        func exported(_ folder: String = "") throws -> [String] {
            let url = folder.isEmpty ? output : output.appendingPathComponent(folder)
            return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        }
    }

    func makeSetup() async throws -> Setup {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC00001.ARW", date: dateA, padding: 300)
        try card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA, padding: 100)
        try card.put("DCIM/100MSDCF/DSC00002.JPG", date: dateB, padding: 120)
        try card.put("DCIM/101MSDCF/DSC00003.ARW", date: dateC, padding: 310)
        let volume = try temp.library.addVolume(uuid: "CARD-A", name: "卡 A", scanRoot: "DCIM")
        try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)
        return Setup(temp: temp, card: card, volume: volume, output: temp.root.appendingPathComponent("精修", isDirectory: true))
    }

    func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func modified(_ url: URL) throws -> Date {
        try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
    }

    @Test func copiesEveryFileWithoutTouchingSources() async throws {
        let setup = try await makeSetup()
        let sources = ["DCIM/100MSDCF/DSC00001.ARW", "DCIM/100MSDCF/DSC00001.JPG", "DCIM/100MSDCF/DSC00002.JPG", "DCIM/101MSDCF/DSC00003.ARW"]
        let before = try sources.map { (try digest(setup.card.url($0)), try modified(setup.card.url($0))) }

        let report = try setup.export()

        #expect(report.exportedPhotos == 3)
        #expect(report.copiedFiles == 4)
        #expect(report.failures.isEmpty)
        #expect(report.elapsed > 0)
        #expect(report.bytesCopied == sources.reduce(0) { $0 + (try! Data(contentsOf: setup.card.url($1)).count) })
        #expect(try setup.exported() == ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.JPG", "DSC00003.ARW"])
        for (index, path) in sources.enumerated() {
            let source = setup.card.url(path)
            let target = setup.output.appendingPathComponent(source.lastPathComponent)
            #expect(try digest(source) == before[index].0, "源文件字节不变：\(path)")
            #expect(try modified(source) == before[index].1, "源文件修改时间不变：\(path)")
            #expect(try digest(target) == before[index].0, "目标内容和源文件一样：\(path)")
            #expect(try modified(target) == before[index].1, "目标保留原来的修改时间：\(path)")
        }
        #expect(try setup.temp.expectConsistentCounts())
    }

    @Test func fileChoiceFallsBackToTheOtherKind() async throws {
        let setup = try await makeSetup()
        let raw = try setup.export(files: .raw)
        // DSC00002 没有 RAW，导出 JPEG。
        #expect(try setup.exported() == ["DSC00001.ARW", "DSC00002.JPG", "DSC00003.ARW"])
        #expect(raw.copiedFiles == 3)
        try FileManager.default.removeItem(at: setup.output)

        let jpeg = try setup.export(files: .jpeg)
        // DSC00003 没有 JPEG，导出 RAW。
        #expect(try setup.exported() == ["DSC00001.JPG", "DSC00002.JPG", "DSC00003.ARW"])
        #expect(jpeg.copiedFiles == 3)
    }

    @Test func neverOverwritesAndKeepsPairsTogether() async throws {
        let setup = try await makeSetup()
        try FileManager.default.createDirectory(at: setup.output, withIntermediateDirectories: true)
        // 目标里已经有一张别的 DSC00001.JPG（别的卡上同名的照片）。
        let existing = setup.output.appendingPathComponent("DSC00001.JPG")
        try Data("另一张照片".utf8).write(to: existing)
        let existingDigest = try digest(existing)

        let report = try setup.export()

        #expect(try digest(existing) == existingDigest, "目标上已有的文件一字节都不动")
        #expect(report.renamedFiles == 2)
        // 同一张照片的 RAW 和 JPEG 用同一个编号，配对不被拆开。
        #expect(try setup.exported() == ["DSC00001 (2).ARW", "DSC00001 (2).JPG", "DSC00001.JPG", "DSC00002.JPG", "DSC00003.ARW"])
        #expect(try digest(setup.output.appendingPathComponent("DSC00001 (2).JPG")) == digest(setup.card.url("DCIM/100MSDCF/DSC00001.JPG")))

        // 再导出一次：每个文件都改名，不覆盖第一次导出的。
        try Data("改过的".utf8).write(to: setup.output.appendingPathComponent("DSC00002.JPG"))
        let again = try setup.export([try #require(try setup.temp.photoID("DSC00002", dateB))])
        #expect(again.copiedFiles == 1 && again.renamedFiles == 1)
        #expect(try String(contentsOf: setup.output.appendingPathComponent("DSC00002.JPG"), encoding: .utf8) == "改过的")
        #expect(try setup.exported().contains("DSC00002 (2).JPG"))
    }

    @Test func retryAfterInterruptionSkipsFilesAlreadyCopied() async throws {
        let setup = try await makeSetup()
        // 第一张照片复制完后取消。
        let calls = CancelAfter(3)
        let first = try setup.export(isCancelled: { calls.tick() })
        #expect(first.cancelled)
        #expect(first.exportedPhotos == 1)
        #expect(first.notAttempted == 2)
        // 只把确实复制完成的文件计入成功，目标里没有半截文件。
        #expect(try setup.exported().filter { !$0.hasPrefix(".") }.count == first.copiedFiles)
        #expect(try setup.exported().allSatisfy { !$0.hasSuffix(".photoai-part") })

        // 模拟上次进程被杀留下的临时文件。
        try Data("半截".utf8).write(to: setup.output.appendingPathComponent(".DSC00002.JPG.1234.photoai-part"))
        let retry = try setup.export()
        #expect(!retry.cancelled)
        #expect(retry.identicalFiles == first.copiedFiles)
        #expect(retry.copiedFiles == 4 - first.copiedFiles)
        #expect(retry.renamedFiles == 0)
        #expect(try setup.exported() == ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.JPG", "DSC00003.ARW"])
    }

    @Test func triesTheNextOnlineLocationAndMarksMissingOnesHistorical() async throws {
        let setup = try await makeSetup()
        // 备份盘上有 DSC00002 的副本。
        let backup = try FakeCard()
        try backup.put("备份/DSC00002.JPG", date: dateB, padding: 120)
        let disk = try setup.temp.library.addVolume(uuid: "DISK-B", name: "盘 B", scanRoot: "")
        try await setup.temp.scanner().scan(volumeID: disk.id, mountURL: backup.root)
        let photo = try #require(try setup.temp.photoID("DSC00002", dateB))
        #expect(try setup.temp.reader.presentLocationCount(of: photo) == 2)

        // 在 Finder 里删掉卡上的那张：软件还不知道。
        try setup.card.remove("DCIM/100MSDCF/DSC00002.JPG")
        let report = try setup.export([photo], finder: setup.finder([disk.id: backup.root]))

        #expect(report.copiedFiles == 1)
        #expect(report.fromOtherLocation == 1)
        #expect(report.missingLocations == 1)
        #expect(report.hiddenPhotoIDs.isEmpty)
        #expect(report.failures.isEmpty)
        #expect(try setup.exported() == ["DSC00002.JPG"])
        #expect(try setup.temp.reader.locations(volume: setup.volume.id, relativePath: "DCIM/100MSDCF/DSC00002.JPG").map(\.status) == ["historical"])
        #expect(try setup.temp.reader.presentLocationCount(of: photo) == 1)
        #expect(try setup.temp.expectConsistentCounts())
    }

    @Test func photoWithNoReadableLocationFailsAndBecomesUnlinked() async throws {
        let setup = try await makeSetup()
        let photo = try #require(try setup.temp.photoID("DSC00002", dateB))
        try setup.temp.library.setRating(4, for: [photo])
        try setup.card.remove("DCIM/100MSDCF/DSC00002.JPG")

        let report = try setup.export()

        #expect(report.exportedPhotos == 2)
        #expect(report.failures.map(\.name) == ["DSC00002.JPG"])
        #expect(report.hiddenPhotoIDs == [photo])
        #expect(!(try setup.exported().contains("DSC00002.JPG")))
        // 照片进入“无卷关联照片”，星级还在。
        #expect(try setup.temp.reader.unlinkedPhotoIDs() == [photo])
        #expect(try setup.temp.reader.rating(of: photo) == 4)
        #expect(try setup.temp.expectConsistentCounts())
    }

    @Test func rawMissingExportsTheJpegOfThePair() async throws {
        let setup = try await makeSetup()
        let photo = try #require(try setup.temp.photoID("DSC00001", dateA))
        try setup.card.remove("DCIM/100MSDCF/DSC00001.ARW")

        let report = try setup.export([photo], files: .raw)

        #expect(try setup.exported() == ["DSC00001.JPG"])
        #expect(report.usedOtherKind == 1)
        #expect(report.exportedPhotos == 1)
        #expect(report.missingLocations == 1)
        #expect(report.hiddenPhotoIDs.isEmpty)
    }

    @Test func unmountedVolumeIsNotTreatedAsDeletedFiles() async throws {
        let setup = try await makeSetup()
        let photo = try #require(try setup.temp.photoID("DSC00002", dateB))
        try setup.card.remove("DCIM/100MSDCF/DSC00002.JPG")

        // 导出途中卡被拔掉：路径消失，但卷已经不挂着，不能改成历史位置。
        let report = try setup.export([photo], finder: setup.finder(mounted: { _ in false }))

        #expect(report.copiedFiles == 0)
        #expect(report.missingLocations == 0)
        #expect(report.failures.count == 1)
        #expect(try setup.temp.reader.presentLocationCount(of: photo) == 1)
    }

    @Test func changedFileIsReportedButKeptPresent() async throws {
        let setup = try await makeSetup()
        let photo = try #require(try setup.temp.photoID("DSC00002", dateB))
        try setup.card.put("DCIM/100MSDCF/DSC00002.JPG", date: dateB, padding: 999)

        let report = try setup.export([photo])

        #expect(report.copiedFiles == 0)
        #expect(report.failures.first?.reason.contains("大小变了") == true)
        #expect(report.missingLocations == 0)
        #expect(try setup.temp.reader.presentLocationCount(of: photo) == 1)
    }

    @Test func offlinePhotosArePlannedAndSkipped() async throws {
        let setup = try await makeSetup()
        let other = try FakeCard()
        try other.put("DCIM/100MSDCF/DSC09999.JPG", date: dateC, padding: 50)
        let card = try setup.temp.library.addVolume(uuid: "CARD-C", name: "卡 C", scanRoot: "DCIM")
        try await setup.temp.scanner().scan(volumeID: card.id, mountURL: other.root)
        let ids = try setup.temp.reader.photos(in: .all).map(\.id)
        let sources = try setup.temp.reader.presentSources(of: ids)

        // 卡 C 拔掉了。
        let plan = ExportPlan(photoIDs: ids, sources: sources, files: .both, online: [setup.volume.id], volumeNames: [setup.volume.id: "卡 A", card.id: "卡 C"])
        #expect(plan.onlinePhotoIDs.count == 3)
        #expect(plan.offlinePhotoIDs == [try #require(try setup.temp.photoID("DSC09999", dateC))])
        #expect(plan.volumes.map(\.name) == ["卡 A", "卡 C"])
        #expect(plan.volumes.map(\.isOnline) == [true, false])
        #expect(plan.volumes.map(\.photoCount) == [3, 1])
        #expect(plan.fileCount == 4)

        let report = try setup.export(ids)
        #expect(report.skippedOfflinePhotos == 1)
        #expect(report.exportedPhotos == 3)
        #expect(report.missingLocations == 0)
    }

    @Test func layoutsByCollectionAndOriginalFolders() async throws {
        let setup = try await makeSetup()
        let one = try #require(try setup.temp.photoID("DSC00001", dateA))
        let two = try #require(try setup.temp.photoID("DSC00002", dateB))
        let classic = try setup.temp.library.createCollection(name: "新疆 · 经典")
        let portrait = try setup.temp.library.createCollection(name: "人像/挑选")
        _ = try setup.temp.library.addPhotos([one, two], to: classic)
        _ = try setup.temp.library.addPhotos([one], to: portrait)

        _ = try setup.export(files: .jpeg, layout: .byCollection)
        #expect(try setup.exported() == ["人像-挑选", "新疆 · 经典", "未归入收藏夹"])
        #expect(try setup.exported("新疆 · 经典") == ["DSC00001.JPG", "DSC00002.JPG"])
        #expect(try setup.exported("人像-挑选") == ["DSC00001.JPG"])
        #expect(try setup.exported("未归入收藏夹") == ["DSC00003.ARW"])
        try FileManager.default.removeItem(at: setup.output)

        // 范围是某个收藏夹：只有这一个文件夹。
        _ = try setup.export([one, two], files: .jpeg, layout: .byCollection, collection: classic)
        #expect(try setup.exported() == ["新疆 · 经典"])
        try FileManager.default.removeItem(at: setup.output)

        _ = try setup.export(layout: .original)
        #expect(try setup.exported() == ["卡 A"])
        #expect(try setup.exported("卡 A/DCIM") == ["100MSDCF", "101MSDCF"])
        #expect(try setup.exported("卡 A/DCIM/100MSDCF") == ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.JPG"])
    }

    @Test func unwritableDestinationStopsTheExport() async throws {
        let setup = try await makeSetup()
        try FileManager.default.createDirectory(at: setup.output, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: setup.output.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: setup.output.path) }

        let report = try setup.export()

        #expect(report.stoppedBy?.contains("没有权限") == true)
        #expect(report.copiedFiles == 0)
        #expect(report.notAttempted == 3)
        #expect(try setup.temp.expectConsistentCounts())
    }

    @Test func numberedNames() {
        #expect(Exporter.numberedName("DSC00001.ARW", 1) == "DSC00001.ARW")
        #expect(Exporter.numberedName("DSC00001.ARW", 2) == "DSC00001 (2).ARW")
        #expect(Exporter.numberedName("README", 3) == "README (3)")
        #expect(Exporter.folderName("..a/b:c ") == "a-b-c")
        #expect(Exporter.folderName("") == "未命名")
    }
}

/// 第 n 次询问时开始返回“取消”。
final class CancelAfter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    init(_ n: Int) { remaining = n }
    func tick() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        remaining -= 1
        return remaining < 0
    }
}

/// 100% 放大读原文件：取像素最大的可读文件，途中发现已经不在的位置报出来。
@Suite struct OriginalViewingTests {
    @Test func picksTheLargestReadableFileAndReportsMissingLocations() throws {
        let card = try FakeCard()
        try SampleImages.writeJPEG(to: card.url("DCIM/small.JPG"), width: 64, height: 48, captureDate: nil)
        try SampleImages.writeJPEG(to: card.url("DCIM/big.ARW"), width: 320, height: 240, captureDate: nil)
        func source(_ path: String, file: FileID, location: Int, kind: FileKind) -> OriginalSource {
            let size = (try? card.url(path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return OriginalSource(photoID: 1, fileID: file, kind: kind, fileExtension: (path as NSString).pathExtension,
                                  locationID: location, volumeID: 1, relativePath: path, fileSize: size)
        }
        let sources = [
            source("DCIM/gone.JPG", file: 1, location: 10, kind: .jpeg),
            source("DCIM/small.JPG", file: 1, location: 11, kind: .jpeg),
            source("DCIM/big.ARW", file: 2, location: 12, kind: .raw)
        ]
        let finder = OriginalFinder(mounts: [1: card.root]) { _ in true }

        let lookup = finder.lookupForViewing(sources)

        #expect(lookup.found?.source.locationID == 12)
        #expect(lookup.missingLocationIDs == [10])
        let url = try #require(lookup.found?.url)
        let image = try #require(OriginalDecoder.decode(url))
        #expect(image.width == 320 && image.height == 240)

        // 卷不挂着时不报“不在”。
        let offline = OriginalFinder(mounts: [1: card.root]) { _ in false }.lookupForViewing([sources[0]])
        #expect(offline.found == nil && offline.missingLocationIDs.isEmpty)
    }
}

extension OriginalViewingTests {
    @Test func prefersTheJpegWhenItIsAboutAsLargeAsTheRaw() throws {
        let card = try FakeCard()
        // 相机设成 16:9：JPEG 裁成 16:9，RAW 仍是 3:2，长边一样。
        try SampleImages.writeJPEG(to: card.url("DCIM/A.JPG"), width: 320, height: 180, captureDate: nil)
        try SampleImages.writeJPEG(to: card.url("DCIM/A.ARW"), width: 324, height: 216, captureDate: nil)
        func source(_ path: String, file: FileID, kind: FileKind) -> OriginalSource {
            let size = (try? card.url(path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return OriginalSource(photoID: 1, fileID: file, kind: kind, fileExtension: "", locationID: file, volumeID: 1, relativePath: path, fileSize: size ?? 0)
        }
        // RAW 排在前面也一样：长边差不多，用 JPEG。
        let lookup = OriginalFinder(mounts: [1: card.root]) { _ in true }
            .lookupForViewing([source("DCIM/A.ARW", file: 2, kind: .raw), source("DCIM/A.JPG", file: 1, kind: .jpeg)])
        #expect(lookup.found?.source.kind == .jpeg)
    }
}
