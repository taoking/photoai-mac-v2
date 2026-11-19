import CryptoKit
import Darwin
import Foundation

// MARK: - 清卡检查（设计稿 §5，数据模型 §7）

/// 清卡检查的结论。卡上每个文件（RAW、JPEG 分开算）归入三类之一，另列预览没就绪的照片。
public struct ClearCardReport: Sendable, Equatable {
    /// 至少有一个文件缺副本的照片。
    public struct MissingPhoto: Sendable, Equatable, Identifiable {
        public var id: PhotoID
        public var baseName: String
        /// 缺副本的文件（补副本只复制这些）。
        public var missingFileIDs: [FileID]
        public var missingKinds: [FileKind]
        /// 卡上这张照片的文件里，有的有副本、有的没有（比如备份盘只有 JPEG）。
        public var isPartial: Bool
        public var rating: Int
        public var flag: Flag
        public var inCollection: Bool

        /// 已打星、已 Pick 或在收藏夹里：清卡时最该留意的。
        public var isMarked: Bool { rating > 0 || flag == .pick || inCollection }
    }

    public var volumeID: VolumeID
    public var photoCount = 0
    public var fileCount = 0
    /// 在线卷上有副本，刚确认还在、大小一致。
    public var verifiedFileCount = 0
    /// 副本只在离线卷上，按上次扫描结果，没法当场核对。
    public var offlineOnlyFileCount = 0
    public var missingFileCount = 0
    /// 只有离线记录的副本在哪些卷上。
    public var offlineCopyVolumeIDs: [VolumeID] = []
    public var missingPhotos: [MissingPhoto] = []
    /// 480 或 1600 预览还没就绪的照片（含生成失败的）。
    public var previewPendingPhotoIDs: [PhotoID] = []
    public var previewFailedCount = 0
    /// 当场核对发现已经不在、顺手改为历史的副本数。
    public var vanishedCopyCount = 0
    /// 副本还在但对不上（大小变了、读不了）：不算核实，原样报告，位置不动。
    public var problems: [String] = []

    public init(volumeID: VolumeID) { self.volumeID = volumeID }

    /// 只有卡上所有文件都已核实、预览全部就绪，才能清空。
    public var canClear: Bool { verifiedFileCount == fileCount && previewPendingPhotoIDs.isEmpty }
    /// 只缺 RAW 的照片（别处只有 JPEG）。
    public var missingRAWOnlyCount: Int { missingPhotos.filter { $0.isPartial && $0.missingKinds == [.raw] }.count }
}

/// 移除卷之前的影响（确认框里说明用），按库里的记录算，不碰磁盘。
public struct RemovalImpact: Sendable, Equatable {
    public var photoCount = 0
    /// 别处一个现存位置都没有：移除后进入“无卷关联照片”。
    public var orphanedCount = 0
    /// 别处有副本，但卡上有的文件别处没有（比如缺 RAW）：照常显示。
    public var partialCount = 0

    public init() {}
}

extension LibraryReader {
    /// 这个卷上有文件别处没有现存副本（大小一致才算）的照片数。标题行的“N 张缺副本”，按记录算，离线卷上的副本也算。
    public func missingCopyCount(volume: VolumeID) throws -> Int {
        try db.scalarInt(
            """
            SELECT COUNT(DISTINCT f.photo_id) FROM locations l JOIN files f ON f.id = l.file_id
            WHERE l.volume_id = ? AND l.status = 'present' AND NOT EXISTS (
                SELECT 1 FROM locations o JOIN volumes v ON v.id = o.volume_id
                WHERE o.file_id = l.file_id AND o.volume_id != l.volume_id AND o.status = 'present'
                  AND v.status = 'active' AND o.file_size = l.file_size
            );
            """,
            [volume]
        )
    }

