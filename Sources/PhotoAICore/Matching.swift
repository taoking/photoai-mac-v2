import Foundation

/// 命令行按名字或编号找照片的一项（产品定位 §3.4）。
///
/// - `DSC01926.ARW`：文件名，去掉扩展名的部分和扩展名都要对上（不分大小写）；
/// - `DSC01926`：去掉扩展名的文件名；
/// - `01926`、`1926`：编号，即文件名里最后一段数字；
/// - `1926-1950`：编号范围，两头都算。
public enum MatchTerm: Sendable, Hashable {
    case fileName(baseName: String, extension: String)
    case baseName(String)
    case number(Int)
    case range(Int, Int)

    /// 编号最多 9 位，和 `PhotoIdentity.fileNumber` 一致；更长的纯数字当文件名。
    static let maxNumberDigits = 9

    /// 解析一项。认不出的返回 nil（比如范围起点比终点大）。
    public static func parse(_ text: String) -> MatchTerm? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let number = Self.number(text) { return .number(number) }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 2, let start = Self.number(parts[0]), let end = Self.number(parts[1]) {
            return start <= end ? .range(start, end) : nil
        }
        let ext = (text as NSString).pathExtension
        if !ext.isEmpty, FileKind(extension: ext) != nil {
            return .fileName(baseName: PhotoIdentity.baseName(ofFileName: text), extension: ext)
        }
        return .baseName(text)
    }

    /// 解析命令行参数：每个参数还可以用逗号隔开写多项。
    public static func parseAll(_ arguments: [String]) throws -> [MatchTerm] {
        var terms: [MatchTerm] = []
        for argument in arguments {
            for piece in argument.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace }) {
                guard let term = parse(String(piece)) else { throw MatchError.badTerm(String(piece)) }
                terms.append(term)
            }
        }
        return terms
    }

    private static func number(_ text: Substring) -> Int? { number(String(text)) }

    private static func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.count <= maxNumberDigits, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }
}

public enum MatchError: Error, CustomStringConvertible, Equatable {
    case badTerm(String)

    public var description: String {
        switch self {
        case .badTerm(let text): "认不出“\(text)”：写文件名、去掉扩展名的文件名、编号或编号范围（起点不大于终点），如 DSC01926.ARW、DSC01926、1926、1926-1950"
        }
    }
}

/// 匹配到的一张照片。
public struct MatchedPhoto: Sendable, Equatable {
    public let id: PhotoID
    public let baseName: String
    public let fileNumber: Int?
    /// `yyyy-MM-dd HH:mm:ss`；没有拍摄时间为 nil。
    public let captureDate: String?
    public let rating: Int
    /// 大写，按字母排序，如 `["ARW", "JPG"]`。
    public let extensions: [String]
}

/// 一次匹配的结果。
public struct MatchReport: Sendable {
    /// 一个编号或一个名字命中的照片：命中多张时取拍摄时间最晚的一张，其余记在 `skipped`。
    public struct Hit: Sendable, Equatable {
        /// 命中的是什么：范围里的单个编号、或者原样的名字。
        public let key: String
        public let photo: MatchedPhoto
        public let skipped: [MatchedPhoto]
    }

    public internal(set) var hits: [Hit] = []
    /// 什么都没匹配到的项；范围里没匹配到的编号合并成一段段，如 `1930`、`1933-1935`。
    public internal(set) var unmatched: [String] = []

    /// 选中的照片，去掉重复，按命中的先后。
    public var photos: [MatchedPhoto] {
        var seen = Set<PhotoID>()
        return hits.map(\.photo).filter { seen.insert($0.id).inserted }
    }

    public var photoIDs: [PhotoID] { photos.map(\.id) }

    /// 被跳过、而且没有被别的项选中的照片。
    public var skipped: [MatchedPhoto] {
        let chosen = Set(photoIDs)
        var seen = Set<PhotoID>()
        return hits.flatMap(\.skipped).filter { !chosen.contains($0.id) && seen.insert($0.id).inserted }
    }
}

