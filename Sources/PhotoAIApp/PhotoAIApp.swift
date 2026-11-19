import AppKit
import SwiftUI

@main
struct PhotoAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel(launchStart: Measurements.processStartDate())

    var body: some Scene {
        Window("PhotoAI", id: "main") {
            MainWindow()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear { model.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                    model.windowDidBecomeKey()
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            PhotoCommands(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 用 swift run 直接启动时也要成为普通的前台应用。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
