import CoreGraphics
import Foundation
import ImageIO
import Vision

public typealias PersonID = Int64

/// 两种后台分析（设计稿 §10）。都用本机的 1600 预览，卷离线也能做；只分析可见照片。
public enum AnalysisKind: String, Sendable, CaseIterable, Hashable {
    case ocr
    case faces

    var stateColumn: String {
        switch self {
        case .ocr: "ocr_state"
        case .faces: "face_state"
        }
    }

    public var displayName: String {
        switch self {
        case .ocr: "OCR"
        case .faces: "人物"
        }
    }
}

/// 某种分析在可见照片上的进度。预览还没好的照片算在“等预览”里，不算待分析。
public struct AnalysisCounts: Sendable, Equatable {
    public var done = 0
    public var failed = 0
    public var pending = 0
    public var waitingForPreview = 0

    public init(done: Int = 0, failed: Int = 0, pending: Int = 0, waitingForPreview: Int = 0) {
        self.done = done
        self.failed = failed
        self.pending = pending
        self.waitingForPreview = waitingForPreview
    }

    public var total: Int { done + failed + pending + waitingForPreview }
}

/// 照片里的一张脸（检查器、人物封面用）。
public struct FaceRecord: Sendable, Equatable {
    public var id: Int64
    public var photoID: PhotoID
    public var box: CGRect
    public var personID: PersonID?
    public var personName: String?
}

// MARK: - 读

extension LibraryReader {
    public func analysisCounts(_ kind: AnalysisKind) throws -> AnalysisCounts {
        var counts = AnalysisCounts()
        try db.query(
            """
            SELECT \(kind.stateColumn), preview_state = 'ready', COUNT(*) FROM photos
            WHERE present_location_count > 0 GROUP BY 1, 2;
            """
        ) { row in
            let count = row.int(2)
            switch row.text(0) {
            case "done": counts.done += count
            case "failed": counts.failed += count
            default:
                if row.int(1) != 0 { counts.pending += count } else { counts.waitingForPreview += count }
            }
        }
        return counts
    }

    /// 下一批要分析的照片：新导入的在前。
    public func photosNeedingAnalysis(_ kind: AnalysisKind, limit: Int, excluding: Set<PhotoID> = []) throws -> [PhotoID] {
        let skip = excluding.isEmpty ? "" : "AND id NOT IN (\(excluding.map(String.init).joined(separator: ",")))"
        return try db.all(
            """
            SELECT id FROM photos
            WHERE \(kind.stateColumn) = 'pending' AND preview_state = 'ready' AND present_location_count > 0 \(skip)
            ORDER BY id DESC LIMIT ?;
            """,
            [limit]
        ) { $0.int(0) }
    }

    public func ocrText(of photo: PhotoID) throws -> String? {
        try db.first("SELECT text FROM ocr_text WHERE rowid = ?;", [photo]) { $0.text(0) ?? "" }
    }

    public func faces(in photo: PhotoID) throws -> [FaceRecord] {
        try db.all(
            """
            SELECT f.id, f.photo_id, f.x, f.y, f.w, f.h, f.person_id, pe.name
            FROM faces f LEFT JOIN people pe ON pe.id = f.person_id
            WHERE f.photo_id = ? ORDER BY f.x;
            """,
            [photo],
            Self.face
        )
    }

    static func face(_ row: Row) -> FaceRecord {
        FaceRecord(
            id: row.int64(0),
            photoID: row.int(1),
            box: CGRect(x: row.double(2), y: row.double(3), width: row.double(4), height: row.double(5)),
            personID: row.isNull(6) ? nil : row.int64(6),
            personName: row.text(7)
        )
    }
}

// MARK: - 写

extension Library {
    /// 记下一张照片的 OCR 结果（没有文字也算做完）。
    public func saveOCR(_ photo: PhotoID, text: String) throws {
        try db.transaction {
            try db.run("DELETE FROM ocr_text WHERE rowid = ?;", [photo])
            if !text.isEmpty {
                try db.run("INSERT INTO ocr_text (rowid, text) VALUES (?, ?);", [photo, text])
            }
            try db.run("UPDATE photos SET ocr_state = 'done' WHERE id = ?;", [photo])
        }
    }

