import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotoAICore

/// M6 后台分析与搜索（计划 · M6 验收）。
struct AnalysisTests {
    // MARK: - 搜索的解析

    @Test func parsesDatesBeforeNumbers() {
        let vocabulary = SearchVocabulary()
        func terms(_ text: String) -> [SearchTerm] { SearchParser.parse(text, vocabulary: vocabulary).terms }
        // `2026-08` 必须按日期而不是编号范围解析（计划 · M6 验收）。
        #expect(terms("2026-08") == [.datePrefix("2026-08")])
        #expect(terms("2026-8-5") == [.datePrefix("2026-08-05")])
        #expect(terms("2026年8月") == [.datePrefix("2026-08")])
        #expect(terms("2026年8月12日") == [.datePrefix("2026-08-12")])
        #expect(terms("2026年") == [.datePrefix("2026")])
        #expect(terms("8月12日 8月") == [.monthDay(month: 8, day: 12), .monthDay(month: 8, day: nil)])
        // 四位数字是编号，不是年份；真正的编号范围照旧。
        #expect(terms("2026") == [.number(2026)])
        #expect(terms("1926-1950") == [.range(1926, 1950)])
        // 不存在的月份不是日期；起点比终点大也不是编号范围，当文字搜。
        #expect(terms("2026-13") == [.text("2026-13")])
        #expect(terms("DSC01926.ARW DSC01926") == [.fileName(baseName: "DSC01926", extension: "ARW"), .text("DSC01926")])
        #expect(terms("“出口 B” 门票") == [.text("出口 B"), .text("门票")])
    }

    @Test func parsesVocabularyWords() {
        let vocabulary = SearchVocabulary(
            labels: ["经典": 1], people: ["妈妈": 7],
            cameras: [(make: "SONY", model: "ILCE-7CM2"), (make: "SONY", model: "ILCE-7M4")],
            lenses: ["FE 70-200mm F2.8 GM OSS II", "E 28-200mm F2.8-5.6 A071"],
            placeTexts: ["杭州市", "中国浙江省杭州市西湖区 西湖街道"]
        )
        func terms(_ text: String) -> [SearchTerm] { SearchParser.parse(text, vocabulary: vocabulary).terms }
        #expect(terms("经典 妈妈") == [.label(1, name: "经典"), .person(7, name: "妈妈")])
        #expect(terms("A7C2") == [.camera(query: "A7C2", models: ["ILCE-7CM2"])])
        #expect(terms("a7cii") == [.camera(query: "a7cii", models: ["ILCE-7CM2"])])
        #expect(terms("A7M4") == [.camera(query: "A7M4", models: ["ILCE-7M4"])])
        #expect(terms("sony") == [.camera(query: "sony", models: ["ILCE-7CM2", "ILCE-7M4"])])
        // 镜头在编号之前：70-200 是镜头；200 只是数字，算编号。
        #expect(terms("70-200") == [.lens(query: "70-200", lenses: ["FE 70-200mm F2.8 GM OSS II"])])
        #expect(terms("200") == [.number(200)])
        #expect(terms("西湖") == [.place("西湖")])
        #expect(terms("门票") == [.text("门票")])
    }

    // MARK: - 搜索的结果

    @Test func searchFindsTextDatesAndSkipsHiddenPhotos() throws {
        let temp = try TemporaryLibrary()
        let a = try temp.insertPhoto("DSC01001", "2026-08-12 10:00:00", lens: "FE 70-200mm F2.8 GM OSS II")
        let b = try temp.insertPhoto("DSC01002", "2026-08-20 10:00:00")
        let c = try temp.insertPhoto("DSC02026", "2025-08-12 10:00:00")
        let hidden = try temp.insertPhoto("DSC01003", "2026-08-12 11:00:00", visible: false)
        try temp.library.saveOCR(a, text: "西湖景区\n出口 B 往断桥")
        try temp.library.saveOCR(b, text: "")
        try temp.library.saveOCR(hidden, text: "西湖景区")

        func search(_ text: String) throws -> [PhotoID] {
            let query = SearchParser.parse(text, vocabulary: try temp.reader.searchVocabulary())
            return try temp.reader.photos(in: .search(query), sort: .fileName).map(\.id)
        }
        // OCR 的一行、其中两个字、文件名的一段都能搜到；隐藏照片不命中。
        #expect(try search("西湖景区") == [a])
        #expect(try search("断桥") == [a])
        #expect(try search("\"出口 B\"") == [a])
        #expect(try search("DSC0100") == [a, b])
        // 日期：2026-08 是月份（不是编号范围 2026–8），8月12日 是每年的这一天，2026 是编号。
        #expect(try search("2026-08") == [a, b])
        #expect(try search("8月12日") == [a, c])
        #expect(try search("2026") == [c])
        // 条件之间取“并且”。
        #expect(try search("2026-08 70-200") == [a])
        #expect(try search("西湖景区 2025-08") == [])
        #expect(try search("没有这段字") == [])
    }