    public func removalImpact(volume: VolumeID) throws -> RemovalImpact {
        var impact = RemovalImpact()
        impact.photoCount = try db.scalarInt(
            """
            SELECT COUNT(DISTINCT f.photo_id) FROM locations l JOIN files f ON f.id = l.file_id
            WHERE l.volume_id = ? AND l.status = 'present';
            """,
            [volume]
        )
        impact.orphanedCount = try db.scalarInt(
            """
            SELECT COUNT(*) FROM photos p
            WHERE p.id IN (
                SELECT f.photo_id FROM locations l JOIN files f ON f.id = l.file_id
                WHERE l.volume_id = ? AND l.status = 'present'
            ) AND NOT EXISTS (
                SELECT 1 FROM files g JOIN locations o ON o.file_id = g.id
                WHERE g.photo_id = p.id AND o.volume_id != ? AND o.status = 'present'
            );
            """,
            [volume, volume]
        )
        impact.partialCount = try missingCopyCount(volume: volume) - impact.orphanedCount
        return impact
    }
}

extension OriginalFinder {
    public enum Presence: Equatable {
        case present
        /// 卷还挂着，文件不在了。
        case missing
        case offline
        /// 在，但对不上（大小和上次扫描时不同、读不了）。
        case mismatch(String)
    }

    /// 只 `stat` 不打开：清卡检查当场确认副本还在。和 `open` 同样只在卷确实还挂着时才算“不在”。
    public func presence(_ source: OriginalSource) -> Presence {
        guard let url = url(source) else { return .offline }
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            let code = errno
            guard isStillMounted(source.volumeID) else { return .offline }
            return code == ENOENT || code == ENOTDIR ? .missing : .mismatch(String(cString: strerror(code)))
        }
        return Int(info.st_size) == source.fileSize ? .present : .mismatch("大小和上次扫描时不一样")
    }
}

/// 清卡检查：按文件核对卡上每个文件在别的卷上的副本，在线的当场确认（设计稿 §5）。
public struct ClearCardChecker: Sendable {
    public var library: Library
    public var finder: OriginalFinder

    public init(library: Library, finder: OriginalFinder) {
        self.library = library
        self.finder = finder
    }

    private struct CardFile {
        var fileID: FileID
        var photoID: PhotoID
        var kind: FileKind
        var size: Int
    }

    private struct PhotoInfo {
        var baseName: String
        var rating: Int
        var flag: Flag
        var inCollection: Bool
        var previewsReady: Bool
        var previewFailed: Bool
    }

