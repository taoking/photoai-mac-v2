import Foundation
import Testing
@testable import PhotoAICore

/// 选片：星级、标记、标签、收藏夹、撤销、筛选。对应计划 · M2 的数据部分。
@Suite struct CullingTests {
    /// 一张卡上 3 张照片：DSC00001 是 RAW + JPG，其余只有 JPG。
    func library() async throws -> (TemporaryLibrary, FakeCard, VolumeRecord, [PhotoID]) {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/DSC00001.ARW", date: "2026-08-12 10:00:01")
        try card.put("DCIM/DSC00001.JPG", date: "2026-08-12 10:00:01")
        try card.put("DCIM/DSC00002.JPG", date: "2026-08-12 10:00:02")
        try card.put("DCIM/DSC00003.JPG", date: "2026-08-12 10:00:03")
        let volume = try temp.library.addVolume(uuid: "CARD", name: "卡", scanRoot: "DCIM")
        try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)
        let ids = try temp.reader.photos(in: .all, sort: .captureDateAscending).map(\.id)
        return (temp, card, volume, ids)
    }

    func summary(_ temp: TemporaryLibrary, _ id: PhotoID) throws -> PhotoSummary {
        try #require(try temp.reader.photos(in: .all).first { $0.id == id })
    }

    @Test func defaultLabelSlots() throws {
        let temp = try TemporaryLibrary()
        let labels = try temp.reader.labels()
        #expect(labels.count == 9)
        #expect(labels.map(\.sortOrder) == Array(0..<9))
        #expect(labels.prefix(4).map(\.name) == ["经典", "人像", "风景", "人文"])
        #expect(labels.dropFirst(4).allSatisfy { !$0.isInUse })
    }

    /// 撤销、重做逐项恢复；重新打开库后值都在，撤销记录清空（只在本次运行内）。
    @Test func undoRedoAndPersistence() async throws {
        let (temp, _, _, ids) = try await library()
        let classic = try temp.reader.labels()[0].id
        var history = EditHistory()
        func run(_ edit: CullingEdit, _ title: String) throws {
            try temp.library.apply(edit)
            history.record(edit, title: title)
        }

        try run(.rating(before: [ids[0]: 0, ids[1]: 0], after: [ids[0]: 5, ids[1]: 5]), "★5")
        try run(.flag(before: [ids[0]: .none], after: [ids[0]: .pick]), "Pick")
        try run(.labels(added: [PhotoLabel(ids[0], classic), PhotoLabel(ids[2], classic)], removed: []), "经典")
        let collection = try temp.library.createCollection(name: "新疆 · 经典")
        try run(.membership(collection: collection, added: [ids[0], ids[2]], removed: []), "加入")

        #expect(try summary(temp, ids[0]).rating == 5)
        #expect(try summary(temp, ids[0]).flag == .pick)
        #expect(try summary(temp, ids[2]).labelIDs == [classic])
        #expect(try temp.reader.collectionMembers(collection) == [ids[0], ids[2]])

        let apply = { (edit: CullingEdit) in try temp.library.apply(edit) }
        #expect(try history.undo(apply)?.title == "加入")
        #expect(try temp.reader.collectionMembers(collection).isEmpty)
        try history.undo(apply)
        #expect(try summary(temp, ids[2]).labelIDs.isEmpty)
        try history.undo(apply)
        #expect(try summary(temp, ids[0]).flag == .none)
        try history.undo(apply)
        #expect(try summary(temp, ids[0]).rating == 0)
        #expect(try summary(temp, ids[1]).rating == 0)
        #expect(try history.undo(apply) == nil)

        try history.redo(apply)
        try history.redo(apply)
        #expect(try summary(temp, ids[1]).rating == 5)
        #expect(try summary(temp, ids[0]).flag == .pick)
        #expect(history.redoTitle == "经典")

        // 新的改动清掉重做记录。
        try run(.rating(before: [ids[2]: 0], after: [ids[2]: 3]), "★3")
        #expect(history.redoStack.isEmpty)

        let reopened = try Library(paths: temp.library.paths)
        let after = try reopened.reader.photos(in: .all, sort: .captureDateAscending)
        #expect(after.map(\.rating) == [5, 5, 3])
        #expect(after.map(\.flag) == [.pick, .none, .none])
        #expect(after.map(\.labelIDs) == [[], [], []])
        #expect(EditHistory().undoStack.isEmpty)
    }

    /// 撤销时写入失败：记录保留，可以再试。
    @Test func failedUndoKeepsEntry() throws {
        var history = EditHistory()
        history.record(.rating(before: [1: 0], after: [1: 4]), title: "★4")
        struct Failure: Error {}
        #expect(throws: Failure.self) { try history.undo { _ in throw Failure() } }
        #expect(history.undoStack.count == 1)
        #expect(history.redoStack.isEmpty)
    }

    @Test func noOpEditsAreNotRecorded() {
        var history = EditHistory()
        history.record(.rating(before: [1: 4], after: [1: 4]), title: "★4")
        history.record(.membership(collection: 1, added: [], removed: []), title: "加入")
        #expect(history.undoStack.isEmpty)
    }

    @Test func collectionsAddRemoveRenameDelete() async throws {
        let (temp, _, _, ids) = try await library()
        let collection = try temp.library.createCollection(name: "精选")
        #expect(try temp.library.addPhotos([ids[0], ids[1]], to: collection) == [ids[0], ids[1]])
        // 已经在里面的不算新加入，撤销时不会被移出。
        #expect(try temp.library.addPhotos([ids[1], ids[2], ids[2]], to: collection) == [ids[2]])
        #expect(try temp.reader.collections().map(\.photoCount) == [3])
        #expect(try temp.library.removePhotos([ids[1], 999], from: collection) == [ids[1]])
        #expect(try temp.reader.collectionMembers(collection) == [ids[0], ids[2]])

        try temp.library.renameCollection(collection, to: "新疆精选")
        #expect(try temp.reader.collections().map(\.name) == ["新疆精选"])
        #expect(try temp.reader.detail(of: ids[0])?.collectionNames == ["新疆精选"])

        try temp.library.setRating(5, for: [ids[0]])
        try temp.library.deleteCollection(collection)
        #expect(try temp.reader.collections().isEmpty)
        #expect(try temp.reader.photos(in: .all).count == 3)
        #expect(try temp.reader.rating(of: ids[0]) == 5)
    }

    /// 照片隐藏后仍是收藏夹成员，但不计数、不显示；卡插回来后又出现。
    @Test func hiddenMembersStayInCollection() async throws {
        let (temp, card, volume, ids) = try await library()
        let collection = try temp.library.createCollection(name: "精选")
        try temp.library.addPhotos(ids, to: collection)
        try card.remove("DCIM/DSC00002.JPG")
        try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)
        #expect(try temp.reader.collections().first?.photoCount == 2)
        #expect(try temp.reader.photos(in: .collection(collection)).count == 2)
        // 已在里面（只是隐藏）的照片再次加入，不算新加入。
        #expect(try temp.library.addPhotos([ids[1]], to: collection).isEmpty)

        try card.put("DCIM/DSC00002.JPG", date: "2026-08-12 10:00:02")
        try await temp.scanner().scan(volumeID: volume.id, mountURL: card.root)
        #expect(try temp.reader.collections().first?.photoCount == 3)
    }

    @Test func clearingALabelNameRemovesItFromPhotos() async throws {
        let (temp, _, _, ids) = try await library()
        let labels = try temp.reader.labels()
        try temp.library.apply(.labels(added: [PhotoLabel(ids[0], labels[0].id), PhotoLabel(ids[0], labels[1].id)], removed: []))
        #expect(try summary(temp, ids[0]).labelIDs == [labels[0].id, labels[1].id])

        try temp.library.updateLabel(labels[0].id, name: "", color: labels[0].color)
        #expect(try summary(temp, ids[0]).labelIDs == [labels[1].id])
        try temp.library.updateLabel(labels[0].id, name: "旅行", color: "#000000")
        #expect(try summary(temp, ids[0]).labelIDs == [labels[1].id])
        #expect(try temp.reader.labels()[0].name == "旅行")

        var history = EditHistory()
        history.record(.labels(added: [PhotoLabel(ids[1], labels[2].id)], removed: []), title: "风景")
        history.record(.rating(before: [ids[1]: 0], after: [ids[1]: 2]), title: "★2")
        history.forget(label: labels[2].id)
        #expect(history.undoStack.map(\.title) == ["★2"])
    }

    /// 两个连接（软件和命令行）一个写标签、一个写星级和收藏夹，互不覆盖。
    @Test func labelAndRatingWritesFromTwoConnections() async throws {
        let (temp, _, _, ids) = try await library()
        let other = try Library(paths: temp.library.paths)
        let label = try temp.reader.labels()[1].id
        try temp.library.apply(.labels(added: [PhotoLabel(ids[0], label)], removed: []))
        try other.setRating(3, for: [ids[0]])
        let collection = try other.createCollection(name: "命令行")
        try other.addPhotos([ids[0]], to: collection)
        let photo = try summary(temp, ids[0])
        #expect(photo.labelIDs == [label])
        #expect(photo.rating == 3)
        #expect(try temp.reader.collectionMembers(collection) == [ids[0]])
    }

    @Test func filterRules() async throws {
        let (temp, _, _, ids) = try await library()
        let labels = try temp.reader.labels()
        let classic = labels[0].id, portrait = labels[1].id
        try temp.library.apply(.rating(before: [:], after: [ids[0]: 5, ids[1]: 3, ids[2]: 0]))
        try temp.library.apply(.flag(before: [:], after: [ids[1]: .pick, ids[2]: .reject]))
        try temp.library.apply(.labels(added: [PhotoLabel(ids[0], classic), PhotoLabel(ids[1], portrait)], removed: []))
        let photos = try temp.reader.photos(in: .all, sort: .captureDateAscending)
        func names(_ filter: PhotoFilter) -> [String] { photos.filter(filter.matches).map(\.baseName) }

        var filter = PhotoFilter()
        #expect(names(filter).count == 3)
        filter.toggleStar(3)
        #expect(names(filter) == ["DSC00001", "DSC00002"])
        filter.toggleStar(5)  // 至少模式单选：换成 ≥5
        #expect(names(filter) == ["DSC00001"])
        filter.toggleStar(5)  // 再点取消
        #expect(filter.stars.isEmpty)

        filter.toggleStarMode()
        filter.toggleStar(0)
        filter.toggleStar(3)  // 正好模式多选：未评分或 3 星
        #expect(names(filter) == ["DSC00002", "DSC00003"])
        filter = PhotoFilter()

        // 同类“或者”：经典 或 人像。
        filter.toggleLabel(classic)
        filter.toggleLabel(portrait)
        #expect(names(filter) == ["DSC00001", "DSC00002"])
        // 不同类“并且”：并且 Pick。
        filter.toggleFlag(.pick)
        #expect(names(filter) == ["DSC00002"])
        #expect(filter.activeGroupCount == 2)
        #expect(filter.summary(labelNames: [classic: "经典", portrait: "人像"]) == "人像/经典 · Pick")

        filter = PhotoFilter()
        filter.noLabel = true
        #expect(names(filter) == ["DSC00003"])
        filter.toggleLabel(classic)
        #expect(names(filter) == ["DSC00001", "DSC00003"])

        filter = PhotoFilter()
        filter.toggleKind(.rawPlusJPEG)
        #expect(names(filter) == ["DSC00001"])
        filter.toggleKind(.jpegOnly)
        #expect(names(filter).count == 3)
        filter = PhotoFilter()
        filter.toggleFlag(.none)
        #expect(names(filter) == ["DSC00001"])
    }
}
