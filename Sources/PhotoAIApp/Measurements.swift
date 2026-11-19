import AppKit
import PhotoAICore

/// 性能目标 PF-1、PF-3、PF-4、PF-5 的实测记录。设置环境变量 `PHOTOAI_MEASURE=1` 时打印到标准输出，
/// 每行以 `PF` 开头，验收记录直接引用这些行。
enum Measurements {
    static let isEnabled = ProcessInfo.processInfo.environment["PHOTOAI_MEASURE"] == "1"

    static func record(_ label: String, since start: Date, count: Int) {
        guard isEnabled else { return }
        emit("\(label)：\(milliseconds(since: start)) ms，\(count) 张")
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
        // 侧栏的毛玻璃材质画不进来，侧栏会是空白；只用来看内容区。
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