    public func check(volumeID: VolumeID) throws -> ClearCardReport {
        let db = library.db
        var report = ClearCardReport(volumeID: volumeID)
        var files: [FileID: CardFile] = [:]
        var fileOrder: [FileID] = []
        var photos: [PhotoID: PhotoInfo] = [:]
        var photoOrder: [PhotoID] = []
        try db.query(
            """
            SELECT l.file_id, f.photo_id, f.kind, l.file_size, p.base_name, p.rating, p.flag, p.thumb_state, p.preview_state,
                   EXISTS (SELECT 1 FROM collection_members c WHERE c.photo_id = p.id)
            FROM locations l JOIN files f ON f.id = l.file_id JOIN photos p ON p.id = f.photo_id
            WHERE l.volume_id = ? AND l.status = 'present'
            ORDER BY p.capture_date, p.capture_subsec, p.base_name, f.kind, l.id;
            """,
            [volumeID]
        ) { row in
            let fileID = row.int(0), photoID = row.int(1)
            if files[fileID] == nil {
                files[fileID] = CardFile(fileID: fileID, photoID: photoID, kind: FileKind(rawValue: row.text(2) ?? "") ?? .raw, size: row.int(3))
                fileOrder.append(fileID)
            }
            if photos[photoID] == nil {
                let thumb = row.text(7), preview = row.text(8)
                photos[photoID] = PhotoInfo(
                    baseName: row.text(4) ?? "",
                    rating: row.int(5),
                    flag: Flag(rawValue: row.text(6) ?? "") ?? .none,
                    inCollection: row.int(9) != 0,
                    previewsReady: thumb == "ready" && preview == "ready",
                    previewFailed: thumb == "failed" || preview == "failed"
                )
                photoOrder.append(photoID)
            }
        }

        // 别的在用卷上的现存位置。
        var copies: [FileID: [OriginalSource]] = [:]
        try db.query(
            """
            SELECT o.file_id, f.photo_id, f.kind, f.extension, o.id, o.volume_id, o.relative_path, o.file_size
            FROM locations l
            JOIN locations o ON o.file_id = l.file_id AND o.volume_id != l.volume_id AND o.status = 'present'
            JOIN volumes v ON v.id = o.volume_id AND v.status = 'active'
            JOIN files f ON f.id = o.file_id
            WHERE l.volume_id = ? AND l.status = 'present'
            ORDER BY o.id;
            """,
            [volumeID]
        ) { row in
            let source = OriginalSource(
                photoID: row.int(1),
                fileID: row.int(0),
                kind: FileKind(rawValue: row.text(2) ?? "") ?? .raw,
                fileExtension: row.text(3) ?? "",
                locationID: row.int(4),
                volumeID: row.int(5),
                relativePath: row.text(6) ?? "",
                fileSize: row.int(7)
            )
            if !(copies[source.fileID]?.contains { $0.locationID == source.locationID } ?? false) {
                copies[source.fileID, default: []].append(source)
            }
        }

        var vanished: [Int] = []
        var offlineVolumes: Set<VolumeID> = []
        var missingByPhoto: [PhotoID: [CardFile]] = [:]
        var filesByPhoto: [PhotoID: Int] = [:]
        for fileID in fileOrder {
            let file = files[fileID]!
            filesByPhoto[file.photoID, default: 0] += 1
            let same = (copies[fileID] ?? []).filter { $0.fileSize == file.size }
            var verified = false
            for copy in same where finder.mounts[copy.volumeID] != nil {
                switch finder.presence(copy) {
                case .present: verified = true
                case .missing: vanished.append(copy.locationID)
                case .offline: continue
                case .mismatch(let reason): report.problems.append("\(copy.fileName)：\(reason)")
                }
                if verified { break }
            }
            if verified {
                report.verifiedFileCount += 1
                continue
            }
            let offline = same.filter { finder.mounts[$0.volumeID] == nil }
            if !offline.isEmpty {
                report.offlineOnlyFileCount += 1
                offline.forEach { offlineVolumes.insert($0.volumeID) }
            } else {
                report.missingFileCount += 1
                missingByPhoto[file.photoID, default: []].append(file)
            }
        }
        report.fileCount = fileOrder.count
        report.photoCount = photoOrder.count
        report.offlineCopyVolumeIDs = offlineVolumes.sorted()
        for photoID in photoOrder {
            let info = photos[photoID]!
            if !info.previewsReady {
                report.previewPendingPhotoIDs.append(photoID)
                if info.previewFailed { report.previewFailedCount += 1 }
            }
            guard let missing = missingByPhoto[photoID] else { continue }
            report.missingPhotos.append(ClearCardReport.MissingPhoto(
                id: photoID,
                baseName: info.baseName,
                missingFileIDs: missing.map(\.fileID),
                missingKinds: missing.map(\.kind),
                isPartial: missing.count < filesByPhoto[photoID, default: 0],
                rating: info.rating,
                flag: info.flag,
                inCollection: info.inCollection
            ))
        }
        if !vanished.isEmpty {
            try library.markLocationsMissing(vanished)
            report.vanishedCopyCount = vanished.count
        }
        return report
    }
}

// MARK: - 补副本（设计稿 §5.3，数据模型 §7）

public enum BackfillError: Error, CustomStringConvertible, Equatable {
    case sameVolume
    case targetNotActive
    case targetOffline(String)
    case outsideScanRoot(volume: String, scanRoot: String)

    public var description: String {
        switch self {
        case .sameVolume: "目标不能是这张卡自己"
        case .targetNotActive: "目标卷不存在或已移除"
        case .targetOffline(let name): "「\(name)」没有插上"
        case .outsideScanRoot(let name, let root):
            "目标文件夹要在「\(name)」的扫描文件夹「\(root.isEmpty ? "整个卷" : root)」里面，不然以后重扫看不到这些副本"
        }
    }
}

