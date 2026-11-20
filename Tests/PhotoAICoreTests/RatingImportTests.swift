import Foundation
import Testing
@testable import PhotoAICore

/// 从文件导入星级（迭代 I-2）。
struct RatingImportTests {
    @Test func parsesOnlyTwoColumnLines() {
        let file = RatingFile(text: """
        # 新疆选片

        DSC01064  1
        DSC01065    4
        \t01066\t5
        1067 3
        dsc01068.arw 2
        _DSC01069.JPG 5
        DSC01070 0
        DSC01071 6
        DSC01072 4 好看
        - DSC01073 4
        IMG_1074 3
        DSC1075 3
        123456 3
        DSC01076 ４
        DSC01077 4.5
        """)
        #expect(file.entries.map(\.key) == ["DSC01064", "DSC01065", "01066", "1067", "dsc01068.arw", "_DSC01069.JPG"])
        #expect(file.entries.map(\.rating) == [1, 4, 5, 3, 2, 5])
        #expect(file.entries.map(\.line) == [3, 4, 5, 6, 7, 8])
        #expect(file.entries.map(\.term) == [
            .baseName("DSC01064"), .baseName("DSC01065"), .number(1066), .number(1067),
            .fileName(baseName: "dsc01068", extension: "arw"), .fileName(baseName: "_DSC01069", extension: "JPG")
        ])
        // 空行不算忽略；标题、星级不在 1–5、多一列、列表符号、别的命名、全角数字都忽略。
        #expect(file.ignored.map(\.line) == [1, 9, 10, 11, 12, 13, 14, 15, 16, 17])
        #expect(file.ignored.first?.text == "# 新疆选片")
        #expect(RatingFile(text: "DSC01064 1\r\nDSC01065 4\r\n").entries.map(\.rating) == [1, 4])
    }

    @Test func plansAndAppliesUndoably() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC01064.ARW", date: "2026-08-12 10:00:01")
        try card.put("DCIM/100MSDCF/DSC01064.JPG", date: "2026-08-12 10:00:01")
        try card.put("DCIM/100MSDCF/DSC01065.JPG", date: "2026-08-12 10:00:02")
        try card.put("DCIM/100MSDCF/DSC01066.JPG", date: "2026-08-12 10:00:03")
        let oldCard = try FakeCard()
        try oldCard.put("DCIM/100MSDCF/DSC01066.JPG", date: "2019-05-01 09:00:00")
        let volume = try temp.library.addVolume(uuid: "CARD", name: "卡", scanRoot: "DCIM")
        let old = try temp.library.addVolume(uuid: "OLD", name: "旧卡", scanRoot: "DCIM")
        try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)
        try await temp.scanner().scan(volumeID: old.id, mountURL: oldCard.root)
        let p1064 = try #require(try temp.photoID("DSC01064", "2026-08-12 10:00:01"))
        let p1065 = try #require(try temp.photoID("DSC01065", "2026-08-12 10:00:02"))
        let p1066 = try #require(try temp.photoID("DSC01066", "2026-08-12 10:00:03"))
        let older1066 = try #require(try temp.photoID("DSC01066", "2019-05-01 09:00:00"))
        try temp.library.setRating(4, for: [p1065])

        let file = RatingFile(text: """
        DSC01064 1
        DSC01065 4
        1066 5
        DSC01099 3
        DSC01064.JPG 2
        说明 一行
        """)
        let plan = try temp.reader.planRatingImport(file)
        // RAW + JPEG 是一张；同一张写了两次以后面的为准；编号循环取最晚的，旧的列为跳过。
        #expect(plan.changes.map(\.photo.id) == [p1064, p1065, p1066])
        #expect(plan.changes.map(\.rating) == [2, 4, 5])
        #expect(plan.changedCount == 2)
        #expect(plan.countsByRating == [2: 1, 4: 1, 5: 1])
        #expect(plan.conflicts.map(\.photo.id) == [p1064])
        #expect(plan.conflicts.first?.ratings == [1, 2])
        #expect(plan.unmatched.map(\.key) == ["DSC01099"])
        #expect(plan.skipped.map(\.id) == [older1066])
        #expect(plan.ignored.map(\.line) == [6])

        try temp.library.apply(plan.edit)
        let after = try temp.reader.match([.range(1064, 1066)]).photos
        #expect(after.map(\.rating) == [2, 4, 5])
        // 撤销回到导入前。
        try temp.library.apply(plan.edit.inverse)
        #expect(try temp.reader.match([.range(1064, 1066)]).photos.map(\.rating) == [0, 4, 0])
    }
}
