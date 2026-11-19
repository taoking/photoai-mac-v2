import Foundation

/// 一张照片上的一个标签。
public struct PhotoLabel: Sendable, Hashable {
    public var photoID: PhotoID
    public var labelID: LabelID

    public init(_ photoID: PhotoID, _ labelID: LabelID) {
        self.photoID = photoID
        self.labelID = labelID
    }
}

/// 一次可撤销的选片改动：星级、标记、标签、收藏夹成员。
///
/// 每种改动只写自己那个字段（数据模型 §8），撤销就是应用它的反向改动。
/// 记下的是每张照片改动前后的值，而不是“加一星”这种相对操作，撤销和重做的结果才确定。
public enum CullingEdit: Sendable, Equatable {
    case rating(before: [PhotoID: Int], after: [PhotoID: Int])
    case flag(before: [PhotoID: Flag], after: [PhotoID: Flag])
    case labels(added: Set<PhotoLabel>, removed: Set<PhotoLabel>)
    /// `added` 只含原本不在收藏夹里的照片，`removed` 只含原本在的，撤销时才不会多删或多加。
    case membership(collection: CollectionID, added: [PhotoID], removed: [PhotoID])

    public var inverse: CullingEdit {
        switch self {
        case .rating(let before, let after): .rating(before: after, after: before)
        case .flag(let before, let after): .flag(before: after, after: before)
        case .labels(let added, let removed): .labels(added: removed, removed: added)
        case .membership(let collection, let added, let removed): .membership(collection: collection, added: removed, removed: added)
        }
    }

    public var photoIDs: Set<PhotoID> {
        switch self {
        case .rating(_, let after): Set(after.keys)
        case .flag(_, let after): Set(after.keys)
        case .labels(let added, let removed): Set(added.map(\.photoID)).union(removed.map(\.photoID))
        case .membership(_, let added, let removed): Set(added).union(removed)
        }
    }

    /// 没有任何照片的值真的变了。
    public var isEmpty: Bool {
        switch self {
        case .rating(let before, let after): after.allSatisfy { before[$0.key] == $0.value }
        case .flag(let before, let after): after.allSatisfy { before[$0.key] == $0.value }
        case .labels(let added, let removed): added.isEmpty && removed.isEmpty
        case .membership(_, let added, let removed): added.isEmpty && removed.isEmpty
        }
    }
}

/// 撤销 / 重做的记录。只在本次运行内有效，重启后清空；扫描、移除卷、删收藏夹不进撤销。
public struct EditHistory: Sendable {
    public struct Entry: Sendable, Equatable {
        public var edit: CullingEdit
        /// 菜单里显示的名字，如“★5”“加入「新疆精选」”。
        public var title: String
    }

    public private(set) var undoStack: [Entry] = []
    public private(set) var redoStack: [Entry] = []
    public let limit: Int

    public init(limit: Int = 1_000) { self.limit = limit }

    public var undoTitle: String? { undoStack.last?.title }
    public var redoTitle: String? { redoStack.last?.title }

