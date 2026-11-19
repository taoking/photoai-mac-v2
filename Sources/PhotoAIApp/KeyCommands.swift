import AppKit
import PhotoAICore
import SwiftUI

/// 选片的全部快捷键只在这里定义一次（设计稿 §7、信息架构 §4）。菜单、键盘处理和“快捷键”速查表都从这张表生成。
enum PhotoCommand: Hashable {
    case previous, next, rowUp, rowDown
    case rate(Int)
    /// 第 n 个标签位置（0–8）。6–9 对应前四个，⌥1–⌥9 对应全部。
    case toggleLabel(slot: Int, viaOption: Bool)
    case clearLabels
    case flag(Flag)
    /// 两张比较时：焦点格 Pick、另一张 Reject。
    case pickFocusRejectOther
    case toggleSingle, compare, focusMode, escape, toggleFilterBar, infoOverlay, zoom, zoomIn, zoomOut, zoomToFit
    case showGrid, showSingle, showCompare
    case addToLastCollection, addToCollection, removeFromCollection
    case selectAll, undo, redo
    case export
    case showShortcuts

    struct Shortcut {
        var key: KeyEquivalent
        var modifiers: EventModifiers = []
        /// 速查表里显示的样子。
        var display: String
    }

    var shortcut: Shortcut {
        switch self {
        case .previous: Shortcut(key: .leftArrow, display: "←")
        case .next: Shortcut(key: .rightArrow, display: "→")
        case .rowUp: Shortcut(key: .upArrow, display: "↑")
        case .rowDown: Shortcut(key: .downArrow, display: "↓")
        case .rate(let n): Shortcut(key: KeyEquivalent(Character("\(n)")), display: "\(n)")
        case .toggleLabel(let slot, let viaOption):
            viaOption
                ? Shortcut(key: KeyEquivalent(Character("\(slot + 1)")), modifiers: .option, display: "⌥\(slot + 1)")
                : Shortcut(key: KeyEquivalent(Character("\(slot + 6)")), display: "\(slot + 6)")
        case .clearLabels: Shortcut(key: "0", modifiers: .option, display: "⌥0")
        case .flag(.pick): Shortcut(key: "p", display: "P")
        case .flag(.reject): Shortcut(key: "x", display: "X")
        case .flag(.none): Shortcut(key: "u", display: "U")
        case .pickFocusRejectOther: Shortcut(key: "p", modifiers: .shift, display: "⇧P")
        case .toggleSingle: Shortcut(key: .space, display: "空格")
        case .compare: Shortcut(key: "c", display: "C")
        case .focusMode: Shortcut(key: "f", display: "F")
        case .escape: Shortcut(key: .escape, display: "Esc")
        case .toggleFilterBar: Shortcut(key: "\\", display: "\\")
        case .infoOverlay: Shortcut(key: "i", display: "I")
        case .zoom: Shortcut(key: "z", display: "Z")
        case .zoomIn: Shortcut(key: "=", modifiers: .command, display: "⌘+")
        case .zoomOut: Shortcut(key: "-", modifiers: .command, display: "⌘−")
        case .zoomToFit: Shortcut(key: "0", modifiers: .command, display: "⌘0")
        case .showGrid: Shortcut(key: "1", modifiers: .command, display: "⌘1")
        case .showSingle: Shortcut(key: "2", modifiers: .command, display: "⌘2")
        case .showCompare: Shortcut(key: "3", modifiers: .command, display: "⌘3")
        case .addToLastCollection: Shortcut(key: "b", display: "B")
        case .addToCollection: Shortcut(key: "b", modifiers: .shift, display: "⇧B")
        case .removeFromCollection: Shortcut(key: .delete, display: "⌫")
        case .selectAll: Shortcut(key: "a", modifiers: .command, display: "⌘A")
        case .undo: Shortcut(key: "z", modifiers: .command, display: "⌘Z")
        case .redo: Shortcut(key: "z", modifiers: [.command, .shift], display: "⇧⌘Z")
        case .export: Shortcut(key: "e", modifiers: .command, display: "⌘E")
        case .showShortcuts: Shortcut(key: "?", display: "?")
        }
    }

