import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 预览的两档尺寸。
public enum PreviewSize: Int, Sendable, CaseIterable {
    case thumb = 480
    case preview = 1600
}

/// 预览文件放在库里，按照片存，不按卷存（数据模型 §1）。
public struct PreviewStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `Previews/<两位子目录>/<photo_id>-480.jpg`。子目录取 id 的末两位：自增 id 的首位分布很偏，末两位才均匀。
    public func url(for photoID: PhotoID, size: PreviewSize) -> URL {
        root
            .appendingPathComponent(String(format: "%02d", photoID % 100), isDirectory: true)
            .appendingPathComponent("\(photoID)-\(size.rawValue).jpg")
    }

    var temporaryDirectory: URL { root.appendingPathComponent(".tmp", isDirectory: true) }

    /// 中途退出留下的临时文件。启动时清掉。
    public func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    /// 文件在、能解码。“离线预览就绪”只认这种。
    public func isDecodable(_ photoID: PhotoID, size: PreviewSize) -> Bool {
        Self.isDecodable(url(for: photoID, size: size))
    }

    static func isDecodable(_ url: URL) -> Bool {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            return false
        }
        return image.width > 0 && image.height > 0
    }
}

/// 把原图缩到指定长边。
///
/// RAW 的内嵌预览（索尼 ARW 约 1616 px）够大就直接用，比完整解码快几十倍；
/// JPEG 通常只内嵌 160 px 的 EXIF 缩略图，不够大，回退到完整解码（v1 `DownsampledImageDecoder` 的经验）。
enum ImageDownsampler {
    static let minimumAcceptableRatio = 0.5

    static func image(at url: URL, maximumPixelSize: Int) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        if let embedded = thumbnail(source, maximumPixelSize: maximumPixelSize, always: false),
           Double(max(embedded.width, embedded.height)) >= Double(maximumPixelSize) * minimumAcceptableRatio {
            return embedded
        }
        return thumbnail(source, maximumPixelSize: maximumPixelSize, always: true)
    }

    static func thumbnail(_ source: CGImageSource, maximumPixelSize: Int, always: Bool) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        if always { options[kCGImageSourceCreateThumbnailFromImageAlways] = true }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// 一张照片生成预览的结果。
public enum PreviewOutcome: Sendable, Equatable {
    case ready
    /// 原片能读但解码不了，记为 failed。
    case failed
    /// 所有来源都读不到（卷拔了、文件不在）：保持 pending，下次插上续做。原片缺失不在这里下结论。
    case sourceUnavailable
}

public struct PreviewWriteError: Error, CustomStringConvertible {
    public var underlying: String
    public var description: String { "预览写不进本机：\(underlying)" }
}

/// 生成一张照片的 480 和 1600 两档预览。
///
/// 先写临时文件，读回能解码再改名到正式位置，最后在事务里记为 `ready`（数据模型 §8）。
/// 写不进去（比如本机盘满了）抛 `PreviewWriteError`，状态保持 pending，由调用方暂停整个队列。
public struct PreviewGenerator: Sendable {
    public var library: Library
    public var store: PreviewStore
    public var quality: Double

    public init(library: Library, store: PreviewStore? = nil, quality: Double = 0.82) {
        self.library = library
        self.store = store ?? PreviewStore(root: library.paths.previews)
        self.quality = quality
    }

    public func generate(_ job: PreviewJob, mountURLs: [VolumeID: URL]) throws -> PreviewOutcome {
        var sawReadableSource = false
        for source in job.sources {
            guard let mount = mountURLs[source.volumeID] else { continue }
            let url = mount.appendingPathComponent(source.relativePath)
            guard FileManager.default.isReadableFile(atPath: url.path) else { continue }
            sawReadableSource = true
            guard let image = ImageDownsampler.image(at: url, maximumPixelSize: PreviewSize.preview.rawValue) else {
                continue
            }
            try write(image, for: job)
            try library.markPreviewsReady(
                photoID: job.photoID,
                thumb: job.needsThumb,
                preview: job.needsPreview,
                sourceFileID: source.fileID
            )
            return .ready
        }
        guard sawReadableSource else { return .sourceUnavailable }
        try library.markPreviewsFailed(photoID: job.photoID)
        return .failed
    }