    public mutating func record(_ edit: CullingEdit, title: String) {
        guard !edit.isEmpty else { return }
        undoStack.append(Entry(edit: edit, title: title))
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    /// 写入成功才移动记录；写入失败时记录原样保留，调用方报错。
    @discardableResult
    public mutating func undo(_ apply: (CullingEdit) throws -> Void) throws -> Entry? {
        guard let entry = undoStack.last else { return nil }
        try apply(entry.edit.inverse)
        undoStack.removeLast()
        redoStack.append(entry)
        return entry
    }

    @discardableResult
    public mutating func redo(_ apply: (CullingEdit) throws -> Void) throws -> Entry? {
        guard let entry = redoStack.last else { return nil }
        try apply(entry.edit)
        redoStack.removeLast()
        undoStack.append(entry)
        return entry
    }

    /// 收藏夹被删掉后，和它有关的记录没法再撤销，一并去掉。
    public mutating func forget(collection: CollectionID) {
        let unrelated: (Entry) -> Bool = {
            if case .membership(let id, _, _) = $0.edit { return id != collection }
            return true
        }
        undoStack = undoStack.filter(unrelated)
        redoStack = redoStack.filter(unrelated)
    }

    /// 标签位置被清空（名字删掉）后，旧记录里的这个标签不能再加回去。
    public mutating func forget(label: LabelID) {
        let unrelated: (Entry) -> Bool = {
            if case .labels(let added, let removed) = $0.edit {
                return !added.contains { $0.labelID == label } && !removed.contains { $0.labelID == label }
            }
            return true
        }
        undoStack = undoStack.filter(unrelated)
        redoStack = redoStack.filter(unrelated)
    }

    public mutating func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}

// MARK: - 写入

extension Library {
    /// 写入一次改动的“改后”那一边。整个改动在一个事务里，失败整体回滚。
    public func apply(_ edit: CullingEdit) throws {
        try db.transaction {
            switch edit {
            case .rating(_, let after):
                for (id, rating) in after {
                    precondition((0...5).contains(rating))
                    try db.run("UPDATE photos SET rating = ? WHERE id = ?;", [rating, id])
                }
            case .flag(_, let after):
                for (id, flag) in after {
                    try db.run("UPDATE photos SET flag = ? WHERE id = ?;", [flag.rawValue, id])
                }
            case .labels(let added, let removed):
                for item in removed {
                    try db.run("DELETE FROM photo_labels WHERE photo_id = ? AND label_id = ?;", [item.photoID, item.labelID])
                }
                for item in added {
                    try db.run(
                        "INSERT OR IGNORE INTO photo_labels (photo_id, label_id) VALUES (?, ?);",
                        [item.photoID, item.labelID]
                    )
                }
            case .membership(let collection, let added, let removed):
                for id in removed {
                    try db.run("DELETE FROM collection_members WHERE collection_id = ? AND photo_id = ?;", [collection, id])
                }
                for id in added {
                    try db.run(
                        "INSERT OR IGNORE INTO collection_members (collection_id, photo_id, added_at) VALUES (?, ?, ?);",
                        [collection, id, now()]
                    )
                }
                if !added.isEmpty {
                    try db.run("UPDATE collections SET last_used_at = ? WHERE id = ?;", [now(), collection])
                }
            }
        }
    }

    public func setRating(_ rating: Int, for photoIDs: [PhotoID]) throws {
        let after = Dictionary(photoIDs.map { ($0, rating) }, uniquingKeysWith: { a, _ in a })
        try apply(.rating(before: [:], after: after))
    }

    public func setFlag(_ flag: Flag, for photoIDs: [PhotoID]) throws {
        let after = Dictionary(photoIDs.map { ($0, flag) }, uniquingKeysWith: { a, _ in a })
        try apply(.flag(before: [:], after: after))
    }

    // MARK: 收藏夹

    @discardableResult
    public func createCollection(name: String) throws -> CollectionID {
        Int(try db.insert("INSERT INTO collections (name, created_at) VALUES (?, ?);", [name, now()]))
    }

    public func renameCollection(_ id: CollectionID, to name: String) throws {
        try db.run("UPDATE collections SET name = ? WHERE id = ?;", [name, id])
    }

    /// 删收藏夹只删它和成员关系，不删照片（信息架构 §3.1）。
    public func deleteCollection(_ id: CollectionID) throws {
        try db.transaction {
            try db.run("DELETE FROM collection_members WHERE collection_id = ?;", [id])
            try db.run("DELETE FROM collections WHERE id = ?;", [id])
        }
    }

    /// 加入收藏夹，返回原本不在里面、这次新加入的照片（撤销只移出这些）。
    @discardableResult
    public func addPhotos(_ photoIDs: [PhotoID], to collection: CollectionID) throws -> [PhotoID] {
        let existing = Set(try reader.allCollectionMembers(collection))
        var seen = Set<PhotoID>()
        let added = photoIDs.filter { !existing.contains($0) && seen.insert($0).inserted }
        try apply(.membership(collection: collection, added: added, removed: []))
        try db.run("UPDATE collections SET last_used_at = ? WHERE id = ?;", [now(), collection])
        return added
    }

