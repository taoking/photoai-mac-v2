import Foundation
import PhotoAICore

// 命令行工具 photoai：find / rate / collect 给 Claude skill 用（见 Commands.swift）；
// exif 记录真实样片的身份字段；dev- 开头的是开发和验收用的命令。
let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "find":
    exit(Commands.find(Array(arguments.dropFirst())))
case "rate":
    exit(Commands.rate(Array(arguments.dropFirst())))
case "collect":
    exit(Commands.collect(Array(arguments.dropFirst())))
case "exif":
    for path in arguments.dropFirst() {
        let url = URL(fileURLWithPath: path)
        print("== \(url.lastPathComponent)")
        for (key, value) in ImageIOMetadataReader.identityFields(at: url).sorted(by: { $0.key < $1.key }) {
            print("  \(key): \(value)")
        }
        if let metadata = try? ImageIOMetadataReader().metadata(at: url) {
            let baseName = PhotoIdentity.baseName(ofFileName: url.lastPathComponent)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            print("  身份: \(PhotoIdentity.key(baseName: baseName, captureDate: metadata.captureDate, fileSize: Int64(size)))")
        } else {
            print("  身份: 读不出元数据")
        }
    }
case "focus":
    // 每个文件一行：文件名、对焦框（转正后 0–1 的 x y 宽 高）或 none / unreadable。核对用。
    for path in arguments.dropFirst() {
        let url = URL(fileURLWithPath: path)
        switch FocusPointReader.read(at: url) {
        case .found(let area): print(String(format: "%@\t%.4f\t%.4f\t%.4f\t%.4f", url.lastPathComponent, area.x, area.y, area.width, area.height))
        case .notRecorded: print("\(url.lastPathComponent)\tnone")
        case nil: print("\(url.lastPathComponent)\tunreadable")
        }
    }
case "dev-synth":
    // 开发用：在指定目录生成合成的十万条库，给性能目标测量用。不碰真实的库。
    guard arguments.count >= 2 else {
        print("用法：photoai dev-synth <目录> [照片数]")
        exit(1)
    }
    var options = SyntheticLibrary.Options()
    if arguments.count >= 3, let count = Int(arguments[2]) { options.photoCount = count }
    let started = Date()
    do {
        try SyntheticLibrary.build(at: LibraryPaths(root: URL(fileURLWithPath: arguments[1], isDirectory: true)), options: options)
        print("已生成 \(options.photoCount) 张，用时 \(Int(Date().timeIntervalSince(started))) 秒")
    } catch {
        print("生成失败：\(error)")
        exit(1)
    }
