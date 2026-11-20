import Foundation

/// 相机记录的对焦位置：转正后的照片上，左上为原点，0–1。宽高是对焦框的大小（相机没记时给一个小方框）。
public struct FocusArea: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// 对焦框的中心。
    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
}

/// 从原文件读对焦位置。只读文件头部的几处，不解码图像。
///
/// 目前认索尼（JPEG 和 ARW）：MakerNote 里的 `FocusLocation`（0x2027，int16u[4]：图宽、图高、对焦点 X、Y，
/// 未转正的传感器方向）和 `FocusFrameSize`（0x2037，6 字节：框宽、框高、有效标志）。
/// 其他相机读不到就返回 `.notRecorded`；文件读不了（卡拔了）返回 `nil`，下次再试。
public enum FocusPointReader {
    public enum Result: Equatable, Sendable {
        case found(FocusArea)
        case notRecorded
    }

    public static func read(at url: URL) -> Result? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let file = RandomAccess(handle: handle)
        guard let head = file.bytes(at: 0, count: 4), head.count == 4 else { return nil }
        let tiffBase: Int
        if head[0] == 0xFF, head[1] == 0xD8 {
            guard let base = exifTIFFBase(inJPEG: file) else { return Result.notRecorded }
            tiffBase = base
        } else if (head[0] == 0x49 && head[1] == 0x49) || (head[0] == 0x4D && head[1] == 0x4D) {
            tiffBase = 0
        } else {
            return Result.notRecorded
        }
        return focus(file: file, tiffBase: tiffBase) ?? Result.notRecorded
    }

    /// JPEG 里 APP1 “Exif” 段的 TIFF 头位置。
    static func exifTIFFBase(inJPEG file: RandomAccess) -> Int? {
        var offset = 2
        for _ in 0..<32 {
            guard let marker = file.bytes(at: offset, count: 4), marker.count == 4, marker[0] == 0xFF else { return nil }
            let length = Int(marker[2]) << 8 | Int(marker[3])
            if marker[1] == 0xE1, let tag = file.bytes(at: offset + 4, count: 6), tag.elementsEqual([0x45, 0x78, 0x69, 0x66, 0, 0]) {
                return offset + 10
            }
            // 到了图像数据还没找到就算没有。
            if marker[1] == 0xDA || length < 2 { return nil }
            offset += 2 + length
        }
        return nil
    }

    private static func focus(file: RandomAccess, tiffBase: Int) -> Result? {
        guard let tiff = TIFFReader(file: file, base: tiffBase), let ifd0 = tiff.ifd(at: tiff.firstIFDOffset) else { return nil }
        let orientation = ifd0[0x0112].flatMap { tiff.uint16s($0).first } ?? 1
        guard let exifEntry = ifd0[0x8769], let exifOffset = tiff.uint32s(exifEntry).first,
              let exif = tiff.ifd(at: Int(exifOffset)),
              let makerNote = exif[0x927C] else { return nil }
        // 索尼的 MakerNote 是一个 IFD，偏移相对 TIFF 头。JPEG 里前面有 12 字节 “SONY DSC ” 头，ARW 里没有头，
        // 所以 ARW 要看 IFD0 的厂商是不是 SONY。
        let start = tiff.valueOffset(makerNote)
        guard let header = file.bytes(at: tiffBase + start, count: 12), header.count == 12 else { return nil }
        let ifdStart: Int
        if header.starts(with: Array("SONY".utf8)) {
            ifdStart = start + 12
        } else if let make = ifd0[0x010F].map({ tiff.ascii($0) }), make.uppercased().hasPrefix("SONY") {
            ifdStart = start
        } else {
            return nil
        }
        guard let sony = tiff.ifd(at: ifdStart),
              let locationEntry = sony[0x2027] else { return nil }
        let location = tiff.uint16s(locationEntry)
        guard location.count == 4, location[0] > 0, location[1] > 0 else { return nil }
        let imageWidth = Double(location[0]), imageHeight = Double(location[1])
        // 对焦点 (0, 0) 是没对上焦或没记录。
        guard location[2] > 0 || location[3] > 0 else { return Result.notRecorded }
        var frameWidth = 0.0, frameHeight = 0.0
        if let frameEntry = sony[0x2037] {
            // 记了框但标为无效：多是没对上焦，点也不可信（真实卡 2,148 张里 3 张，点都在画面正中）。
            let frame = tiff.uint16s(frameEntry, asType: 3)
            guard frame.count >= 3, frame[2] & 0xFF == 1 else { return Result.notRecorded }
            frameWidth = Double(frame[0])
            frameHeight = Double(frame[1])
        }
        // 这台相机不记框时给图宽 3% 的方框。
        if frameWidth <= 0 || frameHeight <= 0 {
            frameWidth = imageWidth * 0.03
            frameHeight = frameWidth
        }
        let sensor = FocusArea(
            x: (Double(location[2]) - frameWidth / 2) / imageWidth, y: (Double(location[3]) - frameHeight / 2) / imageHeight,
            width: frameWidth / imageWidth, height: frameHeight / imageHeight
        )
        return .found(upright(sensor, orientation: Int(orientation)))
    }

    /// 传感器方向的框转到照片转正后的方向（EXIF Orientation）。
    static func upright(_ area: FocusArea, orientation: Int) -> FocusArea {
        let (x, y, w, h) = (area.x, area.y, area.width, area.height)
        let result: FocusArea = switch orientation {
        case 3: FocusArea(x: 1 - x - w, y: 1 - y - h, width: w, height: h)            // 转 180°
        case 6: FocusArea(x: 1 - y - h, y: x, width: h, height: w)                    // 顺时针转 90° 才正
        case 8: FocusArea(x: y, y: 1 - x - w, width: h, height: w)                    // 顺时针转 270° 才正
        default: area
        }
        // 人脸追踪的大框可能伸出画面：截掉伸出去的部分，框里还是原来那块。
        let left = min(max(result.x, 0), 1), top = min(max(result.y, 0), 1)
        let right = min(max(result.x + result.width, 0), 1), bottom = min(max(result.y + result.height, 0), 1)
        return FocusArea(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// 按需读文件的几个字节，不把整个文件读进来（ARW 有几十 MB）。
struct RandomAccess {
    let handle: FileHandle

    func bytes(at offset: Int, count: Int) -> [UInt8]? {
        guard offset >= 0, count > 0, (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.read(upToCount: count) else { return nil }
        return [UInt8](data)
    }
}

/// 最简单的 TIFF / EXIF IFD 读取：字节序、IFD 条目、按类型读数组。
struct TIFFReader {
    struct Entry {
        var tag: UInt16
        var type: UInt16
        var count: Int
        /// 条目里那 4 个字节的位置（相对 TIFF 头）：值放得下就在这里，否则这里是值的偏移。
        var valueField: Int
    }

    let file: RandomAccess
    let base: Int
    let littleEndian: Bool
    let firstIFDOffset: Int

    init?(file: RandomAccess, base: Int) {
        guard let header = file.bytes(at: base, count: 8), header.count == 8 else { return nil }
        self.file = file
        self.base = base
        if header[0] == 0x49, header[1] == 0x49 {
            littleEndian = true
        } else if header[0] == 0x4D, header[1] == 0x4D {
            littleEndian = false
        } else {
            return nil
        }
        let magic = Self.uint16(header, 2, littleEndian)
        guard magic == 42 else { return nil }
        firstIFDOffset = Int(Self.uint32(header, 4, littleEndian))
    }

    func ifd(at offset: Int) -> [UInt16: Entry]? {
        guard offset > 0, let countBytes = file.bytes(at: base + offset, count: 2), countBytes.count == 2 else { return nil }
        let count = Int(Self.uint16(countBytes, 0, littleEndian))
        guard count > 0, count < 1_000, let raw = file.bytes(at: base + offset + 2, count: count * 12), raw.count == count * 12 else { return nil }
        var entries: [UInt16: Entry] = [:]
        for index in 0..<count {
            let at = index * 12
            let entry = Entry(
                tag: Self.uint16(raw, at, littleEndian), type: Self.uint16(raw, at + 2, littleEndian),
                count: Int(Self.uint32(raw, at + 4, littleEndian)), valueField: offset + 2 + at + 8
            )
            entries[entry.tag] = entry
        }
        return entries
    }

    private static let typeSizes: [UInt16: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8]

    /// 值所在的位置（相对 TIFF 头）。
    func valueOffset(_ entry: Entry) -> Int {
        let size = (Self.typeSizes[entry.type] ?? 1) * entry.count
        guard size > 4, let field = file.bytes(at: base + entry.valueField, count: 4), field.count == 4 else { return entry.valueField }
        return Int(Self.uint32(field, 0, littleEndian))
    }

    /// 按 16 位整数读（`asType` 用来把 undefined 类型当 int16u 读）。
    func uint16s(_ entry: Entry, asType: UInt16? = nil) -> [UInt16] {
        let byteCount = (Self.typeSizes[entry.type] ?? 1) * entry.count
        let type = asType ?? entry.type
        guard type == 3 || type == 8, byteCount >= 2, byteCount < 4_096,
              let raw = file.bytes(at: base + valueOffset(entry), count: byteCount), raw.count == byteCount else { return [] }
        return stride(from: 0, to: byteCount - 1, by: 2).map { Self.uint16(raw, $0, littleEndian) }
    }

    func ascii(_ entry: Entry) -> String {
        guard entry.type == 2, entry.count > 0, entry.count < 256,
              let raw = file.bytes(at: base + valueOffset(entry), count: entry.count) else { return "" }
        return String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }

    func uint32s(_ entry: Entry) -> [UInt32] {
        guard entry.type == 4 || entry.type == 9 || entry.type == 13, entry.count > 0, entry.count < 1_024,
              let raw = file.bytes(at: base + valueOffset(entry), count: entry.count * 4), raw.count == entry.count * 4 else { return [] }
        return stride(from: 0, to: raw.count, by: 4).map { Self.uint32(raw, $0, littleEndian) }
    }

    static func uint16(_ bytes: [UInt8], _ at: Int, _ little: Bool) -> UInt16 {
        little ? UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 : UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
    }

    static func uint32(_ bytes: [UInt8], _ at: Int, _ little: Bool) -> UInt32 {
        let b = (0..<4).map { UInt32(bytes[at + $0]) }
        return little ? b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24 : b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]
    }
}
