import AppKit
import ImageIO
import PhotoAICore

// MARK: - 缩略图加载

/// 从本机预览目录读 480 缩略图，后台解码，主线程只拿解码好的图。
@MainActor
final class ThumbnailLoader {
    var store: PreviewStore?
    private let cache = NSCache<NSNumber, NSImage>()
    private var waiting: [PhotoID: [(NSImage?) -> Void]] = [:]
    private let queue = DispatchQueue(label: "thumbnails", qos: .userInitiated, attributes: .concurrent)

    init() { cache.countLimit = 3_000 }

    func cached(_ id: PhotoID) -> NSImage? { cache.object(forKey: NSNumber(value: id)) }

    /// 照片删掉后丢掉缓存（编号可能被新照片重新用上）。
    func forget(_ ids: some Sequence<PhotoID>) {
        for id in ids { cache.removeObject(forKey: NSNumber(value: id)) }
    }

    func load(_ id: PhotoID, completion: @escaping (NSImage?) -> Void) {
        guard let store else { return completion(nil) }
        if waiting[id] != nil {
            waiting[id]?.append(completion)
            return
        }
        waiting[id] = [completion]
        let url = store.url(for: id, size: .thumb)
        queue.async {
            let decoded = Self.decode(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let image = decoded.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                    if let image { self.cache.setObject(image, forKey: NSNumber(value: id)) }
                    let callbacks = self.waiting.removeValue(forKey: id) ?? []
                    for callback in callbacks { callback(image) }
                }
            }
        }
    }

    nonisolated private static func decode(_ url: URL) -> CGImage? {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}

/// 单张、比较视图用的 1600 预览。后台解码，只缓存当前附近的几张；翻页前先把前后几张解好（PF-7）。
@MainActor
final class PreviewImageLoader {
    var store: PreviewStore?
    private let cache = NSCache<NSNumber, NSImage>()
    private var waiting: [PhotoID: [(NSImage?) -> Void]] = [:]
    private let queue = DispatchQueue(label: "previews", qos: .userInitiated, attributes: .concurrent)

    init() { cache.countLimit = 16 }

    func cached(_ id: PhotoID) -> NSImage? { cache.object(forKey: NSNumber(value: id)) }

    /// 照片删掉后丢掉缓存（编号可能被新照片重新用上）。
    func forget(_ ids: some Sequence<PhotoID>) {
        for id in ids { cache.removeObject(forKey: NSNumber(value: id)) }
    }

    func load(_ id: PhotoID, completion: @escaping (NSImage?) -> Void) {
        if let image = cached(id) { return completion(image) }
        guard let store else { return completion(nil) }
        if waiting[id] != nil {
            waiting[id]?.append(completion)
            return
        }
        waiting[id] = [completion]
        let url = store.url(for: id, size: .preview)
        queue.async {
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            let decoded = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, options) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let image = decoded.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                    if let image { self.cache.setObject(image, forKey: NSNumber(value: id)) }
                    for callback in self.waiting.removeValue(forKey: id) ?? [] { callback(image) }
                }
            }
        }
    }

    func prefetch(_ ids: [PhotoID]) {
        for id in ids where cached(id) == nil && waiting[id] == nil {
            load(id) { _ in }
        }
    }
}
