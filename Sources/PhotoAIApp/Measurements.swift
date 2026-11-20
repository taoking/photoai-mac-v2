import AppKit
import PhotoAICore
import Synchronization

/// 性能目标 PF-1、PF-3、PF-4、PF-5 的实测记录。设置环境变量 `PHOTOAI_MEASURE=1` 时打印到标准输出，
/// 每行以 `PF` 开头，验收记录直接引用这些行。
enum Measurements {
    static let isEnabled = ProcessInfo.processInfo.environment["PHOTOAI_MEASURE"] == "1"

    static func record(_ label: String, since start: Date, count: Int) {
        guard isEnabled else { return }
        let elapsed = Date().timeIntervalSince(start) * 1000
        let collected = samples.withLock { samples -> Bool in
            guard var all = samples else { return false }
            all[String(label.prefix { $0 != " " }), default: []].append(elapsed)
            samples = all
            return true
        }
        // 连续测量时只记数，最后汇总打印。
        if !collected { emit("\(label)：\(Int(elapsed)) ms，\(count) 张") }
    }

    /// 按 `PF-6` 这样的前缀收集每次的用时，给连续打星这类上千次的测量汇总用。
    private static let samples = Mutex<[String: [Double]]?>(nil)

    static func startCollecting() { samples.withLock { $0 = [:] } }

    static func percentile(prefix: String, _ fraction: Double) -> Double? {
        samples.withLock { samples in
            guard let values = samples?[prefix]?.sorted(), !values.isEmpty else { return nil }
            return values[min(values.count - 1, Int(Double(values.count) * fraction))]
        }
    }

    static func report(prefix: String, label: String, target: Double) {
        let values = samples.withLock { $0?[prefix]?.sorted() ?? [] }
        guard !values.isEmpty else { return emit("\(label)：没有数据") }
        let over = values.filter { $0 > target }.count
        emit(String(
            format: "%@：%d 次，中位 %.1f ms，95%% %.1f ms，最大 %.1f ms，超过 %.0f ms 的 %d 次",
            label, values.count, values[values.count / 2], values[min(values.count - 1, values.count * 95 / 100)],
            values.last!, target, over
        ))
    }

    /// PF-1：从进程启动到网格第一次有数据。
    static func recordLaunch(since start: Date, count: Int) {
        guard isEnabled else { return }
        emit("PF-1 冷启动到网格可见：\(milliseconds(since: start)) ms，\(count) 张")
        if let path = ProcessInfo.processInfo.environment["PHOTOAI_SNAPSHOT"] {
            // 开发用：把自己的窗口画成 PNG，不需要屏幕录制权限。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { snapshotMainWindow(to: URL(fileURLWithPath: path)) }
            }
        }
        if ProcessInfo.processInfo.environment["PHOTOAI_QUIT_AFTER_LAUNCH"] == "1" {
            // 等网格真正画出来再退出：下一轮主循环之后。
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
        }
    }

    static func recordScan(name: String, since start: Date, summary: ScanSummary) {
        guard isEnabled else { return }
        emit(
            "PF-4/5 扫描 \(name)：\(milliseconds(since: start)) ms，文件 \(summary.filesSeen)，未变 \(summary.unchanged)，"
                + "新增位置 \(summary.added)，新照片 \(summary.newPhotos)，恢复 \(summary.restored)，"
                + "改为历史 \(summary.vanished + summary.replaced)，完整 \(summary.isComplete)"
        )
    }

    static func recordPreviews(since start: Date, progress: PreviewRunner.Progress) {
        guard isEnabled else { return }
        let elapsed = Date().timeIntervalSince(start)
        let perPhoto = progress.ready > 0 ? elapsed / Double(progress.ready) * 1000 : 0
        emit(
            "PF-5 预览：\(Int(elapsed * 1000)) ms，就绪 \(progress.ready)，失败 \(progress.failed)，"
                + "来源不在线 \(progress.unavailable)，平均每张 \(Int(perPhoto)) ms"
        )
    }

    @MainActor
    static func snapshotMainWindow(to url: URL) {
        // `PHOTOAI_SNAPSHOT_SCREEN=1`：用系统截图截这个窗口，侧栏、检查器的材质也在（要有屏幕录制权限）。
        if ProcessInfo.processInfo.environment["PHOTOAI_SNAPSHOT_SCREEN"] == "1",
           let window = NSApp.windows.first(where: { $0.isVisible }) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
            if (try? process.run()) != nil {
                process.waitUntilExit()
                // 锁屏时系统截图截不到窗口，不出文件：退回下面的画法。
                if FileManager.default.fileExists(atPath: url.path) { return }
            }
        }
        // 侧栏、检查器的毛玻璃材质画不进来，会是空白；只用来看内容区。
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let view = window.contentView?.superview ?? window.contentView,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        try? representation.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    static func emit(_ line: String) {
        print(line)
        fflush(stdout)
    }

    /// 进程的启动时间（内核记录），比 `main` 里取的时间更早，冷启动从这里算。
    static func processStartDate() -> Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }
}
