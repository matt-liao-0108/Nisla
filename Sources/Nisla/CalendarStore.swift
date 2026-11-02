import AppKit
import Combine
import EventKit

struct CalendarSource: Identifiable {
    let id: String
    let title: String
    let account: String
    let color: NSColor
    let reminders: Bool
}

struct AgendaEntry: Identifiable {
    let id: String
    let title: String
    let calendar: String
    let color: NSColor
    let start: Date?
    let end: Date?
    let allDay: Bool
}

enum AgendaRules {
    static func window(for date: Date, calendar: Calendar = .current) -> DateInterval? {
        guard let month = calendar.dateInterval(of: .month, for: date),
              let weekEnd = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: date)) else { return nil }
        return DateInterval(start: month.start, end: max(month.end, weekEnd))
    }

    static func monthCells(for date: Date, calendar: Calendar = .current) -> [Date?] {
        guard let month = calendar.dateInterval(of: .month, for: date), let days = calendar.range(of: .day, in: .month, for: date) else { return [] }
        let leading = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
        let total = ((leading + days.count + 6) / 7) * 7
        return (0..<total).map { index in
            let offset = index - leading
            return offset >= 0 && offset < days.count ? calendar.date(byAdding: .day, value: offset, to: month.start) : nil
        }
    }
    static func shiftedMonth(from date: Date, by amount: Int, calendar: Calendar = .current) -> Date? {
        guard let month = calendar.dateInterval(of: .month, for: date),
              let target = calendar.date(byAdding: .month, value: amount, to: month.start),
              let days = calendar.range(of: .day, in: .month, for: target) else { return nil }
        let selectedDay = min(calendar.component(.day, from: date), days.count)
        return calendar.date(byAdding: .day, value: selectedDay - 1, to: target)
    }
    static func dueDate(_ components: DateComponents?, calendar: Calendar = .current) -> Date? {
        guard var components else { return nil }
        if components.calendar == nil { components.calendar = calendar }
        return components.date
    }

    static func overlaps(start: Date, end: Date, day: DateInterval) -> Bool {
        start < day.end && end > day.start
    }

    static func reminderOrder(_ lhs: AgendaEntry, _ rhs: AgendaEntry) -> Bool {
        let a = lhs.start ?? .distantFuture, b = rhs.start ?? .distantFuture
        return a == b ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending : a < b
    }
}

@MainActor final class CalendarStore: ObservableObject {
    static let shared = CalendarStore()
    @Published private(set) var sources: [CalendarSource] = []
    @Published private(set) var events: [AgendaEntry] = []
    @Published private(set) var reminders: [AgendaEntry] = []
    @Published private(set) var eventAccess = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var reminderAccess = EKEventStore.authorizationStatus(for: .reminder)
    @Published private(set) var loading = false
    @Published private(set) var authorizationInProgress = false
    @Published var error: String?
    @Published var selectedDate = Date()
    private let eventStore = EKEventStore()
    private var observers = Set<AnyCancellable>()
    private var fetchToken: Any?
    private var generation = UUID()

    init() {
        NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: eventStore)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &observers)
        // No automatic permission prompts or private-data reads at initialization.
    }

    var hasEvents: Bool { eventAccess == .fullAccess }
    var hasReminders: Bool { reminderAccess == .fullAccess }

    func authorize(reminders: Bool) async {
        guard !authorizationInProgress else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            error = "请运行打包后的 Nisla.app，再授权日历与提醒事项；swift run 不带权限用途说明。"
            return
        }
        error = nil
        let status = EKEventStore.authorizationStatus(for: reminders ? .reminder : .event)
        if status == .notDetermined { authorizationInProgress = true }
        defer { authorizationInProgress = false }
        do {
            let granted: Bool
            if reminders { granted = try await eventStore.requestFullAccessToReminders() }
            else { granted = try await eventStore.requestFullAccessToEvents() }
            if !granted { error = "未获得访问权限，可在系统设置 → 隐私与安全性中允许 Nisla。" }
            eventStore.reset()
        } catch { self.error = "授权失败：\(error.localizedDescription)" }
        refresh()
    }

    func refresh() {
        generation = UUID()
        let current = generation
        if let fetchToken { eventStore.cancelFetchRequest(fetchToken) }
        fetchToken = nil; loading = false
        eventAccess = EKEventStore.authorizationStatus(for: .event)
        reminderAccess = EKEventStore.authorizationStatus(for: .reminder)
        let calendars = (hasEvents ? eventStore.calendars(for: .event) : [])
        let lists = (hasReminders ? eventStore.calendars(for: .reminder) : [])
        sources = (calendars.map { source($0, reminders: false) } + lists.map { source($0, reminders: true) })
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if hasEvents, !calendars.isEmpty,
           let range = AgendaRules.window(for: selectedDate) {
            let predicate = eventStore.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)
            events = eventStore.events(matching: predicate)
                .filter { AgendaRules.overlaps(start: $0.startDate, end: $0.endDate, day: range) }
                .sorted { $0.startDate < $1.startDate }
                .enumerated().map { index, event in
                    AgendaEntry(id: "\(event.eventIdentifier ?? "event")-\(index)", title: event.title ?? "无标题日程", calendar: event.calendar.title, color: NSColor(cgColor: event.calendar.cgColor) ?? .systemBlue, start: event.startDate, end: event.endDate, allDay: event.isAllDay)
                }
        } else { events = [] }
        guard hasReminders, !lists.isEmpty else { reminders = []; return }
        loading = true
        let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
        fetchToken = eventStore.fetchReminders(matching: predicate) { [weak self] rows in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.loading = false; self.fetchToken = nil
                guard let rows else { self.error = "暂时无法读取提醒事项，请刷新重试。"; return }
                self.reminders = rows.map { reminder in
                    AgendaEntry(id: reminder.calendarItemIdentifier, title: reminder.title ?? "无标题提醒", calendar: reminder.calendar.title, color: NSColor(cgColor: reminder.calendar.cgColor) ?? .systemOrange, start: AgendaRules.dueDate(reminder.dueDateComponents), end: nil, allDay: reminder.dueDateComponents?.hour == nil)
                }.sorted(by: AgendaRules.reminderOrder)
            }
        }
    }

    private func source(_ calendar: EKCalendar, reminders: Bool) -> CalendarSource {
        CalendarSource(id: calendar.calendarIdentifier, title: calendar.title, account: calendar.source.title, color: NSColor(cgColor: calendar.cgColor) ?? .systemBlue, reminders: reminders)
    }
}
