import Foundation
import Testing
@testable import echo

@Suite("Stats range bucketing")
struct StatsRangeTests {
    @Test func emptyBucketsDefineEachRangeDomain() {
        let (calendar, now) = clock(year: 2026, month: 9, day: 8, hour: 15, minute: 37)

        let minutes = UsageStatsAggregator.snapshot(takes: [], range: .minutes15, now: now, calendar: calendar)
        let hour = UsageStatsAggregator.snapshot(takes: [], range: .hour, now: now, calendar: calendar)
        let days15 = UsageStatsAggregator.snapshot(takes: [], range: .days15, now: now, calendar: calendar)
        let days90 = UsageStatsAggregator.snapshot(takes: [], range: .days90, now: now, calendar: calendar)

        #expect(minutes.buckets.count == 15)
        #expect(hour.buckets.count == 30)
        #expect(days15.buckets.count == 15)
        #expect(days90.buckets.count == 90)
        #expect(minutes.buckets.allSatisfy { $0.words == 0 && $0.takes == 0 })
        #expect(days15.buckets.allSatisfy { $0.words == 0 && $0.takes == 0 })

        #expect(minutes.domain != hour.domain)
        #expect(hour.domain != days15.domain)
        #expect(days15.domain != days90.domain)
        #expect(minutes.domain.upperBound.timeIntervalSince(minutes.domain.lowerBound) == 15 * 60)
        #expect(hour.domain.upperBound.timeIntervalSince(hour.domain.lowerBound) == 60 * 60)
        #expect(days15.buckets.first?.date == calendar.startOfDay(for: shift(now, days: -14, calendar: calendar)))
        #expect(days15.buckets.last?.date == calendar.startOfDay(for: now))
        #expect(days90.buckets.count - days15.buckets.count == 75)
    }

    @Test func switchingRangeRebucketsTheSameTakes() {
        let (calendar, now) = clock(year: 2026, month: 9, day: 8, hour: 15, minute: 37)
        let takes = [
            take(now.addingTimeInterval(-90), words: 5, ms: 200),
            take(now.addingTimeInterval(-8 * 60), words: 7, ms: 400),
            take(shift(now, days: -3, calendar: calendar), words: 11, ms: 300),
            take(shift(now, days: -20, calendar: calendar), words: 13, ms: 800),
        ].sorted { $0.t < $1.t }

        let minutes = UsageStatsAggregator.snapshot(takes: takes, range: .minutes15, now: now, calendar: calendar)
        let hour = UsageStatsAggregator.snapshot(takes: takes, range: .hour, now: now, calendar: calendar)
        let days15 = UsageStatsAggregator.snapshot(takes: takes, range: .days15, now: now, calendar: calendar)
        let days90 = UsageStatsAggregator.snapshot(takes: takes, range: .days90, now: now, calendar: calendar)

        #expect(minutes.totalTakes == 2)
        #expect(minutes.totalWords == 12)
        #expect(hour.totalTakes == 2)
        #expect(hour.totalWords == 12)
        #expect(days15.totalTakes == 3)
        #expect(days15.totalWords == 23)
        #expect(days90.totalTakes == 4)
        #expect(days90.totalWords == 36)

        #expect(minutes.buckets.contains { $0.words == 5 && $0.takes == 1 })
        #expect(minutes.buckets.contains { $0.words == 7 && $0.takes == 1 })
        #expect(hour.buckets.contains { $0.words == 5 })
        #expect(hour.buckets.contains { $0.words == 7 })
        #expect(days15.buckets.last?.words == 12)
        #expect(days15.buckets[days15.buckets.count - 4].words == 11)
        #expect(days90.buckets.contains { $0.words == 13 })
        #expect(days15.buckets.contains { $0.words == 13 } == false)
    }

    @Test func averageSpeechToTextIgnoresLegacyTakesWithoutTiming() {
        let (calendar, now) = clock(year: 2026, month: 9, day: 8, hour: 12)
        let takes = [
            take(now.addingTimeInterval(-30), words: 4, ms: 100),
            take(now.addingTimeInterval(-20), words: 4, ms: nil),
            take(now.addingTimeInterval(-10), words: 4, ms: 300),
        ]
        let snap = UsageStatsAggregator.snapshot(takes: takes, range: .minutes15, now: now, calendar: calendar)
        #expect(snap.averageSpeechToTextMilliseconds == 200)
        #expect(UsageStatsAggregator.lastSpeechToTextMilliseconds(in: takes) == 300)
    }

