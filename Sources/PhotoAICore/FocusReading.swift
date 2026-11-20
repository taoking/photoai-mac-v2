import Foundation

// MARK: - 读

extension LibraryReader {
    /// 照片的对焦框；没读过、相机没记都是 nil。
    public func focusArea(of photo: PhotoID) throws -> FocusArea? {
        try db.first(
            "SELECT focus_x, focus_y, focus_w, focus_h FROM photos WHERE id = ? AND focus_state = 'found';", [photo]
        ) { FocusArea(x: $0.double(0), y: $0.double(1), width: $0.double(2), height: $0.double(3)) }
    }

    /// 各状态的照片数（pending / found / none），只算可见照片。
    public func focusCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        try db.query("SELECT focus_state, COUNT(*) FROM photos WHERE present_location_count > 0 GROUP BY focus_state;") { row in
            counts[row.text(0) ?? ""] = row.int(1)
        }
        return counts
    }

    /// 还没读对焦框、并且在给定的（在线）卷上有现存位置的照片，每张列出这些卷上的文件，JPEG 在前（文件头小，读得快）。
    public func photosNeedingFocus(limit: Int, onVolumes volumeIDs: [VolumeID], excluding: Set<PhotoID> = []) throws -> [PreviewJob] {
        guard !volumeIDs.isEmpty else { return [] }
        let volumeList = volumeIDs.map(String.init).joined(separator: ",")
        let candidates = try db.all(
            """
            SELECT p.id FROM photos p
            WHERE p.focus_state = 'pending' AND p.present_location_count > 0
              AND EXISTS (SELECT 1 FROM files f JOIN locations l ON l.file_id = f.id
                          WHERE f.photo_id = p.id AND l.status = 'present' AND l.volume_id IN (\(volumeList)))
            LIMIT ?;
            """,
            [limit + excluding.count]
        ) { $0.int(0) }
        var jobs: [PreviewJob] = []
        for id in candidates where !excluding.contains(id) {
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
                    fileID: row.int(0), kind: FileKind(rawValue: row.text(1) ?? "") ?? .raw,
                    volumeID: row.int(2), relativePath: row.text(3) ?? ""
                )
            }
            .sorted { $0.kind.previewPriority < $1.kind.previewPriority }
            jobs.append(PreviewJob(photoID: id, needsThumb: false, needsPreview: false, sources: sources))
        }
        return jobs
    }
}

// MARK: - 写

extension Library {
    /// 一批照片的对焦框，一个事务写完。
    public func saveFocus(_ results: [(PhotoID, FocusPointReader.Result)]) throws {
        guard !results.isEmpty else { return }
        try db.transaction {
            for (photo, result) in results {
                switch result {
                case .found(let area):
                    try db.run(
                        "UPDATE photos SET focus_state = 'found', focus_x = ?, focus_y = ?, focus_w = ?, focus_h = ? WHERE id = ?;",
                        [area.x, area.y, area.width, area.height, photo]
                    )
                case .notRecorded:
                    try db.run("UPDATE photos SET focus_state = 'none' WHERE id = ?;", [photo])
                }
            }
        }
    }
}

// MARK: - 后台读

/// 原片在线时读还没读过的对焦框：每张只读文件头的几处（真实卡 4,300 个文件约 6 秒）。
/// 文件读不了（卡中途拔了）的这一轮跳过，下次插上再读。
public struct FocusRunner: Sendable {
    public let library: Library
    public var batchSize = 200

    public init(library: Library) {
        self.library = library
    }

    /// 返回这一轮读了多少张。
    @discardableResult
    public func run(mountURLs: [VolumeID: URL], shouldStop: @Sendable () -> Bool = { false }) throws -> Int {
        var skipped: Set<PhotoID> = []
        var done = 0
        while !shouldStop() {
            let jobs = try library.reader.photosNeedingFocus(limit: batchSize, onVolumes: Array(mountURLs.keys), excluding: skipped)
            guard !jobs.isEmpty else { break }
            var results: [(PhotoID, FocusPointReader.Result)] = []
            for job in jobs {
                guard !shouldStop() else { break }
                let result = job.sources.lazy.compactMap { source in
                    mountURLs[source.volumeID].flatMap { FocusPointReader.read(at: $0.appendingPathComponent(source.relativePath)) }
                }.first
                if let result { results.append((job.photoID, result)) } else { skipped.insert(job.photoID) }
            }
            try library.saveFocus(results)
            done += results.count
        }
        return done
    }
}