extension LibraryReader {
    /// 按命令行的规则找照片。只看可见照片（至少有一个现存位置）。
    /// 一个编号或名字命中多张时，取拍摄时间最晚的一张（编号循环后旧照片和新照片同号），其余列为跳过。
    public func match(_ terms: [MatchTerm]) throws -> MatchReport {
        var report = MatchReport()
        for term in terms {
            switch term {
            case .number(let number):
                try matchNumbers(number, number, into: &report)
            case .range(let start, let end):
                try matchNumbers(start, end, into: &report)
            case .baseName(let name):
                let photos = try matchedPhotos(where: "p.base_name = ? COLLATE NOCASE", [name])
                Self.add(photos, key: name, into: &report)
            case .fileName(let name, let ext):
                let photos = try matchedPhotos(
                    where: "p.base_name = ? COLLATE NOCASE AND EXISTS (SELECT 1 FROM files f WHERE f.photo_id = p.id AND f.extension = ? COLLATE NOCASE)",
                    [name, ext]
                )
                Self.add(photos, key: "\(name).\(ext)", into: &report)
            }
        }
        return report
    }

    private func matchNumbers(_ start: Int, _ end: Int, into report: inout MatchReport) throws {
        let photos = try matchedPhotos(where: "p.file_number BETWEEN ? AND ?", [start, end])
        var byNumber: [Int: [MatchedPhoto]] = [:]
        for photo in photos { byNumber[photo.fileNumber!, default: []].append(photo) }
        func missing(_ first: Int, _ last: Int) {
            report.unmatched.append(first == last ? "\(first)" : "\(first)-\(last)")
        }
        // 按编号从小到大走一遍，命中的逐个记下，两个命中之间的空档记成一段。范围再大也只走命中的编号。
        var cursor = start
        for number in byNumber.keys.sorted() {
            if number > cursor { missing(cursor, number - 1) }
            Self.add(byNumber[number]!, key: "\(number)", into: &report)
            cursor = number + 1
        }
        if cursor <= end { missing(cursor, end) }
    }

    /// 查询结果已经按“最晚的在前”排好。
    private static func add(_ photos: [MatchedPhoto], key: String, into report: inout MatchReport) {
        guard let latest = photos.first else {
            report.unmatched.append(key)
            return
        }
        report.hits.append(MatchReport.Hit(key: key, photo: latest, skipped: Array(photos.dropFirst())))
    }

    /// 没有拍摄时间的排在最后；同一时刻再按亚秒、导入时间排。
    private func matchedPhotos(where condition: String, _ arguments: [any SQLBindable]) throws -> [MatchedPhoto] {
        try db.all(
            """
            SELECT p.id, p.base_name, p.file_number, p.capture_date, p.rating,
                   (SELECT group_concat(f.extension, ',') FROM files f WHERE f.photo_id = p.id)
            FROM photos p
            WHERE p.present_location_count > 0 AND \(condition)
            ORDER BY p.file_number, p.capture_date IS NULL, p.capture_date DESC, p.capture_subsec DESC, p.imported_at DESC, p.id DESC;
            """,
            arguments
        ) { row in
            MatchedPhoto(
                id: row.int(0), baseName: row.text(1) ?? "", fileNumber: row.optionalInt(2), captureDate: row.text(3),
                rating: row.int(4),
                extensions: (row.text(5) ?? "").split(separator: ",").map { $0.uppercased() }.sorted()
            )
        }
    }

    /// 按名字找收藏夹（区分大小写，名字要完全一样）。
    public func collections(named name: String) throws -> [CollectionRecord] {
        try collections().filter { $0.name == name }
    }
}

/// `photoai collect` 的结果。
public struct CollectResult: Sendable, Equatable {
    public let collection: CollectionID
    public let created: Bool
    /// 这次新加入的；其余原本就在里面。
    public let added: [PhotoID]
}

public enum CollectError: Error, CustomStringConvertible, Equatable {
    case emptyName
    case ambiguousName(String, count: Int)

    public var description: String {
        switch self {
        case .emptyName: "收藏夹名字不能为空"
        case .ambiguousName(let name, let count): "有 \(count) 个收藏夹都叫“\(name)”，先在软件里改个名字再用"
        }
    }
}

extension Library {
    /// 加入叫这个名字的收藏夹；没有就新建一个。新建和加入在同一个事务里，加入失败不会留下空收藏夹。
    public func collect(_ photoIDs: [PhotoID], intoCollectionNamed name: String) throws -> CollectResult {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw CollectError.emptyName }
        return try db.transaction {
            let existing = try reader.collections(named: name)
            guard existing.count <= 1 else { throw CollectError.ambiguousName(name, count: existing.count) }
            let id = try existing.first?.id ?? createCollection(name: name)
            let added = try addPhotos(photoIDs, to: id)
            return CollectResult(collection: id, created: existing.isEmpty, added: added)
        }
    }
}
