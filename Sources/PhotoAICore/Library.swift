import Foundation

/// 库的位置：数据库和预览文件。
public struct LibraryPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `~/Library/Application Support/PhotoAI-Mac-v2`。环境变量 `PHOTOAI_LIBRARY_DIR` 可以换成别处，
    /// 性能测试用它打开合成的十万条数据，不碰真实的库。
    public static var `default`: LibraryPaths {
        if let override = ProcessInfo.processInfo.environment["PHOTOAI_LIBRARY_DIR"], !override.isEmpty {
            return LibraryPaths(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LibraryPaths(root: support.appendingPathComponent("PhotoAI-Mac-v2", isDirectory: true))
    }

    public var database: URL { root.appendingPathComponent("library.sqlite") }
    public var previews: URL { root.appendingPathComponent("Previews", isDirectory: true) }
}

/// 照片库：数据库的读写都从这里走。软件和命令行共用。
///
/// 所有写入按字段更新，不整行覆盖；跨表的操作放在一个事务里，失败整体回滚并抛错。
public final class Library: @unchecked Sendable {
    public let paths: LibraryPaths
    let db: Database
    let now: @Sendable () -> Date

    public init(paths: LibraryPaths = .default, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.paths = paths
        self.now = now
        db = try Database(url: paths.database)
        try Schema.migrate(db)
    }

    /// 另开一个只读连接，给界面线程读网格用，不用排在扫描的写事务后面。
    public func makeReader() throws -> LibraryReader {
        LibraryReader(db: try Database(url: paths.database, readOnly: true))
    }

    public var reader: LibraryReader { LibraryReader(db: db) }

    public func dataVersion() throws -> Int { try db.dataVersion() }

    // MARK: - 卷

    @discardableResult
    public func addVolume(
        uuid: String,
        name: String,
        scanRoot: String,
        capacityBytes: Int? = nil,
        filesystem: String? = nil
    ) throws -> VolumeRecord {
        let id = try db.insert(
            """
            INSERT INTO volumes (volume_uuid, name, scan_root, capacity_bytes, filesystem, status, created_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?, 'active', ?, ?);
            """,
            [uuid, name, Self.normalizedDirectory(scanRoot), capacityBytes, filesystem, now(), now()]
        )
        return try reader.volume(id: Int(id))!
    }

    public func renameVolume(_ id: VolumeID, to name: String) throws {
        try db.run("UPDATE volumes SET name = ? WHERE id = ?;", [name, id])
    }

    public func markVolumeSeen(_ id: VolumeID) throws {
        try db.run("UPDATE volumes SET last_seen_at = ? WHERE id = ?;", [now(), id])
    }

    /// 移除卷：卷记为已移除，卷上的现存位置都变成历史位置，照片的现存位置数同步减少。
    /// 不删照片、预览、评分和收藏夹（设计稿 §4）。
    public func removeVolume(_ id: VolumeID) throws {
        try db.transaction {
            try db.run(
                """
                UPDATE photos SET present_location_count = present_location_count - (
                    SELECT COUNT(*) FROM locations l JOIN files f ON f.id = l.file_id
                    WHERE f.photo_id = photos.id AND l.volume_id = ? AND l.status = 'present'
                )
                WHERE id IN (
                    SELECT f.photo_id FROM locations l JOIN files f ON f.id = l.file_id
                    WHERE l.volume_id = ? AND l.status = 'present'
                );
                """,
                [id, id]
            )
            try db.run("UPDATE locations SET status = 'historical' WHERE volume_id = ? AND status = 'present';", [id])
            try db.run("UPDATE volumes SET status = 'removed', removed_at = ? WHERE id = ?;", [now(), id])
        }
    }

    // MARK: - 选片字段（按字段写入）

    public func setRating(_ rating: Int, for photoIDs: [PhotoID]) throws {
        precondition((0...5).contains(rating))
        try db.transaction {
            for id in photoIDs {
                try db.run("UPDATE photos SET rating = ? WHERE id = ?;", [rating, id])
            }
        }
    }

    public func setFlag(_ flag: Flag, for photoIDs: [PhotoID]) throws {
        try db.transaction {
            for id in photoIDs {
                try db.run("UPDATE photos SET flag = ? WHERE id = ?;", [flag.rawValue, id])
            }
        }
    }

    // MARK: - 收藏夹（M1 只有最小的部分，M2 补全）

    @discardableResult
    public func createCollection(name: String) throws -> CollectionID {
        Int(try db.insert("INSERT INTO collections (name, created_at) VALUES (?, ?);", [name, now()]))
    }

    public func addPhotos(_ photoIDs: [PhotoID], to collection: CollectionID) throws {
        try db.transaction {
            for id in photoIDs {
                try db.run(
                    "INSERT OR IGNORE INTO collection_members (collection_id, photo_id, added_at) VALUES (?, ?, ?);",
                    [collection, id, now()]
                )
            }
            try db.run("UPDATE collections SET last_used_at = ? WHERE id = ?;", [now(), collection])
        }
    }

    // MARK: - 预览状态

    func setPreviewStates(photoID: PhotoID, thumb: PreviewState?, preview: PreviewState?) throws {
        if let thumb {
            try db.run("UPDATE photos SET thumb_state = ? WHERE id = ?;", [thumb.rawValue, photoID])
        }
        if let preview {
            try db.run("UPDATE photos SET preview_state = ? WHERE id = ?;", [preview.rawValue, photoID])
        }
    }

    // MARK: - 路径

    /// 去掉首尾的 `/`。空字符串表示卷根目录。
    static func normalizedDirectory(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : directory + "/" + name
    }
}
