import Foundation
import Testing
@testable import PhotoAICore

/// 命令行的匹配规则（产品定位 §3.4，计划 · M5 验收）。
struct MatchingTests {
    @Test func parsesTerms() throws {
        #expect(MatchTerm.parse("DSC01926.ARW") == .fileName(baseName: "DSC01926", extension: "ARW"))
        #expect(MatchTerm.parse("dsc01926.jpg") == .fileName(baseName: "dsc01926", extension: "jpg"))
        #expect(MatchTerm.parse("DSC01926") == .baseName("DSC01926"))
        #expect(MatchTerm.parse("01926") == .number(1926))
        #expect(MatchTerm.parse("1926-1950") == .range(1926, 1950))
        #expect(MatchTerm.parse("01926-01930") == .range(1926, 1930))
        #expect(MatchTerm.parse("1950-1926") == nil)
        // 不是图片扩展名的点、太长的纯数字（手机时间戳文件名）都当文件名。
        #expect(MatchTerm.parse("IMG_1234.edited") == .baseName("IMG_1234.edited"))
        #expect(MatchTerm.parse("1700000000000") == .baseName("1700000000000"))
        #expect(try MatchTerm.parseAll(["1926,1931", "DSC00001  DSC00002"]) == [
            .number(1926), .number(1931), .baseName("DSC00001"), .baseName("DSC00002")
        ])
        #expect(throws: MatchError.badTerm("9-1")) { try MatchTerm.parseAll(["1926", "9-1"]) }
    }

    @Test func matchesFileNameBaseNameAndNumber() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC01926.ARW", date: "2026-08-12 10:00:01")
        try card.put("DCIM/100MSDCF/DSC01926.JPG", date: "2026-08-12 10:00:01")
        try card.put("DCIM/100MSDCF/DSC01927.JPG", date: "2026-08-12 10:00:02")
        try card.put("DCIM/100MSDCF/DSC01930.JPG", date: "2026-08-12 10:00:05")
        let volume = try temp.library.addVolume(uuid: "CARD", name: "卡", scanRoot: "DCIM")
        try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)
        let p1926 = try #require(try temp.photoID("DSC01926", "2026-08-12 10:00:01"))
        let p1927 = try #require(try temp.photoID("DSC01927", "2026-08-12 10:00:02"))
        let p1930 = try #require(try temp.photoID("DSC01930", "2026-08-12 10:00:05"))

        // 文件名、去扩展名的文件名都不分大小写；RAW + JPEG 是一张照片。
        #expect(try temp.reader.match([.fileName(baseName: "dsc01926", extension: "arw")]).photoIDs == [p1926])
        #expect(try temp.reader.match([.baseName("DSC01926")]).photos.first?.extensions == ["ARW", "JPG"])
        // 有这张照片、但没有这个扩展名的文件，算没匹配到。
        let wrongExtension = try temp.reader.match([.fileName(baseName: "DSC01927", extension: "ARW")])
        #expect(wrongExtension.photoIDs.isEmpty)
        #expect(wrongExtension.unmatched == ["DSC01927.ARW"])

        // 范围：命中的按编号排，没命中的连成段。
        let range = try temp.reader.match([.range(1924, 1932)])
        #expect(range.photoIDs == [p1926, p1927, p1930])
        #expect(range.unmatched == ["1924-1925", "1928-1929", "1931-1932"])
        #expect(try temp.reader.match([.range(1926, 1927)]).unmatched.isEmpty)

        // 同一张照片被几项命中只算一次。
        let repeated = try temp.reader.match([.number(1926), .baseName("DSC01926"), .number(1930)])
        #expect(repeated.photoIDs == [p1926, p1930])
        #expect(try temp.reader.match([.number(42)]).unmatched == ["42"])
    }

    /// 编号循环：同号的旧照片和新照片取拍摄时间最晚的一张，旧的列为跳过；隐藏的照片不参与。
    @Test func numberCycleTakesLatestVisible() async throws {
        let temp = try TemporaryLibrary()
        let oldCard = try FakeCard()
        let newCard = try FakeCard()
        try oldCard.put("DCIM/100MSDCF/DSC01926.JPG", date: "2019-05-01 09:00:00")
        try newCard.put("DCIM/100MSDCF/DSC01926.JPG", date: "2026-08-12 10:00:01")
        try newCard.put("DCIM/101MSDCF/IMG_1926.JPG", date: "2024-01-01 12:00:00")
        try newCard.put("DCIM/101MSDCF/IMG_1927.JPG", date: "")
        let old = try temp.library.addVolume(uuid: "OLD", name: "旧卡", scanRoot: "DCIM")
        let new = try temp.library.addVolume(uuid: "NEW", name: "新卡", scanRoot: "DCIM")
        try await temp.scanner().scan(volumeID: old.id, mountURL: oldCard.root)
        try await temp.scanner().scan(volumeID: new.id, mountURL: newCard.root)
        let older = try #require(try temp.photoID("DSC01926", "2019-05-01 09:00:00"))
        let latest = try #require(try temp.photoID("DSC01926", "2026-08-12 10:00:01"))
        let phone = try #require(try temp.photoID("IMG_1926", "2024-01-01 12:00:00"))

        let byNumber = try temp.reader.match([.number(1926)])
        #expect(byNumber.photoIDs == [latest])
        #expect(byNumber.skipped.map(\.id) == [phone, older])
        // 名字相同、拍摄时间不同的也是两张，同样取最晚的。
        let byName = try temp.reader.match([.baseName("DSC01926")])
        #expect(byName.photoIDs == [latest])
        #expect(byName.skipped.map(\.id) == [older])
        // 被一项跳过、又被另一项选中的，不算跳过。
        #expect(try temp.reader.match([.number(1926), .baseName("IMG_1926")]).skipped.map(\.id) == [older])
        // 没有拍摄时间的也能按编号找到。
        #expect(try temp.reader.match([.number(1927)]).photos.first?.captureDate == nil)

        // 新卡移除后，新照片隐藏：同号只剩旧的那张可见，就选它。
        try temp.library.removeVolume(new.id)
        let afterRemoval = try temp.reader.match([.number(1926), .baseName("IMG_1927")])
        #expect(afterRemoval.photoIDs == [older])
        #expect(afterRemoval.skipped.isEmpty)
        #expect(afterRemoval.unmatched == ["IMG_1927"])
    }

    @Test func rateAndCollect() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        for n in 1...4 { try card.put("DCIM/DSC0000\(n).JPG", date: "2026-08-12 10:00:0\(n)") }
        let volume = try temp.library.addVolume(uuid: "CARD", name: "卡", scanRoot: "DCIM")
        try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)
        let ids = try temp.reader.match([.range(1, 4)]).photoIDs
        #expect(ids.count == 4)

        try temp.library.setRating(5, for: Array(ids.prefix(2)))
        #expect(try temp.reader.match([.range(1, 4)]).photos.map(\.rating) == [5, 5, 0, 0])

        let created = try temp.library.collect(Array(ids.prefix(3)), intoCollectionNamed: " 新疆精选 ")
        #expect(created.created)
        #expect(created.added == Array(ids.prefix(3)))
        #expect(try temp.reader.collections().map(\.name) == ["新疆精选"])
        // 再加一次：用同一个收藏夹，原本就在的不算新加入。
        let again = try temp.library.collect(ids, intoCollectionNamed: "新疆精选")
        #expect(!again.created)
        #expect(again.collection == created.collection)
        #expect(again.added == [ids[3]])
        #expect(try temp.reader.collections().first?.photoCount == 4)

        // 名字区分大小写；重名时报错，不猜。
        _ = try temp.library.createCollection(name: "新疆精选")
        #expect(throws: CollectError.ambiguousName("新疆精选", count: 2)) {
            try temp.library.collect(ids, intoCollectionNamed: "新疆精选")
        }
        #expect(throws: CollectError.emptyName) { try temp.library.collect(ids, intoCollectionNamed: "  ") }
        #expect(try temp.reader.collections().count == 2)
    }

    /// 命令行和软件是两个连接：各写不同字段互不覆盖，同一个字段后写的赢；软件那边的 `data_version` 会变。
    @Test func cliAndAppWriteDifferentFields() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/DSC01926.JPG", date: "2026-08-12 10:00:01")
        let volume = try temp.library.addVolume(uuid: "CARD", name: "卡", scanRoot: "DCIM")
        try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)
        let app = temp.library
        let photo = try #require(try app.reader.match([.number(1926)]).photoIDs.first)
        let label = try #require(try app.reader.labels().first?.id)
        let versionBefore = try app.dataVersion()

        let cli = try Library(paths: app.paths)
        try app.setFlag(.pick, for: [photo])
        try app.apply(.labels(added: [PhotoLabel(photo, label)], removed: []))
        try cli.setRating(5, for: try cli.reader.match([.number(1926)]).photoIDs)
        _ = try cli.collect([photo], intoCollectionNamed: "精选")
        #expect(try app.dataVersion() != versionBefore)

        let detail = try #require(try app.reader.detail(of: photo))
        #expect(detail.summary.rating == 5)
        #expect(detail.summary.flag == .pick)
        #expect(try app.reader.photoLabels()[photo] == [label])
        #expect(try app.reader.collectionNames(of: photo) == ["精选"])

        try app.setRating(2, for: [photo])
        #expect(try cli.reader.match([.number(1926)]).photos.first?.rating == 2)
    }
}
