import Foundation
import Testing
@testable import echo

@Suite("Resource stats")
struct ResourceStatsTests {
    @Test func storePersistsAndPrunesNinetyDays() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-resources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = ResourceStatsStore(fileURL: folder.appendingPathComponent("resources.json"))
        let now = Date(timeIntervalSince1970: 1_788_854_400)
        let fresh = ResourceMinuteSample(t: Int64(now.timeIntervalSince1970), cpu: 4, mem: 100, rss: 80, gpu: 12, src: .system)
        let old = ResourceMinuteSample(
            t: Int64(now.addingTimeInterval(-100 * 24 * 60 * 60).timeIntervalSince1970),
            cpu: 9,
            mem: 50,
            rss: 40,
            gpu: 1,
            src: .system
        )
        await store.upsert(old, now: now)
        await store.upsert(fresh, now: now)

        let points = await store.snapshot(
            from: now.addingTimeInterval(-90 * 24 * 60 * 60),
            to: now,
            maxPoints: 200,
            now: now
        )
        #expect(points.count == 1)
        #expect(points[0].cpuPercent == 4)
        #expect(points[0].gpuPercent == 12)

        let reloaded = ResourceStatsStore(fileURL: folder.appendingPathComponent("resources.json"))
        let again = await reloaded.snapshot(
            from: now.addingTimeInterval(-90 * 24 * 60 * 60),
            to: now,
            maxPoints: 200,
            now: now
        )
        #expect(again.count == 1)
        #expect(again[0].memoryBytes == 100)
    }

    @Test func downsampleAveragesBuckets() {
        var samples: [ResourceMinuteSample] = []
        samples.reserveCapacity(10)
        for index in 0..<10 {
            samples.append(
                ResourceMinuteSample(
                    t: Int64(index * 60),
                    cpu: Float(index),
                    mem: UInt64(index * 10),
                    rss: UInt64(index),
                    gpu: Float(index),
                    src: .system
                )
            )
        }
        let reduced = ResourceDownsample.average(samples, maxPoints: 5)
        #expect(reduced.count == 5)
        #expect(reduced[0].cpu == 0.5)
        #expect(reduced[0].mem == 5)
    }

    @Test func mergeLivePrefersLiveOverHistoricalOverlap() {
        let start = Date(timeIntervalSince1970: 1_000)
        let historical = [
            ResourceChartPoint(date: start, cpuPercent: 1, memoryBytes: 1, residentBytes: 1, gpuPercent: 1, gpuSource: .system),
            ResourceChartPoint(date: start.addingTimeInterval(30), cpuPercent: 2, memoryBytes: 2, residentBytes: 2, gpuPercent: 2, gpuSource: .system),
            ResourceChartPoint(date: start.addingTimeInterval(90), cpuPercent: 9, memoryBytes: 9, residentBytes: 9, gpuPercent: 9, gpuSource: .system),
        ]
        let live = [
            ResourceChartPoint(date: start.addingTimeInterval(60), cpuPercent: 3, memoryBytes: 3, residentBytes: 3, gpuPercent: 3, gpuSource: .process),
            ResourceChartPoint(date: start.addingTimeInterval(120), cpuPercent: 4, memoryBytes: 4, residentBytes: 4, gpuPercent: 4, gpuSource: .process),
        ]
        let merged = ResourceStats.mergeLive(
            live: live,
            historical: historical,
            now: start.addingTimeInterval(120),
            window: 15 * 60
        )
        #expect(merged.map(\.cpuPercent) == [1, 2, 3, 4])
    }

    @Test func processGPUWinsWhenDeltaExistsOtherwiseSystem() {
        let process = GPUMetrics.Raw(processGPUTimeNS: 2_000_000, systemPercent: 40)
        let first = ResourceStats.reading(
            gpuRaw: process,
            previousGPUTimeNS: 1_000_000,
            previousWallNS: 0,
            wallNS: 10_000_000
        )
        #expect(first?.source == .process)
        #expect(first?.percent == 10)

        let systemOnly = GPUMetrics.Raw(processGPUTimeNS: nil, systemPercent: 22)
        let fallback = ResourceStats.reading(
            gpuRaw: systemOnly,
            previousGPUTimeNS: nil,
            previousWallNS: nil,
            wallNS: 10_000_000
        )
        #expect(fallback?.source == .system)
        #expect(fallback?.percent == 22)

        let missing = GPUMetrics.Raw(processGPUTimeNS: nil, systemPercent: nil)
        #expect(
            ResourceStats.reading(
                gpuRaw: missing,
                previousGPUTimeNS: nil,
                previousWallNS: nil,
                wallNS: 10_000_000
            ) == nil
        )
    }

    @Test func defaultFileURLLivesUnderEchoApplicationSupport() {
        let root = URL(fileURLWithPath: "/tmp/echo-app-support-test", isDirectory: true)
        let url = ResourceStatsStore.defaultFileURL(appSupport: root)
        #expect(url.path.hasSuffix("Echo/resources.json"))
    }

    @Test func persistLoopIsMinuteAndLiveSampleIsOneHertz() throws {
        let persist = try AppSource.load("Services/Usage/ResourceStats.swift")
        let pane = try AppSource.load("Views/ResourcesSettingsPane.swift")
        #expect(persist.contains(".seconds(60)"))
        #expect(!persist.contains(".seconds(1)"))
        #expect(pane.contains(".seconds(1)"))
        #expect(!pane.contains("resources.json"))
    }
}

@Suite("GPU metrics parsing")
struct GPUMetricsTests {
    @Test func missingPerformanceStatisticsIsNilNotZero() {
        #expect(GPUMetrics.utilization(fromPerformanceStatistics: [:]) == nil)
        #expect(GPUMetrics.utilization(fromPerformanceStatistics: ["In use system memory": 12]) == nil)
    }

    @Test func readsDeviceUtilizationWithoutInventingValues() {
        #expect(GPUMetrics.utilization(fromPerformanceStatistics: ["Device Utilization %": 13]) == 13)
        #expect(GPUMetrics.utilization(fromPerformanceStatistics: ["Device Utilization %": 0]) == 0)
        #expect(GPUMetrics.utilization(fromPerformanceStatistics: ["GPU Activity(%)": 8.5]) == 8.5)
    }

    @Test func parsesCreatorPIDAndAppUsageTime() {
        #expect(GPUMetrics.parseCreatorPID("pid 4245, echo") == 4245)
        #expect(GPUMetrics.parseCreatorPID("no pid here") == nil)
        #expect(
            GPUMetrics.appUsageGPUTimeNS(fromAppUsage: [
                ["API": "Metal", "accumulatedGPUTime": 1_000],
                ["API": "Metal", "accumulatedGPUTime": 250],
            ]) == 1_250
        )
        #expect(GPUMetrics.appUsageGPUTimeNS(fromAppUsage: [["API": "Metal"]]) == nil)
    }

    @Test func processPercentNeedsElapsedTime() {
        #expect(GPUMetrics.processPercent(from: 10, to: 20, elapsedNS: 100) == 10)
        #expect(GPUMetrics.processPercent(from: 10, to: 20, elapsedNS: 0) == nil)
        #expect(GPUMetrics.processPercent(from: 20, to: 10, elapsedNS: 100) == nil)
    }
}