public struct BackfillReport: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public var fileName: String
        public var reason: String
    }

    /// 复制并校验通过的文件。
    public var copiedFiles = 0
    public var copiedBytes = 0
    /// 目标里已有逐字节相同的同名文件（比如上次补到一半），不再复制，照样登记。
    public var identicalFiles = 0
    /// 因为目标有同名的不同文件而换用的子目录（相对目标卷根目录）。
    public var subfolders: [String] = []
    public var failures: [Failure] = []
    /// 源文件已不在卡上（卡还挂着），位置改为历史。
    public var vanishedSourceCount = 0
    /// 整个补副本停下的原因（目标盘写满、取消、卡被拔出）。
    public var stopReason: String?
    /// 补完后扫描目标目录的结果。
    public var scan: ScanSummary?
    /// 扫描后在目标卷上有了现存位置的文件数。
    public var registeredFiles = 0

    public init() {}
}

public struct BackfillProgress: Sendable, Equatable {
    public var filesDone: Int
    public var fileCount: Int
    public var bytesDone: Int
}

/// 补副本：把缺副本的文件复制到用户选的卷（设计稿 §5）。
///
/// - 保留原文件名，同一张照片的文件放在同一目录；目标已有同名的不同文件时整组换到新的子目录
///   `补副本-日期/`（再冲突就 `补副本-日期-2/`），目标上已有的文件一字节都不动。
/// - 边读边算源文件的 SHA-256，写进临时文件、落盘后绕过缓存读回再算一次，相同才改成正式名字。
/// - 最后扫描目标目录登记副本：靠扫描按身份挂到原来的照片上，和平时插盘一样。
public struct Backfiller: Sendable {
    public var library: Library
    public var finder: OriginalFinder
    public var scanner: VolumeScanner
    public var chunkSize = 1 << 20

    public init(library: Library, finder: OriginalFinder, scanner: VolumeScanner) {
        self.library = library
        self.finder = finder
        self.scanner = scanner
    }

    public static let subfolderPrefix = "补副本-"

