import Darwin
import Foundation

/// 导出原文件去精修（设计稿 §6、信息架构 §7）：只复制、不覆盖、同名自动改名。
public struct ExportRequest: Sendable, Equatable {
    public enum Files: String, Sendable, CaseIterable {
        /// 只导出 RAW；没有 RAW 的导出 JPEG（或其他格式）。
        case raw
        /// 只导出 JPEG（或其他非 RAW 格式）；没有的导出 RAW。
        case jpeg
        case both
    }

    public enum Layout: String, Sendable, CaseIterable {
        case flat
        /// 每个收藏夹一个子文件夹。范围是某个收藏夹时只有这一个；否则照片在几个收藏夹里就放进几个，
        /// 不在任何收藏夹里的放进“未归入收藏夹”。
        case byCollection
        /// `卷名/原来的目录/`。
        case original
    }

    public var photoIDs: [PhotoID]
    public var files: Files
    public var layout: Layout
    public var destination: URL
    /// 范围是某个收藏夹时填上：按收藏夹分子文件夹只用这一个。
    public var collection: CollectionID?

    public init(photoIDs: [PhotoID], files: Files, layout: Layout, destination: URL, collection: CollectionID? = nil) {
        self.photoIDs = photoIDs
        self.files = files
        self.layout = layout
        self.destination = destination
        self.collection = collection
    }
}

/// 一张照片要导出哪些文件：先试 `primary`，一个都没导出时再试 `fallback`（“没有 RAW 的导出 JPEG”）。
/// 每一项是同一个文件的全部现存位置。
struct ExportFilePick {
    var primary: [[OriginalSource]]
    var fallback: [[OriginalSource]]

    init(_ sources: [OriginalSource], files: ExportRequest.Files) {
        var groups: [[OriginalSource]] = []
        var index: [FileID: Int] = [:]
        for source in sources {
            if let position = index[source.fileID] {
                groups[position].append(source)
            } else {
                index[source.fileID] = groups.count
                groups.append([source])
            }
        }
        // RAW 在前，和相机里的顺序一样；其他格式按预览优先级。
        groups.sort { $0[0].kind.previewPriority > $1[0].kind.previewPriority }
        let raws = groups.filter { $0[0].kind == .raw }
        let others = groups.filter { $0[0].kind != .raw }
        switch files {
        case .both: (primary, fallback) = (groups, [])
        case .raw: (primary, fallback) = raws.isEmpty ? (others, []) : (raws, others)
        case .jpeg: (primary, fallback) = others.isEmpty ? (raws, []) : (others, raws)
        }
    }

    /// 只看在线的位置。
    func online(_ online: Set<VolumeID>) -> ExportFilePick {
        var pick = self
        pick.primary = primary.map { $0.filter { online.contains($0.volumeID) } }.filter { !$0.isEmpty }
        pick.fallback = fallback.map { $0.filter { online.contains($0.volumeID) } }.filter { !$0.isEmpty }
        if pick.primary.isEmpty { (pick.primary, pick.fallback) = (pick.fallback, []) }
        return pick
    }
}

/// 导出面板底部的“需要的卷”：哪些照片能从在线卷导出，哪些只在离线卷上。
public struct ExportPlan: Sendable, Equatable {
    public struct VolumeNeed: Sendable, Equatable, Identifiable {
        public var volumeID: VolumeID
        public var name: String
        public var isOnline: Bool
        public var photoCount: Int
        public var id: VolumeID { volumeID }
    }

    public var onlinePhotoIDs: [PhotoID] = []
    /// 现存位置都在离线卷上的照片。
    public var offlinePhotoIDs: [PhotoID] = []
    public var volumes: [VolumeNeed] = []
    /// 在线部分要复制的文件数和大约的字节数（按上次扫描的大小）。
    public var fileCount = 0
    public var byteCount = 0

