import SwiftUI
import EventKit

struct CalendarSettings: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var calendar = CalendarStore.shared
    var body: some View {
        Form {
            Section(L10n.text("系统日历与提醒事项")) {
                Text(L10n.text("读取本机 Calendar 已接入的日历（含可访问的节假日订阅）和 Reminders 列表。只读展示，不创建、修改或删除内容，不上传至 AI 服务。"))
                    .font(.caption).foregroundStyle(.secondary)
                permissionRow(L10n.text("日历"), granted: calendar.hasEvents, reminders: false)
                permissionRow(L10n.text("提醒事项"), granted: calendar.hasReminders, reminders: true)
                Text(L10n.text("macOS 将读取权限称为“完全访问”；Nisla 仅使用查询接口。授权后自动展示系统可访问的全部日历、订阅和提醒事项列表，无需重复勾选。"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("刷新来源")) { calendar.refresh() }
                if let error = calendar.error { Text(L10n.text(error)).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }
            ForEach([false, true], id: \.self) { reminders in
                Section(reminders ? L10n.text("系统提醒事项列表") : L10n.text("系统日历与订阅（含节假日）")) {
                    ForEach(calendar.sources.filter { $0.reminders == reminders }) { source in
                            HStack {
                                Circle().fill(Color(nsColor: source.color)).frame(width: 8, height: 8)
                                Text(source.title)
                                Text(source.account).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: "checkmark").foregroundStyle(.secondary)
                            }
                    }
                    if calendar.sources.filter({ $0.reminders == reminders }).isEmpty {
                        Text(L10n.text("授权后列出系统可访问的来源。没有节假日时，请先在 macOS 日历中添加节假日订阅。")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.formStyle(.grouped).onAppear { calendar.refresh() }
    }

    private func permissionRow(_ title: String, granted: Bool, reminders: Bool) -> some View {
        HStack {
            Label(granted ? L10n.text("\(title)：已授权") : L10n.text("\(title)：未授权"), systemImage: granted ? "checkmark.circle" : "lock")
            Spacer()
            if !granted { Button(L10n.text("授权读取")) { Task { await calendar.authorize(reminders: reminders) } } }
        }
    }
}

struct CalendarShelf: View {
    @ObservedObject private var localization = AppLocalization.shared
    @EnvironmentObject private var store: PinStore
    @ObservedObject private var calendar = CalendarStore.shared
    var body: some View {
        CalendarDashboard(date: $calendar.selectedDate, events: calendar.events, reminders: calendar.reminders,
                          hasEvents: calendar.hasEvents, hasReminders: calendar.hasReminders,
                          loading: calendar.loading, error: calendar.error,
                          authorize: { reminders in Task { await calendar.authorize(reminders: reminders) } },
                          refresh: { calendar.refresh() },
                          onHeightChange: { rows in
                              if store.calendarWeekRows != rows { store.calendarWeekRows = rows }
                          })
        .onChange(of: calendar.selectedDate) { _, _ in calendar.refresh() }
        .task {
            calendar.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { calendar.refresh() }
            }
        }
    }

}
