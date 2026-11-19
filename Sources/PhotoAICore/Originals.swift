import Darwin
import Foundation
import ImageIO

/// 一个文件的一个现存位置。导出、100% 放大读原文件时按顺序尝试。
public struct OriginalSource: Sendable, Equatable {
    public var photoID: PhotoID
    public var fileID: FileID
    public var kind: FileKind
    /// 文件扩展名，保持卡上的大小写。
    public var fileExtension: String
    public var locationID: Int
    public var volumeID: VolumeID
    public var relativePath: String
    /// 上次扫描时的大小。
    public var fileSize: Int

    public var fileName: String { (relativePath as NSString).lastPathComponent }
    /// 位置所在的目录，相对卷根目录。
    public var directory: String { (relativePath as NSString).deletingLastPathComponent }
}

extension LibraryReader {
    /// 照片的全部现存位置（不管卷在不在线），按照片分组，同一张照片按位置记录的先后排列。
    public func presentSources(of photoIDs: [PhotoID]) throws -> [PhotoID: [OriginalSource]] {
        var result: [PhotoID: [OriginalSource]] = [:]
        for chunk in photoIDs.chunked(into: 4_000) {
            let list = chunk.map(String.init).joined(separator: ",")
            try db.query(
                """
                SELECT f.photo_id, f.id, f.kind, f.extension, l.id, l.volume_id, l.relative_path, l.file_size
                FROM files f JOIN locations l ON l.file_id = f.id JOIN volumes v ON v.id = l.volume_id
                WHERE f.photo_id IN (\(list)) AND l.status = 'present' AND v.status = 'active'
                ORDER BY f.photo_id, l.id;
                """
            ) { row in
                let path = row.text(6) ?? ""
                let source = OriginalSource(
                    photoID: row.int(0),
                    fileID: row.int(1),
                    kind: FileKind(rawValue: row.text(2) ?? "") ?? .raw,
                    fileExtension: (path as NSString).pathExtension.isEmpty ? (row.text(3) ?? "") : (path as NSString).pathExtension,
                    locationID: row.int(4),
                    volumeID: row.int(5),
                    relativePath: path,
                    fileSize: row.int(7)
                )
                result[source.photoID, default: []].append(source)
            }
        }
        return result
    }

    /// 位置上次扫描时记下的修改时间（验收核对源文件没被改动用）。
    public func scannedModificationTime(location: Int) throws -> Double? {
        try db.first("SELECT file_mtime FROM locations WHERE id = ?;", [location]) { $0.optionalDouble(0) } ?? nil
    }

    /// 照片所在的收藏夹。
    public func collectionIDs(of photoIDs: [PhotoID]) throws -> [PhotoID: [CollectionID]] {
        var result: [PhotoID: [CollectionID]] = [:]
        for chunk in photoIDs.chunked(into: 4_000) {
            let list = chunk.map(String.init).joined(separator: ",")
            try db.query(
                "SELECT photo_id, collection_id FROM collection_members WHERE photo_id IN (\(list)) ORDER BY collection_id;"
            ) { row in result[row.int(0), default: []].append(row.int(1)) }
        }
        return result
    }
}

extension Library {
    /// 读原文件时发现文件已经不在（卷还挂着）：这些位置改为历史（设计稿 §4.1）。
    /// 返回因此没有现存位置、进入“无卷关联照片”的照片。
    @discardableResult
    public func markLocationsMissing(_ locationIDs: [Int]) throws -> [PhotoID] {
        guard !locationIDs.isEmpty else { return [] }
        return try db.transaction {
            let list = locationIDs.map(String.init).joined(separator: ",")
            let photos = try db.all(
                "SELECT DISTINCT f.photo_id FROM locations l JOIN files f ON f.id = l.file_id WHERE l.id IN (\(list));"
            ) { $0.int(0) }
            try markHistorical(locationIDs: locationIDs)
            let hidden = photos.map(String.init).joined(separator: ",")
            return try db.all("SELECT id FROM photos WHERE id IN (\(hidden)) AND present_location_count = 0 ORDER BY id;") { $0.int(0) }
        }
    }
}

/// 按位置找原文件。在线 / 离线只看卷有没有挂载；只有卷确实还挂着、文件却不在，才算“原片已不在”。
/// 拔卡时挂载点下的路径也会消失，那不是文件被删，不能改成历史位置。
public struct OriginalFinder: Sendable {
    public var mounts: [VolumeID: URL]
    /// 卷是否仍然挂在原来的挂载点上。
    public var isStillMounted: @Sendable (VolumeID) -> Bool

