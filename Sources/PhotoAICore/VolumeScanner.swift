import Foundation

/// 一次扫描的结果与进度。
public struct ScanSummary: Sendable, Equatable {
    public var directoriesComplete = 0
    /// 没扫完的目录（相对卷根目录）与原因。
    public var incompleteDirectories: [String: String] = [:]
    public var filesSeen = 0
    /// 大小和修改时间都没变，没读 EXIF。
    public var unchanged = 0
    /// 读了 EXIF、身份没变，只更新大小或时间。
    public var updated = 0
    public var added = 0
    /// 历史位置原样放回，恢复为现存。
    public var restored = 0
    /// 同一路径换了照片。
    public var replaced = 0
    /// 完整列出的目录里不见了，改为历史位置。
    public var vanished = 0
    public var newPhotos = 0
    public var importBatchID: Int?
    /// 整卷所有目录都完整扫完。
    public var isComplete = false

    public init() {}
}

public enum ScanError: Error, CustomStringConvertible {
    case volumeNotActive(VolumeID)
    case outsideScanRoot(String)

    public var description: String {
        switch self {
        case .volumeNotActive(let id): "卷 \(id) 不存在或已移除"
        case .outsideScanRoot(let dir): "「\(dir)」不在这个卷的扫描文件夹里"
        }
    }
}

/// 按目录扫描一个卷。见 docs/设计/数据模型.md §5。
///
/// 每个目录先完整列出；列不完就记为没扫完，保留上次结果。文件按批提交，网格边扫边出现。
/// 大小和修改时间都没变的文件不读 EXIF；其余的并行读 EXIF（慢速卡上单个文件要零点几秒）。
public struct VolumeScanner: Sendable {
    public var library: Library
    public var lister: any DirectoryListing
    public var metadataReader: any MetadataReading
    public var concurrency: Int
    public var batchSize: Int

