import CoreGraphics
import Foundation

/// 人物网格里的一个人。
public struct PersonSummary: Sendable, Equatable, Identifiable, Hashable {
    public var id: PersonID
    /// nil 是未命名。
    public var name: String?
    public var isHidden: Bool
    /// 有这个人的可见照片数。
    public var photoCount: Int
    /// 封面：拍摄质量最好的那张脸。
    public var coverPhotoID: PhotoID?
    public var coverBox: CGRect?

    public var displayName: String { name ?? "未命名" }
}

extension LibraryReader {
    /// 有可见照片的人物：有名字的在前（按张数），然后是未命名的（按张数）。
    public func people(includeHidden: Bool = false) throws -> [PersonSummary] {
        var covers: [PersonID: (PhotoID, CGRect)] = [:]
        try db.query(
            """
            SELECT person_id, photo_id, x, y, w, h FROM (
                SELECT f.person_id, f.photo_id, f.x, f.y, f.w, f.h,
                       ROW_NUMBER() OVER (PARTITION BY f.person_id ORDER BY f.feature IS NULL, f.quality DESC, f.id) AS rank
                FROM faces f JOIN photos p ON p.id = f.photo_id
                WHERE f.person_id IS NOT NULL AND p.present_location_count > 0
            ) WHERE rank = 1;
            """
        ) { row in
            covers[row.int64(0)] = (row.int(1), CGRect(x: row.double(2), y: row.double(3), width: row.double(4), height: row.double(5)))
        }
        return try db.all(
            """
            SELECT pe.id, pe.name, pe.is_hidden, COUNT(DISTINCT f.photo_id) AS photo_count
            FROM people pe
            JOIN faces f ON f.person_id = pe.id
            JOIN photos p ON p.id = f.photo_id AND p.present_location_count > 0
            \(includeHidden ? "" : "WHERE pe.is_hidden = 0")
            GROUP BY pe.id
            ORDER BY pe.name IS NULL, photo_count DESC, pe.id;
            """
        ) { row in
            let id = row.int64(0)
            return PersonSummary(
                id: id, name: row.text(1), isHidden: row.int(2) != 0, photoCount: row.int(3),
                coverPhotoID: covers[id]?.0, coverBox: covers[id]?.1
            )
        }
    }

    public func person(_ id: PersonID) throws -> PersonSummary? {
        try people(includeHidden: true).first { $0.id == id }
    }

    /// 有名字、没隐藏的人物：名字 → id。搜索认人名用。
    public func namedPeople() throws -> [String: PersonID] {
        var result: [String: PersonID] = [:]
        try db.query("SELECT id, name FROM people WHERE name IS NOT NULL AND is_hidden = 0;") { row in
            if let name = row.text(1) { result[name] = row.int64(0) }
        }
        return result
    }
}

extension Library {
    /// 改名。名字和另一个人物一样就并进那个人物（用户就是这样合并的）；空名字变回未命名。
    /// 返回改完之后这些脸所在的人物。
    @discardableResult
    public func renamePerson(_ id: PersonID, to name: String) throws -> PersonID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try db.transaction {
            if !trimmed.isEmpty, let other = try db.first(
                "SELECT id FROM people WHERE name = ? AND id != ? ORDER BY id LIMIT 1;", [trimmed, id], { $0.int64(0) }
            ) {
                try mergePerson(id, into: other)
                return other
            }
            try db.run("UPDATE people SET name = ? WHERE id = ?;", [trimmed.isEmpty ? nil : trimmed, id])
            return id
        }
    }

    /// 把一个人物的脸全部并进另一个。
    public func mergePerson(_ source: PersonID, into target: PersonID) throws {
        guard source != target else { return }
        try db.transaction {
            try db.run("UPDATE faces SET person_id = ? WHERE person_id = ?;", [target, source])
            try db.run("UPDATE faces SET rejected_person_id = ? WHERE rejected_person_id = ?;", [target, source])
            try db.run("DELETE FROM people WHERE id = ?;", [source])
            try refreshPersonSums([target])
        }
    }

    public func setPersonHidden(_ id: PersonID, _ hidden: Bool) throws {
        try db.run("UPDATE people SET is_hidden = ? WHERE id = ?;", [hidden ? 1 : 0, id])
    }

    /// “不是 TA”：这些照片里归在这个人物下的脸拿出来，以后不再自动归给 TA（可能归给别人）。
    /// 返回拿出来的脸数。
    @discardableResult
    public func removeFromPerson(_ photos: [PhotoID], person: PersonID) throws -> Int {
        guard !photos.isEmpty else { return 0 }
        return try db.transaction {
            var changed = 0
            for chunk in photos.chunked(into: 4_000) {
                changed += try db.run(
                    """
                    UPDATE faces SET person_id = NULL, rejected_person_id = ?
                    WHERE person_id = ? AND photo_id IN (\(chunk.map(String.init).joined(separator: ",")));
                    """,
                    [person, person]
                )
            }
            try refreshPersonSums([person])
            return changed
        }
    }
}
