import Foundation
import PhotoAICore

// 命令行工具 photoai。rate / collect / find 在 M5 实现；M1 只有 exif，用来记录真实样片的身份字段。
let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
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
    print("用法：photoai exif <文件>…")
    exit(arguments.isEmpty ? 0 : 1)
}
