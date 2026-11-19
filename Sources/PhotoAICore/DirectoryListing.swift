import Foundation

/// 目录里的一项。
public struct DirectoryEntry: Sendable, Equatable {
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    /// 修改时间（秒）。只用来跳过没变的文件，不参与身份。
    public var modificationTime: Double

    public init(name: String, isDirectory: Bool, size: Int64 = 0, modificationTime: Double = 0) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationTime = modificationTime
    }
}

/// 列出一个目录。要么完整列出，要么抛错——扫描只对完整列出的目录下结论（数据模型 §5）。
public protocol DirectoryListing: Sendable {
    func list(_ url: URL) throws -> [DirectoryEntry]
}

public struct FileSystemLister: DirectoryListing {
    public init() {}

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey
    ]

    public func list(_ url: URL) throws -> [DirectoryEntry] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Self.keys,
            options: [.skipsHiddenFiles]
        )
        return try urls.compactMap { child in
            // 读不到属性（比如中途拔卡）就整个目录算没列完，而不是跳过这一项。
            let values = try child.resourceValues(forKeys: Set(Self.keys))
            if values.isDirectory == true {
                return DirectoryEntry(name: child.lastPathComponent, isDirectory: true)
            }
            guard values.isRegularFile == true else { return nil }
            return DirectoryEntry(
                name: child.lastPathComponent,
                isDirectory: false,
                size: Int64(values.fileSize ?? 0),
                modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            )
        }
    }
}
