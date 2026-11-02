import SwiftUI

/// Pure presentation: also used by fixture previews without opening EventKit.
struct CalendarDashboard: View {
    @ObservedObject private var localization = AppLocalization.shared
    @Binding var date: Date
    let events: [AgendaEntry]
    let reminders: [AgendaEntry]
    let hasEvents: Bool
    let hasReminders: Bool
    let loading: Bool
    let error: String?
    let authorize: (Bool) -> Void
    let refresh: () -> Void
    var onHeightChange: (Int) -> Void = { _ in }
    @State private var showReminders = false
    private let accent = Color(red: 1, green: 0.40, blue: 0.34)
    private var calendar: Calendar {
        var value = Calendar.current
        value.locale = localization.locale
        return value
    }
    private var requiredWeekRows: Int {
        if error != nil || (showReminders ? !hasReminders : !hasEvents) { return 6 }
        return AgendaRules.monthCells(for: date).count / 7
    }

    private var upcoming: [AgendaEntry] {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        return events.filter { ($0.start ?? .distantFuture) < end && ($0.end ?? $0.start ?? .distantPast) > start }
    }

    private var groups: [(Date, [AgendaEntry])] {
        let start = calendar.startOfDay(for: date)
        let grouped = Dictionary(grouping: upcoming) { entry in calendar.startOfDay(for: max(entry.start ?? start, start)) }
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted { lhs, rhs in
            lhs.allDay != rhs.allDay ? lhs.allDay : (lhs.start ?? .distantPast) < (rhs.start ?? .distantPast)
        }) }
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    agendaToolbar
                    modePicker
                    agenda
                    if let error { Text(L10n.text(error)).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                month.frame(width: max(174, geometry.size.width * 0.43))
            }.padding(.horizontal, 7).padding(.top, 3)
        }
        .onChange(of: requiredWeekRows, initial: true) { _, rows in onHeightChange(rows) }
    }

    private var agendaToolbar: some View {
        HStack(spacing: 4) {
            Text(dateTitle).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise").frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)).help(L10n.text("刷新日历与待办"))
            Button { date = .now } label: {
                Text(L10n.text("今天")).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent).frame(width: 32, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).help(L10n.text("回到今天"))
        }.frame(height: 24)
    }

    private var modePicker: some View {
        HStack(spacing: 4) {
            modeButton(L10n.text("日程"), selected: !showReminders) { showReminders = false }
            modeButton(L10n.text("待办 \(reminders.count)"), selected: showReminders) { showReminders = true }
            Spacer(minLength: 0)
        }.frame(height: 25)
    }

    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .white : .white.opacity(0.55))
                .padding(.horizontal, 9).frame(height: 23)
                .background(selected ? Color.white.opacity(0.13) : .clear, in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var dateTitle: AttributedString {
        var heading = AttributedString(date.formatted(.dateTime.weekday(.abbreviated).locale(localization.locale)).uppercased())
        heading.foregroundColor = accent
        var day = AttributedString("  " + date.formatted(.dateTime.day().locale(localization.locale)))
        day.foregroundColor = .white
        var detail = AttributedString("  " + (showReminders ? L10n.text("待办 \(reminders.count)") : "W\(calendar.component(.weekOfYear, from: date))"))
        detail.foregroundColor = accent.opacity(0.55)
        heading += day
        heading += detail
        return heading
    }

    @ViewBuilder private var agenda: some View {
        if showReminders ? !hasReminders : !hasEvents {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: showReminders ? "checklist" : "calendar.badge.clock").font(.system(size: 24, weight: .light)).foregroundStyle(accent.opacity(0.8))
                Text(showReminders ? L10n.text("让待办触手可及") : L10n.text("把日程放在眼前")).font(.system(size: 13, weight: .medium))
                Text(L10n.text("授权后自动同步系统全部来源")).font(.system(size: 10)).foregroundStyle(.secondary)
                Button { authorize(showReminders) } label: {
                    Text(showReminders ? L10n.text("连接提醒事项") : L10n.text("连接系统日历")).font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 7).background(.white.opacity(0.10), in: Capsule())
                }.buttonStyle(.plain)
            }.frame(maxHeight: .infinity, alignment: .center)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if showReminders {
                        if reminders.isEmpty { empty(loading ? L10n.text("正在读取…") : L10n.text("待办都处理好了"), subtitle: L10n.text("这里显示系统提醒事项")) }
                        ForEach(reminders) { entry in entryRow(entry, reminder: true) }
                    } else {
                        if groups.isEmpty { empty(L10n.text("接下来很轻松"), subtitle: L10n.text("未来 7 天暂无日程或节假日")) }
                        ForEach(groups, id: \.0) { day, entries in
                            if !calendar.isDate(day, inSameDayAs: date) {
                                Text(day.formatted(.dateTime.month().day().weekday(.abbreviated).locale(localization.locale)).uppercased())
                                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.4)).padding(.top, 2)
                            }
                            ForEach(entries) { entry in entryRow(entry, reminder: false) }
                        }
                    }
                }
            }.scrollIndicators(.hidden)
        }
    }

    private func empty(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35)).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 12)
    }

    private func entryRow(_ entry: AgendaEntry, reminder: Bool) -> some View {
        HStack(spacing: 8) {
            if reminder { Image(systemName: "circle").font(.system(size: 13)).foregroundStyle(Color(nsColor: entry.color)) }
            else { RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: entry.color)).frame(width: 2, height: 23) }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.system(size: 11, weight: .medium)).foregroundStyle(Color(nsColor: entry.color)).lineLimit(1)
                Text(timeLabel(entry, reminder: reminder)).font(.system(size: 9)).foregroundStyle(Color(nsColor: entry.color).opacity(0.8)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 7).padding(.vertical, 4)
            .background(Color(nsColor: entry.color).opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
            .help(entry.title + " · " + entry.calendar)
    }

    private func timeLabel(_ entry: AgendaEntry, reminder: Bool) -> String {
        guard let start = entry.start else { return L10n.text("无截止日期 · ") + entry.calendar }
        if reminder { return start.formatted(Date.FormatStyle(date: .abbreviated, time: entry.allDay ? .omitted : .shortened).locale(localization.locale)) }
        if entry.allDay { return L10n.text("全天 · ") + entry.calendar }
        return start.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(localization.locale)) + " – " + (entry.end?.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(localization.locale)) ?? "")
    }

    private var month: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                Text(date.formatted(.dateTime.month(.abbreviated).year().locale(localization.locale)).uppercased())
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(accent).lineLimit(1)
                Spacer(minLength: 0)
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help(L10n.text("上个月"))
                    .accessibilityLabel(L10n.text("上个月"))
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help(L10n.text("下个月"))
                    .accessibilityLabel(L10n.text("下个月"))
            }.frame(height: 24)
            let symbols = calendar.veryShortStandaloneWeekdaySymbols
            HStack(spacing: 0) {
                ForEach(0..<7) { index in
                    Text(symbols[(index + calendar.firstWeekday - 1) % 7]).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35)).frame(maxWidth: .infinity)
                }
            }
            let cells = AgendaRules.monthCells(for: date)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 1) {
                ForEach(cells.indices, id: \.self) { index in
                    if let day = cells[index] { dayButton(day) }
                    else { Color.clear.frame(height: 20) }
                }
            }
        }
    }

    private func shiftMonth(_ amount: Int) {
        if let next = AgendaRules.shiftedMonth(from: date, by: amount, calendar: calendar) { date = next }
    }

    private func dayButton(_ day: Date) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: date)
        let today = calendar.isDateInToday(day)
        let hasEvent = events.contains { entry in
            guard let range = calendar.dateInterval(of: .day, for: day), let start = entry.start, let end = entry.end else { return false }
            return AgendaRules.overlaps(start: start, end: end, day: range)
        }
        return Button { date = day } label: {
            Text("\(calendar.component(.day, from: day))").font(.system(size: 10, weight: selected ? .bold : .medium))
                .foregroundStyle(selected ? .white : today ? accent : calendar.isDateInWeekend(day) ? .white.opacity(0.4) : .white.opacity(0.85))
                .frame(maxWidth: .infinity).frame(height: 20)
                .background { if selected { Circle().fill(accent).frame(width: 20, height: 20) } }
                .overlay(alignment: .bottom) { if hasEvent && !selected { Circle().fill(accent.opacity(0.9)).frame(width: 2, height: 2) } }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(day.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(localization.locale)))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
