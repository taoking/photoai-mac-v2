import Foundation

/// 扫描用到的写入。规则见 docs/数据模型.md §5、§6：
/// 每次位置在现存和历史之间变化，都在同一个事务里同步照片的 `present_location_count`。
extension Library {
    struct ScanFile: Sendable {
        var name: String
        var relativePath: String
        var dirPath: String
        var size: Int64
        var modificationTime: Double
        var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    }

    struct KnownLocation: Sendable {
        var id: Int
        var size: Int64
        var modificationTime: Double
    }

    struct BatchCounts: Sendable {
        var unchanged = 0
        var updated = 0
        var added = 0
        var restored = 0
        var replaced = 0
        var newPhotos = 0
    }

    /// 一个目录里上次扫描后的现存位置，按相对路径索引。
    func presentLocations(volumeID: VolumeID, dirPath: String) throws -> [String: KnownLocation] {
        var result: [String: KnownLocation] = [:]
        try db.query(
            "SELECT id, relative_path, file_size, file_mtime FROM locations WHERE volume_id = ? AND dir_path = ? AND status = 'present';",
            [volumeID, dirPath]
        ) { row in
            result[row.text(1) ?? ""] = KnownLocation(id: row.int(0), size: row.int64(2), modificationTime: row.double(3))
        }
        return result
    }

    /// 提交一批扫描结果。`importBatchID` 在第一次新建照片时才创建，没新照片的重扫不留“最近导入”。
    func applyScanBatch(
        volumeID: VolumeID,
        unchanged: [Int],
        read: [(ScanFile, PhotoMetadata)],
        at time: Date,
        importBatchID: inout Int?
    ) throws -> BatchCounts {
        var batchID = importBatchID
        let counts = try db.transaction { () throws -> BatchCounts in
            var counts = BatchCounts()
            for id in unchanged {
                try db.run("UPDATE locations SET last_seen_at = ? WHERE id = ?;", [time, id])
                counts.unchanged += 1
            }
            for (file, metadata) in read {
                try applyReadFile(file, metadata: metadata, volumeID: volumeID, at: time, batchID: &batchID, counts: &counts)
            }
            return counts
        }
        importBatchID = batchID
        return counts
    }

