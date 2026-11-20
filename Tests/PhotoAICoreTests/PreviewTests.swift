import Foundation
import Testing
@testable import PhotoAICore

/// 预览生成与“离线预览就绪”。对应计划 · M1 验收的预览就绪用例。
@Suite struct PreviewTests {
    /// 一张真实 JPEG 卡：`count` 张横拍照片，可选每张配一个假的 ARW（内容不是图片）。
    func makeCard(count: Int, withRaw: Bool = false) throws -> FakeCard {
        let card = try FakeCard()
        for index in 1...count {
            let name = String(format: "DSC%05d", index)
            let date = String(format: "2026:08:12 10:00:%02d", index)
            try SampleImages.writeJPEG(to: card.url("DCIM/100MSDCF/\(name).JPG"), width: 2400, height: 1600, captureDate: date)
            if withRaw {
                // 用同一张 JPEG 冒充 RAW，让它有同样的拍摄时间、能合组。
                try FileManager.default.copyItem(at: card.url("DCIM/100MSDCF/\(name).JPG"), to: card.url("DCIM/100MSDCF/\(name).ARW"))
            }
        }
        return card
    }

    func importCard(_ card: FakeCard, into temp: TemporaryLibrary) async throws -> VolumeRecord {
        let volume = try temp.library.addVolume(uuid: "CARD-A", name: "卡 A", scanRoot: "DCIM")
        let scanner = VolumeScanner(library: temp.library)
        try await scanner.scan(volumeID: volume.id, mountURL: card.root)
        return volume
    }

    @Test func generatesBothSizesAndCountsReady() async throws {
        let temp = try TemporaryLibrary()
        let card = try makeCard(count: 3)
        let volume = try await importCard(card, into: temp)
        #expect(try temp.reader.volumeStats(volume.id) == VolumeStats(photoCount: 3, previewReadyCount: 0, incompleteDirectoryCount: 0, missingCopyCount: 3))

        let generator = PreviewGenerator(library: temp.library)
        let progress = try await PreviewRunner(generator: generator).run(mountURLs: [volume.id: card.root])
        #expect(progress.ready == 3)
        #expect(try temp.reader.pendingPreviewCount() == 0)

        let ids = try temp.reader.photos(in: .all).map(\.id)
        for id in ids {
            let thumb = try #require(ImageDownsampler.image(at: generator.store.url(for: id, size: .thumb), maximumPixelSize: 5000))
            let preview = try #require(ImageDownsampler.image(at: generator.store.url(for: id, size: .preview), maximumPixelSize: 5000))
            #expect(max(thumb.width, thumb.height) == 480)
            #expect(max(preview.width, preview.height) == 1600)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: generator.store.temporaryDirectory.path)) ?? []
        #expect(leftovers.isEmpty)

        // 断开源卷：用实际能解码的图片数核对“离线预览就绪”。
        try FileManager.default.removeItem(at: card.root)
        #expect(try generator.audit(photoIDs: ids) == 3)
        #expect(try temp.reader.volumeStats(volume.id).previewReadyCount == 3)
        #expect(try temp.reader.photos(in: .all).count == 3)
    }

    @Test func prefersJPEGOverRaw() async throws {
        let temp = try TemporaryLibrary()
        let card = try makeCard(count: 1, withRaw: true)
        let volume = try await importCard(card, into: temp)
        let photo = try #require(try temp.reader.photos(in: .all).first)
        #expect(photo.hasRaw && photo.hasJPEG)

        let job = try #require(try temp.reader.photosNeedingPreviews(limit: 10, onVolumes: [volume.id]).first)
        #expect(job.sources.map(\.kind) == [.jpeg, .raw])
        try await PreviewRunner(generator: PreviewGenerator(library: temp.library)).run(mountURLs: [volume.id: card.root])
        let jpegFile = try temp.library.db.scalarInt("SELECT id FROM files WHERE kind = 'jpeg';")
        #expect(try temp.library.db.scalarInt("SELECT preview_file_id FROM photos WHERE id = ?;", [photo.id]) == jpegFile)
    }

    /// 机内 16:9 裁切：RAW 是 3:2，JPEG 是 16:9。照片的尺寸以生成预览的 JPEG 为准（计划 V-4）。
    @Test func dimensionsFollowPreviewSource() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        let date = "2026:08:12 10:00:01"
        try SampleImages.writeJPEG(to: card.url("DCIM/100MSDCF/DSC00001.ARW"), width: 2400, height: 1600, captureDate: date)
        try SampleImages.writeJPEG(to: card.url("DCIM/100MSDCF/DSC00001.JPG"), width: 2400, height: 1350, captureDate: date)
        let volume = try await importCard(card, into: temp)
        let photo = try #require(try temp.reader.photos(in: .all).first)
        #expect(photo.hasRaw && photo.hasJPEG)

        try await PreviewRunner(generator: PreviewGenerator(library: temp.library)).run(mountURLs: [volume.id: card.root])
        let ready = try #require(try temp.reader.photos(in: .all).first)
        #expect(ready.width == 2400 && ready.height == 1350)
    }