    public init(
        photoIDs: [PhotoID],
        sources: [PhotoID: [OriginalSource]],
        files: ExportRequest.Files,
        online: Set<VolumeID>,
        volumeNames: [VolumeID: String]
    ) {
        var counts: [VolumeID: (isOnline: Bool, count: Int)] = [:]
        for id in photoIDs {
            let all = sources[id] ?? []
            guard let first = all.first else { continue }
            let pick = ExportFilePick(all, files: files).online(online)
            if let source = pick.primary.first?.first {
                onlinePhotoIDs.append(id)
                counts[source.volumeID, default: (true, 0)].count += 1
                fileCount += pick.primary.count
                byteCount += pick.primary.reduce(0) { $0 + $1[0].fileSize }
            } else {
                offlinePhotoIDs.append(id)
                counts[first.volumeID, default: (false, 0)].count += 1
            }
        }
        volumes = counts.map { VolumeNeed(volumeID: $0.key, name: volumeNames[$0.key] ?? "卷", isOnline: $0.value.isOnline, photoCount: $0.value.count) }
            .sorted { ($0.isOnline ? 0 : 1, $0.name) < ($1.isOnline ? 0 : 1, $1.name) }
    }
}

/// 一次导出的结果。只有确实写完、改名到位的文件才计入成功。
public struct ExportReport: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public var photoID: PhotoID
        /// 文件名，例如 `DSC01926.ARW`。
        public var name: String
        public var reason: String
    }

    public var destination: URL
    /// 至少有一个文件导出成功（或目标里已有一模一样的文件）的照片。
    public var exportedPhotos = 0
    public var copiedFiles = 0
    /// 目标里已经有同名、内容一样的文件（比如上次导出到一半），没有再复制。
    public var identicalFiles = 0
    public var bytesCopied = 0
    /// 目标已有同名的不同文件，复制成了 `名字 (2).扩展名`。
    public var renamedFiles = 0
    /// 第一个位置读不到、从别的在线位置导出的文件。
    public var fromOtherLocation = 0
    /// 选的格式读不到，改导出了另一种格式的照片。
    public var usedOtherKind = 0
    /// 读的时候发现已经不在、改为历史的位置。
    public var missingLocations = 0
    /// 因此没有现存位置、进入“无卷关联照片”的照片。
    public var hiddenPhotoIDs: [PhotoID] = []
    public var skippedOfflinePhotos = 0
    /// 照片导出了，但它的另一个文件只在离线卷上（比如 RAW 在没插的卡上）。
    public var skippedOfflineFiles = 0
    public var failures: [Failure] = []
    public var cancelled = false
    /// 目标写不进去（写满、没有权限）时停下，后面的照片没有导出。
    public var stoppedBy: String?
    /// 取消或停下时还没轮到的照片。
    public var notAttempted = 0
    public var elapsed: TimeInterval = 0

    public init(destination: URL) { self.destination = destination }

    public var megabytesPerSecond: Double {
        elapsed > 0 ? Double(bytesCopied) / 1_000_000 / elapsed : 0
    }
}

public struct ExportProgress: Sendable, Equatable {
    public var photosDone: Int
    public var photoTotal: Int
    public var bytesCopied: Int
}

/// 执行导出。读源文件只用 `O_RDONLY`，源文件一个字节都不动。
public struct Exporter: Sendable {
    public var library: Library
    public var finder: OriginalFinder
    /// 每次读写的块大小。
    var chunkSize = 4 << 20

    public init(library: Library, finder: OriginalFinder) {
        self.library = library
        self.finder = finder
    }

