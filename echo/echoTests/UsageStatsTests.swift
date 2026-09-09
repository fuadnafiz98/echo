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

        await store.add(words: 12, takes: 1, speechToTextMilliseconds: 400, now: now, calendar: calendar)
        await store.add(words: 8, takes: 1, speechToTextMilliseconds: 600, now: now, calendar: calendar)

        let takes = await store.allTakes(now: now, calendar: calendar)
        #expect(UsageStatsAggregator.totals(in: takes) == (20, 2))
        let snap = await store.snapshot(for: .days15, now: now, calendar: calendar)
        #expect(snap.totalWords == 20)
        #expect(snap.totalTakes == 2)
        #expect(snap.averageSpeechToTextMilliseconds == 500)

        let reloaded = UsageStatsStore(fileURL: folder.appendingPathComponent("stats.json"))
        let again = await reloaded.allTakes(now: now, calendar: calendar)
        #expect(UsageStatsAggregator.totals(in: again) == (20, 2))
        #expect(again.compactMap(\.ms) == [400, 600])
    }

    @Test func pruneDropsTakesOlderThanRetention() async throws {
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

        let takes = await store.allTakes(now: now, calendar: calendar)
        let totals = UsageStatsAggregator.totals(in: takes)
        #expect(totals.words == 7)
        #expect(takes.contains(where: { $0.words == 9 }) == false)
        #expect(takes.contains(where: { $0.words == 3 }))
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