    var title: String {
        switch self {
        case .previous: "上一张"
        case .next: "下一张"
        case .rowUp: "上一行"
        case .rowDown: "下一行"
        case .rate(0): "清除星级"
        case .rate(let n): String(repeating: "★", count: n)
        case .toggleLabel(let slot, _): "切换第 \(slot + 1) 个标签"
        case .clearLabels: "清除所有标签"
        case .flag(.pick): "Pick"
        case .flag(.reject): "Reject"
        case .flag(.none): "清除标记"
        case .pickFocusRejectOther: "焦点格 Pick、另一张 Reject"
        case .toggleSingle: "网格 ↔ 单张"
        case .compare: "比较所选 2–4 张"
        case .focusMode: "专注模式"
        case .escape: "退出放大 / 专注模式 / 回到网格"
        case .toggleFilterBar: "显示 / 隐藏筛选条"
        case .infoOverlay: "单张视图的参数浮层"
        case .zoom: "放大到 100% / 适合窗口"
        case .zoomIn: "放大一档（50% / 100% / 200%）"
        case .zoomOut: "缩小一档"
        case .zoomToFit: "适合窗口"
        case .showGrid: "网格"
        case .showSingle: "单张"
        case .showCompare: "比较"
        case .addToLastCollection: "加入上一次的收藏夹"
        case .addToCollection: "加入收藏夹…"
        case .removeFromCollection: "从收藏夹移出"
        case .selectAll: "全选当前结果"
        case .undo: "撤销"
        case .redo: "重做"
        case .export: "导出…"
        case .showShortcuts: "快捷键…"
        }
    }

    /// 速查表的分组和顺序。
    static let reference: [(String, [PhotoCommand])] = [
        ("浏览", [.previous, .next, .rowUp, .rowDown, .toggleSingle, .compare, .focusMode, .escape, .toggleFilterBar, .infoOverlay,
                .zoom, .zoomIn, .zoomOut, .zoomToFit, .showGrid, .showSingle, .showCompare]),
        ("打星与标记", [.rate(1), .rate(2), .rate(3), .rate(4), .rate(5), .rate(0),
                     .flag(.pick), .flag(.reject), .flag(.none), .pickFocusRejectOther]),
        ("标签", (0..<4).map { .toggleLabel(slot: $0, viaOption: false) } + (0..<9).map { .toggleLabel(slot: $0, viaOption: true) }
            + [.clearLabels]),
        ("收藏夹", [.addToLastCollection, .addToCollection, .removeFromCollection]),
        ("其他", [.selectAll, .undo, .redo, .export, .showShortcuts])
    ]

    static let all: [PhotoCommand] = reference.flatMap(\.1)

    /// 按键事件对应的命令。Caps Lock（自动前进）开着时字母是大写的，所以字母一律按小写比较，⇧ 另外看。
    static func matching(_ event: NSEvent) -> PhotoCommand? {
        var flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard !flags.contains(.control) else { return nil }
        var key: KeyEquivalent
        switch event.keyCode {
        case 123: key = .leftArrow
        case 124: key = .rightArrow
        case 125: key = .downArrow
        case 126: key = .upArrow
        case 49: key = .space
        case 53: key = .escape
        case 51, 117: key = .delete
        default:
            guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1 else { return nil }
            key = KeyEquivalent(Character(characters))
        }
        // ⌘+ 在美式键盘上是 ⌘⇧=，也常直接按 ⌘=：都算放大。
        if key.character == "+" {
            key = "="
            flags.remove(.shift)
        }
        let isLetter = key.character.isLetter
        return all.first { command in
            let shortcut = command.shortcut
            guard shortcut.key.character == key.character else { return false }
            if shortcut.modifiers.contains(.command) != flags.contains(.command) { return false }
            if shortcut.modifiers.contains(.option) != flags.contains(.option) { return false }
            // 只有字母区分 ⇧（P 与 ⇧P、B 与 ⇧B）；“?” 本身就要按 ⇧。
            if isLetter || shortcut.modifiers.contains(.command), shortcut.modifiers.contains(.shift) != flags.contains(.shift) {
                return false
            }
            return true
        }
    }
}

