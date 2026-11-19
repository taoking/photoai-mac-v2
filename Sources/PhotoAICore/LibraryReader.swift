import Foundation

/// 库的查询。常规列表一律只看可见照片（`present_location_count > 0`，数据模型 §6）。
public struct LibraryReader: Sendable {
    let db: Database

    // MARK: - 卷

    public func volumes(includeRemoved: Bool = false) throws -> [VolumeRecord] {
        try db.all(
            "SELECT \(Self.volumeColumns) FROM volumes \(includeRemoved ? "" : "WHERE status = 'active'") ORDER BY name COLLATE NOCASE, id;",
            [],
            Self.volume
        )
    }

    public func volume(id: VolumeID) throws -> VolumeRecord? {
        try db.first("SELECT \(Self.volumeColumns) FROM volumes WHERE id = ?;", [id], Self.volume)
    }

    /// 按卷 UUID 找在用的卷。已移除的卷不算：重新插上时当新卷。
    public func activeVolume(uuid: String) throws -> VolumeRecord? {
        try db.first(
            "SELECT \(Self.volumeColumns) FROM volumes WHERE volume_uuid = ? AND status = 'active';",
            [uuid],
            Self.volume
        )
    }

    public func volumeStats(_ id: VolumeID) throws -> VolumeStats {
        let counts = try db.first(
            """
            SELECT COUNT(*), COALESCE(SUM(p.thumb_state = 'ready' AND p.preview_state = 'ready'), 0)
            FROM photos p
            WHERE p.id IN (
                SELECT f.photo_id FROM locations l JOIN files f ON f.id = l.file_id
                WHERE l.volume_id = ? AND l.status = 'present'
            );
            """,
            [id]
        ) { ($0.int(0), $0.int(1)) } ?? (0, 0)
        let incomplete = try db.scalarInt(
            "SELECT COUNT(*) FROM scan_dirs WHERE volume_id = ? AND state = 'incomplete';",
            [id]
        )
        return VolumeStats(photoCount: counts.0, previewReadyCount: counts.1, incompleteDirectoryCount: incomplete)
    }

    /// 每个在用卷上的可见照片数，侧栏用。
    public func photoCountsByVolume() throws -> [VolumeID: Int] {
        var counts: [VolumeID: Int] = [:]
        try db.query(
            """
            SELECT l.volume_id, COUNT(DISTINCT f.photo_id)
            FROM locations l JOIN files f ON f.id = l.file_id
            WHERE l.status = 'present'
            GROUP BY l.volume_id;
            """
        ) { counts[$0.int(0)] = $0.int(1) }
        return counts
    }

    // MARK: - 照片

    public func photos(in scope: PhotoScope, sort: PhotoSort = .captureDateDescending) throws -> [PhotoSummary] {
        let (condition, arguments) = Self.condition(for: scope)
        let order: String
        switch sort {
        case .captureDateDescending:
            order = "p.capture_date IS NULL, p.capture_date DESC, p.capture_subsec DESC, p.base_name DESC"
        case .captureDateAscending:
            order = "p.capture_date IS NULL, p.capture_date, p.capture_subsec, p.base_name"
        case .fileName:
            order = "p.base_name COLLATE NOCASE, p.capture_date"
        }
        return try db.all(
            """
            SELECT p.id, p.base_name, p.capture_date, p.width, p.height, p.rating, p.flag, p.thumb_state,
                   EXISTS (SELECT 1 FROM files f WHERE f.photo_id = p.id AND f.kind = 'raw'),
                   EXISTS (SELECT 1 FROM files f WHERE f.photo_id = p.id AND f.kind = 'jpeg')
            FROM photos p
            WHERE p.present_location_count > 0 AND \(condition)
            ORDER BY \(order);
            """,
            arguments
        ) { row in
            PhotoSummary(
                id: row.int(0),
                baseName: row.text(1) ?? "",
                captureDate: row.text(2),
                width: row.optionalInt(3),
                height: row.optionalInt(4),
                rating: row.int(5),
                flag: Flag(rawValue: row.text(6) ?? "") ?? .none,
                thumbState: PreviewState(rawValue: row.text(7) ?? "") ?? .pending,
                hasRaw: row.int(8) != 0,
                hasJPEG: row.int(9) != 0
            )
        }
    }