    public func run(
        _ request: ExportRequest,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: (@Sendable (ExportProgress) -> Void)? = nil
    ) throws -> ExportReport {
        let started = Date()
        var report = ExportReport(destination: request.destination)
        let reader = library.reader
        let sources = try reader.presentSources(of: request.photoIDs)
        let volumeNames = Dictionary(uniqueKeysWithValues: try reader.volumes().map { ($0.id, $0.name) })
        var collectionFolders: [PhotoID: [String]] = [:]
        if request.layout == .byCollection {
            let names = Dictionary(uniqueKeysWithValues: try reader.collections().map { ($0.id, $0.name) })
            if let collection = request.collection {
                let folder = Self.folderName(names[collection] ?? "收藏夹")
                for id in request.photoIDs { collectionFolders[id] = [folder] }
            } else {
                for (id, collections) in try reader.collectionIDs(of: request.photoIDs) {
                    collectionFolders[id] = collections.compactMap { names[$0] }.map(Self.folderName)
                }
            }
        }
        try FileManager.default.createDirectory(at: request.destination, withIntermediateDirectories: true)
        let online = Set(finder.mounts.keys)
        var cleaned: Set<String> = []

        for (index, photoID) in request.photoIDs.enumerated() {
            if isCancelled() {
                report.cancelled = true
                report.notAttempted = request.photoIDs.count - index
                break
            }
            let all = sources[photoID] ?? []
            let fullPick = ExportFilePick(all, files: request.files)
            let pick = fullPick.online(online)
            guard !pick.primary.isEmpty else {
                if !all.isEmpty { report.skippedOfflinePhotos += 1 }
                continue
            }
            report.skippedOfflineFiles += fullPick.primary.filter { !$0.contains { online.contains($0.volumeID) } }.count
            var photo = PhotoExport(
                exporter: self,
                request: request,
                candidates: (pick.primary + pick.fallback).map { ($0[0].fileName, $0[0].fileSize) },
                folders: { source in
                    switch request.layout {
                    case .flat: [request.destination]
                    case .byCollection: (collectionFolders[photoID] ?? ["未归入收藏夹"]).map { request.destination.appendingPathComponent($0, isDirectory: true) }
                    case .original:
                        [source.directory.split(separator: "/").reduce(
                            request.destination.appendingPathComponent(Self.folderName(volumeNames[source.volumeID] ?? "卷"), isDirectory: true)
                        ) { $0.appendingPathComponent(Self.folderName(String($1)), isDirectory: true) }]
                    }
                },
                isCancelled: isCancelled
            )
            do {
                var exported = try photo.export(pick.primary, report: &report, cleaned: &cleaned)
                if exported == 0, !pick.fallback.isEmpty {
                    // 选的格式一个都读不到：照“没有 RAW 的导出 JPEG”改导出另一种。
                    exported = try photo.export(pick.fallback, report: &report, cleaned: &cleaned)
                    if exported > 0 { report.usedOtherKind += 1 }
                }
                if exported > 0 { report.exportedPhotos += 1 }
            } catch ExportStop.cancelled {
                report.cancelled = true
                report.notAttempted = request.photoIDs.count - index
            } catch ExportStop.destination(let message) {
                report.stoppedBy = message
                report.notAttempted = request.photoIDs.count - index
            }
            if !photo.missingLocationIDs.isEmpty {
                let hidden = try library.markLocationsMissing(photo.missingLocationIDs)
                report.missingLocations += photo.missingLocationIDs.count
                report.hiddenPhotoIDs += hidden
            }
            progress?(ExportProgress(photosDone: index + 1, photoTotal: request.photoIDs.count, bytesCopied: report.bytesCopied))
            if report.cancelled || report.stoppedBy != nil { break }
        }
        report.elapsed = Date().timeIntervalSince(started)
        return report
    }

    /// 收藏夹名、卷名用作文件夹名：去掉 `/` 和 `:`，不以 `.` 开头。
    static func folderName(_ name: String) -> String {
        var result = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") { result.removeFirst() }
        return result.isEmpty ? "未命名" : result
    }

    /// `DSC01926.ARW` 的第 n 个名字：`DSC01926.ARW`、`DSC01926 (2).ARW`、`DSC01926 (3).ARW`……
    static func numberedName(_ name: String, _ n: Int) -> String {
        guard n > 1 else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
    }
}

enum ExportStop: Error {
    case cancelled
    case destination(String)
}

/// 导出一张照片。同一张照片的 RAW 和 JPEG 在同一个目录里用同一个编号，免得配对被拆开。
struct PhotoExport {
    let exporter: Exporter
    let request: ExportRequest
    /// 这张照片可能导出的全部文件（名字、大小），选编号时一起看。
    let candidates: [(name: String, size: Int)]
    let folders: (OriginalSource) -> [URL]
    let isCancelled: @Sendable () -> Bool
    var missingLocationIDs: [Int] = []
    /// 每个目录用的编号（1 表示不加编号）。
    private var numbers: [URL: Int] = [:]