    private func write(_ image: CGImage, for job: PreviewJob) throws {
        let fileManager = FileManager.default
        let temporary = store.temporaryDirectory
        do {
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        } catch {
            throw PreviewWriteError(underlying: error.localizedDescription)
        }
        let previewTemp = temporary.appendingPathComponent(UUID().uuidString + ".jpg")
        let thumbTemp = temporary.appendingPathComponent(UUID().uuidString + ".jpg")
        defer {
            try? fileManager.removeItem(at: previewTemp)
            try? fileManager.removeItem(at: thumbTemp)
        }

        try encode(image, to: previewTemp)
        // 480 从刚写好的 1600 缩出来，不再读一次原片。
        guard let previewSource = CGImageSourceCreateWithURL(previewTemp as CFURL, nil),
              let thumb = ImageDownsampler.thumbnail(previewSource, maximumPixelSize: PreviewSize.thumb.rawValue, always: true) else {
            throw PreviewWriteError(underlying: "读不回刚写的预览")
        }
        try encode(thumb, to: thumbTemp)
        guard PreviewStore.isDecodable(previewTemp), PreviewStore.isDecodable(thumbTemp) else {
            throw PreviewWriteError(underlying: "写出的预览无法解码")
        }

        var moves: [(URL, PreviewSize)] = []
        if job.needsPreview { moves.append((previewTemp, .preview)) }
        if job.needsThumb { moves.append((thumbTemp, .thumb)) }
        for (temp, size) in moves {
            let destination = store.url(for: job.photoID, size: size)
            do {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination.path) {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
                } else {
                    try fileManager.moveItem(at: temp, to: destination)
                }
            } catch {
                throw PreviewWriteError(underlying: error.localizedDescription)
            }
        }
    }

    private func encode(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PreviewWriteError(underlying: "无法创建 \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PreviewWriteError(underlying: "写入 \(url.lastPathComponent) 失败")
        }
    }

    /// 启动时核对：状态是 `ready` 但文件不在的档位改回 `pending`。返回改回的照片数。
    /// 只检查文件在不在、大小是否为 0；逐个解码十万张太慢，`audit` 才做解码核对。
    @discardableResult
    public func verifyReadyFiles() throws -> Int {
        store.removeTemporaryFiles()
        var resets: [(photoID: PhotoID, thumb: Bool, preview: Bool)] = []
        for item in try library.reader.photosWithReadyPreviews() {
            let thumbMissing = item.thumb && !Self.hasContent(store.url(for: item.id, size: .thumb))
            let previewMissing = item.preview && !Self.hasContent(store.url(for: item.id, size: .preview))
            if thumbMissing || previewMissing {
                resets.append((item.id, thumbMissing, previewMissing))
            }
        }
        try library.resetPreviews(resets)
        return resets.count
    }

    /// 逐个解码核对两档预览。返回实际能解码的照片数；解码不了的改回 `pending`。
    public func audit(photoIDs: [PhotoID]) throws -> Int {
        var decodable = 0
        var resets: [(photoID: PhotoID, thumb: Bool, preview: Bool)] = []
        for id in photoIDs {
            let thumb = store.isDecodable(id, size: .thumb)
            let preview = store.isDecodable(id, size: .preview)
            if thumb && preview { decodable += 1 } else { resets.append((id, !thumb, !preview)) }
        }
        try library.resetPreviews(resets)
        return decodable
    }

    static func hasContent(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil ?? 0) > 0
    }
}

/// 后台把待做的预览一批批做完。可暂停（`shouldStop` 返回 true 时在下一张前停下）。
public struct PreviewRunner: Sendable {
    public struct Progress: Sendable, Equatable {
        public var ready = 0
        public var failed = 0
        public var unavailable = 0
        /// 写不进本机时的原因；出现后整个队列停下。
        public var writeError: String?
    }

