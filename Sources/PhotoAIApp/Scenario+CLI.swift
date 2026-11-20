import AppKit
import PhotoAICore

/// `PHOTOAI_SCENARIO=cli`：命令行和软件一起用（计划 · M5）。准备工作见 `Scripts/m5-cli-test.sh`。
///
/// - 软件关闭时：脚本先用命令行给 `PHOTOAI_CLI_CLOSED` 打 3 星、加入「命令行·关闭时」，再打开软件，这里核对星级和收藏夹；
/// - 软件开着时：软件里先打一次星、标一次 Pick（有撤销记录），再跑命令行给 `PHOTOAI_CLI_OPEN` 打 4 星、加入「命令行·开着时」。
///   窗口没重新获得焦点前界面不变；获得焦点后刷新、撤销记录清空、软件写的字段还在。
///
/// 不需要卡插着（离线的卷照样算有关联）。只对库的副本用。
extension ScenarioRunner {
    func buildCLI() {
        let cli = environment["PHOTOAI_CLI"] ?? ""
        let closedTerms = environment["PHOTOAI_CLI_CLOSED"] ?? ""
        let openTerms = environment["PHOTOAI_CLI_OPEN"] ?? ""
        var openIDs: [PhotoID] = []
        var appRated: PhotoID = 0
        var output = (status: Int32(-1), stdout: "", stderr: "")

        func match(_ text: String) -> [PhotoID] {
            guard let terms = try? MatchTerm.parseAll([text]) else { return [] }
            return (try? model.reader?.match(terms).photoIDs) ?? []
        }

        wait("照片读好", timeout: 30) { [self] in model.photoCount > 0 && model.scanStatus == nil }
        step("软件关闭时命令行做的改动") { [self] in
            check(FileManager.default.isExecutableFile(atPath: cli), "有命令行工具（PHOTOAI_CLI）")
            model.selection = .all
            let ids = match(closedTerms)
            check(ids.count >= 5, "PHOTOAI_CLI_CLOSED 匹配到 \(ids.count) 张")
            check(ids.allSatisfy { model.photo($0)?.rating == 3 }, "打开软件后这些照片是 3 星")
            let collection = model.collections.first { $0.name == "命令行·关闭时" }
            check(collection?.photoCount == ids.count, "侧栏有「命令行·关闭时」，\(collection?.photoCount ?? 0) 张")
            check(model.history.undoTitle == nil, "撤销记录是空的")
        }
        step("软件里打星、标 Pick") { [self] in
            openIDs = match(openTerms)
            check(openIDs.count >= 3 && openIDs.allSatisfy { model.photo($0)?.rating != 4 }, "PHOTOAI_CLI_OPEN 匹配到 \(openIDs.count) 张，都还不是 4 星")
            appRated = model.resultIDs.first { !openIDs.contains($0) && model.photo($0)?.rating == 0 } ?? 0
            model.focusOnly(appRated)
            model.setRating(2)
            if let first = openIDs.first {
                model.focusOnly(first)
                model.setFlag(.pick)
            }
            check(model.history.undoStack.count == 2, "软件里的两次改动可以撤销")
        }
        asyncStep("软件开着时跑命令行") { [self] done in
            Task {
                let (rate, collect) = await Task.detached {
                    (Self.runCLI(cli, ["rate", "4", openTerms]), Self.runCLI(cli, ["collect", "命令行·开着时", openTerms]))
                }.value
                output = (rate.status == 0 && collect.status == 0 ? 0 : 1, rate.stdout + collect.stdout, rate.stderr + collect.stderr)
                done()
            }
        }
        step("切回窗口之前") { [self] in
            print(output.stdout.split(separator: "\n").prefix(4).map { "  命令行：\($0)" }.joined(separator: "\n"))
            check(output.status == 0, "命令行两次都成功")
            check(output.stderr.contains("PhotoAI 正开着"), "命令行提示软件正开着，但不阻止：\(output.stderr.trimmingCharacters(in: .newlines))")
            check(openIDs.allSatisfy { model.photo($0)?.rating != 4 }, "窗口没重新获得焦点前，界面里的星级不变")
            check(model.history.undoStack.count == 2, "撤销记录还在")
        }
        step("窗口重新获得焦点") { [self] in
            // 和切回窗口时系统发的通知一样，走同一个处理（PhotoAIApp 里的 onReceive）。
            let window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        }
        wait("界面刷新", timeout: 5) { [self] in openIDs.allSatisfy { model.photo($0)?.rating == 4 } }
        step("刷新之后") { [self] in
            check(openIDs.allSatisfy { model.photo($0)?.rating == 4 }, "命令行打的 4 星显示出来")
            let collection = model.collections.first { $0.name == "命令行·开着时" }
            check(collection?.photoCount == openIDs.count, "侧栏出现「命令行·开着时」，\(collection?.photoCount ?? 0) 张")
            check(model.history.undoTitle == nil && model.history.redoTitle == nil, "别的进程改过库：撤销记录清空")
            check(model.photo(appRated)?.rating == 2, "软件打的 2 星还在")
            check(openIDs.first.flatMap { model.photo($0)?.flag } == .pick, "软件标的 Pick 还在（命令行只写星级）")
            snapshot("m5-after-refresh")
        }
        step("没有外部改动时再获得焦点") { [self] in
            model.setRating(1)
            let window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            check(model.history.undoStack.count == 1, "软件自己的改动不算外部改动，撤销记录保留")
        }
    }

    nonisolated static func runCLI(_ path: String, _ arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, "", "\(error)") }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }
}
