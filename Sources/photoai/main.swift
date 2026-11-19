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
default:
    print("用法：photoai exif <文件>…")
    exit(arguments.isEmpty ? 0 : 1)
}