/// 把按键交给命令表。
///
/// 菜单上也挂着同样的快捷键（显示用、也能用鼠标点），但按键先经过这里：
/// - 主窗口里没有在输入文字时，由这里执行命令，菜单不会再收到这个键；
/// - 正在输入文字（文本框、改名框）时，单键快捷键让位给输入：直接交给文本框，不让菜单抢走。
@MainActor
final class KeyRouter {
    private var monitor: Any?
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    /// 返回 true 表示这个键已经处理完，不再往下传。
    private func handle(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        if event.type == .flagsChanged {
            model.setAutoAdvance(event.modifierFlags.contains(.capsLock))
            return false
        }
        guard let command = PhotoCommand.matching(event) else { return false }
        guard let window = event.window ?? NSApp.keyWindow else { return false }
        let responder = window.firstResponder
        let isEditing = responder is NSText
        let isMainWindow = window.identifier?.rawValue.hasPrefix("main") == true && window.attachedSheet == nil
        if isEditing {
            // Esc、回车照常走窗口：面板的“取消”“确定”按钮要收到。
            if event.keyCode == 53 { return false }
            let modifiers = command.shortcut.modifiers
            if modifiers.contains(.command) {
                // 文本框里的 ⌘A / ⌘Z 是文字的全选和撤销。
                switch command {
                case .selectAll: NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                case .undo: NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                case .redo: NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                default: return false
                }
                return true
            }
            responder?.keyDown(with: event)
            return true
        }
        // 面板、提示框里不执行选片命令（`perform` 也会再挡一次）。
        guard isMainWindow else { return false }
        model.perform(command)
        return true
    }
}

/// 菜单栏：图库、照片、显示、帮助。菜单项从命令表生成。
struct PhotoCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .undoRedo) {
            item(.undo, title: model.history.undoTitle.map { "撤销 \($0)" } ?? "撤销")
                .disabled(model.history.undoTitle == nil)
            item(.redo, title: model.history.redoTitle.map { "重做 \($0)" } ?? "重做")
                .disabled(model.history.redoTitle == nil)
        }
        CommandGroup(replacing: .textEditing) {
            item(.selectAll)
        }
        CommandMenu("图库") {
            item(.export)
            Divider()
            Button("新建收藏夹…") { model.beginNewCollection(adding: []) }
            Button("标签设置…") { model.activeSheet = .labelSettings }
        }
        CommandMenu("照片") {
            Menu("星级") { ForEach([1, 2, 3, 4, 5, 0], id: \.self) { item(.rate($0)) } }
            Menu("标签") {
                ForEach(Array(model.labels.enumerated()), id: \.offset) { slot, label in
                    item(.toggleLabel(slot: slot, viaOption: true), title: label.isInUse ? label.name : "（未使用的位置 \(slot + 1)）")
                        .disabled(!label.isInUse)
                }
                Divider()
                item(.clearLabels)
            }
            item(.flag(.pick))
            item(.flag(.reject))
            item(.flag(.none))
            Divider()
            item(.addToLastCollection, title: model.lastCollectionName.map { "加入「\($0)」" } ?? "加入上一次的收藏夹")
            item(.addToCollection)
            item(.removeFromCollection)
            Divider()
            Toggle("自动前进（⇪ Caps Lock）", isOn: .constant(model.autoAdvance)).disabled(true)
        }
        CommandMenu("显示") {
            item(.showGrid)
            item(.showSingle)
            item(.showCompare)
            Divider()
            item(.toggleFilterBar)
            item(.focusMode)
            item(.infoOverlay)
            item(.zoom, title: model.zoomed ? "适合窗口" : "放大到 100%")
            item(.zoomIn)
            item(.zoomOut)
            item(.zoomToFit)
            Divider()
            Picker("背景", selection: style(\.background)) {
                ForEach(ViewerStyle.Background.allCases) { Text($0.title).tag($0) }
            }
            Toggle("照片细边框和投影", isOn: style(\.framed))
            Picker("四周留白", selection: style(\.margin)) {
                ForEach(ViewerStyle.Margin.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Button(model.showInspector ? "隐藏检查器" : "显示检查器") { model.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            item(.showShortcuts)
        }
    }

    private func style<Value>(_ path: WritableKeyPath<ViewerStyle, Value>) -> Binding<Value> {
        Binding(get: { model.viewerStyle[keyPath: path] }, set: { model.viewerStyle[keyPath: path] = $0 })
    }

    private func item(_ command: PhotoCommand, title: String? = nil) -> some View {
        Button(title ?? command.title) { model.perform(command) }
            .keyboardShortcut(command.shortcut.key, modifiers: command.shortcut.modifiers)
    }
}
