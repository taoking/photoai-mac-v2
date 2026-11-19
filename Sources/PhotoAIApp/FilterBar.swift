import PhotoAICore
import SwiftUI

/// 筛选条：一行，常用条件点一下即生效（信息架构 §3.3.1）。
///
/// `≥/=` 切换至少 / 正好；★1–★5（正好模式多一个“未评分”）；正在用的标签；Pick / Reject / 未标记；
/// “更多”里是文件类型和“无标签”。“刷新结果”只在有照片已不符合条件时出现，“清除”只在有条件时出现。
struct FilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let filter = model.currentFilter
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                group {
                    chip(filter.starMode == .atLeast ? "≥" : "=", on: false, help: "切换：至少 N 星 / 正好 N 星") {
                        edit { $0.toggleStarMode() }
                    }
                    ForEach(1...5, id: \.self) { n in
                        chip("★\(n)", on: filter.stars.contains(n)) { edit { $0.toggleStar(n) } }
                    }
                    if filter.starMode == .exactly {
                        chip("未评分", on: filter.stars.contains(0)) { edit { $0.toggleStar(0) } }
                    }
                }
                group {
                    ForEach(model.labels.filter(\.isInUse)) { label in
                        chip(label.name, on: filter.labels.contains(label.id), color: Color(nsColor: NSColor(hex: label.color))) {
                            edit { $0.toggleLabel(label.id) }
                        }
                    }
                }
                group {
                    ForEach([Flag.pick, .reject, .none], id: \.self) { flag in
                        chip(flag.displayName, on: filter.flags.contains(flag)) { edit { $0.toggleFlag(flag) } }
                    }
                }
                group {
                    let moreCount = filter.kinds.count + (filter.noLabel ? 1 : 0)
                    Menu {
                        ForEach(PhotoFilter.Kind.allCases, id: \.self) { kind in
                            Toggle(kind.rawValue, isOn: Binding(get: { filter.kinds.contains(kind) }, set: { _ in edit { $0.toggleKind(kind) } }))
                        }
                        Divider()
                        Toggle("无标签", isOn: Binding(get: { filter.noLabel }, set: { value in edit { $0.noLabel = value } }))
                    } label: {
                        Text(moreCount > 0 ? "更多 \(moreCount)" : "更多")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .background(moreCount > 0 ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    if model.staleCount > 0 {
                        Button("刷新结果（\(model.staleCount) 张已不符合）") { model.refreshResult() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help("按当前条件重新筛选")
                    }
                    if !filter.isEmpty {
                        chip("清除", on: false) { model.clearFilter() }
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 34)
    }

    private func edit(_ change: (inout PhotoFilter) -> Void) {
        var filter = model.currentFilter
        change(&filter)
        model.currentFilter = filter
    }

    @ViewBuilder
    private func group(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 2) { content() }
            .padding(.trailing, 8)
    }

    private func chip(_ title: String, on: Bool, color: Color? = nil, help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let color { Circle().fill(color).frame(width: 8, height: 8) }
                Text(title)
            }
            .font(.callout)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(on ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(on ? Color.white : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
    }
}
