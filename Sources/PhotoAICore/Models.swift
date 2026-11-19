import Foundation

public typealias VolumeID = Int
public typealias PhotoID = Int
public typealias FileID = Int
public typealias CollectionID = Int

/// 库里记录的一个卷。在线 / 离线不在这里：那是运行时状态，看卷有没有挂载。
public struct VolumeRecord: Sendable, Equatable, Identifiable, Hashable {
    public enum Status: String, Sendable { case active, removed }

    public let id: VolumeID
    public var volumeUUID: String
    public var name: String
    /// 扫描的文件夹，相对卷根目录；空字符串表示整个卷。
    public var scanRoot: String
    public var capacityBytes: Int?
    public var filesystem: String?
    public var status: Status
    public var createdAt: Date
    public var removedAt: Date?
    public var lastSeenAt: Date?
    public var lastScannedAt: Date?
}

public enum PreviewState: String, Sendable { case pending, ready, failed }
public enum Flag: String, Sendable { case none, pick, reject }

/// 网格里一格需要的字段。10 万条一次读出，所以只放必需的。
public struct PhotoSummary: Sendable, Equatable, Identifiable {
    public let id: PhotoID
    public var baseName: String
    /// `yyyy-MM-dd HH:mm:ss`；没有拍摄时间为 nil。
    public var captureDate: String?
    public var width: Int?
    public var height: Int?
    public var rating: Int
    public var flag: Flag
    public var thumbState: PreviewState
    public var hasRaw: Bool
    public var hasJPEG: Bool

    /// 按天分组用：`yyyy-MM-dd`；没有拍摄时间的归到“日期未知”。
    public var day: String? { captureDate.map { String($0.prefix(10)) } }

    public var aspectRatio: Double {
        guard let width, let height, width > 0, height > 0 else { return 1.5 }
        return Double(width) / Double(height)
    }
}

/// 照片详情：检查器用。
public struct PhotoDetail: Sendable, Equatable {
    public struct Location: Sendable, Equatable {
        public var volumeID: VolumeID
        public var volumeName: String
        public var relativePath: String
        public var isPresent: Bool
    }

    public var summary: PhotoSummary
    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?
    public var focalLength: Double?
    public var aperture: Double?
    public var shutter: Double?
    public var iso: Int?
    public var previewState: PreviewState
    public var presentLocationCount: Int
    public var extensions: [String]
    public var locations: [Location]
}

/// 侧栏或命令行选的一组照片。
public enum PhotoScope: Sendable, Hashable {
    case all
    case volume(VolumeID)
    /// `yyyy`、`yyyy-MM` 或 `yyyy-MM-dd`。
    case datePrefix(String)
    /// 没有拍摄时间的照片。
    case undated
    case importBatch(Int)
    case collection(CollectionID)
}

public enum PhotoSort: Sendable, Hashable {
    case captureDateDescending
    case captureDateAscending
    case fileName
}

/// 一个卷的收录与预览进度（卷详情、清卡检查用）。
public struct VolumeStats: Sendable, Equatable {
    /// 在这个卷上有现存位置的照片数，即“已收录”。
    public var photoCount: Int
    /// 其中 480 和 1600 两档预览都已就绪的照片数，即“离线预览就绪”。
    public var previewReadyCount: Int
    public var incompleteDirectoryCount: Int
}

public struct ImportBatch: Sendable, Equatable, Identifiable {
    public let id: Int
    public var volumeID: VolumeID
    public var volumeName: String
    public var startedAt: Date
    public var photoCount: Int
}

/// 侧栏的时间树：每天的照片数。
public struct DayCount: Sendable, Equatable {
    public var day: String
    public var count: Int
}