    /// 记下一张照片的脸。脸先不归人物，`assignPendingFaces` 再统一归。
    public func saveFaces(_ photo: PhotoID, faces: [DetectedFace]) throws {
        try db.transaction {
            // 重新分析时先去掉旧的脸，人物的特征和跟着改。
            let previous = Set(try db.all(
                "SELECT DISTINCT person_id FROM faces WHERE photo_id = ? AND person_id IS NOT NULL;", [photo]
            ) { $0.int64(0) })
            try db.run("DELETE FROM faces WHERE photo_id = ?;", [photo])
            for face in faces {
                try db.run(
                    "INSERT INTO faces (photo_id, x, y, w, h, quality, feature) VALUES (?, ?, ?, ?, ?, ?, ?);",
                    [photo, Double(face.box.minX), Double(face.box.minY), Double(face.box.width), Double(face.box.height),
                     Double(face.quality), face.feature.isEmpty ? nil : FaceMath.data(face.feature)]
                )
            }
            try db.run("UPDATE photos SET face_state = 'done' WHERE id = ?;", [photo])
            try refreshPersonSums(previous)
        }
    }

    /// 读不了预览、Vision 出错：记失败，不再重试（重新分析时清掉）。
    public func markAnalysisFailed(_ kind: AnalysisKind, photo: PhotoID) throws {
        try db.run("UPDATE photos SET \(kind.stateColumn) = 'failed' WHERE id = ?;", [photo])
    }

    /// 等待归属的脸数（有特征、还没归人物）。
    public func pendingFaceCount() throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM faces WHERE person_id IS NULL AND feature IS NOT NULL;")
    }

    /// 把还没归属的脸归到人物里（`FaceClusterer`）。已经归好的脸、用户的决定都不动；
    /// 未命名的人物可能被并进别的人物。返回这次归了几张脸。
    ///
    /// 分组在事务外算（人物多时要几百毫秒，不能占着写锁让打星等着），事务里只写结果，
    /// 写之前再核对一次：期间被用户改过的脸、起了名字的人物不动。
    @discardableResult
    public func assignPendingFaces(_ clusterer: FaceClusterer = FaceClusterer()) throws -> Int {
        let faces = try db.all(
            "SELECT id, feature, rejected_person_id FROM faces WHERE person_id IS NULL AND feature IS NOT NULL ORDER BY id;"
        ) { row in
            FaceClusterer.NewFace(
                id: row.int64(0),
                feature: FaceMath.vector(row.blob(1) ?? Data()),
                rejectedPerson: row.isNull(2) ? nil : row.int64(2)
            )
        }.filter { $0.feature.count == FaceEmbedder.featureLength }
        guard !faces.isEmpty else { return 0 }
        let people = try db.all(
            "SELECT id, name IS NOT NULL, feature_sum, face_count FROM people WHERE face_count > 0;"
        ) { row in
            FaceClusterer.Person(
                id: row.int64(0), isNamed: row.int(1) != 0,
                sum: FaceMath.vector(row.blob(2) ?? Data()), count: row.int(3)
            )
        }.filter { $0.sum.count == FaceEmbedder.featureLength }
        let result = clusterer.cluster(faces, into: people)

        return try db.transaction {
            var touched = Set<PersonID>()
            var assigned = 0
            for (from, to) in result.merged {
                // 期间被起了名字的人物不并。
                guard try db.scalarInt("SELECT COUNT(*) FROM people WHERE id = ? AND name IS NULL;", [from]) == 1,
                      try db.scalarInt("SELECT COUNT(*) FROM people WHERE id = ?;", [to]) == 1 else { continue }
                try db.run("UPDATE faces SET person_id = ? WHERE person_id = ?;", [to, from])
                try db.run("UPDATE faces SET rejected_person_id = ? WHERE rejected_person_id = ?;", [to, from])
                try db.run("DELETE FROM people WHERE id = ?;", [from])
                touched.insert(to)
            }
            for (face, person) in result.assigned {
                let target = result.merged[person] ?? person
                assigned += try db.run(
                    "UPDATE faces SET person_id = ? WHERE id = ? AND person_id IS NULL AND EXISTS (SELECT 1 FROM people WHERE id = ?);",
                    [target, face, target]
                )
                touched.insert(target)
            }
            for group in result.newPeople {
                let person = try db.insert("INSERT INTO people (created_at) VALUES (?);", [now()])
                for face in group {
                    assigned += try db.run("UPDATE faces SET person_id = ? WHERE id = ? AND person_id IS NULL;", [person, face])
                }
                touched.insert(person)
            }
            try refreshPersonSums(touched)
            return assigned
        }
    }

    /// 按人物现在的脸重算特征之和；没有脸的未命名人物删掉。
    func refreshPersonSums(_ people: Set<PersonID>) throws {
        for person in people {
            var sum = [Float](repeating: 0, count: FaceEmbedder.featureLength)
            var count = 0
            try db.query("SELECT feature FROM faces WHERE person_id = ? AND feature IS NOT NULL;", [person]) { row in
                let feature = FaceMath.vector(row.blob(0) ?? Data())
                guard feature.count == sum.count else { return }
                for index in sum.indices { sum[index] += feature[index] }
                count += 1
            }
            try db.run(
                "UPDATE people SET feature_sum = ?, face_count = ? WHERE id = ?;",
                [count > 0 ? FaceMath.data(sum) : nil, count, person]
            )
            try db.run(
                "DELETE FROM people WHERE id = ? AND name IS NULL AND NOT EXISTS (SELECT 1 FROM faces WHERE person_id = ?);",
                [person, person]
            )
        }
    }

    /// 让某种分析对所有照片重做（换了模型、调了阈值以后）。人物的名字留着，脸重新归。
    public func resetAnalysis(_ kind: AnalysisKind) throws {
        try db.transaction {
            try db.run("UPDATE photos SET \(kind.stateColumn) = 'pending';")
            switch kind {
            case .ocr:
                try db.run("DELETE FROM ocr_text;")
            case .faces:
                try db.run("DELETE FROM faces;")
                try db.run("UPDATE people SET feature_sum = NULL, face_count = 0;")
                try db.run("DELETE FROM people WHERE name IS NULL;")
            }
        }
    }
}