    // MARK: - OCR 队列

    @Test func ocrRunnerFindsRenderedTextAndResumesAfterPause() async throws {
        let temp = try TemporaryLibrary()
        let store = PreviewStore(root: temp.library.paths.previews)
        var ids: [PhotoID] = []
        for index in 0..<4 {
            let id = try temp.insertPhoto(String(format: "DSC%05d", index), "2026-08-12 10:00:0\(index)")
            try Self.writeTextImage(index == 2 ? "PHOTOAI 西湖断桥" : "", to: store.url(for: id, size: .preview))
            ids.append(id)
        }
        // 预览还没好的照片不分析，算“等预览”。
        let waiting = try temp.insertPhoto("DSC09999", "2026-08-13 10:00:00", previewReady: false)

        let runner = AnalysisRunner(library: temp.library, work: .ocr(TextRecognizer()))
        // 做一张就停（暂停），状态留在数据库里。
        let stopAfterOne = StopAfter(1)
        let first = try await runner.run(shouldStop: { stopAfterOne.check() })
        #expect(first.done == 1)
        #expect(try temp.reader.analysisCounts(.ocr) == AnalysisCounts(done: 1, pending: 3, waitingForPreview: 1))
        // 续跑：从没做的接着做，做过的不重做。
        let second = try await runner.run()
        #expect(second.done == 3)
        #expect(try temp.reader.analysisCounts(.ocr) == AnalysisCounts(done: 4, waitingForPreview: 1))
        #expect(try temp.reader.ocrText(of: ids[2])?.contains("西湖断桥") == true)
        let query = SearchParser.parse("西湖断桥", vocabulary: SearchVocabulary())
        #expect(try temp.reader.photos(in: .search(query)).map(\.id) == [ids[2]])
        #expect(try temp.reader.photosNeedingAnalysis(.ocr, limit: 10).isEmpty)
        _ = waiting
    }

    // MARK: - 人物

    @Test func clustererGroupsPeopleAndRespectsNames() {
        var generator = SystemRandomNumberGenerator()
        let people = (0..<3).map { _ in Self.randomUnitVector(&generator) }
        var faces: [FaceClusterer.NewFace] = []
        for index in 0..<30 {
            faces.append(.init(id: Int64(index), feature: Self.jitter(people[index % 3], &generator)))
        }
        let result = FaceClusterer().cluster(faces, into: [])
        #expect(result.newPeople.count == 3)
        #expect(Set(result.newPeople.map { Set($0.map { Int($0) % 3 }) }) == [[0], [1], [2]])

        // 已有两个有名字的人物、长得一样：新脸归进其中一个，两个人物不自动合并。
        let sum = people[0].map { $0 * 5 }
        let named = [
            FaceClusterer.Person(id: 10, isNamed: true, sum: sum, count: 5),
            FaceClusterer.Person(id: 11, isNamed: true, sum: sum, count: 5)
        ]
        let second = FaceClusterer().cluster([.init(id: 100, feature: Self.jitter(people[0], &generator))], into: named)
        #expect(second.merged.isEmpty)
        #expect(second.assigned[100] != nil)
        // 用户说过“不是 TA”的人物，不再归进去。
        let rejected = FaceClusterer().cluster(
            [.init(id: 101, feature: Self.jitter(people[0], &generator), rejectedPerson: 10)], into: [named[0]]
        )
        #expect(rejected.assigned.isEmpty)
        #expect(rejected.newPeople == [[101]])
    }

