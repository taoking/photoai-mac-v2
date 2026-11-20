import Foundation
import Testing
@testable import PhotoAICore

/// 相机记录的对焦框：索尼 MakerNote 的解析、方向换算、后台读进库。
@Suite struct FocusPointTests {
    /// 一个最小的索尼 TIFF：IFD0（厂商、方向、Exif 指针）→ Exif IFD（MakerNote）→ 索尼 IFD（0x2027、0x2037）。
    /// `withHeader` 为 true 时 MakerNote 前面有 “SONY DSC ” 头（JPEG 里那样），否则没有（ARW 里那样）。
    static func sonyTIFF(
        make: String = "SONY", orientation: UInt16 = 1, withHeader: Bool,
        location: [UInt16] = [6000, 4000, 3000, 1000], frame: [UInt16] = [300, 200, 1]
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        func u16(_ value: UInt16) { bytes += [UInt8(value & 0xFF), UInt8(value >> 8)] }
        func u32(_ value: Int) { bytes += (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) } }
        func entry(_ tag: UInt16, _ type: UInt16, _ count: Int, _ value: Int) { u16(tag); u16(type); u32(count); u32(value) }

        let makeOffset = 50, exifOffset = 56, makerOffset = 74
        let headerLength = withHeader ? 12 : 0
        let sonyIFD = makerOffset + headerLength
        let locationOffset = sonyIFD + 30, frameOffset = locationOffset + 8
        bytes += Array("II".utf8); u16(42); u32(8)
        u16(3)
        entry(0x010F, 2, 5, makeOffset)
        entry(0x0112, 3, 1, Int(orientation))
        entry(0x8769, 4, 1, exifOffset)
        u32(0)
        bytes += Array(make.prefix(4).utf8) + [0]
        while bytes.count < exifOffset { bytes.append(0) }
        u16(1)
        entry(0x927C, 7, headerLength + 30 + 14, makerOffset)
        u32(0)
        if withHeader { bytes += Array("SONY DSC ".utf8) + [0, 0, 0] }
        u16(2)
        entry(0x2027, 3, 4, locationOffset)
        entry(0x2037, 7, 6, frameOffset)
        u32(0)
        location.forEach(u16)
        frame.forEach(u16)
        return bytes
    }

    static func jpeg(wrapping tiff: [UInt8]) -> [UInt8] {
        let length = 2 + 6 + tiff.count
        return [0xFF, 0xD8, 0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + Array("Exif".utf8) + [0, 0] + tiff + [0xFF, 0xD9]
    }

    func write(_ bytes: [UInt8], name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("focus-\(UUID().uuidString)-\(name)")
        try Data(bytes).write(to: url)
        return url
    }

    func expectArea(_ result: FocusPointReader.Result?, _ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        guard case .found(let area) = result else {
            Issue.record("没读到对焦框：\(String(describing: result))")
            return
        }
        #expect(abs(area.x - x) < 1e-9 && abs(area.y - y) < 1e-9 && abs(area.width - w) < 1e-9 && abs(area.height - h) < 1e-9, "\(area)")
    }

    @Test func readsSonyJPEG() throws {
        let url = try write(Self.jpeg(wrapping: Self.sonyTIFF(withHeader: true)), name: "a.JPG")
        defer { try? FileManager.default.removeItem(at: url) }
        // 中心 (3000, 1000)，框 300×200：左上 (2850, 900)。
        expectArea(FocusPointReader.read(at: url), 0.475, 0.225, 0.05, 0.05)
    }

    @Test func readsSonyARWWithoutHeaderAndTurnsUpright() throws {
        let url = try write(Self.sonyTIFF(orientation: 8, withHeader: false), name: "a.ARW")
        defer { try? FileManager.default.removeItem(at: url) }
        // 方向 8（顺时针转 270° 才正）：(x, y) → (y, 1 − x − w)。
        expectArea(FocusPointReader.read(at: url), 0.225, 0.475, 0.05, 0.05)
    }

    @Test func orientations() {
        let sensor = FocusArea(x: 0.1, y: 0.2, width: 0.3, height: 0.1)
        let same = FocusPointReader.upright(sensor, orientation: 1)
        #expect(abs(same.x - 0.1) < 1e-9 && abs(same.y - 0.2) < 1e-9 && abs(same.width - 0.3) < 1e-9 && abs(same.height - 0.1) < 1e-9)
        let turned180 = FocusPointReader.upright(sensor, orientation: 3)
        #expect(abs(turned180.x - 0.6) < 1e-9 && abs(turned180.y - 0.7) < 1e-9)
        let turned90 = FocusPointReader.upright(sensor, orientation: 6)
        #expect(abs(turned90.x - 0.7) < 1e-9 && abs(turned90.y - 0.1) < 1e-9 && abs(turned90.width - 0.1) < 1e-9 && abs(turned90.height - 0.3) < 1e-9)
        // 伸出画面的框截掉伸出去的部分。
        let clipped = FocusPointReader.upright(FocusArea(x: -0.05, y: 0.5, width: 0.2, height: 0.2), orientation: 1)
        #expect(abs(clipped.x) < 1e-9 && abs(clipped.width - 0.15) < 1e-9)
    }

    @Test func notRecordedCases() throws {
        let invalid = try write(Self.jpeg(wrapping: Self.sonyTIFF(withHeader: true, frame: [300, 200, 0])), name: "invalid.JPG")
        let otherMake = try write(Self.sonyTIFF(make: "NIKO", withHeader: false), name: "nikon.NEF")
        let zeroPoint = try write(Self.jpeg(wrapping: Self.sonyTIFF(withHeader: true, location: [6000, 4000, 0, 0])), name: "zero.JPG")
        let text = try write(Array("not an image".utf8), name: "a.txt")
        defer { for url in [invalid, otherMake, zeroPoint, text] { try? FileManager.default.removeItem(at: url) } }
        #expect(FocusPointReader.read(at: invalid) == .notRecorded, "框标为无效")
        #expect(FocusPointReader.read(at: otherMake) == .notRecorded, "不是索尼")
        #expect(FocusPointReader.read(at: zeroPoint) == .notRecorded, "对焦点 (0, 0)")
        #expect(FocusPointReader.read(at: text) == .notRecorded, "不是图片")
        #expect(FocusPointReader.read(at: URL(fileURLWithPath: "/nonexistent/DSC00001.JPG")) == nil, "读不了的文件下次再试")
    }

    @Test func runnerStoresFocusForOnlinePhotos() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        for index in 1...2 {
            try SampleImages.writeJPEG(
                to: card.url(String(format: "DCIM/100MSDCF/DSC%05d.JPG", index)), width: 600, height: 400,
                captureDate: String(format: "2026:08:12 10:00:%02d", index)
            )
        }
        let volume = try temp.library.addVolume(uuid: "CARD-A", name: "卡 A", scanRoot: "DCIM")
        try await VolumeScanner(library: temp.library).scan(volumeID: volume.id, mountURL: card.root)
        let photos = try temp.reader.photos(in: .all).sorted { $0.baseName < $1.baseName }
        #expect(photos.count == 2)
        // 第一张换成带索尼对焦框的文件（只换内容，库里的记录不变）；第二张是没有 MakerNote 的普通 JPEG。
        try Data(Self.jpeg(wrapping: Self.sonyTIFF(withHeader: true))).write(to: card.url("DCIM/100MSDCF/DSC00001.JPG"))

        #expect(try FocusRunner(library: temp.library).run(mountURLs: [:]) == 0, "没有在线的卷就不读")
        #expect(try FocusRunner(library: temp.library).run(mountURLs: [volume.id: card.root]) == 2)
        let area = try #require(try temp.reader.focusArea(of: photos[0].id))
        #expect(abs(area.x - 0.475) < 1e-9 && abs(area.y - 0.225) < 1e-9)
        #expect(try temp.reader.focusArea(of: photos[1].id) == nil, "相机没记就没有框")
        #expect(try FocusRunner(library: temp.library).run(mountURLs: [volume.id: card.root]) == 0, "读过的不再读")
    }
}