    private func applyReadFile(
        _ file: ScanFile,
        metadata: PhotoMetadata,
        volumeID: VolumeID,
        at time: Date,
        batchID: inout Int?,
        counts: inout BatchCounts
    ) throws {
        let baseName = PhotoIdentity.baseName(ofFileName: file.name)
        let key = PhotoIdentity.key(baseName: baseName, captureDate: metadata.captureDate, fileSize: file.size)

        // 同一路径上已有现存位置：身份相同就更新大小和时间；不同就是同一路径换了照片。
        if let present = try db.first(
            """
            SELECT l.id, p.identity_key FROM locations l
            JOIN files f ON f.id = l.file_id JOIN photos p ON p.id = f.photo_id
            WHERE l.volume_id = ? AND l.relative_path = ? AND l.status = 'present';
            """,
            [volumeID, file.relativePath],
            { ($0.int(0), $0.text(1) ?? "") }
        ) {
            if present.1 == key {
                try db.run(
                    "UPDATE locations SET file_size = ?, file_mtime = ?, last_seen_at = ? WHERE id = ?;",
                    [file.size, file.modificationTime, time, present.0]
                )
                counts.updated += 1
                return
            }
            try markHistorical(locationIDs: [present.0])
            counts.replaced += 1
        }

        // 同一路径上的历史位置、身份相同：原样放回来了，恢复为现存，评分随照片回来。
        if let historical = try db.first(
            """
            SELECT l.id FROM locations l
            JOIN files f ON f.id = l.file_id JOIN photos p ON p.id = f.photo_id
            WHERE l.volume_id = ? AND l.relative_path = ? AND l.status = 'historical' AND p.identity_key = ?
            ORDER BY l.id DESC LIMIT 1;
            """,
            [volumeID, file.relativePath, key],
            { $0.int(0) }
        ) {
            try db.run(
                "UPDATE locations SET status = 'present', file_size = ?, file_mtime = ?, last_seen_at = ? WHERE id = ?;",
                [file.size, file.modificationTime, time, historical]
            )
            try adjustPresentCount(locationID: historical, by: 1)
            counts.restored += 1
            return
        }

        // 新位置：挂到身份对应的照片上，没有就新建。新照片不继承同一路径上旧照片的任何东西。
        let photoID: Int
        if let existing = try db.first("SELECT id FROM photos WHERE identity_key = ?;", [key], { $0.int(0) }) {
            photoID = existing
        } else {
            if batchID == nil {
                batchID = Int(try db.insert(
                    "INSERT INTO import_batches (volume_id, started_at) VALUES (?, ?);",
                    [volumeID, time]
                ))
            }
            photoID = Int(try db.insert(
                """
                INSERT INTO photos (identity_key, base_name, file_number, capture_date, capture_subsec,
                    camera_make, camera_model, lens, focal_length, aperture, shutter, iso, width, height,
                    latitude, longitude, imported_at, import_batch_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                [
                    key, baseName, PhotoIdentity.fileNumber(ofBaseName: baseName),
                    metadata.captureDate, metadata.captureSubsec,
                    metadata.cameraMake, metadata.cameraModel, metadata.lens,
                    metadata.focalLength, metadata.aperture, metadata.shutter, metadata.iso,
                    metadata.width, metadata.height, metadata.latitude, metadata.longitude,
                    time, batchID
                ]
            ))
            try db.run("UPDATE import_batches SET photo_count = photo_count + 1 WHERE id = ?;", [batchID])
            counts.newPhotos += 1
        }

        let ext = file.fileExtension
        let fileID: Int
        if let existing = try db.first(
            "SELECT id FROM files WHERE photo_id = ? AND extension = ?;", [photoID, ext], { $0.int(0) }
        ) {
            fileID = existing
        } else {
            let kind = FileKind(extension: ext) ?? .raw
            fileID = Int(try db.insert(
                "INSERT INTO files (photo_id, extension, kind, file_size) VALUES (?, ?, ?, ?);",
                [photoID, ext, kind.rawValue, file.size]
            ))
            try db.run("UPDATE photos SET preview_file_id = ? WHERE id = ? AND preview_file_id IS NULL;", [fileID, photoID])
        }

        let locationID = Int(try db.insert(
            """
            INSERT INTO locations (file_id, volume_id, relative_path, dir_path, file_size, file_mtime, status, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?, 'present', ?);
            """,
            [fileID, volumeID, file.relativePath, file.dirPath, file.size, file.modificationTime, time]
        ))
        try adjustPresentCount(locationID: locationID, by: 1)
        counts.added += 1
    }

    /// 目录完整列出之后：本次没见到的现存位置改为历史；上次还在、这次不见了的子目录，
    /// 其下所有现存位置也改为历史。然后把目录记为完整扫完。返回改为历史的位置数。
    func finishDirectory(
        volumeID: VolumeID,
        dirPath: String,
        seenPaths: Set<String>,
        subdirectories: Set<String>,
        at time: Date
    ) throws -> Int {
        try db.transaction {
            var vanished: [Int] = []
            try db.query(
                "SELECT id, relative_path FROM locations WHERE volume_id = ? AND dir_path = ? AND status = 'present';",
                [volumeID, dirPath]
            ) { row in
                if !seenPaths.contains(row.text(1) ?? "") { vanished.append(row.int(0)) }
            }

            let knownChildren = try knownDirectories(volumeID: volumeID, under: dirPath)
                .filter { Self.isDirectChild($0, of: dirPath) }
            for child in knownChildren {
                let name = dirPath.isEmpty ? child : String(child.dropFirst(dirPath.count + 1))
                guard !subdirectories.contains(name) else { continue }
                let (lower, upper) = Self.descendantRange(of: child)
                try db.query(
                    """
                    SELECT id FROM locations WHERE volume_id = ? AND status = 'present'
                      AND (dir_path = ? OR (dir_path >= ? AND dir_path < ?));
                    """,
                    [volumeID, child, lower, upper]
                ) { vanished.append($0.int(0)) }
                try db.run(
                    "DELETE FROM scan_dirs WHERE volume_id = ? AND (dir_path = ? OR (dir_path >= ? AND dir_path < ?));",
                    [volumeID, child, lower, upper]
                )
            }

            try markHistorical(locationIDs: vanished)
            try db.run(
                """
                INSERT INTO scan_dirs (volume_id, dir_path, state, last_complete_at, last_error)
                VALUES (?, ?, 'complete', ?, NULL)
                ON CONFLICT (volume_id, dir_path) DO UPDATE SET
                    state = 'complete', last_complete_at = excluded.last_complete_at, last_error = NULL;
                """,
                [volumeID, dirPath, time]
            )
            return vanished.count
        }
    }

    /// 目录没扫完：只记原因，不动这个目录下的任何位置。
    func markDirectoryIncomplete(volumeID: VolumeID, dirPath: String, reason: String) throws {
        try db.run(
            """
            INSERT INTO scan_dirs (volume_id, dir_path, state, last_error) VALUES (?, ?, 'incomplete', ?)
            ON CONFLICT (volume_id, dir_path) DO UPDATE SET state = 'incomplete', last_error = excluded.last_error;
            """,
            [volumeID, dirPath, reason]
        )
    }

    /// 这次扫描没走到的已知目录（比如上级目录没列出来、扫描中断）都记为没扫完。
    /// `under`：只看这个目录和它下面的（只扫一棵子树时）。
    func markUnvisitedDirectoriesIncomplete(volumeID: VolumeID, visited: Set<String>, under root: String? = nil, reason: String) throws {
        try db.transaction {
            let known = try db.all("SELECT dir_path FROM scan_dirs WHERE volume_id = ?;", [volumeID]) { $0.text(0) ?? "" }
            for dir in known where !visited.contains(dir) && (root.map { Library.isDirectory(dir, inside: $0) } ?? true) {
                try markDirectoryIncomplete(volumeID: volumeID, dirPath: dir, reason: reason)
            }
        }
    }

    /// 整卷的目录都扫完了才更新 `last_scanned_at`。
    func finishVolumeScan(volumeID: VolumeID, importBatchID: Int?, at time: Date, wholeVolume: Bool = true) throws -> Bool {
        try db.transaction {
            try db.run("UPDATE volumes SET last_seen_at = ? WHERE id = ?;", [time, volumeID])
            if let importBatchID {
                try db.run("UPDATE import_batches SET finished_at = ? WHERE id = ?;", [time, importBatchID])
            }
            let incomplete = try db.scalarInt(
                "SELECT COUNT(*) FROM scan_dirs WHERE volume_id = ? AND state = 'incomplete';", [volumeID]
            )
            if incomplete == 0, wholeVolume {
                try db.run("UPDATE volumes SET last_scanned_at = ? WHERE id = ?;", [time, volumeID])
            }
            return incomplete == 0
        }
    }

    /// 把现存位置改为历史，同步照片的现存位置数。已经是历史的位置跳过。
    func markHistorical(locationIDs: [Int]) throws {
        try db.transaction {
            for id in locationIDs {
                let changed = try db.run("UPDATE locations SET status = 'historical' WHERE id = ? AND status = 'present';", [id])
                if changed > 0 { try adjustPresentCount(locationID: id, by: -1) }
            }
        }
    }

    private func adjustPresentCount(locationID: Int, by delta: Int) throws {
        try db.run(
            """
            UPDATE photos SET present_location_count = present_location_count + ?
            WHERE id = (SELECT f.photo_id FROM locations l JOIN files f ON f.id = l.file_id WHERE l.id = ?);
            """,
            [delta, locationID]
        )
    }

    private func knownDirectories(volumeID: VolumeID, under dirPath: String) throws -> [String] {
        if dirPath.isEmpty {
            return try db.all(
                "SELECT dir_path FROM scan_dirs WHERE volume_id = ? AND dir_path != '';", [volumeID]
            ) { $0.text(0) ?? "" }
        }
        let (lower, upper) = Self.descendantRange(of: dirPath)
        return try db.all(
            "SELECT dir_path FROM scan_dirs WHERE volume_id = ? AND dir_path >= ? AND dir_path < ?;",
            [volumeID, lower, upper]
        ) { $0.text(0) ?? "" }
    }

    /// `a/b` 的所有下级目录都落在 [`a/b/`, `a/b0`) 里（`0` 是 `/` 的下一个字符），不用 LIKE 也就不用转义。
    static func descendantRange(of dirPath: String) -> (String, String) {
        (dirPath + "/", dirPath + "0")
    }

    static func isDirectChild(_ child: String, of parent: String) -> Bool {
        if parent.isEmpty { return !child.isEmpty && !child.contains("/") }
        guard child.hasPrefix(parent + "/") else { return false }
        return !child.dropFirst(parent.count + 1).contains("/")
    }
}
