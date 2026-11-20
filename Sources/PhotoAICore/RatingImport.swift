import Foundation

/// 从文本文件导入星级（迭代 I-2）：每行“编号或文件名  星级”，中间一个或多个空格（Tab 也行）。
///
/// 只认索尼 A7C II 的命名，格式不对的行整行忽略：
/// - 第一列：`DSC01064`、`_DSC01064`（AdobeRGB 色彩空间时的前缀），可带 `.ARW` / `.JPG` / `.HIF`；或者编号 `1064`、`01064`（最多 5 位）；
/// - 第二列：星级 1–5；
/// - 一行只能有这两列。
public struct RatingFile: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        /// 第几行，从 1 开始。
        public let line: Int
        /// 第一列原样。
        public let key: String
        public let term: MatchTerm
        public let rating: Int
    }

    public struct IgnoredLine: Sendable, Equatable {
        public let line: Int
        public let text: String
    }

    public internal(set) var entries: [Entry] = []
    /// 不是空行、但格式不对的行。
    public internal(set) var ignored: [IgnoredLine] = []

    nonisolated(unsafe) private static let keyPattern = #/(?i)(_?DSC[0-9]{5}(\.(ARW|JPG|HIF))?|[0-9]{1,5})/#

    public init(text: String) {
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if columns.count == 2, columns[0].wholeMatch(of: Self.keyPattern) != nil,
               let rating = Int(columns[1]), (1...5).contains(rating), columns[1].count == 1,
               let term = MatchTerm.parse(columns[0]) {
                entries.append(Entry(line: index + 1, key: columns[0], term: term, rating: rating))
            } else {
                ignored.append(IgnoredLine(line: index + 1, text: line))
            }
        }
    }
}

/// 导入前先给用户看的结果：要改哪些照片、哪些行没对上。确认后按 `edit` 写库（可撤销）。
public struct RatingImportPlan: Sendable, Equatable {
    public struct Change: Sendable, Equatable {
        public let photo: MatchedPhoto
        public let rating: Int
    }

    /// 一张照片在文件里写了不同的星级：以后面的行为准。
    public struct Conflict: Sendable, Equatable {
        public let photo: MatchedPhoto
        public let ratings: [Int]
    }

    /// 每张照片一项，按文件里第一次出现的先后。
    public internal(set) var changes: [Change] = []
    /// 没匹配到照片的行。
    public internal(set) var unmatched: [RatingFile.Entry] = []
    /// 同一个编号命中多张时，没被选中的旧照片（和命令行一样只取拍摄时间最晚的一张）。
    public internal(set) var skipped: [MatchedPhoto] = []
    public internal(set) var conflicts: [Conflict] = []
    public internal(set) var ignored: [RatingFile.IgnoredLine] = []

    /// 星级真的会变的照片数。
    public var changedCount: Int { changes.filter { $0.photo.rating != $0.rating }.count }

    /// 每个星级几张（含原本就是的）。
    public var countsByRating: [Int: Int] {
        Dictionary(grouping: changes, by: \.rating).mapValues(\.count)
    }

    public var edit: CullingEdit {
        .rating(
            before: Dictionary(uniqueKeysWithValues: changes.map { ($0.photo.id, $0.photo.rating) }),
            after: Dictionary(uniqueKeysWithValues: changes.map { ($0.photo.id, $0.rating) })
        )
    }
}

extension LibraryReader {
    /// 按命令行的匹配规则逐行找照片（只看可见照片）。
    public func planRatingImport(_ file: RatingFile) throws -> RatingImportPlan {
        var plan = RatingImportPlan(ignored: file.ignored)
        var index: [PhotoID: Int] = [:]
        var ratings: [PhotoID: [Int]] = [:]
        var skipped: [PhotoID: MatchedPhoto] = [:]
        for entry in file.entries {
            let report = try match([entry.term])
            guard let photo = report.photos.first else {
                plan.unmatched.append(entry)
                continue
            }
            for old in report.skipped { skipped[old.id] = old }
            ratings[photo.id, default: []].append(entry.rating)
            if let at = index[photo.id] {
                plan.changes[at] = RatingImportPlan.Change(photo: photo, rating: entry.rating)
            } else {
                index[photo.id] = plan.changes.count
                plan.changes.append(RatingImportPlan.Change(photo: photo, rating: entry.rating))
            }
        }
        plan.skipped = skipped.values.filter { index[$0.id] == nil }.sorted { $0.id < $1.id }
        plan.conflicts = plan.changes.compactMap { change in
            let all = ratings[change.photo.id] ?? []
            return Set(all).count > 1 ? RatingImportPlan.Conflict(photo: change.photo, ratings: all) : nil
        }
        return plan
    }
}