    public init(
        library: Library,
        lister: any DirectoryListing = FileSystemLister(),
        metadataReader: any MetadataReading = ImageIOMetadataReader(),
        concurrency: Int = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount)),
        batchSize: Int = 200
    ) {
        self.library = library
        self.lister = lister
        self.metadataReader = metadataReader
        self.concurrency = concurrency
        self.batchSize = batchSize
    }

    /// 扫描一个已挂载的卷。`isCancelled` 返回 true 时（取消、卷被拔出）在下一个文件批次前停下，
    /// 当前目录和之后的目录都记为没扫完。
    ///
    /// `subtree`：只扫这个目录和它下面的（补副本后登记副本用），必须在卷的扫描文件夹之内。
    /// 结论只下在这棵子树里：别的目录保持上次的状态，也不更新整卷的“最后扫完”时间。
    @discardableResult
    public func scan(
        volumeID: VolumeID,
        mountURL: URL,
        subtree: String? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        progress: (@Sendable (ScanSummary) -> Void)? = nil
    ) async throws -> ScanSummary {
        guard let volume = try library.reader.volume(id: volumeID), volume.status == .active else {
            throw ScanError.volumeNotActive(volumeID)
        }
        let time = library.now()
        var summary = ScanSummary()
        var importBatchID: Int?
        let start = subtree.map(Library.normalizedDirectory) ?? volume.scanRoot
        guard Library.isDirectory(start, inside: volume.scanRoot) else { throw ScanError.outsideScanRoot(start) }
        var queue = [start]
        var visited: Set<String> = []
        var interruption: String?

        while !queue.isEmpty {
            if isCancelled() {
                interruption = "扫描中断"
                break
            }
            let dir = queue.removeFirst()
            let entries: [DirectoryEntry]
            do {
                entries = try lister.list(Self.url(of: dir, in: mountURL))
            } catch {
                let reason = Self.reason(for: error)
                try library.markDirectoryIncomplete(volumeID: volumeID, dirPath: dir, reason: reason)
                summary.incompleteDirectories[dir] = reason
                visited.insert(dir)
                continue
            }

            let subdirectories = Set(entries.filter(\.isDirectory).map(\.name))
            let files = entries
                .filter { !$0.isDirectory && FileKind(extension: ($0.name as NSString).pathExtension) != nil }
                .sorted { $0.name < $1.name }
                .map {
                    Library.ScanFile(
                        name: $0.name,
                        relativePath: Library.join(dir, $0.name),
                        dirPath: dir,
                        size: $0.size,
                        modificationTime: $0.modificationTime
                    )
                }
            let known = try library.presentLocations(volumeID: volumeID, dirPath: dir)
            var seen: Set<String> = []
            var finished = true
            var failure: String?

            for start in stride(from: 0, to: files.count, by: batchSize) {
                if isCancelled() {
                    finished = false
                    break
                }
                let chunk = files[start..<min(start + batchSize, files.count)]
                var unchanged: [Int] = []
                var toRead: [Library.ScanFile] = []
                for file in chunk {
                    seen.insert(file.relativePath)
                    if let location = known[file.relativePath],
                       location.size == file.size, location.modificationTime == file.modificationTime {
                        unchanged.append(location.id)
                    } else {
                        toRead.append(file)
                    }
                }
                let (read, readCount, readFailure) = await readMetadata(toRead, mountURL: mountURL, isCancelled: isCancelled)
                let counts = try library.applyScanBatch(
                    volumeID: volumeID, unchanged: unchanged, read: read, at: time, importBatchID: &importBatchID
                )
                summary.filesSeen += unchanged.count + readCount
                summary.unchanged += counts.unchanged
                summary.updated += counts.updated
                summary.added += counts.added
                summary.restored += counts.restored
                summary.replaced += counts.replaced
                summary.newPhotos += counts.newPhotos
                summary.importBatchID = importBatchID
                progress?(summary)
                if let readFailure {
                    failure = readFailure
                    break
                }
                if readCount < toRead.count {
                    finished = false
                    break
                }
            }

            if let failure {
                // 有文件读不了：这个目录不下结论，接着扫别的目录。
                try library.markDirectoryIncomplete(volumeID: volumeID, dirPath: dir, reason: failure)
                summary.incompleteDirectories[dir] = failure
                visited.insert(dir)
                continue
            }
            // 下结论（没见到的改为历史）之前再确认一次没被取消：列目录的同时可能刚好拔卡。
            if !finished || isCancelled() {
                interruption = "扫描中断"
                try library.markDirectoryIncomplete(volumeID: volumeID, dirPath: dir, reason: "扫描中断")
                summary.incompleteDirectories[dir] = "扫描中断"
                visited.insert(dir)
                break
            }

            summary.vanished += try library.finishDirectory(
                volumeID: volumeID, dirPath: dir, seenPaths: seen, subdirectories: subdirectories, at: time
            )
            summary.directoriesComplete += 1
            visited.insert(dir)
            queue.append(contentsOf: subdirectories.sorted().map { Library.join(dir, $0) })
            progress?(summary)
        }

        // 列出来了但没走到的目录，以及上级没列出来的已知目录，都记为没扫完。
        let reason = interruption ?? "上级目录没扫完"
        for dir in queue {
            try library.markDirectoryIncomplete(volumeID: volumeID, dirPath: dir, reason: reason)
            summary.incompleteDirectories[dir] = reason
            visited.insert(dir)
        }
        try library.markUnvisitedDirectoriesIncomplete(volumeID: volumeID, visited: visited, under: subtree == nil ? nil : start, reason: reason)
        for (dir, state) in try library.reader.scanDirectoryStates(volume: volumeID)
        where state == "incomplete" && summary.incompleteDirectories[dir] == nil {
            summary.incompleteDirectories[dir] = reason
        }
        summary.isComplete = try library.finishVolumeScan(
            volumeID: volumeID, importBatchID: importBatchID, at: time, wholeVolume: subtree == nil
        )
        progress?(summary)
        return summary
    }

    private enum ReadOutcome: Sendable {
        case metadata(PhotoMetadata)
        case notAnImage
        case failed(String)
        case cancelled
    }

    /// 并行读 EXIF，保持原顺序。只返回第一次取消或读错之前的那一段：
    /// （读出的结果，处理掉的文件数，读错的原因）。不是图片的文件算处理掉了，但不登记。
    private func readMetadata(
        _ files: [Library.ScanFile],
        mountURL: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> ([(Library.ScanFile, PhotoMetadata)], Int, String?) {
        guard !files.isEmpty else { return ([], 0, nil) }
        let reader = metadataReader
        var outcomes = [ReadOutcome](repeating: .cancelled, count: files.count)
        await withTaskGroup(of: (Int, ReadOutcome).self) { group in
            var next = 0
            func add() {
                let index = next
                let url = Self.url(of: files[index].relativePath, in: mountURL)
                group.addTask {
                    if isCancelled() { return (index, .cancelled) }
                    do {
                        if let metadata = try reader.metadata(at: url) { return (index, .metadata(metadata)) }
                        return (index, .notAnImage)
                    } catch {
                        return (index, .failed(Self.reason(for: error)))
                    }
                }
                next += 1
            }
            while next < min(concurrency, files.count) { add() }
            while let (index, outcome) = await group.next() {
                outcomes[index] = outcome
                if next < files.count { add() }
            }
        }
        var ordered: [(Library.ScanFile, PhotoMetadata)] = []
        var processed = 0
        for (file, outcome) in zip(files, outcomes) {
            switch outcome {
            case .metadata(let metadata):
                ordered.append((file, metadata))
            case .notAnImage:
                break
            case .failed(let reason):
                return (ordered, processed, reason)
            case .cancelled:
                return (ordered, processed, nil)
            }
            processed += 1
        }
        return (ordered, processed, nil)
    }

    static func url(of relativePath: String, in mountURL: URL) -> URL {
        relativePath.isEmpty ? mountURL : mountURL.appendingPathComponent(relativePath)
    }

    static func reason(for error: Error) -> String {
        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, NSFileReadNoPermissionError): return "没有权限"
        case (NSCocoaErrorDomain, NSFileReadNoSuchFileError), (NSPOSIXErrorDomain, Int(ENOENT)): return "目录不在了或卷已拔出"
        default:
            if let error = error as? MetadataReadError { return "文件读不了：\((error.path as NSString).lastPathComponent)" }
            return "读取出错：\(nsError.localizedDescription)"
        }
    }
}
