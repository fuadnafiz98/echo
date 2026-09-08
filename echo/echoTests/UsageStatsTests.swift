import Foundation
import Testing
@testable import echo

@Suite("Usage stats")
struct UsageStatsTests {
    @Test func wordCountSplitsOnWhitespace() {
        #expect(UsageWords.count("hello world") == 2)
        #expect(UsageWords.count("  hello   world  ") == 2)
        #expect(UsageWords.count("") == 0)
        #expect(UsageWords.count("one") == 1)
        #expect(UsageWords.count("hello\nworld\ttab") == 3)
    }

    @Test func storePersistsAndAggregatesInTempDir() async throws {
        let (store, folder, calendar, now) = try makeTempStore(day: (2026, 9, 8))
        defer { try? FileManager.default.removeItem(at: folder) }

        await store.add(words: 12, takes: 1, now: now, calendar: calendar)
        await store.add(words: 8, takes: 1, now: now, calendar: calendar)

        let todaySnap = await store.snapshot(now: now, calendar: calendar)
        #expect(todaySnap.totalWords == 20)
        #expect(todaySnap.totalTakes == 2)
        #expect(todaySnap.days.count == 1)
        #expect(todaySnap.totals(for: .today, now: now, calendar: calendar).words == 20)

        let reloaded = UsageStatsStore(fileURL: folder.appendingPathComponent("stats.json"))
        let again = await reloaded.snapshot(now: now, calendar: calendar)
        #expect(again.totalWords == 20)
        #expect(again.totalTakes == 2)
    }

    @Test func rangeTotalsIgnoreOlderDays() async throws {
        let (store, folder, calendar, now) = try makeTempStore(day: (2026, 9, 8))
        defer { try? FileManager.default.removeItem(at: folder) }

        await store.add(words: 5, takes: 1, now: now, calendar: calendar)
        await store.add(
            words: 7,
            takes: 1,
            now: shift(now, days: -3, calendar: calendar),
            calendar: calendar
        )
        await store.add(
            words: 11,
            takes: 2,
            now: shift(now, days: -10, calendar: calendar),
            calendar: calendar
        )
        await store.add(
            words: 13,
            takes: 1,
            now: shift(now, days: -40, calendar: calendar),
            calendar: calendar
        )
        await store.add(
            words: 17,
            takes: 1,
            now: shift(now, days: -100, calendar: calendar),
            calendar: calendar
        )

        let snap = await store.snapshot(now: now, calendar: calendar)
        #expect(snap.totals(for: .today, now: now, calendar: calendar) == (5, 1))
        #expect(snap.totals(for: .last7, now: now, calendar: calendar) == (12, 2))
        #expect(snap.totals(for: .last30, now: now, calendar: calendar) == (23, 4))
        #expect(snap.totals(for: .last90, now: now, calendar: calendar) == (36, 5))
        #expect(snap.totals(for: .all, now: now, calendar: calendar) == (53, 6))
    }

    @Test func pruneDropsDaysOlderThanRetention() async throws {
        let (store, folder, calendar, now) = try makeTempStore(day: (2026, 9, 8))
        defer { try? FileManager.default.removeItem(at: folder) }

        await store.add(
            words: 3,
            takes: 1,
            now: shift(now, days: -80, calendar: calendar),
            calendar: calendar
        )
        await store.add(
            words: 9,
            takes: 1,
            now: shift(now, days: -150, calendar: calendar),
            calendar: calendar
        )
        await store.add(words: 4, takes: 1, now: now, calendar: calendar)

        let snap = await store.snapshot(now: now, calendar: calendar)
        #expect(snap.totalWords == 7)
        #expect(snap.days.contains(where: { $0.wordCount == 9 }) == false)
        #expect(snap.days.contains(where: { $0.wordCount == 3 }))
    }

    @Test func chartDaysZeroFillsMissingDays() async throws {
        let (store, folder, calendar, now) = try makeTempStore(day: (2026, 9, 8))
        defer { try? FileManager.default.removeItem(at: folder) }

        await store.add(words: 10, takes: 2, now: now, calendar: calendar)
        await store.add(
            words: 4,
            takes: 1,
            now: shift(now, days: -2, calendar: calendar),
            calendar: calendar
        )

        let snap = await store.snapshot(now: now, calendar: calendar)
        let week = snap.chartDays(for: .last7, now: now, calendar: calendar)
        #expect(week.count == 7)
        #expect(week.last?.words == 10)
        #expect(week.last?.takes == 2)
        #expect(week[week.count - 3].words == 4)
        #expect(week[week.count - 2].words == 0)
        #expect(week[0].words == 0)

        let today = snap.chartDays(for: .today, now: now, calendar: calendar)
        #expect(today.count == 1)
        #expect(today[0].words == 10)
    }

    @Test func defaultFileURLLivesUnderEchoApplicationSupport() {
        let root = URL(fileURLWithPath: "/tmp/echo-app-support-test", isDirectory: true)
        let url = UsageStatsStore.defaultFileURL(appSupport: root)
        #expect(url.path.hasSuffix("Echo/stats.json"))
    }

    private func makeTempStore(day: (Int, Int, Int)) throws -> (UsageStatsStore, URL, Calendar, Date) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-stats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let now = try #require(
            calendar.date(from: DateComponents(year: day.0, month: day.1, day: day.2, hour: 15))
        )
        let store = UsageStatsStore(fileURL: folder.appendingPathComponent("stats.json"))
        return (store, folder, calendar, now)
    }

    private func shift(_ date: Date, days: Int, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }
}
