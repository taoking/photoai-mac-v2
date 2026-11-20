import Foundation

/// 照片身份。见 docs/设计/数据模型.md §4。
///
/// 名字不同一定不是同一张；名字相同时看拍摄时间（精确到秒，不用亚秒），
/// 没有拍摄时间时看文件大小。文件名只统一大小写，不去掉 `(1)` 之类的复制后缀。
public enum PhotoIdentity {
    public static func key(baseName: String, captureDate: String?, fileSize: Int64) -> String {
        let name = baseName.lowercased()
        if let captureDate {
            return "\(name)|\(captureDate)"
        }
        return "\(name)|size:\(fileSize)"
    }

    /// 去掉扩展名的文件名：`DSC01926.ARW` → `DSC01926`。只去掉最后一个扩展名。
    public static func baseName(ofFileName fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
    }

    /// 文件名里最后一段数字：`DSC01926` → 1926。命令行按编号匹配用。
    public static func fileNumber(ofBaseName baseName: String) -> Int? {
        var digits = Substring()
        var index = baseName.startIndex
        while index < baseName.endIndex {
            if baseName[index].isASCII, baseName[index].isNumber {
                let start = index
                while index < baseName.endIndex, baseName[index].isASCII, baseName[index].isNumber {
                    index = baseName.index(after: index)
                }
                digits = baseName[start..<index]
            } else {
                index = baseName.index(after: index)
            }
        }
        // 太长的数字串（比如手机的时间戳文件名）不当编号。
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        return Int(digits)
    }
}

/// 文件的格式类别。
public enum FileKind: String, Sendable, CaseIterable {
    case raw
    case jpeg
    case heif
    case tiff
    case png

    public static let rawExtensions: Set<String> = [
        "arw", "cr2", "cr3", "dng", "nef", "nrw", "orf", "raf", "rw2", "pef", "srw", "x3f", "3fr", "iiq", "raw"
    ]

    public init?(extension ext: String) {
        let ext = ext.lowercased()
        if Self.rawExtensions.contains(ext) {
            self = .raw
            return
        }
        switch ext {
        case "jpg", "jpeg": self = .jpeg
        case "heic", "heif", "hif": self = .heif
        case "tif", "tiff": self = .tiff
        case "png": self = .png
        default: return nil
        }
    }

    /// 生成预览时的优先顺序：JPEG 最快也最接近相机直出，RAW 排最后。
    var previewPriority: Int {
        switch self {
        case .jpeg: 0
        case .heif: 1
        case .tiff: 2
        case .png: 3
        case .raw: 4
        }
    }
}

/// EXIF 拍摄时间。
public enum CaptureDate {
    /// 把 EXIF 的 `yyyy:MM:dd HH:mm:ss` 规范成 `yyyy-MM-dd HH:mm:ss`。
    ///
    /// 存相机写的本地时间文本，不换算时区：身份只需要“同一个时刻的同一段文字”，
    /// 换算会让改过系统时区的机器算出不同的身份。全 0 或格式不对时返回 nil。
    public static func normalize(exif text: String) -> String? {
        let bytes = Array(text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).utf8)
        guard bytes.count >= 19,
              bytes[4] == UInt8(ascii: ":") || bytes[4] == UInt8(ascii: "-"),
              bytes[7] == UInt8(ascii: ":") || bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: " ") || bytes[10] == UInt8(ascii: "T"),
              bytes[13] == UInt8(ascii: ":"),
              bytes[16] == UInt8(ascii: ":") else {
            return nil
        }
        func number(_ range: Range<Int>) -> Int? {
            var result = 0
            for index in range {
                let digit = Int(bytes[index]) &- 48
                guard (0...9).contains(digit) else { return nil }
                result = result * 10 + digit
            }
            return result
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              year > 0, (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second < 61 else {
            return nil
        }
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
    }
}