    public func visiblePhotoCount(in scope: PhotoScope = .all) throws -> Int {
        let (condition, arguments) = Self.condition(for: scope)
        return try db.scalarInt(
            "SELECT COUNT(*) FROM photos p WHERE p.present_location_count > 0 AND \(condition);",
            arguments
        )
    }

    /// “无卷关联照片”：一个现存位置都没有的照片（M4 做界面，M1 的测试用它核对）。
    public func unlinkedPhotoIDs() throws -> [PhotoID] {
        try db.all("SELECT id FROM photos WHERE present_location_count = 0 ORDER BY id;") { $0.int(0) }
    }

    public func dayCounts() throws -> [DayCount] {
        try db.all(
            """
            SELECT substr(capture_date, 1, 10) AS day, COUNT(*) FROM photos
            WHERE present_location_count > 0 AND capture_date IS NOT NULL
            GROUP BY day ORDER BY day DESC;
            """
        ) { DayCount(day: $0.text(0) ?? "", count: $0.int(1)) }
    }

    public func undatedCount() throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM photos WHERE present_location_count > 0 AND capture_date IS NULL;")
    }

    public func importBatches(limit: Int = 20) throws -> [ImportBatch] {
        try db.all(
            """
            SELECT b.id, b.volume_id, v.name, b.started_at,
                   (SELECT COUNT(*) FROM photos p WHERE p.import_batch_id = b.id AND p.present_location_count > 0)
            FROM import_batches b JOIN volumes v ON v.id = b.volume_id
            WHERE b.photo_count > 0
            ORDER BY b.started_at DESC LIMIT ?;
            """,
            [limit]
        ) { row in
            ImportBatch(
                id: row.int(0),
                volumeID: row.int(1),
                volumeName: row.text(2) ?? "",
                startedAt: row.date(3) ?? Date(),
                photoCount: row.int(4)
            )
        }
    }

    public func detail(of id: PhotoID) throws -> PhotoDetail? {
        guard var detail = try db.first(
            """
            SELECT p.id, p.base_name, p.capture_date, p.width, p.height, p.rating, p.flag, p.thumb_state,
                   p.camera_make, p.camera_model, p.lens, p.focal_length, p.aperture, p.shutter, p.iso,
                   p.preview_state, p.present_location_count
            FROM photos p WHERE p.id = ?;
            """,
            [id],
            { row in
                PhotoDetail(
                    summary: PhotoSummary(
                        id: row.int(0),
                        baseName: row.text(1) ?? "",
                        captureDate: row.text(2),
                        width: row.optionalInt(3),
                        height: row.optionalInt(4),
                        rating: row.int(5),
                        flag: Flag(rawValue: row.text(6) ?? "") ?? .none,
                        thumbState: PreviewState(rawValue: row.text(7) ?? "") ?? .pending,
                        hasRaw: false,
                        hasJPEG: false
                    ),
                    cameraMake: row.text(8),
                    cameraModel: row.text(9),
                    lens: row.text(10),
                    focalLength: row.optionalDouble(11),
                    aperture: row.optionalDouble(12),
                    shutter: row.optionalDouble(13),
                    iso: row.optionalInt(14),
                    previewState: PreviewState(rawValue: row.text(15) ?? "") ?? .pending,
                    presentLocationCount: row.int(16),
                    extensions: [],
                    locations: []
                )
            }
        ) else { return nil }
        let kinds = try db.all("SELECT extension, kind FROM files WHERE photo_id = ? ORDER BY kind DESC;", [id]) {
            ($0.text(0) ?? "", $0.text(1) ?? "")
        }
        detail.extensions = kinds.map { $0.0.uppercased() }
        detail.summary.hasRaw = kinds.contains { $0.1 == FileKind.raw.rawValue }
        detail.summary.hasJPEG = kinds.contains { $0.1 == FileKind.jpeg.rawValue }
        detail.locations = try db.all(
            """
            SELECT l.volume_id, v.name, l.relative_path, l.status = 'present'
            FROM locations l JOIN files f ON f.id = l.file_id JOIN volumes v ON v.id = l.volume_id
            WHERE f.photo_id = ? ORDER BY l.status = 'present' DESC, v.name, l.relative_path;
            """,
            [id]
        ) { row in
            PhotoDetail.Location(
                volumeID: row.int(0),
                volumeName: row.text(1) ?? "",
                relativePath: row.text(2) ?? "",
                isPresent: row.int(3) != 0
            )
        }
        return detail
    }

    public func rating(of id: PhotoID) throws -> Int? {
        try db.first("SELECT rating FROM photos WHERE id = ?;", [id]) { $0.int(0) }
    }

    public func photoID(identityKey: String) throws -> PhotoID? {
        try db.first("SELECT id FROM photos WHERE identity_key = ?;", [identityKey]) { $0.int(0) }
    }

    public func presentLocationCount(of id: PhotoID) throws -> Int? {
        try db.first("SELECT present_location_count FROM photos WHERE id = ?;", [id]) { $0.int(0) }
    }

    /// 按现存位置重新数一遍，和冗余字段 `present_location_count` 核对（测试与自检用）。
    public func countedPresentLocations(of id: PhotoID) throws -> Int {
        try db.scalarInt(
            """
            SELECT COUNT(*) FROM locations l JOIN files f ON f.id = l.file_id JOIN volumes v ON v.id = l.volume_id
            WHERE f.photo_id = ? AND l.status = 'present' AND v.status = 'active';
            """,
            [id]
        )
    }

    /// 冗余计数与实际现存位置数不一致的照片。正常情况下应为空。
    public func inconsistentLocationCounts() throws -> [PhotoID] {
        try db.all(
            """
            SELECT p.id FROM photos p
            WHERE p.present_location_count != (
                SELECT COUNT(*) FROM locations l JOIN files f ON f.id = l.file_id JOIN volumes v ON v.id = l.volume_id
                WHERE f.photo_id = p.id AND l.status = 'present' AND v.status = 'active'
            );
            """
        ) { $0.int(0) }
    }

    public func collectionMembers(_ collection: CollectionID) throws -> [PhotoID] {
        try db.all(
            """
            SELECT p.id FROM collection_members m JOIN photos p ON p.id = m.photo_id
            WHERE m.collection_id = ? AND p.present_location_count > 0 ORDER BY p.id;
            """,
            [collection]
        ) { $0.int(0) }
    }

    public func scanDirectoryStates(volume: VolumeID) throws -> [String: String] {
        var states: [String: String] = [:]
        try db.query("SELECT dir_path, state FROM scan_dirs WHERE volume_id = ?;", [volume]) {
            states[$0.text(0) ?? ""] = $0.text(1)
        }
        return states
    }

    /// 某个卷上某个路径的所有位置：(照片身份, 状态)，按记录先后排列。测试用。
    public func locations(volume: VolumeID, relativePath: String) throws -> [(identityKey: String, status: String)] {
        try db.all(
            """
            SELECT p.identity_key, l.status FROM locations l
            JOIN files f ON f.id = l.file_id JOIN photos p ON p.id = f.photo_id
            WHERE l.volume_id = ? AND l.relative_path = ? ORDER BY l.id;
            """,
            [volume, relativePath]
        ) { ($0.text(0) ?? "", $0.text(1) ?? "") }
    }

    // MARK: - 预览

    /// 需要生成预览、并且在给定的（在线）卷上有现存位置的照片。
    /// 每张照片列出所有可用的来源，JPEG 排在 RAW 前面（预览优先用 JPEG 生成）。
    public func photosNeedingPreviews(limit: Int, onVolumes volumeIDs: [VolumeID], excluding: Set<PhotoID> = []) throws -> [PreviewJob] {
        guard !volumeIDs.isEmpty else { return [] }
        let volumeList = volumeIDs.map(String.init).joined(separator: ",")
        let candidates = try db.all(
            """
            SELECT p.id, p.thumb_state = 'pending', p.preview_state = 'pending' FROM photos p
            WHERE p.present_location_count > 0
              AND (p.thumb_state = 'pending' OR p.preview_state = 'pending')
              AND EXISTS (SELECT 1 FROM files f JOIN locations l ON l.file_id = f.id
                          WHERE f.photo_id = p.id AND l.status = 'present' AND l.volume_id IN (\(volumeList)))
            ORDER BY p.capture_date DESC
            LIMIT ?;
            """,
            [limit + excluding.count]
        ) { ($0.int(0), $0.int(1) != 0, $0.int(2) != 0) }
        var jobs: [PreviewJob] = []
        for (id, needsThumb, needsPreview) in candidates where !excluding.contains(id) {
            guard jobs.count < limit else { break }
            let sources = try db.all(
                """
                SELECT f.id, f.kind, l.volume_id, l.relative_path FROM files f
                JOIN locations l ON l.file_id = f.id
                WHERE f.photo_id = ? AND l.status = 'present' AND l.volume_id IN (\(volumeList));
                """,
                [id]
            ) { row in
                PreviewJob.Source(
                    fileID: row.int(0),
                    kind: FileKind(rawValue: row.text(1) ?? "") ?? .raw,
                    volumeID: row.int(2),
                    relativePath: row.text(3) ?? ""
                )
            }
            .sorted { $0.kind.previewPriority < $1.kind.previewPriority }
            jobs.append(PreviewJob(photoID: id, needsThumb: needsThumb, needsPreview: needsPreview, sources: sources))
        }
        return jobs
    }

    public func pendingPreviewCount() throws -> Int {
        try db.scalarInt(
            "SELECT COUNT(*) FROM photos WHERE present_location_count > 0 AND (thumb_state = 'pending' OR preview_state = 'pending');"
        )
    }

    /// 状态是 `ready` 的照片 id，启动时核对文件还在不在。
    public func photosWithReadyPreviews() throws -> [(id: PhotoID, thumb: Bool, preview: Bool)] {
        try db.all(
            "SELECT id, thumb_state = 'ready', preview_state = 'ready' FROM photos WHERE thumb_state = 'ready' OR preview_state = 'ready';"
        ) { ($0.int(0), $0.int(1) != 0, $0.int(2) != 0) }
    }

    // MARK: - 内部

    static let volumeColumns = """
        id, volume_uuid, name, scan_root, capacity_bytes, filesystem, status, created_at, removed_at, last_seen_at, last_scanned_at
        """

    static func volume(_ row: Row) -> VolumeRecord {
        VolumeRecord(
            id: row.int(0),
            volumeUUID: row.text(1) ?? "",
            name: row.text(2) ?? "",
            scanRoot: row.text(3) ?? "",
            capacityBytes: row.optionalInt(4),
            filesystem: row.text(5),
            status: VolumeRecord.Status(rawValue: row.text(6) ?? "") ?? .active,
            createdAt: row.date(7) ?? Date(),
            removedAt: row.date(8),
            lastSeenAt: row.date(9),
            lastScannedAt: row.date(10)
        )
    }

    static func condition(for scope: PhotoScope) -> (String, [any SQLBindable]) {
        switch scope {
        case .all:
            return ("1", [])
        case .volume(let id):
            return (
                """
                p.id IN (SELECT f.photo_id FROM locations l JOIN files f ON f.id = l.file_id
                         WHERE l.volume_id = ? AND l.status = 'present')
                """,
                [id]
            )
        case .datePrefix(let prefix):
            // 用范围比较走索引：`2026-08` ≤ capture_date < `2026-08~`。
            return ("p.capture_date >= ? AND p.capture_date < ?", [prefix, prefix + "~"])
        case .undated:
            return ("p.capture_date IS NULL", [])
        case .importBatch(let id):
            return ("p.import_batch_id = ?", [id])
        case .collection(let id):
            return ("p.id IN (SELECT photo_id FROM collection_members WHERE collection_id = ?)", [id])
        }
    }
}

/// 一张照片的预览生成任务。
public struct PreviewJob: Sendable, Equatable {
    public struct Source: Sendable, Equatable {
        public var fileID: FileID
        public var kind: FileKind
        public var volumeID: VolumeID
        public var relativePath: String
    }

    public var photoID: PhotoID
    public var needsThumb: Bool
    public var needsPreview: Bool
    public var sources: [Source]
}
