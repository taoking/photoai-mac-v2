import Foundation

// MARK: - 无卷关联照片（设计稿 §4，信息架构 §8）

/// 一张无卷关联照片：一个现存位置都没有。
public struct OrphanPhoto: Sendable, Equatable, Identifiable {
    public var id: PhotoID
    public var baseName: String
    public var captureDate: String?
    public var rating: Int
    public var flag: Flag
    public var inCollection: Bool
    public var width: Int?
    public var height: Int?

    public var isMarked: Bool { rating > 0 || flag == .pick || inCollection }
}

/// 按曾经所在的卷分组：照片最后一次被看到的那个位置所在的卷。
public struct OrphanGroup: Sendable, Equatable, Identifiable {
    public var id: VolumeID
    public var volumeName: String
    public var volumeStatus: VolumeRecord.Status
    public var removedAt: Date?
    /// 组内按拍摄时间排列。
    public var photos: [OrphanPhoto]
}

public struct OrphanDeletion: Sendable, Equatable {
    public var deleted: [PhotoID] = []
    /// 确认时已经重新有了现存位置（期间被重扫找回），没删。
    public var kept: [PhotoID] = []
    /// 已移除、而且一个位置都不剩的卷，一并删掉了记录。
    public var removedVolumes: [VolumeID] = []

    public init() {}
}

extension LibraryReader {
    public func orphanGroups() throws -> [OrphanGroup] {
        var volumes: [VolumeID: VolumeRecord] = [:]
        for volume in try self.volumes(includeRemoved: true) { volumes[volume.id] = volume }
        var groups: [VolumeID: [OrphanPhoto]] = [:]
        try db.query(
            """
            SELECT p.id, p.base_name, p.capture_date, p.rating, p.flag, p.width, p.height,
                   EXISTS (SELECT 1 FROM collection_members c WHERE c.photo_id = p.id),
                   (SELECT l.volume_id FROM files f JOIN locations l ON l.file_id = f.id
                    WHERE f.photo_id = p.id ORDER BY l.last_seen_at DESC, l.id DESC LIMIT 1)
            FROM photos p
            WHERE p.present_location_count = 0
            ORDER BY p.capture_date, p.capture_subsec, p.base_name, p.id;
            """
        ) { row in
            let photo = OrphanPhoto(
                id: row.int(0),
                baseName: row.text(1) ?? "",
                captureDate: row.text(2),
                rating: row.int(3),
                flag: Flag(rawValue: row.text(4) ?? "") ?? .none,
                inCollection: row.int(7) != 0,
                width: row.optionalInt(5),
                height: row.optionalInt(6)
            )
            groups[row.optionalInt(8) ?? 0, default: []].append(photo)
        }
        return groups.map { id, photos in
            let volume = volumes[id]
            return OrphanGroup(
                id: id,
                volumeName: volume?.name ?? "未知的卷",
                volumeStatus: volume?.status ?? .removed,
                removedAt: volume?.removedAt,
                photos: photos
            )
        }
        // 最近移除的卷在前；还在用的卷（重扫时文件不在了）排在后面。
        .sorted {
            ($0.removedAt ?? .distantPast, $0.id) > ($1.removedAt ?? .distantPast, $1.id)
        }
    }

    public func orphanCount() throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM photos WHERE present_location_count = 0;")
    }
}

extension Library {
    /// 删除无卷关联照片的记录（文件、位置、标签、收藏夹成员随之删除）和本机预览。
    /// 在删除事务里按当时的状态再核对一次：期间被重扫找回的照片不删。卡和盘上的文件一概不碰。
    public func deleteOrphans(_ photoIDs: [PhotoID], previews: PreviewStore? = nil) throws -> OrphanDeletion {
        var result = OrphanDeletion()
        guard !photoIDs.isEmpty else { return result }
        try db.transaction {
            for chunk in photoIDs.chunked(into: 4_000) {
                let list = chunk.map(String.init).joined(separator: ",")
                let deletable = Set(try db.all(
                    "SELECT id FROM photos WHERE id IN (\(list)) AND present_location_count = 0;"
                ) { $0.int(0) })
                result.kept += chunk.filter { !deletable.contains($0) }
                guard !deletable.isEmpty else { continue }
                let ids = chunk.filter(deletable.contains)
                try db.run("DELETE FROM photos WHERE id IN (\(ids.map(String.init).joined(separator: ",")));")
                result.deleted += ids
            }
            result.removedVolumes = try db.all(
                """
                SELECT id FROM volumes v
                WHERE v.status = 'removed' AND NOT EXISTS (SELECT 1 FROM locations l WHERE l.volume_id = v.id)
                ORDER BY id;
                """
            ) { $0.int(0) }
            for volume in result.removedVolumes {
                try db.run(
                    "UPDATE photos SET import_batch_id = NULL WHERE import_batch_id IN (SELECT id FROM import_batches WHERE volume_id = ?);",
                    [volume]
                )
                try db.run("DELETE FROM import_batches WHERE volume_id = ?;", [volume])
                try db.run("DELETE FROM scan_dirs WHERE volume_id = ?;", [volume])
                try db.run("DELETE FROM volumes WHERE id = ?;", [volume])
            }
        }
        // 记录删掉之后再删预览文件：中途出错最多留下没人用的预览，不会出现有记录没预览。
        if let previews {
            for id in result.deleted {
                for size in PreviewSize.allCases {
                    try? FileManager.default.removeItem(at: previews.url(for: id, size: size))
                }
            }
        }
        return result
    }
}
