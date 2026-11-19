import AppKit
import PhotoAICore
import SwiftUI

/// ⇧B：把照片加入一个收藏夹，或新建一个并加入。上一次用过的标出来（之后按 B 直接加入那里）。
struct AddToCollectionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let photoIDs: [PhotoID]
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("把 \(photoIDs.count.formatted()) 张照片加入收藏夹").font(.title3.bold())
            if model.collections.isEmpty {
                Text("还没有收藏夹。").foregroundStyle(.secondary)
            } else {
                List(model.collections) { collection in
                    Button {
                        dismiss()
                        model.addToCollection(collection.id, photoIDs: photoIDs)
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text(collection.name)
                            Spacer()
                            Text("\(collection.photoCount.formatted()) 张" + (collection.id == model.lastCollectionID ? " · 上次用过（B）" : ""))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: min(260, CGFloat(model.collections.count) * 28 + 16))
            }
            GroupBox("或新建一个") {
                HStack {
                    TextField("名字", text: $newName)
                        .onSubmit(create)
                    Button("新建并加入", action: create)
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmed.isEmpty)
                }
                .padding(4)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { newName = model.suggestedCollectionName() }
    }

    private var trimmed: String { newName.trimmingCharacters(in: .whitespaces) }

    private func create() {
        guard !trimmed.isEmpty else { return }
        let name = trimmed
        dismiss()
        model.createCollection(named: name, adding: photoIDs)
    }
}

/// 新建收藏夹（菜单“图库 → 新建收藏夹…”），可以带上要加入的照片。
struct NewCollectionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let photoIDs: [PhotoID]
    @State private var name = ""

    var body: some View {
        NameSheet(
            title: "新建收藏夹",
            name: $name,
            confirm: photoIDs.isEmpty ? "新建" : "新建并加入 \(photoIDs.count) 张"
        ) {
            model.createCollection(named: $0, adding: photoIDs)
        }
        .onAppear { name = photoIDs.isEmpty ? "新收藏夹" : model.suggestedCollectionName() }
    }
}

struct RenameCollectionSheet: View {
    @Environment(AppModel.self) private var model
    let collectionID: CollectionID
    @State private var name = ""

    var body: some View {
        NameSheet(title: "给收藏夹改名", name: $name, confirm: "改名") {
            model.renameCollection(collectionID, to: $0)
        }
        .onAppear { name = model.collections.first { $0.id == collectionID }?.name ?? "" }
    }
}

/// 只有一个名字输入框的面板。
struct NameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @Binding var name: String
    let confirm: String
    let onConfirm: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.bold())
            TextField("名字", text: $name)
                .onSubmit(done)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirm, action: done)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private func done() {
        guard !trimmed.isEmpty else { return }
        let value = trimmed
        dismiss()
        onConfirm(value)
    }
}

/// 标签设置：9 个位置，顺序决定快捷键（信息架构 §3.3.2）。名字留空表示不用这个位置。
struct LabelSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var edited: [LabelRecord] = []

    static let palette = ["#e5484d", "#f5a524", "#30a46c", "#3e63dd", "#8e4ec6", "#12a594", "#e93d82", "#ad7f58", "#8b8d98"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("标签设置").font(.title3.bold())
            Text("顺序决定快捷键：第 1–4 个对应 6–9，全部对应 ⌥1–⌥9。名字留空表示不用这个位置；删掉名字会把这个标签从所有照片上去掉，照片本身不受影响。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach($edited) { $label in
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(nsColor: NSColor(hex: label.color)))
                        .frame(width: 16, height: 16)
                        .onTapGesture { label.color = nextColor(after: label.color) }
                        .help("点击换颜色")
                    TextField("（未使用）", text: $label.name)
                    Text(shortcutText(label.sortOrder))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
            }
            if removedCount > 0 {
                Text("将从 \(removedCount) 个标签位置上去掉名字：这些标签会从所有照片上去掉。")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("完成") {
                    let trimmed = edited.map { label -> LabelRecord in
                        var label = label
                        label.name = label.name.trimmingCharacters(in: .whitespaces)
                        return label
                    }
                    dismiss()
                    model.saveLabels(trimmed)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { edited = model.labels }
    }

    private var removedCount: Int {
        edited.filter { label in
            label.name.trimmingCharacters(in: .whitespaces).isEmpty && (model.labels.first { $0.id == label.id }?.isInUse ?? false)
        }.count
    }

    private func nextColor(after color: String) -> String {
        let index = Self.palette.firstIndex(of: color) ?? -1
        return Self.palette[(index + 1) % Self.palette.count]
    }

    private func shortcutText(_ order: Int) -> String {
        order < 4 ? "\(order + 6)  ⌥\(order + 1)" : "⌥\(order + 1)"
    }
}

/// 快捷键速查表：从命令表生成，和菜单、键盘处理是同一份定义。
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快捷键").font(.title3.bold())
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(PhotoCommand.reference, id: \.0) { group, commands in
                        GridRow {
                            Text(group).font(.headline).padding(.top, 8)
                            Color.clear.frame(height: 1)
                        }
                        ForEach(commands, id: \.self) { command in
                            GridRow {
                                Text(command.shortcut.display)
                                    .font(.body.monospaced())
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                                Text(command.title)
                            }
                        }
                    }
                }
            }
            .frame(height: 420)
            Text("⇪ Caps Lock：自动前进，打星、打标签、标记后自动跳到下一张。文本框获得焦点时，单键快捷键让位给输入。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("好") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
