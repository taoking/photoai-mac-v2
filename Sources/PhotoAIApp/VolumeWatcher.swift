import AppKit

/// 卷的挂载和卸载由系统通知推送；开销只和卷的数量有关，不逐个检查原片（数据模型 §3 volumes）。
@MainActor
final class VolumeWatcher {
    enum Event {
        case mounted(URL)
        case unmounted(URL)
    }

    private var observers: [NSObjectProtocol] = []

    init(handler: @escaping @Sendable (Event) -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
            if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL { handler(.mounted(url)) }
        })
        // willUnmount 比 didUnmount 早：扫描可以先停下，不必等到读文件出错。
        for name in [NSWorkspace.willUnmountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL { handler(.unmounted(url)) }
            })
        }
    }

    isolated deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }
}
