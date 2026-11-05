import Foundation
import ReqlingKit

/// Runs started on one calendar day, titled Today, Yesterday, or the date.
struct RunHistoryDay: Identifiable, Equatable {
    struct Row: Identifiable, Equatable {
        let run: RunSummary
        let time: String

        var id: RunID {
            run.id
        }
    }

    let start: Date
    let title: String
    let runs: [Row]

    /// Its first run's: a clock set back can repeat a day further down, so the date alone may not be unique.
    var id: RunID? {
        runs.first?.id
    }

    /// Keeps the runs' order, newest first, so days come out newest first too.
    static func group(_ runs: [RunSummary], formats: RunDateFormats, now: Date = Date()) -> [RunHistoryDay] {
        var days: [RunHistoryDay] = []
        var start: Date?
        var rows: [Row] = []
        func closeDay() {
            if let start, !rows.isEmpty {
                days.append(RunHistoryDay(start: start, title: formats.dayTitle(start, now: now), runs: rows))
            }
        }
        for run in runs {
            let day = formats.calendar.startOfDay(for: run.startedAt)
            if day != start {
                closeDay()
                start = day
                rows = []
            }
            rows.append(Row(run: run, time: formats.time(run.startedAt)))
        }
        closeDay()
        return days
    }
}

/// Dates as the window's locale and time zone show them, which snapshots pin. Equal when they format alike, so a
/// memo keyed on them survives re-renders.
struct RunDateFormats: Equatable {
    let calendar: Calendar
    private let timeStyle: Date.FormatStyle
    private let dayStyle: Date.FormatStyle
    private let stampStyle: Date.FormatStyle

    init(locale: Locale, calendar: Calendar, timeZone: TimeZone) {
        var calendar = calendar
        calendar.timeZone = timeZone
        self.calendar = calendar
        timeStyle = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone)
        dayStyle = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone)
        stampStyle = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone)
    }

    func time(_ date: Date) -> String {
        date.formatted(timeStyle)
    }

    /// A date and time, for naming one run on its own.
    func stamp(_ date: Date) -> String {
        date.formatted(stampStyle)
    }

    func dayTitle(_ start: Date, now: Date) -> String {
        if calendar.isDate(start, inSameDayAs: now) {
            return "Today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(start, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return start.formatted(dayStyle)
    }
}