    public func run(
        _ photos: [ClearCardReport.MissingPhoto],
        from sourceVolume: VolumeID,
        to targetVolume: VolumeID,
        directory: String,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        progress: (@Sendable (BackfillProgress) -> Void)? = nil
    ) async throws -> BackfillReport {
        guard sourceVolume != targetVolume else { throw BackfillError.sameVolume }
        guard let target = try library.reader.volume(id: targetVolume), target.status == .active else {
            throw BackfillError.targetNotActive
        }
        guard let mount = finder.mounts[targetVolume] else { throw BackfillError.targetOffline(target.name) }
        let directory = Library.normalizedDirectory(directory)
        guard Library.isDirectory(directory, inside: target.scanRoot) else {
            throw BackfillError.outsideScanRoot(volume: target.name, scanRoot: target.scanRoot)
        }

        // 每张照片要复制的文件：卡上的位置。
        let wanted = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, Set($0.missingFileIDs)) })
        let sources = try library.reader.presentSources(of: photos.map(\.id))
        var groups: [[OriginalSource]] = []
        for photo in photos {
            var seen: Set<FileID> = []
            let group = (sources[photo.id] ?? []).filter {
                $0.volumeID == sourceVolume && wanted[photo.id]!.contains($0.fileID) && seen.insert($0.fileID).inserted
            }
            if !group.isEmpty { groups.append(group) }
        }

        var report = BackfillReport()
        let copy = BackfillCopy(backfiller: self, isCancelled: isCancelled)
        let fileCount = groups.reduce(0) { $0 + $1.count }
        var done = 0
        var vanished: [Int] = []
        var registered: [(fileID: FileID, path: String)] = []
        let date = Self.dateFormatter.string(from: library.now())

        groupLoop: for (index, group) in groups.enumerated() {
            if let stop = report.stopReason ?? (isCancelled() ? "已取消" : nil) {
                report.stopReason = stop
                for rest in groups[index...].joined() {
                    report.failures.append(.init(fileName: rest.fileName, reason: "没有复制：\(stop)"))
                }
                break
            }
            let folder = copy.folder(for: group, in: directory, mount: mount, date: date)
            if folder != directory, !report.subfolders.contains(folder) { report.subfolders.append(folder) }
            for (fileIndex, source) in group.enumerated() {
                defer {
                    done += 1
                    progress?(BackfillProgress(filesDone: done, fileCount: fileCount, bytesDone: report.copiedBytes))
                }
                let relative = Library.join(folder, source.fileName)
                switch finder.open(source) {
                case .missing:
                    vanished.append(source.locationID)
                    report.failures.append(.init(fileName: source.fileName, reason: "源文件已不在卡上"))
                case .offline:
                    report.stopReason = "卡已拔出"
                    for rest in group[fileIndex...] {
                        report.failures.append(.init(fileName: rest.fileName, reason: "没有复制：卡已拔出"))
                    }
                    done += group.count - fileIndex - 1
                    continue groupLoop
                case .unreadable(let reason):
                    report.failures.append(.init(fileName: source.fileName, reason: reason))
                case .file(let fd, _, let size, let modified):
                    defer { Darwin.close(fd) }
                    do {
                        switch try copy.copy(fd: fd, size: size, modified: modified, to: mount.appendingPathComponent(relative)) {
                        case .copied:
                            report.copiedFiles += 1
                            report.copiedBytes += size
                        case .identical:
                            report.identicalFiles += 1
                        }
                        registered.append((source.fileID, relative))
                    } catch BackfillCopy.Failure.file(let reason) {
                        report.failures.append(.init(fileName: source.fileName, reason: reason))
                    } catch BackfillCopy.Failure.stop(let reason) {
                        report.stopReason = reason
                        for rest in group[fileIndex...] {
                            report.failures.append(.init(fileName: rest.fileName, reason: "没有复制：\(reason)"))
                        }
                        done += group.count - fileIndex - 1
                        continue groupLoop
                    }
                }
            }
        }

        if !vanished.isEmpty {
            try library.markLocationsMissing(vanished)
            report.vanishedSourceCount = vanished.count
        }
        if !registered.isEmpty {
            report.scan = try await scanner.scan(volumeID: targetVolume, mountURL: mount, subtree: directory, isCancelled: { false })
            report.registeredFiles = try registered.filter { item in
                try library.reader.hasPresentLocation(file: item.fileID, volume: targetVolume, relativePath: item.path)
            }.count
        }
        return report
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

extension LibraryReader {
    /// 这个文件在这个卷的这个路径上有现存位置吗（补副本后核对登记）。
    public func hasPresentLocation(file: FileID, volume: VolumeID, relativePath: String) throws -> Bool {
        try db.scalarInt(
            "SELECT COUNT(*) FROM locations WHERE file_id = ? AND volume_id = ? AND relative_path = ? AND status = 'present';",
            [file, volume, relativePath]
        ) > 0
    }
}

/// 一次补副本里的复制：选目录、写临时文件、校验、改名。
private struct BackfillCopy {
    let backfiller: Backfiller
    let isCancelled: @Sendable () -> Bool

    enum Failure: Error {
        /// 这一个文件没成功，接着做下一个。
        case file(String)
        /// 整个补副本停下（目标盘写满、只读、取消）。
        case stop(String)
    }

    enum Outcome { case copied, identical }

    /// 这组文件放在哪个目录：目标目录里没有同名文件（或者同名的逐字节相同）就放在目标目录，
    /// 否则换到 `补副本-日期/`、`补副本-日期-2/`……里第一个不冲突的。
    func folder(for group: [OriginalSource], in directory: String, mount: URL, date: String) -> String {
        var n = 0
        while true {
            let name = n == 0 ? directory
                : Library.join(directory, Backfiller.subfolderPrefix + date + (n == 1 ? "" : "-\(n)"))
            let conflict = group.contains { source in
                let url = mount.appendingPathComponent(Library.join(name, source.fileName))
                guard FileManager.default.fileExists(atPath: url.path) else { return false }
                return !sameContents(source, as: url)
            }
            if !conflict { return name }
            n += 1
        }
    }

