import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 合成的大库，给性能目标用（计划 · 性能目标）：默认 10 万条照片、6 个卷、其中 30% 有两处副本。
/// 直接写数据库，不经过扫描；预览文件用少量真实 JPEG 硬链接出来，网格解码的开销和真实情况一样。
public enum SyntheticLibrary {
    public struct Options: Sendable {
        public var photoCount = 100_000
        public var volumeCount = 6
        public var duplicateFraction = 0.3
        public var rawFraction = 0.5
        public var withPreviewFiles = true
        public init() {}
    }

    public static func build(at paths: LibraryPaths, options: Options = Options()) throws {
        if FileManager.default.fileExists(atPath: paths.database.path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: paths.database.path])
        }
        let library = try Library(paths: paths)
        let db = library.db
        var generator = SplitMix(seed: 42)
        let now = Date()

        var volumeIDs: [Int] = []
        for index in 0..<options.volumeCount {
            let volume = try library.addVolume(
                uuid: "SYNTHETIC-\(index)", name: index < options.volumeCount / 2 ? "卡 \(index + 1)" : "备份盘 \(index + 1)",
                scanRoot: "DCIM"
            )
            volumeIDs.append(volume.id)
        }
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        try db.transaction {
            let batch = Int(try db.insert("INSERT INTO import_batches (volume_id, started_at, photo_count) VALUES (?, ?, ?);",
                                          [volumeIDs[0], now, options.photoCount]))
            for index in 0..<options.photoCount {
                // 约 3 年，每天最多几百张，成团出现，和真实的拍摄习惯接近。
                let seconds = Double(index) * 950 + Double(generator.next() % 600)
                let date = start.addingTimeInterval(seconds)
                let captureDate = formatter.string(from: date)
                let baseName = String(format: "DSC%05d", index % 100_000)
                let landscape = generator.next() % 5 != 0
                let photoID = Int(try db.insert(
                    """
                    INSERT INTO photos (identity_key, base_name, file_number, capture_date, camera_make, camera_model,
                        width, height, thumb_state, preview_state, imported_at, import_batch_id)
                    VALUES (?, ?, ?, ?, 'SONY', 'ILCE-7RM5', ?, ?, ?, ?, ?, ?);
                    """,
                    [
                        PhotoIdentity.key(baseName: baseName, captureDate: captureDate, fileSize: 0), baseName, index % 100_000,
                        captureDate, landscape ? 6000 : 4000, landscape ? 4000 : 6000,
                        options.withPreviewFiles ? "ready" : "pending", options.withPreviewFiles ? "ready" : "pending",
                        now, batch
                    ]
                ))
                var kinds: [(String, String, Int)] = [("jpg", "jpeg", 12_000_000)]
                if Double(generator.next() % 1000) / 1000 < options.rawFraction { kinds.append(("arw", "raw", 35_000_000)) }
                let primary = volumeIDs[index * options.volumeCount / options.photoCount]
                var homes = [primary]
                if Double(generator.next() % 1000) / 1000 < options.duplicateFraction {
                    homes.append(volumeIDs[(volumeIDs.firstIndex(of: primary)! + options.volumeCount / 2) % options.volumeCount])
                }
                var locationCount = 0
                for (ext, kind, size) in kinds {
                    let fileID = Int(try db.insert(
                        "INSERT INTO files (photo_id, extension, kind, file_size) VALUES (?, ?, ?, ?);",
                        [photoID, ext, kind, size]
                    ))
                    if kind == "jpeg" {
                        try db.run("UPDATE photos SET preview_file_id = ? WHERE id = ?;", [fileID, photoID])
                    }
                    let dir = "DCIM/\(100 + index / 9999)MSDCF"
                    for volume in homes {
                        try db.run(
                            """
                            INSERT INTO locations (file_id, volume_id, relative_path, dir_path, file_size, file_mtime, status, last_seen_at)
                            VALUES (?, ?, ?, ?, ?, ?, 'present', ?);
                            """,
                            [fileID, volume, "\(dir)/\(baseName).\(ext.uppercased())", dir, size, date.timeIntervalSince1970, now]
                        )
                        locationCount += 1
                    }
                }
                try db.run("UPDATE photos SET present_location_count = ? WHERE id = ?;", [locationCount, photoID])
            }
        }

        if options.withPreviewFiles {
            try writePreviewFiles(store: PreviewStore(root: paths.previews), count: options.photoCount, reader: library.reader)
        }
    }

    /// 先画 24 张不同颜色的真实 JPEG，再硬链接到每张照片的预览路径。
    private static func writePreviewFiles(store: PreviewStore, count: Int, reader: LibraryReader) throws {
        let fileManager = FileManager.default
        let seeds = store.root.appendingPathComponent(".synthetic", isDirectory: true)
        try fileManager.createDirectory(at: seeds, withIntermediateDirectories: true)
        var sources: [PreviewSize: [URL]] = [:]
        for size in PreviewSize.allCases {
            for index in 0..<24 {
                let url = seeds.appendingPathComponent("\(size.rawValue)-\(index).jpg")
                let landscape = index % 5 != 0
                let long = size.rawValue
                let short = long * 2 / 3
                try writeJPEG(to: url, width: landscape ? long : short, height: landscape ? short : long, hue: Double(index) / 24)
                sources[size, default: []].append(url)
            }
        }
        let ids = try reader.db.all("SELECT id, height > width FROM photos ORDER BY id;") { ($0.int(0), $0.int(1) != 0) }
        for (id, portrait) in ids {
            for size in PreviewSize.allCases {
                let destination = store.url(for: id, size: size)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                // 编号是 5 的倍数的种子图是竖的，其余是横的。
                let pool = sources[size]!.enumerated().filter { ($0.offset % 5 == 0) == portrait }.map(\.element)
                try fileManager.linkItem(at: pool[id % pool.count], to: destination)
            }
        }
    }

    private static func writeJPEG(to url: URL, width: Int, height: Int, hue: Double) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        // 简单的渐变加几个色块，让 JPEG 的大小和解码开销接近真实照片。
        for band in 0..<16 {
            let t = Double(band) / 16
            context.setFillColor(CGColor(red: 0.3 + 0.6 * hue, green: 0.2 + 0.6 * t, blue: 0.8 - 0.5 * hue * t, alpha: 1))
            context.fill(CGRect(x: 0, y: height * band / 16, width: width, height: height / 16 + 1))
        }
        var random = SplitMix(seed: UInt64(width * 31 + Int(hue * 1000)))
        for _ in 0..<400 {
            context.setFillColor(CGColor(gray: Double(random.next() % 100) / 100, alpha: 0.35))
            context.fillEllipse(in: CGRect(x: Int(random.next() % UInt64(width)), y: Int(random.next() % UInt64(height)), width: 24, height: 24))
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

/// 可复现的伪随机数，合成数据每次都一样。
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