    public init(mounts: [VolumeID: URL], isStillMounted: @escaping @Sendable (VolumeID) -> Bool) {
        self.mounts = mounts
        self.isStillMounted = isStillMounted
    }

    /// 用卷 UUID 核对挂载点：挂载点还在、UUID 没变才算还挂着。
    public init(mounts: [VolumeID: URL], volumeUUIDs: [VolumeID: String]) {
        self.init(mounts: mounts) { id in
            guard let url = mounts[id], let uuid = volumeUUIDs[id] else { return false }
            return (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == uuid
        }
    }

    public enum Opened {
        /// 打开了，调用方负责 `close(fd)`。
        case file(fd: Int32, url: URL, size: Int, modified: timespec)
        /// 卷还挂着，文件不在了。
        case missing
        /// 卷不在线（或者刚被拔掉）。
        case offline
        /// 文件在，但读不了（权限、读写错误、大小和上次扫描时不同）。不改历史位置。
        case unreadable(String)
    }

    public func url(_ source: OriginalSource) -> URL? {
        mounts[source.volumeID]?.appendingPathComponent(source.relativePath)
    }

    public func open(_ source: OriginalSource) -> Opened {
        guard let url = url(source) else { return .offline }
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR {
                return isStillMounted(source.volumeID) ? .missing : .offline
            }
            return isStillMounted(source.volumeID) ? .unreadable(String(cString: strerror(code))) : .offline
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            return .unreadable(message)
        }
        guard Int(info.st_size) == source.fileSize else {
            Darwin.close(fd)
            return .unreadable("文件和上次扫描时不一样（大小变了），重新扫描这个卷后再试")
        }
        return .file(fd: fd, url: url, size: Int(info.st_size), modified: info.st_mtimespec)
    }

    public struct Lookup: Sendable {
        public var found: (source: OriginalSource, url: URL)?
        public var missingLocationIDs: [Int] = []
        public var problems: [String] = []
    }

    /// 依次尝试各个位置，返回第一个能打开的文件，以及途中发现已经不在的位置。
    /// 100% 放大用：只确认能打开，解码交给调用方。
    public func lookup(_ sources: [OriginalSource]) -> Lookup {
        var lookup = Lookup()
        for source in sources {
            switch open(source) {
            case .file(let fd, let url, _, _):
                Darwin.close(fd)
                lookup.found = (source, url)
                return lookup
            case .missing:
                lookup.missingLocationIDs.append(source.locationID)
            case .offline:
                continue
            case .unreadable(let reason):
                lookup.problems.append("\(source.fileName)：\(reason)")
            }
        }
        return lookup
    }
}

extension OriginalFinder {
    /// 100% 放大用：每个文件找第一个能打开的位置，优先用 JPEG（解码快十倍以上，和预览、相机直出一致）。
    /// JPEG 的长边不到最大那个文件的九成时（相机同时存 RAW 和小尺寸 JPEG）才用 RAW。
    /// 比长边不比面积：相机设成 16:9 时 JPEG 是 7008×3944、RAW 仍是 7008×4672，清晰度一样，应当用 JPEG。
    public func lookupForViewing(_ sources: [OriginalSource]) -> Lookup {
        var lookup = Lookup()
        var candidates: [(source: OriginalSource, url: URL, longEdge: Int)] = []
        let ordered = sources.enumerated().sorted {
            ($0.element.kind.previewPriority, $0.offset) < ($1.element.kind.previewPriority, $1.offset)
        }.map(\.element)
        var opened: Set<FileID> = []
        for source in ordered where !opened.contains(source.fileID) {
            let one = self.lookup([source])
            lookup.missingLocationIDs += one.missingLocationIDs
            lookup.problems += one.problems
            guard let found = one.found else { continue }
            opened.insert(source.fileID)
            let longEdge = OriginalDecoder.pixelSize(at: found.url).map { max($0.width, $0.height) } ?? 0
            candidates.append((found.source, found.url, longEdge))
        }
        let largest = candidates.map(\.longEdge).max() ?? 0
        lookup.found = candidates.first { Double($0.longEdge) >= Double(largest) * 0.9 }.map { ($0.source, $0.url) }
        return lookup
    }
}

/// 把原文件完整解码，按 EXIF 方向转正（100% 放大用）。
public enum OriginalDecoder {
    /// 转正之后的像素尺寸，只读文件头。
    public static func pixelSize(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return nil
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }

    public static func decode(_ url: URL) -> CGImage? {
        guard let size = pixelSize(at: url),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height)
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