    @Test func aggregationScansOnlyTakesInsideTheWindow() {
        let (calendar, now) = clock(year: 2026, month: 9, day: 8, hour: 16)
        var takes: [UsageTake] = []
        takes.reserveCapacity(5_002)
        let old = shift(now, days: -40, calendar: calendar)
        for i in 0..<5_000 {
            takes.append(take(old.addingTimeInterval(TimeInterval(i)), words: 1, ms: 50))
        }
        takes.append(take(now.addingTimeInterval(-45), words: 9, ms: 120))
        takes.append(take(now.addingTimeInterval(-10), words: 3, ms: 80))
        takes.sort { $0.t < $1.t }

        let minutes = UsageStatsAggregator.snapshot(takes: takes, range: .minutes15, now: now, calendar: calendar)
        #expect(minutes.totalTakes == 2)
        #expect(minutes.totalWords == 12)
        #expect(minutes.averageSpeechToTextMilliseconds == 100)
        #expect(minutes.buckets.count == 15)

        let startTs = Int64(minutes.domain.lowerBound.timeIntervalSince1970)
        let index = UsageTakeIndex.firstIndex(in: takes, atOrAfter: startTs)
        #expect(index == 5_000)
        #expect(takes.count - index == 2)
    }

    @Test func storeSnapshotMatchesAggregatorForSelectedRange() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-stats-range-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let (calendar, now) = clock(year: 2026, month: 9, day: 8, hour: 15)
        let store = UsageStatsStore(fileURL: folder.appendingPathComponent("stats.json"))
        await store.add(words: 6, takes: 1, speechToTextMilliseconds: 250, now: now, calendar: calendar)
        await store.add(
            words: 10,
            takes: 1,
            speechToTextMilliseconds: 350,
            now: shift(now, days: -4, calendar: calendar),
            calendar: calendar
        )
        await store.add(
            words: 20,
            takes: 1,
            now: shift(now, days: -40, calendar: calendar),
            calendar: calendar
        )

        let minutes = await store.snapshot(for: .minutes15, now: now, calendar: calendar)
        let days15 = await store.snapshot(for: .days15, now: now, calendar: calendar)
        let days90 = await store.snapshot(for: .days90, now: now, calendar: calendar)
        #expect(minutes.totalWords == 6)
        #expect(days15.totalWords == 16)
        #expect(days90.totalWords == 36)
        #expect(minutes.buckets.count == 15)
        #expect(days15.buckets.count == 15)
        #expect(days90.buckets.count == 90)
    }

    @Test func migratesLegacyDailyTotalsIntoTakes() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-stats-migrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let (calendar, now) = clock(year: 2026, month: 9, day: 8, hour: 15)
        let url = folder.appendingPathComponent("stats.json")
        let payload = """
        {"days":[{"date":"2026-09-08","wordCount":20,"takeCount":2},{"date":"2026-09-01","wordCount":5,"takeCount":1}]}
        """
        try Data(payload.utf8).write(to: url)

        let store = UsageStatsStore(fileURL: url)
        let days15 = await store.snapshot(for: .days15, now: now, calendar: calendar)
        #expect(days15.totalWords == 25)
        #expect(days15.totalTakes == 3)
        #expect(days15.averageSpeechToTextMilliseconds == nil)
    }

    @Test func migratesLegacyTodayBeforeNoonIntoTheOpenWindow() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-stats-migrate-am-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let (calendar, morning) = clock(year: 2026, month: 9, day: 8, hour: 9, minute: 10)
        let url = folder.appendingPathComponent("stats.json")
        try Data(#"{"days":[{"date":"2026-09-08","wordCount":20,"takeCount":2}]}"#.utf8).write(to: url)

        let store = UsageStatsStore(fileURL: url)
        let hours24 = await store.snapshot(for: .hours24, now: morning, calendar: calendar)
        #expect(hours24.totalWords == 20)
        #expect(hours24.totalTakes == 2)
        #expect(hours24.buckets.contains { $0.takes == 2 })
    }

    private func clock(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0
    ) -> (Calendar, Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let date = calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        ) ?? Date(timeIntervalSince1970: 0)
        return (calendar, date)
    }

    private func take(_ date: Date, words: Int, ms: Int?) -> UsageTake {
        UsageTake(t: Int64(date.timeIntervalSince1970), words: words, speechToTextMilliseconds: ms)
    }

    private func shift(_ date: Date, days: Int, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }
}