    /// 目标里同名的文件和源文件逐字节相同吗？源文件打不开时当作不同（换目录，绝不碰已有文件）。
    private func sameContents(_ source: OriginalSource, as target: URL) -> Bool {
        guard (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) == source.fileSize,
              case .file(let fd, _, _, _) = backfiller.finder.open(source) else { return false }
        defer { Darwin.close(fd) }
        let other = Darwin.open(target.path, O_RDONLY)
        guard other >= 0 else { return false }
        defer { Darwin.close(other) }
        guard let a = try? digest(fd: fd), let b = try? digest(fd: other) else { return false }
        return a == b
    }

    func copy(fd: Int32, size: Int, modified: timespec, to target: URL) throws -> Outcome {
        if FileManager.default.fileExists(atPath: target.path) {
            // `folder(for:)` 只在同名文件逐字节相同时才留在这个目录。
            return .identical
        }
        let folder = target.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Failure.stop("建不了目录 \(folder.lastPathComponent)：\((error as NSError).localizedDescription)")
        }
        let temp = folder.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString)\(PhotoExport.partSuffix)")
        var keep = false
        defer { if !keep { unlink(temp.path) } }
        let written = try write(fd: fd, size: size, modified: modified, to: temp)
        // 绕过缓存读回刚写的文件再算一次。
        let check = Darwin.open(temp.path, O_RDONLY)
        guard check >= 0 else { throw Failure.file("读不回刚写的文件：\(String(cString: strerror(errno)))") }
        defer { Darwin.close(check) }
        _ = fcntl(check, F_NOCACHE, 1)
        let readBack = try digest(fd: check)
        guard readBack == written else { throw Failure.file("校验不一致：写进去的和读出来的不同") }
        switch PhotoExport.renameExclusive(temp, to: target) {
        case 0:
            keep = true
            return .copied
        case EEXIST:
            throw Failure.file("目标里刚出现了同名文件，没有覆盖")
        case let code:
            throw Failure.stop(PhotoExport.destinationMessage(code, target))
        }
    }

    /// 写临时文件，边读边算源文件的 SHA-256。
    private func write(fd: Int32, size: Int, modified: timespec, to temp: URL) throws -> SHA256.Digest {
        let out = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard out >= 0 else { throw Failure.stop(PhotoExport.destinationMessage(errno, temp)) }
        defer { Darwin.close(out) }
        _ = fcntl(out, F_NOCACHE, 1)
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw Failure.file("读不了：\(String(cString: strerror(errno)))") }
        let chunk = backfiller.chunkSize
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        var total = 0
        while true {
            if isCancelled() { throw Failure.stop("已取消") }
            let count = read(fd, buffer, chunk)
            if count < 0 { throw Failure.file("读到一半出错：\(String(cString: strerror(errno)))") }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            var offset = 0
            while offset < count {
                let written = Darwin.write(out, buffer + offset, count - offset)
                guard written > 0 else { throw Failure.stop(PhotoExport.destinationMessage(errno, temp)) }
                offset += written
            }
            total += count
        }
        guard total == size else { throw Failure.file("读到的字节数（\(total)）和文件大小（\(size)）不一致") }
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), modified]
        futimens(out, &times)
        guard fsync(out) == 0 else { throw Failure.stop(PhotoExport.destinationMessage(errno, temp)) }
        return hasher.finalize()
    }

    private func digest(fd: Int32) throws -> SHA256.Digest {
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw Failure.file("读不了：\(String(cString: strerror(errno)))") }
        let chunk = backfiller.chunkSize
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        while true {
            if isCancelled() { throw Failure.stop("已取消") }
            let count = read(fd, buffer, chunk)
            if count < 0 { throw Failure.file("读到一半出错：\(String(cString: strerror(errno)))") }
            if count == 0 { return hasher.finalize() }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
        }
    }
}
