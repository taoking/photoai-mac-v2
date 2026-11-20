import Foundation

/// 全局搜索的一个条件（信息架构 §6）。条件之间取“并且”，每个条件在界面上是一个可以删掉的标签。
public enum SearchTerm: Sendable, Hashable {
    case number(Int)
    case range(Int, Int)
    case fileName(baseName: String, extension: String)
    /// `2026`、`2026-08`、`2026-08-12`：拍摄时间以它开头。
    case datePrefix(String)
    /// `8月`、`8月12日`：任何一年的这个月、这一天。
    case monthDay(month: Int, day: Int?)
    /// 认出来的相机型号（库里实际的写法，可能几个）。
    case camera(query: String, models: [String])
    case lens(query: String, lenses: [String])
    case label(LabelID, name: String)
    case person(PersonID, name: String)
    /// 地名里含有这段文字。
    case place(String)
    /// OCR 文字或文件名里含有这段文字。
    case text(String)

    /// 标签上显示的字。
    public var title: String {
        switch self {
        case .number(let number): "编号 \(number)"
        case .range(let start, let end): "编号 \(start)–\(end)"
        case .fileName(let baseName, let ext): "文件 \(baseName).\(ext)"
        case .datePrefix(let prefix): "日期：\(prefix)"
        case .monthDay(let month, let day): day.map { "日期：\(month) 月 \($0) 日" } ?? "日期：\(month) 月"
        case .camera(let query, _): "相机：\(query)"
        case .lens(let query, _): "镜头：\(query)"
        case .label(_, let name): "标签：\(name)"
        case .person(_, let name): "人物：\(name)"
        case .place(let text): "地点：\(text)"
        case .text(let text): "文字：\(text)"
        }
    }
}

/// 一次搜索：原来输入的文字和认出来的条件。
public struct SearchQuery: Sendable, Hashable {
    public var input: String
    public var terms: [SearchTerm]

    public init(input: String, terms: [SearchTerm]) {
        self.input = input
        self.terms = terms
    }
}

/// 认条件要用到的库里的词：标签名、人名、相机、镜头、地名。
public struct SearchVocabulary: Sendable, Equatable {
    public var labels: [String: LabelID] = [:]
    public var people: [String: PersonID] = [:]
    public var cameras: [(make: String?, model: String)] = []
    public var lenses: [String] = []
    /// 地名和完整地址。
    public var placeTexts: [String] = []

    public init(
        labels: [String: LabelID] = [:], people: [String: PersonID] = [:],
        cameras: [(make: String?, model: String)] = [], lenses: [String] = [], placeTexts: [String] = []
    ) {
        self.labels = labels
        self.people = people
        self.cameras = cameras
        self.lenses = lenses
        self.placeTexts = placeTexts
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.labels == b.labels && a.people == b.people && a.lenses == b.lenses && a.placeTexts == b.placeTexts
            && a.cameras.map { "\($0.make ?? "")\u{1}\($0.model)" } == b.cameras.map { "\($0.make ?? "")\u{1}\($0.model)" }
    }
}

/// 本地规则解析搜索框的输入（信息架构 §6）。一项一项认，顺序是：
/// 日期 → 标签 → 人名 → 相机 → 镜头 → 编号 / 文件名 → 地名 → 其他文字。
/// 日期在编号之前，`2026-08` 不会被当成编号范围；镜头在编号之前，`70-200` 不会被当成编号范围。
public enum SearchParser {
    public static func parse(_ input: String, vocabulary: SearchVocabulary) -> SearchQuery {
        SearchQuery(input: input, terms: tokens(input).map { term(for: $0.text, quoted: $0.quoted, vocabulary: vocabulary) })
    }

