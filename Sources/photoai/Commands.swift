import AppKit
import PhotoAICore

/// `find` / `rate` / `collect`：按文件名或编号找照片、批量打星、加入收藏夹（产品定位 §3.4）。
/// 匹配规则在 `PhotoAICore` 的 `Matching.swift`，这里只负责参数和输出。
///
/// 退出码：0 有匹配到的照片；2 一张都没匹配到（什么都没写）；1 参数或库出错。
enum Commands {
    /// 列出的照片超过这么多张时只列前面这些，后面报个数。
    static let listLimit = 100

    static func find(_ arguments: [String]) -> Int32 {
        guard !arguments.isEmpty else { return usage("photoai find <文件名|编号|范围>…") }
        return run(arguments) { _, report in
            print("匹配到 \(report.photos.count) 张：")
            printList(report.photos) { line($0) }
            return 0
        }
    }

    static func rate(_ arguments: [String]) -> Int32 {
        guard arguments.count >= 2, let rating = Int(arguments[0]), (0...5).contains(rating) else {
            return usage("photoai rate <0-5> <文件名|编号|范围>…")
        }
        warnIfAppRunning()
        return run(Array(arguments.dropFirst())) { library, report in
            try library.setRating(rating, for: report.photoIDs)
            let unchanged = report.photos.filter { $0.rating == rating }.count
            print("已设为 \(stars(rating))：\(report.photos.count) 张\(unchanged > 0 ? "（其中 \(unchanged) 张原本就是）" : "")")
            printList(report.photos) { photo in
                photo.rating == rating ? line(photo) : "\(line(photo))  → \(stars(rating))"
            }
            return 0
        }
    }

    static func collect(_ arguments: [String]) -> Int32 {
        guard arguments.count >= 2 else { return usage("photoai collect <收藏夹名字> <文件名|编号|范围>…") }
        let name = arguments[0]
        warnIfAppRunning()
        return run(Array(arguments.dropFirst())) { library, report in
            let result = try library.collect(report.photoIDs, intoCollectionNamed: name)
            let already = report.photos.count - result.added.count
            print("\(result.created ? "新建收藏夹" : "加入收藏夹")「\(name.trimmingCharacters(in: .whitespaces))」："
                + "新加入 \(result.added.count) 张\(already > 0 ? "，\(already) 张原本就在里面" : "")")
            let added = Set(result.added)
            printList(report.photos) { added.contains($0.id) ? line($0) : "\(line($0))  （原本就在）" }
            return 0
        }
    }

    // MARK: -

    /// 解析、匹配、打印跳过和没匹配到的；有匹配到的照片才调用 `body`。
    private static func run(_ arguments: [String], _ body: (Library, MatchReport) throws -> Int32) -> Int32 {
        do {
            let terms = try MatchTerm.parseAll(arguments)
            let library = try Library()
            let report = try library.reader.match(terms)
            let status: Int32 = report.photos.isEmpty ? 2 : try body(library, report)
            if report.photos.isEmpty { print("一张都没匹配到，什么都没改。") }
            let skipped = report.skipped
            if !skipped.isEmpty {
                print("跳过 \(skipped.count) 张（同一个编号或名字命中多张时，只取拍摄时间最晚的一张）：")
                printList(skipped) { line($0) }
            }
            if !report.unmatched.isEmpty {
                print("没有匹配到：\(report.unmatched.joined(separator: "、"))")
            }
            return status
        } catch {
            printError("\(error)")
            return 1
        }
    }

    private static func line(_ photo: MatchedPhoto) -> String {
        let name = ([photo.baseName] + [photo.extensions.joined(separator: "+")]).joined(separator: ".")
        return "  \(name)  \(photo.captureDate ?? "没有拍摄时间")  \(stars(photo.rating))"
    }

    private static func printList(_ photos: [MatchedPhoto], _ format: (MatchedPhoto) -> String) {
        for photo in photos.prefix(listLimit) { print(format(photo)) }
        if photos.count > listLimit { print("  …还有 \(photos.count - listLimit) 张") }
    }

    private static func stars(_ rating: Int) -> String { rating == 0 ? "无星" : "★\(rating)" }

    /// 软件开着时只提示、不阻止（产品定位 §3.4）。
    private static func warnIfAppRunning() {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "local.photoai.mac.v2").isEmpty else { return }
        printError("提示：PhotoAI 正开着。改动在切回软件窗口后显示，软件里的撤销记录会清空。")
    }

    private static func usage(_ text: String) -> Int32 {
        printError("用法：\(text)")
        return 1
    }

    static func printError(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
