import PhotoAICore
import SwiftUI

/// 侧栏：图库、时间、卷（信息架构 §3.1）。收藏夹、人物、地点在后面的阶段加。
/// 已移除的卷和无卷关联照片不出现在侧栏。
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: VolumeRecord?
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.selection }, set: { if let item = $0 { model.selection = item } })) {
            Section("图库") {
                Label("全部照片", systemImage: "photo.on.rectangle").tag(SidebarItem.all)
                DisclosureGroup {
                    ForEach(model.importBatches) { batch in
                        HStack {
                            Text("\(batch.volumeName) · \(batch.startedAt.formatted(date: .abbreviated, time: .shortened))")
                            Spacer()
                            Text(batch.photoCount.formatted()).foregroundStyle(.secondary)
                        }
                        .tag(SidebarItem.importBatch(batch.id))
                    }
                } label: {
                    Label("最近导入", systemImage: "clock.arrow.circlepath")
                }
            }

            Section("时间") {
                ForEach(years, id: \.year) { year in
                    DisclosureGroup(isExpanded: expansion(year.year, defaultOpen: year.year == years.first?.year)) {
                        ForEach(year.months, id: \.month) { month in
                            DisclosureGroup(isExpanded: expansion(month.month, defaultOpen: month.month == years.first?.months.first?.month)) {
                                ForEach(month.days, id: \.day) { day in
                                    CountRow(title: "\(Int(day.day.suffix(2)) ?? 0) 日", count: day.count)
                                        .tag(SidebarItem.day(day.day))
                                }
                            } label: {
                                CountRow(title: "\(Int(month.month.suffix(2)) ?? 0) 月", count: month.count)
                                    .tag(SidebarItem.month(month.month))
                            }
                        }
                    } label: {
                        CountRow(title: year.year, count: year.count).tag(SidebarItem.year(year.year))
                    }
                }
                if model.undatedCount > 0 {
                    CountRow(title: "日期未知", count: model.undatedCount).tag(SidebarItem.undated)
                }
            }

            Section("卷") {
                ForEach(model.volumes) { volume in
                    let online = model.onlineVolumes[volume.id] != nil
                    HStack {
                        Image(systemName: online ? "circle.fill" : "circle")
                            .font(.system(size: 8))
                            .foregroundStyle(online ? .green : .secondary)
                        Text(volume.name)
                        Spacer()
                        Text((model.volumeCounts[volume.id] ?? 0).formatted()).foregroundStyle(.secondary)
                    }
                    .tag(SidebarItem.volume(volume.id))
                    .contextMenu {
                        Button("重新扫描") { model.enqueueScan(volume.id) }
                            .disabled(!online)
                        Button("改名…") {
                            newName = volume.name
                            renaming = volume
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .alert("给卷改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名字", text: $newName)
            Button("取消", role: .cancel) { renaming = nil }
            Button("改名") {
                if let renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    model.rename(renaming.id, to: newName.trimmingCharacters(in: .whitespaces))
                }
                renaming = nil
            }
        }
    }

    @State private var expanded: [String: Bool] = [:]

    private func expansion(_ key: String, defaultOpen: Bool) -> Binding<Bool> {
        Binding(get: { expanded[key] ?? defaultOpen }, set: { expanded[key] = $0 })
    }

    struct YearGroup { var year: String; var count: Int; var months: [MonthGroup] }
    struct MonthGroup { var month: String; var count: Int; var days: [DayCount] }

    /// 按天的计数折成 年 → 月 → 日。`dayCounts` 已按日期倒序。
    private var years: [YearGroup] {
        var result: [YearGroup] = []
        for day in model.dayCounts {
            let year = String(day.day.prefix(4))
            let month = String(day.day.prefix(7))
            if result.last?.year != year { result.append(YearGroup(year: year, count: 0, months: [])) }
            result[result.count - 1].count += day.count
            if result[result.count - 1].months.last?.month != month {
                result[result.count - 1].months.append(MonthGroup(month: month, count: 0, days: []))
            }
            let monthIndex = result[result.count - 1].months.count - 1
            result[result.count - 1].months[monthIndex].count += day.count
            result[result.count - 1].months[monthIndex].days.append(day)
        }
        return result
    }
}

private struct CountRow: View {
    var title: String
    var count: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(count.formatted()).foregroundStyle(.secondary)
        }
    }
}
