import Foundation
import Testing
@testable import PhotoAICore

/// 扫描与可见性。对应计划 · M1 验收的数据层用例，以及数据模型 §5、§6。
@Suite struct ScanTests {
    let dateA = "2026-08-12 10:00:01"
    let dateB = "2026-08-12 10:00:02"
    let dateC = "2026-08-13 09:30:00"

    @Test func importsAndGroupsRawWithJpeg() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC00001.ARW", date: dateA)
        try card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try card.put("DCIM/100MSDCF/DSC00002.JPG", date: dateB)
        try card.put("DCIM/100MSDCF/notes.txt", date: nil)

        let volume = try temp.library.addVolume(uuid: "CARD-A", name: "卡 A", scanRoot: "DCIM")
        let summary = try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)

        #expect(summary.isComplete)
        #expect(summary.added == 3)
        #expect(summary.newPhotos == 2)
        let photos = try temp.reader.photos(in: .all)
        #expect(photos.map(\.baseName) == ["DSC00002", "DSC00001"])
        #expect(photos[1].hasRaw && photos[1].hasJPEG)
        #expect(!photos[0].hasRaw && photos[0].hasJPEG)
        #expect(try temp.reader.presentLocationCount(of: photos[1].id) == 2)
        #expect(try temp.reader.volume(id: volume.id)?.lastScannedAt != nil)
        #expect(try temp.reader.importBatches().map(\.photoCount) == [2])
        #expect(try temp.expectConsistentCounts())
    }

    @Test func rescanSkipsUnchangedFiles() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        for index in 1...7 {
            try card.put("DCIM/100MSDCF/DSC0000\(index).JPG", date: "2026-08-12 10:00:0\(index)")
        }
        let volume = try temp.library.addVolume(uuid: "CARD-A", name: "卡 A", scanRoot: "DCIM")
        let reader = FakeMetadataReader()
        try await temp.scanner(reader: reader).scan(volumeID: volume.id, mountURL: card.root)
        #expect(reader.readNames.count == 7)

        reader.resetReads()
        try card.put("DCIM/100MSDCF/DSC00008.JPG", date: "2026-08-12 10:00:08")
        let summary = try await temp.scanner(reader: reader).scan(volumeID: volume.id, mountURL: card.root)
        #expect(reader.readNames == ["DSC00008.JPG"])
        #expect(summary.unchanged == 7)
        #expect(summary.added == 1)
        #expect(summary.newPhotos == 1)
        // 第二次只有一张新照片，“最近导入”多一个批次。
        #expect(try temp.reader.importBatches().map(\.photoCount) == [1, 7])

        reader.resetReads()
        let quiet = try await temp.scanner(reader: reader).scan(volumeID: volume.id, mountURL: card.root)
        #expect(reader.readNames.isEmpty)
        #expect(quiet.importBatchID == nil)
        #expect(try temp.reader.importBatches().count == 2)
    }

    @Test func missingFileBecomesHistoricalAndKeepsRating() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try card.put("DCIM/100MSDCF/DSC00002.JPG", date: dateB)
        let volume = try temp.library.addVolume(uuid: "CARD-A", name: "卡 A", scanRoot: "DCIM")
        try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)
        let first = try #require(try temp.photoID("DSC00001", dateA))
        try temp.library.setRating(4, for: [first])

        try card.remove("DCIM/100MSDCF/DSC00001.JPG")
        let summary = try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)

        #expect(summary.vanished == 1)
        #expect(try temp.reader.photos(in: .all).map(\.baseName) == ["DSC00002"])
        #expect(try temp.reader.unlinkedPhotoIDs() == [first])
        #expect(try temp.reader.rating(of: first) == 4)
        #expect(try temp.reader.locations(volume: volume.id, relativePath: "DCIM/100MSDCF/DSC00001.JPG").map(\.status) == ["historical"])
        #expect(try temp.expectConsistentCounts())
    }

    /// 原样放回：大小和修改时间都和删掉前一样，也必须恢复，旧评分随之回来。
    @Test func fileRestoredUnchangedRecoversRating() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        let path = "DCIM/100MSDCF/DSC00001.JPG"
        let mtime = try card.put(path, date: dateA)
        let volume = try temp.library.addVolume(uuid: "CARD-A", name: "卡 A", scanRoot: "DCIM")
        try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)
        let photo = try #require(try temp.photoID("DSC00001", dateA))
        try temp.library.setRating(5, for: [photo])
        let collection = try temp.library.createCollection(name: "新疆精选")
        try temp.library.addPhotos([photo], to: collection)

        try card.remove(path)
        try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)
        #expect(try temp.reader.visiblePhotoCount() == 0)
        #expect(try temp.reader.collectionMembers(collection).isEmpty)

        try card.put(path, date: dateA, mtime: mtime)
        let summary = try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)

        #expect(summary.restored == 1)
        #expect(summary.added == 0)
        #expect(try temp.reader.photos(in: .all).map(\.id) == [photo])
        #expect(try temp.reader.rating(of: photo) == 5)
        #expect(try temp.reader.collectionMembers(collection) == [photo])
        #expect(try temp.reader.locations(volume: volume.id, relativePath: path).map(\.status) == ["present"])
        #expect(try temp.expectConsistentCounts())
    }

    /// 同一路径换了照片（卡删光后编号重置）：旧位置变历史，新照片不继承旧评分。
    @Test func samePathNewPhotoDoesNotInheritRating() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        let path = "DCIM/100MSDCF/DSC00001.JPG"
        try card.put(path, date: dateA)
        let volume = try temp.library.addVolume(uuid: "CARD-A", name: "卡 A", scanRoot: "DCIM")
        try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)
        let old = try #require(try temp.photoID("DSC00001", dateA))
        try temp.library.setRating(5, for: [old])

        try card.put(path, date: dateC)
        let summary = try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)

        #expect(summary.replaced == 1)
        let new = try #require(try temp.photoID("DSC00001", dateC))
        #expect(new != old)
        #expect(try temp.reader.rating(of: new) == 0)
        #expect(try temp.reader.rating(of: old) == 5)
        #expect(try temp.reader.photos(in: .all).map(\.id) == [new])
        #expect(try temp.reader.unlinkedPhotoIDs() == [old])
        let history = try temp.reader.locations(volume: volume.id, relativePath: path)
        #expect(history.map(\.status) == ["historical", "present"])
        #expect(try temp.expectConsistentCounts())

        // 旧照片又放回这个路径：新照片的位置变历史，旧照片恢复，评分还在。
        try card.put(path, date: dateA)
        let back = try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)
        #expect(back.replaced == 1 && back.restored == 1)
        #expect(try temp.reader.photos(in: .all).map(\.id) == [old])
        #expect(try temp.reader.rating(of: old) == 5)
        #expect(try temp.expectConsistentCounts())
    }

    @Test func deletedSubdirectoryBecomesHistorical() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try card.put("DCIM/101MSDCF/DSC00002.JPG", date: dateB)
        try card.put("DCIM/101MSDCF/deep/DSC00003.JPG", date: dateC)
        let volume = try temp.library.addVolume(uuid: "CARD-A", name: "卡 A", scanRoot: "DCIM")
        try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)
        #expect(try temp.reader.visiblePhotoCount() == 3)
        #expect(Set(try temp.reader.scanDirectoryStates(volume: volume.id).keys)
            == ["DCIM", "DCIM/100MSDCF", "DCIM/101MSDCF", "DCIM/101MSDCF/deep"])

        try FileManager.default.removeItem(at: card.url("DCIM/101MSDCF"))
        let summary = try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)

        #expect(summary.vanished == 2)
        #expect(summary.isComplete)
        #expect(try temp.reader.photos(in: .all).map(\.baseName) == ["DSC00001"])
        #expect(Set(try temp.reader.scanDirectoryStates(volume: volume.id).keys) == ["DCIM", "DCIM/100MSDCF"])
        #expect(try temp.expectConsistentCounts())
    }

    /// 扫描中断：含两个子目录的卷，在第二个子目录前中断。
    /// 未读部分的照片、位置、收藏夹可见性都不变，卷不记为扫完。
    @Test(arguments: [InterruptingLister.Mode.cancel, .throwError])
    func interruptedScanKeepsUnreadDirectories(mode: InterruptingLister.Mode) async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try card.put("DCIM/101MSDCF/DSC00002.JPG", date: dateB)
        try card.put("DCIM/101MSDCF/DSC00003.JPG", date: dateC)
        let volume = try temp.library.addVolume(uuid: "CARD-A", name: "卡 A", scanRoot: "DCIM")
        try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)
        let firstScan = try #require(try temp.reader.volume(id: volume.id)?.lastScannedAt)
        let second = try #require(try temp.photoID("DSC00002", dateB))
        let collection = try temp.library.createCollection(name: "精选")
        try temp.library.addPhotos([second], to: collection)
        try temp.library.setRating(3, for: [second])

        // 卡上 101 里的文件其实已经删了，但这次扫描到不了那里，不能下结论。
        try card.remove("DCIM/101MSDCF/DSC00002.JPG")
        try card.remove("DCIM/101MSDCF/DSC00003.JPG")
        let flag = CancelFlag()
        let lister = InterruptingLister(failingDirectory: "DCIM/101MSDCF", mode: mode, cancelFlag: flag)
        let summary = try await temp.scanner(lister: lister)
            .scan(volumeID: volume.id, mountURL: card.root, isCancelled: { flag.isCancelled })

        #expect(!summary.isComplete)
        #expect(summary.vanished == 0)
        #expect(summary.incompleteDirectories.keys.contains("DCIM/101MSDCF"))
        #expect(try temp.reader.visiblePhotoCount() == 3)
        #expect(try temp.reader.collectionMembers(collection) == [second])
        #expect(try temp.reader.rating(of: second) == 3)
        #expect(try temp.reader.locations(volume: volume.id, relativePath: "DCIM/101MSDCF/DSC00002.JPG").map(\.status) == ["present"])
        #expect(try temp.reader.scanDirectoryStates(volume: volume.id)["DCIM/101MSDCF"] == "incomplete")
        #expect(try temp.reader.scanDirectoryStates(volume: volume.id)["DCIM/100MSDCF"] == "complete")
        #expect(try temp.reader.volume(id: volume.id)?.lastScannedAt == firstScan)
        #expect(try temp.reader.volumeStats(volume.id).incompleteDirectoryCount == 1)
        #expect(try temp.expectConsistentCounts())

        // 下次完整扫完，才确认那两个文件确实不在了。
        let resumed = try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)
        #expect(resumed.isComplete)
        #expect(resumed.vanished == 2)
        #expect(try temp.reader.visiblePhotoCount() == 1)
        #expect(try temp.reader.collectionMembers(collection).isEmpty)
        #expect(try temp.reader.volumeStats(volume.id).incompleteDirectoryCount == 0)
    }

    /// 上级目录读不了时，它下面的已知子目录也不下结论。
    @Test func unreadableParentKeepsDescendants() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try card.put("DCIM/100MSDCF/sub/DSC00002.JPG", date: dateB)
        let volume = try temp.library.addVolume(uuid: "CARD-A", name: "卡 A", scanRoot: "DCIM")
        try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)

        let lister = InterruptingLister(failingDirectory: "DCIM/100MSDCF", mode: .throwError, cancelFlag: CancelFlag())
        let summary = try await temp.scanner(lister: lister).scan(volumeID: volume.id, mountURL: card.root)

        #expect(!summary.isComplete)
        #expect(Set(summary.incompleteDirectories.keys) == ["DCIM/100MSDCF", "DCIM/100MSDCF/sub"])
        #expect(try temp.reader.visiblePhotoCount() == 2)
    }

    /// 读文件时出错（比如读到一半拔卡）不能当成“没有拍摄时间”，否则会误判成同一路径换了照片。
    @Test func unreadableFileLeavesDirectoryIncomplete() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        let path = "DCIM/100MSDCF/DSC00001.JPG"
        try card.put(path, date: dateA)
        let volume = try temp.library.addVolume(uuid: "CARD-A", name: "卡 A", scanRoot: "DCIM")
        try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)
        let photo = try #require(try temp.photoID("DSC00001", dateA))

        try card.put(path, date: dateA)  // 修改时间变了，要重读
        let summary = try await temp.scanner(reader: FakeMetadataReader(failingNames: ["DSC00001.JPG"]))
            .scan(volumeID: volume.id, mountURL: card.root)

        #expect(!summary.isComplete)
        #expect(summary.replaced == 0)
        #expect(try temp.reader.photos(in: .all).map(\.id) == [photo])
        #expect(try temp.reader.scanDirectoryStates(volume: volume.id)["DCIM/100MSDCF"] == "incomplete")
    }

    @Test func copiesOnTwoVolumesAndRemovingOne() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        let backup = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC00001.ARW", date: dateA)
        try card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try card.put("DCIM/100MSDCF/DSC00002.JPG", date: dateB)
        try backup.put("照片/2026-08/DSC00001.JPG", date: dateA)

        let cardVolume = try temp.library.addVolume(uuid: "CARD-A", name: "卡 A", scanRoot: "DCIM")
        let backupVolume = try temp.library.addVolume(uuid: "DISK-2", name: "备份盘 2", scanRoot: "照片")
        try await temp.scanner().scan(volumeID: cardVolume.id, mountURL: card.root)
        try await temp.scanner().scan(volumeID: backupVolume.id, mountURL: backup.root)

        let first = try #require(try temp.photoID("DSC00001", dateA))
        let second = try #require(try temp.photoID("DSC00002", dateB))
        try temp.library.setRating(5, for: [first, second])
        #expect(try temp.reader.presentLocationCount(of: first) == 3)
        #expect(try temp.reader.photoCountsByVolume() == [cardVolume.id: 2, backupVolume.id: 1])

        try temp.library.removeVolume(cardVolume.id)
        #expect(try temp.reader.photos(in: .all).map(\.id) == [first])
        #expect(try temp.reader.presentLocationCount(of: first) == 1)
        #expect(try temp.reader.unlinkedPhotoIDs() == [second])
        #expect(try temp.reader.rating(of: second) == 5)
        #expect(try temp.reader.volumes().map(\.id) == [backupVolume.id])
        #expect(try temp.expectConsistentCounts())

        // 移除后的卡重新插上：建新记录，照片对回原记录，评分还在。
        #expect(try temp.reader.activeVolume(uuid: "CARD-A") == nil)
        let again = try temp.library.addVolume(uuid: "CARD-A", name: "卡 A", scanRoot: "DCIM")
        #expect(again.id != cardVolume.id)
        let summary = try await temp.scanner().scan(volumeID: again.id, mountURL: card.root)
        #expect(summary.newPhotos == 0)
        #expect(Set(try temp.reader.photos(in: .all).map(\.id)) == [first, second])
        #expect(try temp.reader.rating(of: second) == 5)
        #expect(try temp.reader.presentLocationCount(of: first) == 3)
        #expect(try temp.expectConsistentCounts())
    }

    @Test func scanningRemovedVolumeIsRefused() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        let volume = try temp.library.addVolume(uuid: "CARD-A", name: "卡 A", scanRoot: "DCIM")
        try temp.library.removeVolume(volume.id)
        await #expect(throws: ScanError.self) {
            try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)
        }
    }

    @Test func wholeVolumeScanRoot() async throws {
        let temp = try TemporaryLibrary()
        let disk = try FakeCard()
        try disk.put("a.JPG", date: dateA)
        try disk.put("2026/b.JPG", date: dateB)
        let volume = try temp.library.addVolume(uuid: "DISK", name: "盘", scanRoot: "/")
        try await temp.scanner().scan(volumeID: volume.id, mountURL: disk.root)
        #expect(try temp.reader.visiblePhotoCount() == 2)

        try FileManager.default.removeItem(at: disk.url("2026"))
        let summary = try await temp.scanner().scan(volumeID: volume.id, mountURL: disk.root)
        #expect(summary.vanished == 1)
        #expect(try temp.reader.photos(in: .all).map(\.baseName) == ["a"])
    }
}
