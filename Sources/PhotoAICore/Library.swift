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

    // MARK: - 预览状态

    /// 预览文件已写完并能解码之后才调用：在一个事务里把对应档位记为 `ready`，并记下用的是哪个文件。
    /// `pixelSize` 是生成预览的那个文件转正后的尺寸，照片的尺寸以它为准：
    /// 机内 16:9 裁切时 JPEG 是 7008×3944、RAW 是 7008×4672，看到的是 JPEG 生成的预览。
    public func markPreviewsReady(
        photoID: PhotoID,
        thumb: Bool,
        preview: Bool,
        sourceFileID: FileID,
        pixelSize: (width: Int, height: Int)? = nil
    ) throws {
        try db.transaction {
            if thumb { try db.run("UPDATE photos SET thumb_state = 'ready' WHERE id = ?;", [photoID]) }
            if preview { try db.run("UPDATE photos SET preview_state = 'ready' WHERE id = ?;", [photoID]) }
            try db.run("UPDATE photos SET preview_file_id = ? WHERE id = ?;", [sourceFileID, photoID])
            if let pixelSize, pixelSize.width > 0, pixelSize.height > 0 {
                try db.run("UPDATE photos SET width = ?, height = ? WHERE id = ?;", [pixelSize.width, pixelSize.height, photoID])
            }
        }
    }

    /// 一次性整理：M3 之前合组时尺寸记的是先扫到的文件（往往是 RAW），机内裁切的照片比例不对。
    /// 按已有的 480 缩略图的比例校正一次：长边不变，短边按缩略图的比例算（差一两个像素，只用于排版）。
    /// 只读文件头，不解码。做完记在 `library_meta`，以后不再做。返回改了几张。
    @discardableResult
    public func correctDimensionsFromThumbnails(store: PreviewStore) throws -> Int {
        let key = "dimensions_from_thumbnails"
        guard try db.first("SELECT value FROM library_meta WHERE key = ?;", [key], { $0.text(0) }) == nil else { return 0 }
        let rows = try db.all(
            "SELECT id, width, height FROM photos WHERE thumb_state = 'ready' AND width > 0 AND height > 0;"
        ) { ($0.int(0), $0.int(1), $0.int(2)) }
        var fixes: [(PhotoID, Int, Int)] = []
        for (id, width, height) in rows {
            guard let thumb = OriginalDecoder.pixelSize(at: store.url(for: id, size: .thumb)),
                  thumb.width > 0, thumb.height > 0 else { continue }
            let stored = Double(width) / Double(height)
            let shown = Double(thumb.width) / Double(thumb.height)
            guard abs(stored / shown - 1) > 0.02 else { continue }
            let longEdge = max(width, height)
            fixes.append(thumb.width >= thumb.height
                ? (id, longEdge, Int((Double(longEdge) / shown).rounded()))
                : (id, Int((Double(longEdge) * shown).rounded()), longEdge))
        }
        try db.transaction {
            for (id, width, height) in fixes {
                try db.run("UPDATE photos SET width = ?, height = ? WHERE id = ?;", [width, height, id])
            }
            try db.run("INSERT INTO library_meta (key, value) VALUES (?, ?);", [key, "\(fixes.count)"])
        }
        return fixes.count
    }

    /// 原片能读但解码不了：记为 `failed`，不再反复重试。
    public func markPreviewsFailed(photoID: PhotoID) throws {
        try db.run(
            """
            UPDATE photos SET
                thumb_state = CASE thumb_state WHEN 'pending' THEN 'failed' ELSE thumb_state END,
                preview_state = CASE preview_state WHEN 'pending' THEN 'failed' ELSE preview_state END
            WHERE id = ?;
            """,
            [photoID]
        )
    }

    /// 文件缺失或解码失败的档位改回 `pending`，卷重新插上时续做。
    public func resetPreviews(_ items: [(photoID: PhotoID, thumb: Bool, preview: Bool)]) throws {
        try db.transaction {
            for item in items {
                if item.thumb { try db.run("UPDATE photos SET thumb_state = 'pending' WHERE id = ?;", [item.photoID]) }
                if item.preview { try db.run("UPDATE photos SET preview_state = 'pending' WHERE id = ?;", [item.photoID]) }
            }
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