    @Test func peopleNamingMergingAndRemoval() throws {
        let temp = try TemporaryLibrary()
        var generator = SystemRandomNumberGenerator()
        let mother = Self.randomUnitVector(&generator), father = Self.randomUnitVector(&generator)
        var photos: [PhotoID] = []
        for index in 0..<6 {
            let id = try temp.insertPhoto(String(format: "DSC%05d", index), "2026-08-12 10:00:0\(index)")
            let feature = Self.jitter(index < 4 ? mother : father, &generator)
            try temp.library.saveFaces(id, faces: [
                DetectedFace(box: CGRect(x: 0.4, y: 0.3, width: 0.1, height: 0.15), feature: feature, quality: 0.5),
                // 背景里的小脸：只记位置。
                DetectedFace(box: CGRect(x: 0.9, y: 0.1, width: 0.02, height: 0.03), feature: [], quality: 0.1)
            ])
            photos.append(id)
        }
        #expect(try temp.library.assignPendingFaces() == 6)
        var people = try temp.reader.people()
        #expect(people.map(\.photoCount) == [4, 2])
        #expect(people.allSatisfy { $0.name == nil && $0.coverPhotoID != nil })
        let motherID = people[0].id, fatherID = people[1].id

        // 命名后能按人名搜到。
        try temp.library.renamePerson(motherID, to: "妈妈")
        let query = SearchParser.parse("妈妈", vocabulary: try temp.reader.searchVocabulary())
        #expect(query.terms == [.person(motherID, name: "妈妈")])
        #expect(Set(try temp.reader.photos(in: .search(query)).map(\.id)) == Set(photos[0..<4]))

        // “不是 TA”：拿出来的脸不再归回妈妈。
        #expect(try temp.library.removeFromPerson([photos[3]], person: motherID) == 1)
        try temp.library.assignPendingFaces()
        #expect(try temp.reader.faces(in: photos[3]).first { $0.box.width > 0.05 }?.personID != motherID)
        #expect(try temp.reader.person(motherID)?.photoCount == 3)

        // 起一样的名字就是合并。拿出来的那张自成一个未命名的人物，不跟着并。
        #expect(try temp.library.renamePerson(fatherID, to: "妈妈") == motherID)
        people = try temp.reader.people()
        #expect(people.map(\.photoCount) == [5, 1])
        #expect(people.first?.id == motherID && people.last?.name == nil)

        // 隐藏的人物不出现在人物网格，也不能按名字搜。
        try temp.library.setPersonHidden(motherID, true)
        #expect(try temp.reader.people().contains { $0.id == motherID } == false)
        #expect(try temp.reader.searchVocabulary().people["妈妈"] == nil)
    }

    @Test func deletingOrphansCleansFacesAndText() throws {
        let temp = try TemporaryLibrary()
        var generator = SystemRandomNumberGenerator()
        let person = Self.randomUnitVector(&generator)
        let kept = try temp.insertPhoto("DSC00001", "2026-08-12 10:00:00")
        let orphan = try temp.insertPhoto("DSC00002", "2026-08-12 10:00:01", visible: false)
        for id in [kept, orphan] {
            try temp.library.saveFaces(id, faces: [DetectedFace(box: CGRect(x: 0.4, y: 0.3, width: 0.1, height: 0.1),
                                                                feature: Self.jitter(person, &generator), quality: 0.6)])
            try temp.library.saveOCR(id, text: "门票 \(id)")
        }
        try temp.library.assignPendingFaces()
        let personID = try #require(try temp.reader.people().first?.id)
        _ = try temp.library.deleteOrphans([orphan])
        #expect(try temp.library.db.scalarInt("SELECT face_count FROM people WHERE id = ?;", [personID]) == 1)
        #expect(try temp.reader.ocrText(of: orphan) == nil)
        #expect(try temp.reader.ocrText(of: kept) != nil)
    }

    // MARK: - 地点