    init(
        exporter: Exporter,
        request: ExportRequest,
        candidates: [(name: String, size: Int)],
        folders: @escaping (OriginalSource) -> [URL],
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        self.exporter = exporter
        self.request = request
        self.candidates = candidates
        self.folders = folders
        self.isCancelled = isCancelled
    }

    /// 导出这些文件，返回成功的文件数（含目标里已有一样的）。读不到的文件记进报告。
    mutating func export(_ groups: [[OriginalSource]], report: inout ExportReport, cleaned: inout Set<String>) throws -> Int {
        var exported = 0
        for locations in groups {
            var pending: [URL]?
            var problems: [String] = []
            var triedOther = false
            for (attempt, source) in locations.enumerated() {
                if attempt > 0 { triedOther = true }
                switch exporter.finder.open(source) {
                case .missing:
                    missingLocationIDs.append(source.locationID)
                    problems.append("原片已不在 \(source.relativePath)")
                    continue
                case .offline:
                    problems.append("卷已离线")
                    continue
                case .unreadable(let reason):
                    problems.append(reason)
                    continue
                case .file(let fd, _, let size, let modified):
                    defer { Darwin.close(fd) }
                    if pending == nil { pending = folders(source) }
                    while let folder = pending?.first {
                        try prepare(folder, cleaned: &cleaned)
                        do {
                            let outcome = try copy(fd: fd, size: size, modified: modified, name: source.fileName, into: folder)
                            switch outcome {
                            case .copied(let renamed):
                                report.copiedFiles += 1
                                report.bytesCopied += size
                                if renamed { report.renamedFiles += 1 }
                            case .identical:
                                report.identicalFiles += 1
                            }
                            pending?.removeFirst()
                        } catch CopyFailure.source(let reason) {
                            problems.append(reason)
                            break
                        }
                    }
                }
                if pending?.isEmpty == true { break }
            }
            if pending?.isEmpty == true {
                exported += 1
                if triedOther { report.fromOtherLocation += 1 }
            } else {
                let name = locations[0].fileName
                let reason = problems.isEmpty ? "所有在线位置都读不到" : "所有在线位置都读不到：" + problems.joined(separator: "；")
                report.failures.append(ExportReport.Failure(photoID: locations[0].photoID, name: name, reason: reason))
            }
        }
        return exported
    }