    /// 移出收藏夹，返回原本在里面、这次移出的照片。
    @discardableResult
    public func removePhotos(_ photoIDs: [PhotoID], from collection: CollectionID) throws -> [PhotoID] {
        let existing = Set(try reader.allCollectionMembers(collection))
        let removed = Array(Set(photoIDs).intersection(existing))
        try apply(.membership(collection: collection, added: [], removed: removed))
        return removed
    }

    // MARK: 标签

    /// 改一个标签位置的名字和颜色。名字改成空表示不再用这个位置：同一个事务里把它从所有照片上去掉（照片本身不受影响）。
    public func updateLabel(_ id: LabelID, name: String, color: String) throws {
        try db.transaction {
            if name.isEmpty {
                try db.run("DELETE FROM photo_labels WHERE label_id = ?;", [id])
            }
            try db.run("UPDATE labels SET name = ?, color = ? WHERE id = ?;", [name, color, id])
        }
    }
}

// MARK: - 读取

extension LibraryReader {
    /// 9 个标签位置，按快捷键顺序。
    public func labels() throws -> [LabelRecord] {
        try db.all("SELECT id, name, color, sort_order FROM labels ORDER BY sort_order;") { row in
            LabelRecord(id: row.int(0), name: row.text(1) ?? "", color: row.text(2) ?? "#8b8d98", sortOrder: row.int(3))
        }
    }

    /// 每张照片的标签，按标签位置排序。只含正在用的标签。给了范围时只读这个范围里的可见照片。
    public func photoLabels(in scope: PhotoScope? = nil) throws -> [PhotoID: [LabelID]] {
        var result: [PhotoID: [LabelID]] = [:]
        var restriction = ""
        var arguments: [any SQLBindable] = []
        if let scope {
            let (condition, scopeArguments) = Self.condition(for: scope)
            restriction = "AND pl.photo_id IN (SELECT p.id FROM photos p WHERE p.present_location_count > 0 AND \(condition))"
            arguments = scopeArguments
        }
        try db.query(
            """
            SELECT pl.photo_id, pl.label_id FROM photo_labels pl JOIN labels l ON l.id = pl.label_id
            WHERE l.name != '' \(restriction)
            ORDER BY pl.photo_id, l.sort_order;
            """,
            arguments
        ) { result[$0.int(0), default: []].append($0.int(1)) }
        return result
    }

    /// 所有收藏夹和可见成员数，按名字排序。
    public func collections() throws -> [CollectionRecord] {
        try db.all(
            """
            SELECT c.id, c.name, c.created_at, c.last_used_at,
                   (SELECT COUNT(*) FROM collection_members m JOIN photos p ON p.id = m.photo_id
                    WHERE m.collection_id = c.id AND p.present_location_count > 0)
            FROM collections c ORDER BY c.name COLLATE NOCASE, c.id;
            """
        ) { row in
            CollectionRecord(
                id: row.int(0), name: row.text(1) ?? "", createdAt: row.date(2) ?? Date(),
                lastUsedAt: row.date(3), photoCount: row.int(4)
            )
        }
    }

    /// 收藏夹的所有成员，含隐藏的照片（写入时判断“原本在不在”用）。
    func allCollectionMembers(_ collection: CollectionID) throws -> [PhotoID] {
        try db.all("SELECT photo_id FROM collection_members WHERE collection_id = ?;", [collection]) { $0.int(0) }
    }

    /// 照片所在的收藏夹。
    public func collectionNames(of photo: PhotoID) throws -> [String] {
        try db.all(
            """
            SELECT c.name FROM collection_members m JOIN collections c ON c.id = m.collection_id
            WHERE m.photo_id = ? ORDER BY c.name COLLATE NOCASE;
            """,
            [photo]
        ) { $0.text(0) ?? "" }
    }

    /// 某个收藏夹里有哪些照片：给定的照片里，已经在里面的那些。
    public func members(of collection: CollectionID, among photoIDs: [PhotoID]) throws -> Set<PhotoID> {
        Set(try allCollectionMembers(collection)).intersection(photoIDs)
    }
}
