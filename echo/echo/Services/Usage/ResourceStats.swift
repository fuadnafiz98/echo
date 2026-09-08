import Foundation
import os

nonisolated enum ResourceHistoryWindow: String, CaseIterable, Identifiable, Sendable {
    case live15
    case hour
    case day
    case week
    case days90

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live15: "15 minutes"
        case .hour: "1 hour"
        case .day: "24 hours"
        case .week: "7 days"
        case .days90: "90 days"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .live15: 15 * 60
        case .hour: 60 * 60
        case .day: 24 * 60 * 60
        case .week: 7 * 24 * 60 * 60
        case .days90: 90 * 24 * 60 * 60
        }
    }

    var chartPointBudget: Int {
        switch self {
        case .live15: 900
        case .hour: 60
        case .day: 288
        case .week: 168
        case .days90: 180
        }
    }

    var axisFormat: Date.FormatStyle {
        switch self {
        case .live15:
            .dateTime.minute().second()
        case .hour, .day:
            .dateTime.hour().minute()
        case .week, .days90:
            .dateTime.month(.abbreviated).day()
        }
    }
}

nonisolated struct ResourceChartPoint: Sendable, Equatable, Identifiable {
    var date: Date
    var cpuPercent: Double
    var memoryBytes: UInt64
    var residentBytes: UInt64
    var gpuPercent: Double?
    var gpuSource: GPUMetrics.Source?

    var id: Date { date }

    var memoryMegabytes: Double {
        Double(memoryBytes) / 1_048_576
    }
}

nonisolated struct ResourceMinuteSample: Codable, Sendable, Equatable, Identifiable {
    var t: Int64
    var cpu: Float
    var mem: UInt64
    var rss: UInt64
    var gpu: Float?
    var src: GPUMetrics.Source?

    var id: Int64 { t }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(t))
    }

    func chartPoint() -> ResourceChartPoint {
        ResourceChartPoint(
            date: date,
            cpuPercent: Double(cpu),
            memoryBytes: mem,
            residentBytes: rss,
            gpuPercent: gpu.map(Double.init),
            gpuSource: src
        )
    }
}

nonisolated enum ResourceDownsample: Sendable {
    static func average(_ samples: [ResourceMinuteSample], maxPoints: Int) -> [ResourceMinuteSample] {
        guard maxPoints > 0, samples.count > maxPoints else { return samples }
        let chunk = max(1, Int((Double(samples.count) / Double(maxPoints)).rounded(.up)))
        var result: [ResourceMinuteSample] = []
        result.reserveCapacity((samples.count + chunk - 1) / chunk)
        var index = 0
        while index < samples.count {
            let end = min(index + chunk, samples.count)
            result.append(average(samples[index..<end]))
            index = end
        }
        return result
    }

    static func average(_ slice: ArraySlice<ResourceMinuteSample>) -> ResourceMinuteSample {
        let count = Double(slice.count)
        let cpu = slice.reduce(0) { $0 + $1.cpu } / Float(count)
        let mem = UInt64((slice.reduce(0.0) { $0 + Double($1.mem) } / count).rounded())
        let rss = UInt64((slice.reduce(0.0) { $0 + Double($1.rss) } / count).rounded())
        let gpuValues = slice.compactMap(\.gpu)
        let gpu = gpuValues.isEmpty ? nil : gpuValues.reduce(0, +) / Float(gpuValues.count)
        let src = slice.reversed().compactMap(\.src).first
        return ResourceMinuteSample(
            t: slice[slice.startIndex].t,
            cpu: cpu,
            mem: mem,
            rss: rss,
            gpu: gpu,
            src: src
        )
    }
}