// MARK: - 识别

/// OCR：Vision 文字识别，中文简繁、英文。
public struct TextRecognizer: Sendable {
    /// 置信度低于这个值的行不要：多是纹理、树枝被认成字。
    public var minimumConfidence: Float = 0.3

    public init() {}

    public func text(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= minimumConfidence }
            .map(\.string)
            .joined(separator: "\n")
    }
}

// MARK: - 后台队列

/// 一种分析的后台队列：一张一张做，随时可以停（暂停），下次从数据库里的状态接着做（续跑）。
/// 用户在操作时（`shouldYield`）先让一让，交互优先（设计稿 §6）。
public struct AnalysisRunner: Sendable {
    public struct Progress: Sendable, Equatable {
        public var done = 0
        public var failed = 0
        /// 预览文件读不了，这一轮跳过。
        public var skipped = 0
    }

    public enum Work: Sendable {
        case ocr(TextRecognizer)
        case faces(FaceAnalyzer, FaceClusterer)

        var kind: AnalysisKind {
            switch self {
            case .ocr: .ocr
            case .faces: .faces
            }
        }
    }

    public var library: Library
    public var store: PreviewStore
    public var work: Work
    public var batchSize = 16
    /// 攒够这么多张没归属的脸就归一次；队列做完时也归一次。
    public var assignEvery = 200

    public init(library: Library, work: Work) {
        self.library = library
        self.store = PreviewStore(root: library.paths.previews)
        self.work = work
    }

    public func run(
        shouldStop: @escaping @Sendable () -> Bool = { Task.isCancelled },
        shouldYield: @escaping @Sendable () -> Bool = { false },
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Progress {
        var total = Progress()
        var skipped: Set<PhotoID> = []
        let kind = work.kind
        var unassigned = 0
        defer {
            if case .faces(_, let clusterer) = work, unassigned > 0 { _ = try? library.assignPendingFaces(clusterer) }
        }
        while !shouldStop() {
            let batch = try library.reader.photosNeedingAnalysis(kind, limit: batchSize, excluding: skipped)
            if batch.isEmpty { break }
            for photo in batch {
                while shouldYield(), !shouldStop() { try? await Task.sleep(for: .milliseconds(100)) }
                if shouldStop() { break }
                guard let image = Self.loadImage(store.url(for: photo, size: .preview)) else {
                    skipped.insert(photo)
                    total.skipped += 1
                    continue
                }
                do {
                    switch work {
                    case .ocr(let recognizer):
                        try library.saveOCR(photo, text: try recognizer.text(in: image))
                    case .faces(let analyzer, _):
                        let faces = try analyzer.faces(in: image)
                        try library.saveFaces(photo, faces: faces)
                        unassigned += faces.filter { !$0.feature.isEmpty }.count
                    }
                    total.done += 1
                } catch let error as DatabaseError {
                    throw error
                } catch {
                    try library.markAnalysisFailed(kind, photo: photo)
                    total.failed += 1
                }
                await Task.yield()
            }
            if case .faces(_, let clusterer) = work, unassigned >= assignEvery {
                try library.assignPendingFaces(clusterer)
                unassigned = 0
            }
            progress?(total)
        }
        if case .faces(_, let clusterer) = work, unassigned > 0 {
            try library.assignPendingFaces(clusterer)
            unassigned = 0
        }
        return total
    }

    static func loadImage(_ url: URL) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}
