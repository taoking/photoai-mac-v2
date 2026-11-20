import AppKit
import PhotoAICore
import SwiftUI
import UniformTypeIdentifiers

/// 菜单“图库 → 从文件导入星级…”（迭代 I-2）：选一个 `.md` / `.txt`，先列出要改哪些照片，确认后一次写进库，`⌘Z` 整批撤销。
extension AppModel {
    func chooseRatingFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType("net.daringfireball.markdown"), .plainText].compactMap { $0 }
        panel.message = "每行写：编号或文件名  星级（1–5），如 DSC01064  4"
        panel.prompt = "读取"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prepareRatingImport(from: url)
    }

    /// 读文件、按命令行的规则匹配照片，弹出确认面板。不写库。
    func prepareRatingImport(from url: URL) {
        guard let reader else { return }
        do {
            var encoding = String.Encoding.utf8
            let text = try (try? String(contentsOf: url, encoding: .utf8)) ?? String(contentsOf: url, usedEncoding: &encoding)
            let plan = try reader.planRatingImport(RatingFile(text: text))
            activeSheet = .ratingImport(fileName: url.lastPathComponent, plan)
        } catch {
            errorMessage = "读不了“\(url.lastPathComponent)”：\(error.localizedDescription)"
        }
    }

    func applyRatingImport(_ plan: RatingImportPlan) {
        commit(plan.edit, title: "导入星级", advance: false)
        show("导入星级：\(plan.changedCount.formatted()) 张改了星级")
    }
}

/// 导入前的确认：要改哪些、没对上哪些。
struct RatingImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let fileName: String
    let plan: RatingImportPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("从「\(fileName)」导入星级").font(.title3.bold())
            if plan.changes.isEmpty {
                Text("没有可以导入的照片。每行写：编号或文件名  星级（1–5），如 DSC01064  4。")
                    .foregroundStyle(.secondary)
            } else {
                summary
            }
            details
            HStack {
                Text("导入后可以用 ⌘Z 整批撤销。").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("导入（\(plan.changedCount.formatted()) 张）") {
                    dismiss()
                    model.applyRatingImport(plan)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(plan.changedCount == 0)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var summary: some View {
        let unchanged = plan.changes.count - plan.changedCount
        return VStack(alignment: .leading, spacing: 6) {
            Text("匹配到 \(plan.changes.count.formatted()) 张照片，\(plan.changedCount.formatted()) 张星级会变"
                + (unchanged > 0 ? "，\(unchanged.formatted()) 张原本就是" : "") + "。")
            HStack(spacing: 14) {
                ForEach(1...5, id: \.self) { rating in
                    if let count = plan.countsByRating[rating] {
                        Text("\(String(repeating: "★", count: rating))  \(count.formatted()) 张").monospacedDigit()
                    }
                }
            }
            .font(.callout)
        }
    }

    private var details: some View {
        let changed = plan.changes.filter { $0.photo.rating != $0.rating }
        return VStack(alignment: .leading, spacing: 4) {
            group("要改的 \(changed.count.formatted()) 张", changed.map { change in
                "\(change.photo.baseName)  \(stars(change.photo.rating)) → \(stars(change.rating))"
            }, expanded: true)
            group("没匹配到照片 \(plan.unmatched.count.formatted()) 行", plan.unmatched.map { "第 \($0.line) 行  \($0.key)  \($0.rating)" })
            group("同一张写了不同星级，以后面的为准 \(plan.conflicts.count.formatted()) 张", plan.conflicts.map { conflict in
                "\(conflict.photo.baseName)  " + conflict.ratings.map(String.init).joined(separator: " → ")
            })
            group("同一编号还有更早拍的照片，没改 \(plan.skipped.count.formatted()) 张", plan.skipped.map { photo in
                "\(photo.baseName)  \(photo.captureDate ?? "没有拍摄时间")"
            })
            group("格式不对、忽略 \(plan.ignored.count.formatted()) 行", plan.ignored.map { "第 \($0.line) 行  \($0.text)" })
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ lines: [String], expanded: Bool = false) -> some View {
        if !lines.isEmpty { ImportDetailGroup(title: title, lines: lines, isExpanded: expanded) }
    }

    private func stars(_ rating: Int) -> String { rating == 0 ? "无星" : "★\(rating)" }
}

/// 确认面板里一类明细，可以展开 / 收起。
private struct ImportDetailGroup: View {
    /// 最多列这么多行。
    static let listLimit = 200

    let title: String
    let lines: [String]
    @State var isExpanded: Bool

    var body: some View {
        DisclosureGroup(title, isExpanded: $isExpanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.prefix(Self.listLimit).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout.monospaced()).textSelection(.enabled)
                    }
                    if lines.count > Self.listLimit {
                        Text("…还有 \((lines.count - Self.listLimit).formatted()) 行").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
    }
}