/// Minute-resolution persist. Never call from `deliver`, the audio tap, or overlay show.
nonisolated enum ResourceStats: Sendable {
    private static let persistLoopStarted = OSAllocatedUnfairLock(initialState: false)

    static func startBackgroundPersist() {
        let alreadyStarted = persistLoopStarted.withLock { started -> Bool in
            if started { return true }
            started = true
            return false
        }
        guard !alreadyStarted else { return }
        Task.detached(priority: .utility) {
            var previousMetrics: ProcessMetrics.Raw?
            var previousGPUTimeNS: UInt64?
            var previousWallNS: UInt64?
            previousMetrics = ProcessMetrics.read()
            let firstGPU = GPUMetrics.readRaw()
            previousGPUTimeNS = firstGPU.processGPUTimeNS
            previousWallNS = ProcessMetrics.nanoseconds(fromMachTicks: mach_absolute_time())

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let sample = capture(
                    previousMetrics: &previousMetrics,
                    previousGPUTimeNS: &previousGPUTimeNS,
                    previousWallNS: &previousWallNS
                ) else { continue }
                await ResourceStatsStore.shared.upsert(sample)
            }
        }
    }

    static func capture(
        previousMetrics: inout ProcessMetrics.Raw?,
        previousGPUTimeNS: inout UInt64?,
        previousWallNS: inout UInt64?
    ) -> ResourceMinuteSample? {
        guard let raw = ProcessMetrics.read() else { return nil }
        let gpuRaw = GPUMetrics.readRaw()
        let wallNS = ProcessMetrics.nanoseconds(fromMachTicks: raw.wallTicks)
        var cpu = 0.0
        if let previousMetrics {
            cpu = ProcessMetrics.cpuPercent(from: previousMetrics, to: raw)
        }
        previousMetrics = raw

        let reading = reading(
            gpuRaw: gpuRaw,
            previousGPUTimeNS: previousGPUTimeNS,
            previousWallNS: previousWallNS,
            wallNS: wallNS
        )
        previousGPUTimeNS = gpuRaw.processGPUTimeNS
        previousWallNS = wallNS

        let memory = raw.footprintBytes > 0 ? raw.footprintBytes : raw.residentBytes
        let minute = (Int64(Date.now.timeIntervalSince1970) / 60) * 60
        return ResourceMinuteSample(
            t: minute,
            cpu: Float(cpu),
            mem: memory,
            rss: raw.residentBytes,
            gpu: reading.map { Float($0.percent) },
            src: reading?.source
        )
    }

    static func reading(
        gpuRaw: GPUMetrics.Raw,
        previousGPUTimeNS: UInt64?,
        previousWallNS: UInt64?,
        wallNS: UInt64
    ) -> GPUMetrics.Reading? {
        if let current = gpuRaw.processGPUTimeNS,
           let previous = previousGPUTimeNS,
           let previousWall = previousWallNS,
           wallNS > previousWall,
           let percent = GPUMetrics.processPercent(
            from: previous,
            to: current,
            elapsedNS: wallNS &- previousWall
           ) {
            return GPUMetrics.Reading(percent: percent, source: .process)
        }
        if let system = gpuRaw.systemPercent {
            return GPUMetrics.Reading(percent: system, source: .system)
        }
        return nil
    }

    static func mergeLive(
        live: [ResourceChartPoint],
        historical: [ResourceChartPoint],
        now: Date = .now,
        window: TimeInterval = ResourceHistoryWindow.live15.duration
    ) -> [ResourceChartPoint] {
        let start = now.addingTimeInterval(-window)
        let liveStart = live.first?.date
        var merged: [ResourceChartPoint] = []
        for point in historical where point.date >= start {
            if let liveStart, point.date >= liveStart { break }
            merged.append(point)
        }
        merged.append(contentsOf: live.filter { $0.date >= start })
        return merged
    }
}

actor ResourceStatsStore {
    static let shared = ResourceStatsStore()
    static let retentionDays = 90

    private let fileURL: URL
    private var samples: [Int64: ResourceMinuteSample] = [:]
    private var loaded = false

    init(fileURL: URL = ResourceStatsStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL(
        appSupport: URL = LocalModelPaths.applicationSupport()
    ) -> URL {
        appSupport
            .appendingPathComponent("Echo", isDirectory: true)
            .appendingPathComponent("resources.json", isDirectory: false)
    }

    func upsert(_ sample: ResourceMinuteSample, now: Date = .now) {
        loadIfNeeded(now: now)
        samples[sample.t] = sample
        prune(now: now)
        persist()
    }

    func snapshot(
        from start: Date,
        to end: Date = .now,
        maxPoints: Int,
        now: Date = .now
    ) -> [ResourceChartPoint] {
        loadIfNeeded(now: now)
        prune(now: now)
        let startT = Int64(start.timeIntervalSince1970)
        let endT = Int64(end.timeIntervalSince1970)
        let rows = samples.values
            .filter { $0.t >= startT && $0.t <= endT }
            .sorted { $0.t < $1.t }
        return ResourceDownsample.average(rows, maxPoints: maxPoints).map { $0.chartPoint() }
    }

    private func loadIfNeeded(now: Date) {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        samples = Dictionary(uniqueKeysWithValues: payload.samples.map { ($0.t, $0) })
        prune(now: now)
    }

    private func prune(now: Date) {
        let cutoff = Int64(now.timeIntervalSince1970) - Int64(Self.retentionDays) * 24 * 60 * 60
        samples = samples.filter { $0.key >= cutoff }
    }

    private func persist() {
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let payload = Payload(samples: samples.values.sorted { $0.t < $1.t })
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private struct Payload: Codable {
        var samples: [ResourceMinuteSample]
    }
}