    /// 按空格、逗号、顿号分开；引号里的是一整段文字（OCR 里有空格的一行）。
    static func tokens(_ input: String) -> [(text: String, quoted: Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        var quote: Character?
        func flush(quoted: Bool) {
            let text = current.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { result.append((text, quoted)) }
            current = ""
        }
        for character in input {
            if let open = quote {
                if character == open || (open == "“" && character == "”") {
                    flush(quoted: true)
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "“" {
                flush(quoted: false)
                quote = character
            } else if character.isWhitespace || ",，、;；".contains(character) {
                flush(quoted: false)
            } else {
                current.append(character)
            }
        }
        flush(quoted: quote != nil)
        return result
    }

    static func term(for token: String, quoted: Bool, vocabulary: SearchVocabulary) -> SearchTerm {
        if quoted { return .text(token) }
        if let date = date(token) { return date }
        if let id = vocabulary.labels.first(where: { $0.key.caseInsensitiveCompare(token) == .orderedSame }) {
            return .label(id.value, name: id.key)
        }
        if let id = vocabulary.people[token] { return .person(id, name: token) }
        let hasLetter = token.contains { $0.isLetter }
        if hasLetter, let models = cameras(token, vocabulary.cameras) { return .camera(query: token, models: models) }
        if token.contains(where: { !$0.isNumber }), token.count >= 2 {
            let lenses = vocabulary.lenses.filter { $0.range(of: token, options: .caseInsensitive) != nil }
            if !lenses.isEmpty { return .lens(query: token, lenses: lenses.sorted()) }
        }
        switch MatchTerm.parse(token) {
        case .number(let number): return .number(number)
        case .range(let start, let end): return .range(start, end)
        case .fileName(let baseName, let ext): return .fileName(baseName: baseName, extension: ext)
        case .baseName, nil: break
        }
        if vocabulary.placeTexts.contains(where: { $0.range(of: token, options: .caseInsensitive) != nil }) {
            return .place(token)
        }
        return .text(token)
    }

    static func date(_ token: String) -> SearchTerm? {
        func prefix(_ year: Int, _ month: Int?, _ day: Int?) -> SearchTerm? {
            guard (1900...2999).contains(year) else { return nil }
            guard let month else { return .datePrefix(String(year)) }
            guard (1...12).contains(month) else { return nil }
            guard let day else { return .datePrefix(String(format: "%04d-%02d", year, month)) }
            guard (1...31).contains(day) else { return nil }
            return .datePrefix(String(format: "%04d-%02d-%02d", year, month, day))
        }
        if let match = token.wholeMatch(of: /(\d{4})[-\/.](\d{1,2})(?:[-\/.](\d{1,2}))?/) {
            return prefix(Int(match.1)!, Int(match.2)!, match.3.map { Int($0)! })
        }
        if let match = token.wholeMatch(of: /(\d{4})年(?:(\d{1,2})月(?:(\d{1,2})[日号])?)?/) {
            return prefix(Int(match.1)!, match.2.map { Int($0)! }, match.3.map { Int($0)! })
        }
        if let match = token.wholeMatch(of: /(\d{1,2})月(?:(\d{1,2})[日号]?)?/) {
            let month = Int(match.1)!, day = match.2.map { Int($0)! }
            guard (1...12).contains(month), day.map({ (1...31).contains($0) }) ?? true else { return nil }
            return .monthDay(month: month, day: day)
        }
        return nil
    }

    /// 相机：型号或厂商。索尼的型号写法很多：`ILCE-7CM2` 也写作 `A7C2`、`A7CII`、`a7c m2`。
    static func cameras(_ token: String, _ cameras: [(make: String?, model: String)]) -> [String]? {
        let query = cameraKey(token)
        guard query.count >= 2 else { return nil }
        let models = cameras.filter { camera in
            let key = cameraKey(camera.model)
            if key == query || (query.count >= 3 && key.contains(query)) { return true }
            guard let make = camera.make?.lowercased() else { return false }
            return make.hasPrefix(token.lowercased()) || (token == "索尼" && make.hasPrefix("sony"))
        }.map(\.model)
        return models.isEmpty ? nil : Array(Set(models)).sorted()
    }

    static func cameraKey(_ text: String) -> String {
        var key = text.lowercased().filter { $0.isLetter || $0.isNumber }
        if key.hasPrefix("ilce") { key = "a" + key.dropFirst(4) }
        for (roman, digit) in [("iv", "m4"), ("iii", "m3"), ("ii", "m2")] where key.hasSuffix(roman) && key.count > roman.count + 1 {
            key = key.dropLast(roman.count) + digit
            break
        }
        // A7C2 → a7cm2、A7R5 → a7rm5：型号字母后面直接跟代数（A7M4 本来就有 m）。
        if let match = key.wholeMatch(of: /(a\d+[a-ln-z])(\d)/) { key = match.1 + "m" + match.2 }
        return key
    }
}

extension LibraryReader {
    /// 搜索框认词用的词表。
    public func searchVocabulary() throws -> SearchVocabulary {
        var vocabulary = SearchVocabulary()
        for label in try labels() where !label.name.isEmpty { vocabulary.labels[label.name] = label.id }
        vocabulary.people = try namedPeople()
        vocabulary.cameras = try db.all(
            "SELECT DISTINCT camera_make, camera_model FROM photos WHERE camera_model IS NOT NULL;"
        ) { (make: $0.text(0), model: $0.text(1) ?? "") }
        vocabulary.lenses = try db.all("SELECT DISTINCT lens FROM photos WHERE lens IS NOT NULL;") { $0.text(0) ?? "" }
        vocabulary.placeTexts = try db.all(
            "SELECT name, detail FROM places WHERE state = 'found';"
        ) { [$0.text(0), $0.text(1)].compactMap { $0 } }.flatMap { $0 }
        return vocabulary
    }

    /// 一个搜索条件的 SQL（照片表的别名是 p）。
    static func condition(for term: SearchTerm) -> (String, [any SQLBindable]) {
        switch term {
        case .number(let number):
            return ("p.file_number = ?", [number])
        case .range(let start, let end):
            return ("p.file_number BETWEEN ? AND ?", [start, end])
        case .fileName(let baseName, let ext):
            return (
                """
                p.base_name = ? COLLATE NOCASE
                AND EXISTS (SELECT 1 FROM files f WHERE f.photo_id = p.id AND f.extension = ? COLLATE NOCASE)
                """,
                [baseName, ext]
            )
        case .datePrefix(let prefix):
            return ("p.capture_date >= ? AND p.capture_date < ?", [prefix, prefix + "~"])
        case .monthDay(let month, let day):
            if let day {
                return ("substr(p.capture_date, 6, 5) = ?", [String(format: "%02d-%02d", month, day)])
            }
            return ("substr(p.capture_date, 6, 2) = ?", [String(format: "%02d", month)])
        case .camera(_, let models):
            return ("p.camera_model IN (\(placeholders(models.count)))", models.map { $0 as any SQLBindable })
        case .lens(_, let lenses):
            return ("p.lens IN (\(placeholders(lenses.count)))", lenses.map { $0 as any SQLBindable })
        case .label(let id, _):
            return ("p.id IN (SELECT photo_id FROM photo_labels WHERE label_id = ?)", [id])
        case .person(let id, _):
            return ("p.id IN (SELECT photo_id FROM faces WHERE person_id = ?)", [id])
        case .place(let text):
            let pattern = likePattern(text)
            return (
                """
                p.geo_cell IN (SELECT geo_cell FROM places
                               WHERE state = 'found' AND (name LIKE ? ESCAPE '\\' OR detail LIKE ? ESCAPE '\\'))
                """,
                [pattern, pattern]
            )
        case .text(let text):
            // trigram 索引：三个字以上走索引，一两个字逐行比（OCR 文字不多）。
            let pattern = likePattern(text)
            return (
                "(p.base_name LIKE ? ESCAPE '\\' OR p.id IN (SELECT rowid FROM ocr_text WHERE text LIKE ? ESCAPE '\\'))",
                [pattern, pattern]
            )
        }
    }

    static func condition(for query: SearchQuery) -> (String, [any SQLBindable]) {
        guard !query.terms.isEmpty else { return ("0", []) }
        var parts: [String] = []
        var arguments: [any SQLBindable] = []
        for term in query.terms {
            let (sql, values) = condition(for: term)
            parts.append("(\(sql))")
            arguments += values
        }
        return (parts.joined(separator: " AND "), arguments)
    }

    private static func placeholders(_ count: Int) -> String {
        count == 0 ? "NULL" : Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private static func likePattern(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }
}