    /// 第一次往这个目录写之前：建目录，清掉上次中断留下的临时文件。
    private func prepare(_ folder: URL, cleaned: inout Set<String>) throws {
        guard cleaned.insert(folder.path).inserted else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ExportStop.destination("建不了目录 \(folder.lastPathComponent)：\(error.localizedDescription)")
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in leftovers where name.hasPrefix(".") && name.hasSuffix(PhotoExport.partSuffix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    static let partSuffix = ".photoai-part"

    enum CopyOutcome { case copied(renamed: Bool), identical }
    enum CopyFailure: Error { case source(String) }

    private mutating func number(for folder: URL) -> Int {
        if let number = numbers[folder] { return number }
        // 从 1 开始找一个编号，让这张照片的每个文件名在目录里都还没被占用（或者占用的大小一样，可能就是上次导出的）。
        var n = 1
        while candidates.contains(where: { candidate in
            let url = folder.appendingPathComponent(Exporter.numberedName(candidate.name, n))
            return FileManager.default.fileExists(atPath: url.path)
                && (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) != candidate.size
        }) {
            n += 1
        }
        numbers[folder] = n
        return n
    }

    /// 复制一个文件到目录。先写临时文件，写完、落盘后再改成正式的名字；改名不覆盖已有文件。
    private mutating func copy(fd: Int32, size: Int, modified: timespec, name: String, into folder: URL) throws -> CopyOutcome {
        var n = number(for: folder)
        while true {
            let target = folder.appendingPathComponent(Exporter.numberedName(name, n))
            if FileManager.default.fileExists(atPath: target.path) {
                if try sameContents(fd: fd, size: size, as: target) { return .identical }
                n += 1
                continue
            }
            let temp = folder.appendingPathComponent(".\(name).\(UUID().uuidString)\(Self.partSuffix)")
            try write(fd: fd, size: size, modified: modified, to: temp)
            switch Self.renameExclusive(temp, to: target) {
            case 0:
                return .copied(renamed: n != 1)
            case EEXIST:
                unlink(temp.path)
                n += 1
            case let code:
                unlink(temp.path)
                throw ExportStop.destination("改名失败 \(target.lastPathComponent)：\(String(cString: strerror(code)))")
            }
        }
    }

    private func write(fd: Int32, size: Int, modified: timespec, to temp: URL) throws {
        let out = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard out >= 0 else { throw ExportStop.destination(Self.destinationMessage(errno, temp)) }
        var finished = false
        defer {
            Darwin.close(out)
            if !finished { unlink(temp.path) }
        }
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw CopyFailure.source("读不了：\(String(cString: strerror(errno)))") }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: exporter.chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        var total = 0
        while true {
            if isCancelled() { throw ExportStop.cancelled }
            let count = read(fd, buffer, exporter.chunkSize)
            if count < 0 { throw CopyFailure.source("读到一半出错：\(String(cString: strerror(errno)))") }
            if count == 0 { break }
            var offset = 0
            while offset < count {
                let written = Darwin.write(out, buffer + offset, count - offset)
                guard written > 0 else { throw ExportStop.destination(Self.destinationMessage(errno, temp)) }
                offset += written
            }
            total += count
        }
        guard total == size else { throw CopyFailure.source("读到的字节数（\(total)）和文件大小（\(size)）不一致") }
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), modified]
        futimens(out, &times)
        guard fsync(out) == 0 else { throw ExportStop.destination(Self.destinationMessage(errno, temp)) }
        finished = true
    }

    /// 目标里同名的文件和源文件逐字节相同吗？
    private func sameContents(fd: Int32, size: Int, as target: URL) throws -> Bool {
        guard (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) == size else { return false }
        let other = Darwin.open(target.path, O_RDONLY)
        guard other >= 0 else { return false }
        defer { Darwin.close(other) }
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw CopyFailure.source("读不了：\(String(cString: strerror(errno)))") }
        let chunk = exporter.chunkSize
        let a = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        let b = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { a.deallocate(); b.deallocate() }
        while true {
            if isCancelled() { throw ExportStop.cancelled }
            let count = read(fd, a, chunk)
            if count < 0 { throw CopyFailure.source("读到一半出错：\(String(cString: strerror(errno)))") }
            if count == 0 { return true }
            var filled = 0
            while filled < count {
                let got = read(other, b + filled, count - filled)
                guard got > 0 else { return false }
                filled += got
            }
            if memcmp(a, b, count) != 0 { return false }
        }
    }

    /// 改名但不覆盖：`renamex_np(RENAME_EXCL)`；文件系统不支持时用硬链接，再不行先查再改。返回 0 或 errno。
    static func renameExclusive(_ from: URL, to: URL) -> Int32 {
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 { return 0 }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else { return code }
        if link(from.path, to.path) == 0 {
            unlink(from.path)
            return 0
        }
        let linkCode = errno
        if linkCode == EEXIST { return EEXIST }
        // exFAT 之类不支持硬链接：先确认目标不存在再改名。只有本软件在写这个目录，中间被别人占用的机会可以忽略。
        if FileManager.default.fileExists(atPath: to.path) { return EEXIST }
        return Darwin.rename(from.path, to.path) == 0 ? 0 : errno
    }

    static func destinationMessage(_ code: Int32, _ url: URL) -> String {
        switch code {
        case ENOSPC: "目标盘空间不够"
        case EROFS: "目标盘是只读的"
        case EACCES, EPERM: "没有权限写入 \(url.deletingLastPathComponent().lastPathComponent)"
        default: "写入失败：\(String(cString: strerror(code)))"
        }
    }
}
