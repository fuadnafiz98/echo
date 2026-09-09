import Foundation
import os

nonisolated enum UsageWords: Sendable {
    static func count(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

/// One successful paste. `ms` is stop → transcript ready, before cleanup / paste / polish.
nonisolated struct UsageTake: Codable, Sendable, Equatable {
    var t: Int64
    var w: Int
    var ms: Int?

    var words: Int { w }
    var speechToTextMilliseconds: Int? { ms }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(t)) }

    init(t: Int64, words: Int, speechToTextMilliseconds: Int? = nil) {
        self.t = t
        self.w = words
        self.ms = speechToTextMilliseconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        t = try container.decode(Int64.self, forKey: .t)
        w = try container.decode(Int.self, forKey: .w)
        ms = try container.decodeIfPresent(Int.self, forKey: .ms)
    }

    enum CodingKeys: String, CodingKey {
        case t
        case w
        case ms
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(t, forKey: .t)
        try container.encode(w, forKey: .w)
        try container.encodeIfPresent(ms, forKey: .ms)
    }
}

/// v1 `stats.json` daily rollup. Kept only to migrate into takes.
nonisolated struct UsageDayRow: Codable, Sendable, Equatable, Identifiable {
    var date: String
    var wordCount: Int
    var takeCount: Int

    var id: String { date }
}

nonisolated enum UsageStatsRange: String, CaseIterable, Identifiable, Sendable {
    case minutes15
    case hour
    case hours24
    case days15
    case days90

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minutes15: "15 minutes"
        case .hour: "1 hour"
        case .hours24: "24 hours"
        case .days15: "15 days"
        case .days90: "90 days"
        }
    }

    var usesCalendarDays: Bool {
        switch self {
        case .minutes15, .hour, .hours24: false
        case .days15, .days90: true
        }
    }

    var duration: TimeInterval {
        switch self {
        case .minutes15: 15 * 60
        case .hour: 60 * 60
        case .hours24: 24 * 60 * 60
        case .days15: 15 * 24 * 60 * 60
        case .days90: 90 * 24 * 60 * 60
        }
    }

    var bucketCount: Int {
        switch self {
        case .minutes15: 15
        case .hour: 30
        case .hours24: 24
        case .days15: 15
        case .days90: 90
        }
    }

    var bucketWidth: TimeInterval {
        duration / Double(bucketCount)
    }

    var bucketTitle: String {
        switch self {
        case .minutes15: "one minute"
        case .hour: "two minutes"
        case .hours24: "one hour"
        case .days15, .days90: "one day"
        }
    }

    var axisFormat: Date.FormatStyle {
        switch self {
        case .minutes15:
            .dateTime.hour().minute()
        case .hour, .hours24:
            .dateTime.hour().minute()
        case .days15, .days90:
            .dateTime.month(.abbreviated).day()
        }
    }

    func window(now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        if usesCalendarDays {
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -(bucketCount - 1), to: today) ?? today
            let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
            return (start, end)
        }
        return (now.addingTimeInterval(-duration), now)
    }
}

nonisolated struct UsageChartBucket: Sendable, Equatable, Identifiable {
    var date: Date
    var words: Int
    var takes: Int

    var id: Date { date }
}

nonisolated struct UsageStatsSnapshot: Sendable, Equatable {
    var buckets: [UsageChartBucket]
    var totalWords: Int
    var totalTakes: Int
    var averageSpeechToTextMilliseconds: Double?
    var domain: ClosedRange<Date>

    static let empty = UsageStatsSnapshot(
        buckets: [],
        totalWords: 0,
        totalTakes: 0,
        averageSpeechToTextMilliseconds: nil,
        domain: Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 1)
    )
}