    public var generator: PreviewGenerator
    public var concurrency: Int
    public var batchSize: Int

    public init(generator: PreviewGenerator, concurrency: Int = 3, batchSize: Int = 24) {
        self.generator = generator
        self.concurrency = concurrency
        self.batchSize = batchSize
    }

    public func run(
        mountURLs: [VolumeID: URL],
        shouldStop: @escaping @Sendable () -> Bool = { Task.isCancelled },
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Progress {
        var total = Progress()
        // 这一轮里读不到来源的照片不再重试，免得原地打转。
        var skipped: Set<PhotoID> = []
        let generator = generator
        while !shouldStop() {
            let jobs = try generator.library.reader.photosNeedingPreviews(
                limit: batchSize, onVolumes: Array(mountURLs.keys), excluding: skipped
            )
            if jobs.isEmpty { break }
            let outcomes = await withTaskGroup(of: (PhotoID, Result<PreviewOutcome, Error>).self) { group in
                var results: [(PhotoID, Result<PreviewOutcome, Error>)] = []
                var next = 0
                func add() {
                    let job = jobs[next]
                    next += 1
                    group.addTask {
                        if shouldStop() { return (job.photoID, .success(.sourceUnavailable)) }
                        return (job.photoID, Result { try generator.generate(job, mountURLs: mountURLs) })
                    }
                }
                while next < min(concurrency, jobs.count) { add() }
                while let result = await group.next() {
                    results.append(result)
                    if case .failure = result.1 { continue }
                    if next < jobs.count { add() }
                }
                return results
            }
            for (photoID, outcome) in outcomes {
                switch outcome {
                case .success(.ready): total.ready += 1
                case .success(.failed): total.failed += 1
                case .success(.sourceUnavailable):
                    total.unavailable += 1
                    skipped.insert(photoID)
                case .failure(let error):
                    total.writeError = (error as? PreviewWriteError)?.description ?? "\(error)"
                }
            }
            progress?(total)
            if total.writeError != nil { break }
        }
        return total
    }
}

/// 当前挂载的卷：卷 UUID → 挂载点。在线 / 离线只看这个，不逐个检查原片（设计稿 §4.1）。
public enum MountedVolumes {
    public struct Info: Sendable, Equatable {
        public var uuid: String
        public var url: URL
        public var name: String
        public var capacityBytes: Int?
        public var filesystem: String?
        public var isInternal: Bool
        public var isRemovable: Bool
        /// 根目录下有 `DCIM`：按存储卡处理，默认扫描 `DCIM`。
        public var hasDCIM: Bool
    }

    private static let keys: [URLResourceKey] = [
        .volumeUUIDStringKey, .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey,
        .volumeLocalizedFormatDescriptionKey, .volumeIsInternalKey, .volumeIsRemovableKey,
        .volumeIsEjectableKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey
    ]

    public static func list() -> [Info] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap(info(for:))
    }

    public static func info(for url: URL) -> Info? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)),
              let uuid = values.volumeUUIDString,
              values.volumeIsRootFileSystem != true,
              values.volumeIsBrowsable != false else {
            return nil
        }
        // 系统盘上的其他卷（Recovery、Preboot 之类）不算。
        if values.volumeIsInternal == true, values.volumeIsEjectable != true, url.path.hasPrefix("/System") {
            return nil
        }
        var isDirectory: ObjCBool = false
        let hasDCIM = FileManager.default.fileExists(atPath: url.appendingPathComponent("DCIM").path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        return Info(
            uuid: uuid,
            url: url,
            name: values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent,
            capacityBytes: values.volumeTotalCapacity,
            filesystem: values.volumeLocalizedFormatDescription,
            isInternal: values.volumeIsInternal ?? false,
            isRemovable: values.volumeIsRemovable ?? false,
            hasDCIM: hasDCIM
        )
    }
}
