import Foundation
import Synchronization
@testable import PhotoAICore

/// 一个临时的库，测试结束后删掉。
final class TemporaryLibrary {
    let root: URL
    let library: Library

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photoai-tests-\(UUID().uuidString)", isDirectory: true)
        library = try Library(paths: LibraryPaths(root: root.appendingPathComponent("library", isDirectory: true)))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var reader: LibraryReader { library.reader }
}

/// 一张假的卡：目录里放文本文件，内容就是拍摄时间（空内容表示没有拍摄时间），
/// 配合 `FakeMetadataReader` 使用，不需要真实图片。
final class FakeCard {
    let root: URL
    private var clock: Double = 1_700_000_000

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photoai-card-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// 写一个文件。`padding` 用来改变大小（没有拍摄时间时按大小认身份）。
    @discardableResult
    func put(_ relativePath: String, date: String?, padding: Int = 0, mtime: Double? = nil) throws -> Double {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = (date ?? "") + String(repeating: " ", count: padding)
        try Data(content.utf8).write(to: url)
        clock += 10
        let time = mtime ?? clock
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: url.path)
        return time
    }

    func remove(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(relativePath))
    }

    func url(_ relativePath: String) -> URL { root.appendingPathComponent(relativePath) }
}

/// 把文件内容当作拍摄时间。记下读了哪些文件，用来确认没变的文件没被重读。
final class FakeMetadataReader: MetadataReading, @unchecked Sendable {
    private let reads = Mutex<[String]>([])
    /// 读到这些文件名时抛错，模拟读到一半拔卡。
    let failingNames: Set<String>

    init(failingNames: Set<String> = []) { self.failingNames = failingNames }

    var readNames: [String] { reads.withLock { $0 } }
    func resetReads() { reads.withLock { $0 = [] } }

    func metadata(at url: URL) throws -> PhotoMetadata? {
        reads.withLock { $0.append(url.lastPathComponent) }
        if failingNames.contains(url.lastPathComponent) { throw MetadataReadError(path: url.path) }
        let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespaces)
        return PhotoMetadata(captureDate: text.isEmpty ? nil : text, width: 6000, height: 4000)
    }
}

/// 包一层真实的目录列表：列到指定目录时抛错，或者先触发取消（模拟扫到一半拔卡）。
struct InterruptingLister: DirectoryListing {
    enum Mode: Sendable { case throwError, cancel }

    let base = FileSystemLister()
    let failingDirectory: String
    let mode: Mode
    let cancelFlag: CancelFlag

    func list(_ url: URL) throws -> [DirectoryEntry] {
        if url.path.hasSuffix("/" + failingDirectory) {
            switch mode {
            case .throwError:
                throw CocoaError(.fileReadNoSuchFile)
            case .cancel:
                cancelFlag.cancel()
            }
        }
        return try base.list(url)
    }
}

final class CancelFlag: Sendable {
    private let value = Mutex(false)
    func cancel() { value.withLock { $0 = true } }
    var isCancelled: Bool { value.withLock { $0 } }
}

extension TemporaryLibrary {
    func scanner(
        reader: FakeMetadataReader = FakeMetadataReader(),
        lister: any DirectoryListing = FileSystemLister()
    ) -> VolumeScanner {
        VolumeScanner(library: library, lister: lister, metadataReader: reader, concurrency: 4, batchSize: 3)
    }

    func photoID(_ baseName: String, _ date: String) throws -> PhotoID? {
        try reader.photoID(identityKey: PhotoIdentity.key(baseName: baseName, captureDate: date, fileSize: 0))
    }

    func expectConsistentCounts() throws -> Bool {
        try reader.inconsistentLocationCounts().isEmpty
    }
}

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 生成真实的小 JPEG（带 EXIF 拍摄时间），给 ImageIO 和预览生成的测试用。
enum SampleImages {
    static func writeJPEG(to url: URL, width: Int, height: Int, captureDate: String?, subsec: String? = nil) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        var exif: [CFString: Any] = [:]
        if let captureDate { exif[kCGImagePropertyExifDateTimeOriginal] = captureDate }
        if let subsec { exif[kCGImagePropertyExifSubsecTimeOriginal] = subsec }
        let properties: [CFString: Any] = [kCGImagePropertyExifDictionary: exif]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