nonisolated enum UsageTakeIndex: Sendable {
    static func firstIndex(in takes: [UsageTake], atOrAfter timestamp: Int64) -> Int {
        var low = 0
        var high = takes.count
        while low < high {
            let mid = (low + high) / 2
            if takes[mid].t < timestamp {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

nonisolated enum UsageStatsAggregator: Sendable {
    static func snapshot(
        takes: [UsageTake],
        range: UsageStatsRange,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> UsageStatsSnapshot {
        let window = range.window(now: now, calendar: calendar)
        let start = window.start
        let end = window.end
        let count = range.bucketCount
        var buckets = makeEmptyBuckets(range: range, start: start, calendar: calendar)
        var words = 0
        var takeCount = 0
        var sttSum = 0
        var sttCount = 0

        let startTs = Int64(start.timeIntervalSince1970)
        let endTs = Int64(now.timeIntervalSince1970)
        var index = UsageTakeIndex.firstIndex(in: takes, atOrAfter: startTs)
        while index < takes.count {
            let take = takes[index]
            if take.t > endTs { break }
            if let bucketIndex = bucketIndex(
                for: take,
                range: range,
                start: start,
                count: count,
                calendar: calendar
            ) {
                buckets[bucketIndex].words += take.words
                buckets[bucketIndex].takes += 1
                words += take.words
                takeCount += 1
                if let ms = take.ms {
                    sttSum += ms
                    sttCount += 1
                }
            }
            index += 1
        }

        let average = sttCount == 0 ? nil : Double(sttSum) / Double(sttCount)
        return UsageStatsSnapshot(
            buckets: buckets,
            totalWords: words,
            totalTakes: takeCount,
            averageSpeechToTextMilliseconds: average,
            domain: start...end
        )
    }

    static func lastSpeechToTextMilliseconds(in takes: [UsageTake]) -> Int? {
        for take in takes.reversed() {
            if let ms = take.ms { return ms }
        }
        return nil
    }

    static func totals(in takes: [UsageTake]) -> (words: Int, takes: Int) {
        var words = 0
        for take in takes {
            words += take.words
        }
        return (words, takes.count)
    }

    private static func makeEmptyBuckets(
        range: UsageStatsRange,
        start: Date,
        calendar: Calendar
    ) -> [UsageChartBucket] {
        let count = range.bucketCount
        var buckets: [UsageChartBucket] = []
        buckets.reserveCapacity(count)
        if range.usesCalendarDays {
            var cursor = start
            for _ in 0..<count {
                buckets.append(UsageChartBucket(date: cursor, words: 0, takes: 0))
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor)
                    ?? cursor.addingTimeInterval(24 * 60 * 60)
            }
        } else {
            let width = range.bucketWidth
            for i in 0..<count {
                buckets.append(
                    UsageChartBucket(
                        date: start.addingTimeInterval(Double(i) * width),
                        words: 0,
                        takes: 0
                    )
                )
            }
        }
        return buckets
    }

    private static func bucketIndex(
        for take: UsageTake,
        range: UsageStatsRange,
        start: Date,
        count: Int,
        calendar: Calendar
    ) -> Int? {
        if range.usesCalendarDays {
            let day = calendar.startOfDay(for: take.date)
            let offset = calendar.dateComponents([.day], from: start, to: day).day ?? 0
            guard offset >= 0, offset < count else { return nil }
            return offset
        }
        let elapsed = take.date.timeIntervalSince(start)
        guard elapsed >= 0 else { return nil }
        let raw = Int(elapsed / range.bucketWidth)
        if raw < 0 { return nil }
        return min(raw, count - 1)
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

/// In-memory paste log. `recordSuccessfulPaste` is a lock plus one append — no I/O.
nonisolated enum UsageStats: Sendable {
    private static let pending = OSAllocatedUnfairLock(initialState: [UsageTake]())
    private static let flushLoopStarted = OSAllocatedUnfairLock(initialState: false)

    static func recordSuccessfulPaste(wordCount: Int, speechToTextMilliseconds: Double) {
        let milliseconds = max(0, Int(speechToTextMilliseconds.rounded()))
        let take = UsageTake(
            t: Int64(Date().timeIntervalSince1970),
            words: wordCount,
            speechToTextMilliseconds: milliseconds
        )
        pending.withLock { $0.append(take) }
    }

    static func peekPending() -> [UsageTake] {
        pending.withLock { $0 }
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
        let batch = pending.withLock { state -> [UsageTake] in
            let copy = state
            state = []
            return copy
        }
        guard !batch.isEmpty else { return }
        await store.add(batch)
    }
}

/// Disk-backed takes. Never call from `deliver`, the audio tap, or overlay show.
actor UsageStatsStore {
    static let shared = UsageStatsStore()
    static let retentionDays = 120

    private let fileURL: URL
    private var takes: [UsageTake] = []
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

    func add(_ incoming: [UsageTake], now: Date = .now, calendar: Calendar = .current) {
        guard !incoming.isEmpty else { return }
        loadIfNeeded(now: now, calendar: calendar)
        if takes.isEmpty {
            takes = incoming.sorted { $0.t < $1.t }
        } else {
            takes.append(contentsOf: incoming)
            takes.sort { $0.t < $1.t }
        }
        prune(now: now)
        persist()
    }

    func add(
        words: Int,
        takes takeCount: Int,
        speechToTextMilliseconds: Int? = nil,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        let count = max(takeCount, words == 0 ? 0 : 1)
        guard count > 0 else { return }
        let t = Int64(now.timeIntervalSince1970)
        let base = words / count
        let extra = words % count
        var batch: [UsageTake] = []
        batch.reserveCapacity(count)
        for i in 0..<count {
            batch.append(
                UsageTake(
                    t: t + Int64(i),
                    words: base + (i < extra ? 1 : 0),
                    speechToTextMilliseconds: speechToTextMilliseconds
                )
            )
        }
        add(batch, now: now, calendar: calendar)
    }

    func allTakes(now: Date = .now, calendar: Calendar = .current) -> [UsageTake] {
        loadIfNeeded(now: now, calendar: calendar)
        prune(now: now)
        return takes
    }

    func snapshot(
        for range: UsageStatsRange,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> UsageStatsSnapshot {
        UsageStatsAggregator.snapshot(
            takes: allTakes(now: now, calendar: calendar),
            range: range,
            now: now,
            calendar: calendar
        )
    }

    private func loadIfNeeded(now: Date, calendar: Calendar = .current) {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        var migrated = false
        if !payload.takes.isEmpty {
            takes = payload.takes.sorted { $0.t < $1.t }
        } else if let days = payload.days, !days.isEmpty {
            takes = Self.migrateDays(days, now: now, calendar: calendar)
            migrated = true
        }
        prune(now: now)
        if migrated {
            persist()
        }
    }

    private func prune(now: Date) {
        let cutoff = Int64(now.timeIntervalSince1970) - Int64(Self.retentionDays) * 24 * 60 * 60
        let firstKept = UsageTakeIndex.firstIndex(in: takes, atOrAfter: cutoff)
        if firstKept > 0 {
            takes.removeFirst(firstKept)
        }
    }

    private func persist() {
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let payload = Payload(takes: takes)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func migrateDays(_ days: [UsageDayRow], now: Date, calendar: Calendar) -> [UsageTake] {
        var migrated: [UsageTake] = []
        for day in days {
            guard let date = UsageCalendar.date(fromDayKey: day.date, calendar: calendar) else { continue }
            let start = calendar.startOfDay(for: date)
            let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? start
            let clamped = min(noon, now.addingTimeInterval(-1))
            let stamp = max(clamped, start)
            let t = Int64(stamp.timeIntervalSince1970)
            let count = max(day.takeCount, day.wordCount > 0 ? 1 : 0)
            guard count > 0 else { continue }
            let base = day.wordCount / count
            let extra = day.wordCount % count
            for i in 0..<count {
                migrated.append(
                    UsageTake(
                        t: t + Int64(i),
                        words: base + (i < extra ? 1 : 0),
                        speechToTextMilliseconds: nil
                    )
                )
            }
        }
        migrated.sort { $0.t < $1.t }
        return migrated
    }

    private struct Payload: Codable {
        var v: Int
        var takes: [UsageTake]
        var days: [UsageDayRow]?

        init(takes: [UsageTake]) {
            v = 2
            self.takes = takes
            days = nil
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            v = try container.decodeIfPresent(Int.self, forKey: .v) ?? 1
            takes = try container.decodeIfPresent([UsageTake].self, forKey: .takes) ?? []
            days = try container.decodeIfPresent([UsageDayRow].self, forKey: .days)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(v, forKey: .v)
            try container.encode(takes, forKey: .takes)
        }

        enum CodingKeys: String, CodingKey {
            case v
            case takes
            case days
        }
    }
}
