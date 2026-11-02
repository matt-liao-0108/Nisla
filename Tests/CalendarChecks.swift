import Foundation
import AppKit

@main struct CalendarChecks {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let day = calendar.dateInterval(of: .day, for: date)!
        precondition(day.duration == 23 * 3600)
        precondition(AgendaRules.overlaps(start: day.start.addingTimeInterval(-3600), end: day.start.addingTimeInterval(3600), day: day))
        precondition(!AgendaRules.overlaps(start: day.end, end: day.end.addingTimeInterval(3600), day: day))
        precondition(!AgendaRules.overlaps(start: day.start.addingTimeInterval(-3600), end: day.start, day: day))
        print("PASS: DST-aware day boundaries, overnight events and exclusive all-day ends")
        let due = AgendaRules.dueDate(DateComponents(year: 2026, month: 3, day: 8), calendar: calendar)!
        precondition(calendar.isDate(due, inSameDayAs: date))
        precondition(AgendaRules.dueDate(nil) == nil)
        print("PASS: date-only and undated reminders")
        func entry(_ id: String, _ date: Date?) -> AgendaEntry {
            AgendaEntry(id: id, title: id, calendar: "Fixture", color: .systemBlue, start: date, end: nil, allDay: true)
        }
        let rows = [entry("undated", nil), entry("future", date.addingTimeInterval(3600)), entry("overdue", date.addingTimeInterval(-3600))]
        precondition(rows.sorted(by: AgendaRules.reminderOrder).map(\.id) == ["overdue", "future", "undated"])
        print("PASS: overdue-first reminder ordering; no real EventKit store or data accessed")
        calendar.firstWeekday = 2
        let leap = calendar.date(from: DateComponents(year: 2028, month: 2, day: 12))!
        let cells = AgendaRules.monthCells(for: leap, calendar: calendar)
        precondition(cells.count % 7 == 0 && cells.compactMap { $0 }.count == 29)
        precondition(calendar.component(.day, from: cells.compactMap { $0 }.first!) == 1)
        let last = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30))!
        let window = AgendaRules.window(for: last, calendar: calendar)!
        precondition(window.end >= calendar.date(byAdding: .day, value: 7, to: last)!)
        print("PASS: locale week start, leap-year month grid and cross-month upcoming agenda")
        let jan31 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31))!
        let feb = AgendaRules.shiftedMonth(from: jan31, by: 1, calendar: calendar)!
        precondition(calendar.component(.month, from: feb) == 2 && calendar.component(.day, from: feb) == 28)
        let march = AgendaRules.shiftedMonth(from: feb, by: 1, calendar: calendar)!
        precondition(calendar.component(.month, from: march) == 3 && calendar.component(.day, from: march) == 28)
        print("PASS: month arrows stay in the intended month at shorter month boundaries")
    }
}