    /// 旧库：尺寸记成了 RAW 的，按缩略图的比例校正一次，之后不再做。
    @Test func oldLibraryDimensionsAreCorrectedOnce() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try SampleImages.writeJPEG(to: card.url("DCIM/100MSDCF/DSC00001.JPG"), width: 2400, height: 1350, captureDate: "2026:08:12 10:00:01")
        try SampleImages.writeJPEG(to: card.url("DCIM/100MSDCF/DSC00002.JPG"), width: 1600, height: 2400, captureDate: "2026:08:12 10:00:02")
        let volume = try await importCard(card, into: temp)
        let generator = PreviewGenerator(library: temp.library)
        try await PreviewRunner(generator: generator).run(mountURLs: [volume.id: card.root])
        try temp.library.db.run("UPDATE photos SET width = 2400, height = 1600 WHERE base_name = 'DSC00001';")

        #expect(try temp.library.correctDimensionsFromThumbnails(store: generator.store) == 1)
        let photos = try temp.reader.photos(in: .all)
        let wide = try #require(photos.first { $0.baseName == "DSC00001" })
        let tall = try #require(photos.first { $0.baseName == "DSC00002" })
        #expect(wide.width == 2400 && wide.height == 1350)
        #expect(tall.width == 1600 && tall.height == 2400)

        try temp.library.db.run("UPDATE photos SET width = 2400, height = 1600 WHERE base_name = 'DSC00001';")
        #expect(try temp.library.correctDimensionsFromThumbnails(store: generator.store) == 0)
    }

    /// 生成中拔盘：读不到来源的照片保持 pending；重新插上后续做。
    @Test func unplugDuringGenerationResumesLater() async throws {
        let temp = try TemporaryLibrary()
        let card = try makeCard(count: 2)
        let volume = try await importCard(card, into: temp)
        let runner = PreviewRunner(generator: PreviewGenerator(library: temp.library))

        let gone = card.root.appendingPathComponent("not-mounted")
        let first = try await runner.run(mountURLs: [volume.id: gone])
        #expect(first.ready == 0 && first.unavailable == 2)
        #expect(try temp.reader.pendingPreviewCount() == 2)

        // 离线卷不在任务里。
        #expect(try temp.reader.photosNeedingPreviews(limit: 10, onVolumes: []).isEmpty)

        let second = try await runner.run(mountURLs: [volume.id: card.root])
        #expect(second.ready == 2)
        #expect(try temp.reader.pendingPreviewCount() == 0)
    }

    /// 中途退出 / 文件丢失：重启时发现 `ready` 但文件不在，改回 pending，再次插上时补做缺的那一档。
    @Test func missingPreviewFileIsDetectedOnLaunch() async throws {
        let temp = try TemporaryLibrary()
        let card = try makeCard(count: 2)
        let volume = try await importCard(card, into: temp)
        let generator = PreviewGenerator(library: temp.library)
        try await PreviewRunner(generator: generator).run(mountURLs: [volume.id: card.root])
        let photo = try #require(try temp.reader.photos(in: .all).first?.id)

        try FileManager.default.removeItem(at: generator.store.url(for: photo, size: .thumb))
        // 中途退出留下的临时文件。
        try FileManager.default.createDirectory(at: generator.store.temporaryDirectory, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: generator.store.temporaryDirectory.appendingPathComponent("x.jpg"))

        #expect(try generator.verifyReadyFiles() == 1)
        #expect(!FileManager.default.fileExists(atPath: generator.store.temporaryDirectory.path))
        #expect(try temp.reader.volumeStats(volume.id).previewReadyCount == 1)
        let job = try #require(try temp.reader.photosNeedingPreviews(limit: 10, onVolumes: [volume.id]).first)
        #expect(job.photoID == photo && job.needsThumb && !job.needsPreview)

        try await PreviewRunner(generator: generator).run(mountURLs: [volume.id: card.root])
        #expect(try temp.reader.volumeStats(volume.id).previewReadyCount == 2)
    }

    /// 预览文件损坏（能找到但解码不了）：核对时改回 pending。
    @Test func corruptPreviewIsResetByAudit() async throws {
        let temp = try TemporaryLibrary()
        let card = try makeCard(count: 1)
        let volume = try await importCard(card, into: temp)
        let generator = PreviewGenerator(library: temp.library)
        try await PreviewRunner(generator: generator).run(mountURLs: [volume.id: card.root])
        let photo = try #require(try temp.reader.photos(in: .all).first?.id)

        try Data("garbage".utf8).write(to: generator.store.url(for: photo, size: .preview))
        #expect(try generator.audit(photoIDs: [photo]) == 0)
        #expect(try temp.reader.volumeStats(volume.id).previewReadyCount == 0)
    }

    /// 写不进本机（模拟盘满）：状态保持 pending，队列停下并报告原因。
    @Test func writeFailureStopsQueueAndKeepsPending() async throws {
        let temp = try TemporaryLibrary()
        let card = try makeCard(count: 3)
        let volume = try await importCard(card, into: temp)
        let generator = PreviewGenerator(library: temp.library)
        // 在临时目录的位置放一个普通文件，目录建不出来，写入必然失败。
        try FileManager.default.createDirectory(at: generator.store.root, withIntermediateDirectories: true)
        try Data().write(to: generator.store.temporaryDirectory)

        let progress = try await PreviewRunner(generator: generator, concurrency: 1).run(mountURLs: [volume.id: card.root])
        #expect(progress.writeError != nil)
        #expect(progress.ready == 0)
        #expect(try temp.reader.pendingPreviewCount() == 3)

        try FileManager.default.removeItem(at: generator.store.temporaryDirectory)
        let retry = try await PreviewRunner(generator: generator).run(mountURLs: [volume.id: card.root])
        #expect(retry.ready == 3)
    }
}
