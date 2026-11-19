import Foundation

/// 筛选条的条件（信息架构 §3.3.1）：同类里多选取“或者”，不同类之间取“并且”。
///
/// 只在内存里对已经读出的照片判断，十万条一次在几毫秒内（PF-8）。
public struct PhotoFilter: Sendable, Hashable {
    public enum StarMode: Sendable, Hashable {
        /// 至少 N 星：只能选一个 N。
        case atLeast
        /// 正好 N 星：可以多选，0 表示未评分。
        case exactly
    }

    /// “更多”里的文件类型。
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case rawPlusJPEG = "RAW+JPG"
        case jpegOnly = "JPG"
        case rawOnly = "RAW"
    }

    public var starMode: StarMode = .atLeast
    public var stars: Set<Int> = []
    public var labels: Set<LabelID> = []
    /// “没有标签”，和 `labels` 同类，取“或者”。
    public var noLabel = false
    public var flags: Set<Flag> = []
    public var kinds: Set<Kind> = []

    public init() {}

    public var isEmpty: Bool { activeGroupCount == 0 }

    /// 生效的条件有几类（工具栏“筛选”按钮上的数字）。
    public var activeGroupCount: Int {
        (stars.isEmpty ? 0 : 1) + (labels.isEmpty && !noLabel ? 0 : 1) + (flags.isEmpty ? 0 : 1) + (kinds.isEmpty ? 0 : 1)
    }

    public func matches(_ photo: PhotoSummary) -> Bool {
        if !stars.isEmpty {
            switch starMode {
            case .atLeast:
                if photo.rating < (stars.min() ?? 0) { return false }
            case .exactly:
                if !stars.contains(photo.rating) { return false }
            }
        }
        if !labels.isEmpty || noLabel {
            let hit = (noLabel && photo.labelIDs.isEmpty) || photo.labelIDs.contains { labels.contains($0) }
            if !hit { return false }
        }
        if !flags.isEmpty, !flags.contains(photo.flag) { return false }
        if !kinds.isEmpty, !kinds.contains(Self.kind(of: photo)) { return false }
        return true
    }

    public static func kind(of photo: PhotoSummary) -> Kind {
        if photo.hasRaw && photo.hasJPEG { return .rawPlusJPEG }
        return photo.hasRaw ? .rawOnly : .jpegOnly
    }

    // MARK: 筛选条上点一下

    /// 点星级按钮：至少模式下单选（再点取消），正好模式下多选。
    public mutating func toggleStar(_ n: Int) {
        switch starMode {
        case .atLeast:
            let had = stars.contains(n)
            stars.removeAll()
            if !had { stars.insert(n) }
        case .exactly:
            if stars.contains(n) { stars.remove(n) } else { stars.insert(n) }
        }
    }

    /// 切换“至少 / 正好”，已选的星级清空。
    public mutating func toggleStarMode() {
        starMode = starMode == .atLeast ? .exactly : .atLeast
        stars.removeAll()
    }

    public mutating func toggleLabel(_ id: LabelID) {
        if labels.contains(id) { labels.remove(id) } else { labels.insert(id) }
    }

    public mutating func toggleFlag(_ flag: Flag) {
        if flags.contains(flag) { flags.remove(flag) } else { flags.insert(flag) }
    }

    public mutating func toggleKind(_ kind: Kind) {
        if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
    }

    /// 标题行的摘要，如“★5+ · 经典/人像 · Pick”。
    public func summary(labelNames: [LabelID: String]) -> String {
        var parts: [String] = []
        if !stars.isEmpty {
            switch starMode {
            case .atLeast: parts.append("★\(stars.min() ?? 0)+")
            case .exactly: parts.append(stars.sorted().map { $0 == 0 ? "未评分" : "★\($0)" }.joined(separator: "/"))
            }
        }
        var labelParts = labels.compactMap { labelNames[$0] }.sorted()
        if noLabel { labelParts.append("无标签") }
        if !labelParts.isEmpty { parts.append(labelParts.joined(separator: "/")) }
        if !flags.isEmpty {
            let order: [Flag] = [.pick, .reject, .none]
            parts.append(order.filter { flags.contains($0) }.map(\.displayName).joined(separator: "/"))
        }
        if !kinds.isEmpty {
            parts.append(Kind.allCases.filter { kinds.contains($0) }.map(\.rawValue).joined(separator: "/"))
        }
        return parts.joined(separator: " · ")
    }
}

extension Flag {
    public var displayName: String {
        switch self {
        case .pick: "Pick"
        case .reject: "Reject"
        case .none: "未标记"
        }
    }
}
