import Foundation
import os

nonisolated enum UsageWords: Sendable {
    static func count(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

nonisolated struct UsageDayRow: Codable, Sendable, Equatable, Identifiable {
    var date: String
    var wordCount: Int
    var takeCount: Int

    var id: String { date }
}

nonisolated enum UsageStatsRange: String, CaseIterable, Identifiable, Sendable {
    case today
    case last7
    case last30
    case last90
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .last7: "7 days"
        case .last30: "30 days"
        case .last90: "90 days"
        case .all: "All"
        }
    }

    /// Inclusive calendar days in the range. `all` is resolved from stored rows.
    var daySpan: Int? {
        switch self {
        case .today: 1
        case .last7: 7
        case .last30: 30
        case .last90: 90
        case .all: nil
        }
    }

    func startDayKey(now: Date, calendar: Calendar) -> String? {
        switch self {
        case .all:
            return nil
        case .today:
            return UsageCalendar.dayKey(for: now, calendar: calendar)
        case .last7:
            return UsageCalendar.dayKey(offset: -6, from: now, calendar: calendar)
        case .last30:
            return UsageCalendar.dayKey(offset: -29, from: now, calendar: calendar)
        case .last90:
            return UsageCalendar.dayKey(offset: -89, from: now, calendar: calendar)
        }
    }
}

nonisolated struct UsageChartDay: Sendable, Equatable, Identifiable {
    var date: Date
    var words: Int
    var takes: Int

    var id: Date { date }
}

nonisolated struct UsageStatsSnapshot: Sendable, Equatable {
    var days: [UsageDayRow]
    var totalWords: Int
    var totalTakes: Int

    static let empty = UsageStatsSnapshot(days: [], totalWords: 0, totalTakes: 0)

    func totals(
        for range: UsageStatsRange,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> (words: Int, takes: Int) {
        let today = UsageCalendar.dayKey(for: now, calendar: calendar)
        guard let start = range.startDayKey(now: now, calendar: calendar) else {
            return (totalWords, totalTakes)
        }
        var words = 0
        var takes = 0
        for day in days where day.date >= start && day.date <= today {
            words += day.wordCount
            takes += day.takeCount
        }
        return (words, takes)
    }

    func averageWordsPerDay(
        for range: UsageStatsRange,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Double {
        let words = totals(for: range, now: now, calendar: calendar).words
        let span = range.daySpan ?? max(days.count, 1)
        return Double(words) / Double(max(span, 1))
    }

    func chartDays(
        for range: UsageStatsRange,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [UsageChartDay] {
        let todayStart = calendar.startOfDay(for: now)
        let start: Date
        if let key = range.startDayKey(now: now, calendar: calendar),
           let date = UsageCalendar.date(fromDayKey: key, calendar: calendar) {
            start = calendar.startOfDay(for: date)
        } else if let oldest = days.min(by: { $0.date < $1.date }),
                  let date = UsageCalendar.date(fromDayKey: oldest.date, calendar: calendar) {
            start = calendar.startOfDay(for: date)
        } else {
            start = todayStart
        }

        let byKey = Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0) })
        var rows: [UsageChartDay] = []
        rows.reserveCapacity(max(calendar.dateComponents([.day], from: start, to: todayStart).day ?? 0, 0) + 1)
        var cursor = start
        while cursor <= todayStart {
            let key = UsageCalendar.dayKey(for: cursor, calendar: calendar)
            let stored = byKey[key]
            rows.append(
                UsageChartDay(
                    date: cursor,
                    words: stored?.wordCount ?? 0,
                    takes: stored?.takeCount ?? 0
                )
            )
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
            if rows.count >= UsageStatsStore.retentionDays { break }
        }
        return rows
    }

    func addingPending(words: Int, takes: Int, today: String) -> UsageStatsSnapshot {
        guard words != 0 || takes != 0 else { return self }
        var days = self.days
        if let index = days.firstIndex(where: { $0.date == today }) {
            days[index].wordCount += words
            days[index].takeCount += takes
        } else {
            days.append(UsageDayRow(date: today, wordCount: words, takeCount: takes))
            days.sort { $0.date > $1.date }
        }
        return UsageStatsSnapshot(
            days: days,
            totalWords: totalWords + words,
            totalTakes: totalTakes + takes
        )
    }
}