case "dev-import":
    // 开发与验收用：按软件里同样的流程导入一个已挂载的卷（认卷 → 扫描 → 生成预览），打印 PF-4 / PF-5 的数字。
    // 库的位置和软件一样，可用 PHOTOAI_LIBRARY_DIR 换到别处。
    guard arguments.count >= 2 else {
        print("用法：photoai dev-import <挂载点> [扫描的文件夹]")
        exit(1)
    }
    let mount = URL(fileURLWithPath: arguments[1], isDirectory: true)
    guard let info = MountedVolumes.info(for: mount) else {
        print("不是一个可用的卷：\(mount.path)")
        exit(1)
    }
    do {
        let library = try Library()
        let volume: VolumeRecord
        if let known = try library.reader.activeVolume(uuid: info.uuid) {
            volume = known
            print("已知的卷：\(known.name)（\(info.uuid)），扫描 \(known.scanRoot.isEmpty ? "整个卷" : known.scanRoot)")
        } else {
            let root = arguments.count >= 3 ? arguments[2] : (info.hasDCIM ? "DCIM" : "")
            volume = try library.addVolume(
                uuid: info.uuid, name: info.name, scanRoot: root,
                capacityBytes: info.capacityBytes, filesystem: info.filesystem
            )
            print("新卷：\(info.name)（\(info.filesystem ?? "未知格式")，\(info.uuid)），扫描 \(root.isEmpty ? "整个卷" : root)")
        }
        let semaphore = DispatchSemaphore(value: 0)
        // 顶层代码在主线程上，下面要阻塞主线程等结果，所以任务不能再排到主线程上。
        Task.detached {
            do {
                let scanStart = Date()
                let summary = try await VolumeScanner(library: library).scan(volumeID: volume.id, mountURL: info.url)
                let scanSeconds = Date().timeIntervalSince(scanStart)
                print(String(
                    format: "扫描：%.2f 秒，文件 %d，未变 %d，新增位置 %d，新照片 %d，恢复 %d，改为历史 %d，完整 %@",
                    scanSeconds, summary.filesSeen, summary.unchanged, summary.added, summary.newPhotos,
                    summary.restored, summary.vanished + summary.replaced, summary.isComplete ? "是" : "否"
                ))
                for (dir, reason) in summary.incompleteDirectories.sorted(by: { $0.key < $1.key }) {
                    print("  没扫完：\(dir)（\(reason)）")
                }
                let previewStart = Date()
                let progress = try await PreviewRunner(generator: PreviewGenerator(library: library))
                    .run(mountURLs: [volume.id: info.url])
                let previewSeconds = Date().timeIntervalSince(previewStart)
                print(String(
                    format: "预览：%.2f 秒，就绪 %d，失败 %d，来源不在线 %d，平均每张 %.0f ms%@",
                    previewSeconds, progress.ready, progress.failed, progress.unavailable,
                    progress.ready > 0 ? previewSeconds / Double(progress.ready) * 1000 : 0,
                    progress.writeError.map { "，写入出错：\($0)" } ?? ""
                ))
                let stats = try library.reader.volumeStats(volume.id)
                print("卷：已收录 \(stats.photoCount) · 离线预览就绪 \(stats.previewReadyCount) · 没扫完的目录 \(stats.incompleteDirectoryCount)")
                print("库：可见照片 \(try library.reader.visiblePhotoCount())")
            } catch {
                print("导入失败：\(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
    } catch {
        print("打不开照片库：\(error)")
        exit(1)
    }
case "dev-export":
    // 验收用：把可见照片（或某个卷上的照片）导出到一个目录，走和软件一样的导出流程，打印结果和 PF-9 吞吐。
    // 源文件只读；目标只复制、不覆盖。可用 PHOTOAI_LIBRARY_DIR 换库。
    guard arguments.count >= 2 else {
        print("用法：photoai dev-export <目标目录> [raw|jpeg|both] [flat|byCollection|original] [卷名|-] [张数|跳过:张数]")
        exit(1)
    }
    do {
        let library = try Library()
        let volumes = try library.reader.volumes()
        var mounts: [VolumeID: URL] = [:]
        for info in MountedVolumes.list() {
            if let volume = volumes.first(where: { $0.volumeUUID == info.uuid }) { mounts[volume.id] = info.url }
        }
        let files = arguments.count >= 3 ? ExportRequest.Files(rawValue: arguments[2]) ?? .both : .both
        let layout = arguments.count >= 4 ? ExportRequest.Layout(rawValue: arguments[3]) ?? .flat : .flat
        var scope = PhotoScope.all
        if arguments.count >= 5, arguments[4] != "-" {
            guard let volume = volumes.first(where: { $0.name == arguments[4] }) else {
                print("没有叫“\(arguments[4])”的卷")
                exit(1)
            }
            scope = .volume(volume.id)
        }
        var ids = try library.reader.photos(in: scope).map(\.id)
        if arguments.count >= 6 {
            let parts = arguments[5].split(separator: ":").compactMap { Int($0) }
            if parts.count == 2 { ids = Array(ids.dropFirst(parts[0]).prefix(parts[1])) }
            if parts.count == 1 { ids = Array(ids.prefix(parts[0])) }
        }
        let finder = OriginalFinder(mounts: mounts, volumeUUIDs: Dictionary(uniqueKeysWithValues: volumes.map { ($0.id, $0.volumeUUID) }))
        let request = ExportRequest(photoIDs: ids, files: files, layout: layout, destination: URL(fileURLWithPath: arguments[1], isDirectory: true))
        let report = try Exporter(library: library, finder: finder).run(request)
        print(String(
            format: "PF-9 导出：%d 张、%d 个文件、%.1f MB，%.2f 秒，%.1f MB/s",
            report.exportedPhotos, report.copiedFiles, Double(report.bytesCopied) / 1_000_000, report.elapsed, report.megabytesPerSecond
        ))
        print("已有相同 \(report.identicalFiles)，改名 \(report.renamedFiles)，从其他位置 \(report.fromOtherLocation)，改用另一种格式 \(report.usedOtherKind)，"
            + "改为历史 \(report.missingLocations)，移到无卷关联 \(report.hiddenPhotoIDs.count)，跳过离线照片 \(report.skippedOfflinePhotos)，"
            + "离线文件 \(report.skippedOfflineFiles)，失败 \(report.failures.count)\(report.stoppedBy.map { "，停下：\($0)" } ?? "")")
        for failure in report.failures.prefix(20) { print("  失败：\(failure.name)：\(failure.reason)") }
    } catch {
        print("导出失败：\(error)")
        exit(1)
    }
case "dev-audit":
    // 验收用：逐个解码本机的 480 和 1600 预览，核对“离线预览就绪”的计数。不需要任何卷在线。
    do {
        let library = try Library()
        let ids = try library.reader.photos(in: .all).map(\.id)
        let readyBefore = try library.reader.volumes().reduce(0) { $0 + (try library.reader.volumeStats($1.id).previewReadyCount) }
        let decodable = try PreviewGenerator(library: library).audit(photoIDs: ids)
        print("可见照片 \(ids.count)，两档预览都能解码 \(decodable)，核对前各卷“离线预览就绪”合计 \(readyBefore)")
    } catch {
        print("核对失败：\(error)")
        exit(1)
    }
default:
    print("""
    用法：
      photoai find <匹配项>…              找照片，不改任何东西
      photoai rate <0-5> <匹配项>…        打星（0 是去掉星级）
      photoai collect <收藏夹> <匹配项>…  加入收藏夹，没有就新建
      photoai exif <文件>…                看文件的身份字段
      photoai focus <文件>…               看相机记录的对焦框（目前认索尼）
    匹配项：文件名 DSC01926.ARW、去掉扩展名的文件名 DSC01926、编号 1926 或 01926、编号范围 1926-1950；
    可以写多项，用空格或逗号隔开。只匹配可见照片；一个编号命中多张时取拍摄时间最晚的一张。
    用 PHOTOAI_LIBRARY_DIR 换库。
    """)
    exit(arguments.isEmpty ? 0 : 1)
}