    @Test func placesAreLookedUpOncePerCell() async throws {
        let temp = try TemporaryLibrary()
        let a = try temp.insertPhoto("DSC00001", "2026-08-12 10:00:00", latitude: 30.2512, longitude: 120.1501)
        let b = try temp.insertPhoto("DSC00002", "2026-08-12 10:01:00", latitude: 30.2534, longitude: 120.1488)
        let c = try temp.insertPhoto("DSC00003", "2026-08-13 10:00:00", latitude: 39.9100, longitude: 116.3900)
        _ = try temp.insertPhoto("DSC00004", "2026-08-13 11:00:00")
        let geocoder = FakeGeocoder(["30.25,120.15": PlaceInfo(name: "杭州市", detail: "中国浙江省杭州市西湖区")])
        let result = try await PlaceRunner(library: temp.library, geocoder: geocoder, interval: .zero).run()
        // 同一个约 1 公里的网格只查一次；查不到地名的也记下，不再查。
        #expect(geocoder.calls == 2)
        #expect(result == PlaceRunner.Progress(found: 1, none: 1, failed: 0))
        #expect(try temp.reader.places() == [PlaceSummary(name: "杭州市", photoCount: 2)])
        #expect(Set(try temp.reader.photos(in: .place("杭州市")).map(\.id)) == [a, b])
        let query = SearchParser.parse("西湖区", vocabulary: try temp.reader.searchVocabulary())
        #expect(query.terms == [.place("西湖区")])
        #expect(Set(try temp.reader.photos(in: .search(query)).map(\.id)) == [a, b])
        _ = try await PlaceRunner(library: temp.library, geocoder: geocoder, interval: .zero).run()
        #expect(geocoder.calls == 2)
        _ = c
    }

    // MARK: - 辅助

    static func randomUnitVector(_ generator: inout SystemRandomNumberGenerator) -> [Float] {
        FaceMath.normalized((0..<FaceEmbedder.featureLength).map { _ in Float.random(in: -1...1, using: &generator) })
    }

    /// 同一个人的另一张脸：加一点噪声（和原向量的相似度约 0.7）。
    static func jitter(_ vector: [Float], _ generator: inout SystemRandomNumberGenerator) -> [Float] {
        let noise = randomUnitVector(&generator)
        return FaceMath.normalized(zip(vector, noise).map { $0 + 0.9 * $1 })
    }

    static func writeTextImage(_ text: String, to url: URL) throws {
        let width = 1600, height = 1067
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if !text.isEmpty {
            let font = CTFontCreateWithName("PingFang SC" as CFString, 96, nil)
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ])
            context.textPosition = CGPoint(x: 120, y: 480)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// 做完 n 张以后让队列停下（模拟暂停）。
final class StopAfter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    init(_ count: Int) { remaining = count + 1 }
    func check() -> Bool { lock.withLock { remaining -= 1; return remaining < 0 } }
}

final class FakeGeocoder: ReverseGeocoder, @unchecked Sendable {
    private let lock = NSLock()
    private let places: [String: PlaceInfo]
    private var count = 0
    init(_ places: [String: PlaceInfo]) { self.places = places }
    var calls: Int { lock.withLock { count } }
    func place(latitude: Double, longitude: Double) async throws -> PlaceInfo? {
        lock.withLock { count += 1 }
        return places[String(format: "%.2f,%.2f", latitude, longitude)]
    }
}

extension TemporaryLibrary {
    /// 直接往库里写一张照片（不经过扫描）。`visible` 为 false 时没有现存位置（隐藏）。
    @discardableResult
    func insertPhoto(
        _ baseName: String, _ date: String, visible: Bool = true, previewReady: Bool = true,
        lens: String? = nil, latitude: Double? = nil, longitude: Double? = nil
    ) throws -> PhotoID {
        let number = Int(baseName.filter(\.isNumber)) ?? 0
        return Int(try library.db.insert(
            """
            INSERT INTO photos (identity_key, base_name, file_number, capture_date, camera_make, camera_model, lens,
                latitude, longitude, thumb_state, preview_state, present_location_count, imported_at)
            VALUES (?, ?, ?, ?, 'SONY', 'ILCE-7CM2', ?, ?, ?, ?, ?, ?, ?);
            """,
            [PhotoIdentity.key(baseName: baseName, captureDate: date, fileSize: 0), baseName, number, date, lens,
             latitude, longitude, previewReady ? "ready" : "pending", previewReady ? "ready" : "pending",
             visible ? 1 : 0, Date()]
        ))
    }
}
