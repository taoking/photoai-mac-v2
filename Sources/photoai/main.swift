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
default:
    print("用法：photoai exif <文件>…")
    exit(arguments.isEmpty ? 0 : 1)
}