nonisolated enum UsageCalendar: Sendable {
    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func dayKey(offset: Int, from date: Date, calendar: Calendar) -> String {
        let start = calendar.startOfDay(for: date)
        let shifted = calendar.date(byAdding: .day, value: offset, to: start) ?? start
        return dayKey(for: shifted, calendar: calendar)
    }

    static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}

/// In-memory paste counters. `recordSuccessfulPaste` is two integer adds under a lock.
nonisolated enum UsageStats: Sendable {
    private struct Pending: Sendable {
        var words = 0
        var takes = 0
    }

    private static let pending = OSAllocatedUnfairLock(initialState: Pending())
    private static let flushLoopStarted = OSAllocatedUnfairLock(initialState: false)

    static func recordSuccessfulPaste(wordCount: Int) {
        pending.withLock {
            $0.words += wordCount
            $0.takes += 1
        }
    }

    static func peekPending() -> (words: Int, takes: Int) {
        pending.withLock { ($0.words, $0.takes) }
    }

    static func startBackgroundFlush() {
        let alreadyStarted = flushLoopStarted.withLock { started -> Bool in
            if started { return true }
            started = true
            return false
        }
        guard !alreadyStarted else { return }
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await flushPending()
            }
        }
    }

    static func flushPending(to store: UsageStatsStore = .shared) async {
        let batch = pending.withLock { state -> Pending in
            let copy = state
            state = Pending()
            return copy
        }
        guard batch.words != 0 || batch.takes != 0 else { return }
        await store.add(words: batch.words, takes: batch.takes)
    }
}

/// Disk-backed daily totals. Never call from `deliver`, the audio tap, or overlay show.
actor UsageStatsStore {
    static let shared = UsageStatsStore()
    static let retentionDays = 120

    private let fileURL: URL
    private var days: [String: UsageDayRow] = [:]
    private var loaded = false

    init(fileURL: URL = UsageStatsStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL(
        appSupport: URL = LocalModelPaths.applicationSupport()
    ) -> URL {
        appSupport
            .appendingPathComponent("Echo", isDirectory: true)
            .appendingPathComponent("stats.json", isDirectory: false)
    }

    func add(
        words: Int,
        takes: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        guard words != 0 || takes != 0 else { return }
        loadIfNeeded(now: now, calendar: calendar)
        let key = UsageCalendar.dayKey(for: now, calendar: calendar)
        var row = days[key] ?? UsageDayRow(date: key, wordCount: 0, takeCount: 0)
        row.wordCount += words
        row.takeCount += takes
        days[key] = row
        prune(now: now, calendar: calendar)
        persist()
    }

    func snapshot(
        now: Date = .now,
        calendar: Calendar = .current
    ) -> UsageStatsSnapshot {
        loadIfNeeded(now: now, calendar: calendar)
        prune(now: now, calendar: calendar)
        let rows = days.values.sorted { $0.date > $1.date }
        return UsageStatsSnapshot(
            days: rows,
            totalWords: rows.reduce(0) { $0 + $1.wordCount },
            totalTakes: rows.reduce(0) { $0 + $1.takeCount }
        )
    }

    private func loadIfNeeded(now: Date, calendar: Calendar) {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        days = Dictionary(uniqueKeysWithValues: payload.days.map { ($0.date, $0) })
        prune(now: now, calendar: calendar)
    }

    private func prune(now: Date, calendar: Calendar) {
        let cutoff = UsageCalendar.dayKey(
            offset: -(Self.retentionDays - 1),
            from: now,
            calendar: calendar
        )
        days = days.filter { $0.key >= cutoff }
    }

    private func persist() {
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let payload = Payload(days: days.values.sorted { $0.date < $1.date })
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private struct Payload: Codable {
        var days: [UsageDayRow]
    }
}
