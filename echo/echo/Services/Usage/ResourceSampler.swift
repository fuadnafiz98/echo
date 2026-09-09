import Foundation

/// Tab-scoped sampler. No launch timer. 1 Hz while Resources is visible; persist at most once a minute.
struct ResourceSampler: Sendable {
    private(set) var previousProcess: ProcessMetrics.Raw?
    private(set) var previousGPUTimeNS: UInt64?
    private(set) var previousWallNS: UInt64?
    private var lastPersistMinute: Int64?

    init(
        previousProcess: ProcessMetrics.Raw? = nil,
        previousGPUTimeNS: UInt64? = nil,
        previousWallNS: UInt64? = nil
    ) {
        self.previousProcess = previousProcess
        self.previousGPUTimeNS = previousGPUTimeNS
        self.previousWallNS = previousWallNS
    }

    mutating func tick(now: Date = .now) -> ResourceSample? {
        guard let raw = ProcessMetrics.read() else { return nil }
        let gpuRaw = GPUMetrics.readRaw()
        let wallNS = ProcessMetrics.nanoseconds(fromMachTicks: raw.wallTicks)
        let processCPU = previousProcess.flatMap { ProcessMetrics.cpuPercent(from: $0, to: raw) }
        let systemCPU: Double?
        if let previousHost = previousProcess?.host, let host = raw.host {
            systemCPU = ProcessMetrics.systemCPUPercent(from: previousHost, to: host)
        } else {
            systemCPU = nil
        }
        let gpu = ResourceStats.reading(
            gpuRaw: gpuRaw,
            previousGPUTimeNS: previousGPUTimeNS,
            previousWallNS: previousWallNS,
            wallNS: wallNS
        )
        previousProcess = raw
        previousGPUTimeNS = gpuRaw.processGPUTimeNS
        previousWallNS = wallNS

        return ResourceSample(
            date: now,
            processCPUPercent: processCPU,
            systemCPUPercent: systemCPU,
            footprintBytes: raw.footprintBytes,
            residentBytes: raw.residentBytes,
            neuralInFootprintBytes: raw.neuralInFootprintBytes,
            neuralReclaimableBytes: raw.neuralReclaimableBytes,
            metalAllocatedBytes: GPUMetrics.metalAllocatedBytes(),
            gpuPercent: gpu?.percent,
            gpuSource: gpu?.source
        )
    }

    /// At most one persist per wall-clock minute. First tick (no CPU delta) is not persisted.
    mutating func persistIfDue(_ sample: ResourceSample) -> ResourceMinuteSample? {
        guard sample.processCPUPercent != nil else { return nil }
        let minute = ResourceSampler.minute(for: sample.date)
        if lastPersistMinute == minute { return nil }
        lastPersistMinute = minute
        return ResourceSampler.minuteSample(from: sample)
    }

    static func minute(for date: Date) -> Int64 {
        (Int64(date.timeIntervalSince1970) / 60) * 60
    }

    static func minuteSample(from sample: ResourceSample, at date: Date? = nil) -> ResourceMinuteSample {
        let when = date ?? sample.date
        return ResourceMinuteSample(
            t: minute(for: when),
            cpu: Float(sample.processCPUPercent ?? 0),
            mem: sample.footprintBytes,
            rss: sample.residentBytes,
            gpu: sample.gpuPercent.map { Float($0) },
            src: sample.gpuSource,
            nrl: sample.neuralReclaimableBytes,
            sys: sample.systemCPUPercent.map { Float($0) },
            mtl: sample.metalAllocatedBytes
        )
    }

    static func minuteSample(from point: ResourceChartPoint, at date: Date) -> ResourceMinuteSample {
        ResourceMinuteSample(
            t: minute(for: date),
            cpu: Float(point.cpuPercent),
            mem: point.memoryBytes,
            rss: point.residentBytes,
            gpu: point.gpuPercent.map { Float($0) },
            src: point.gpuSource,
            nrl: point.neuralReclaimableBytes,
            sys: point.systemCPUPercent.map { Float($0) },
            mtl: point.metalAllocatedBytes
        )
    }
}

struct ResourceSample: Sendable, Equatable {
    var date: Date
    /// This process, percent of one logical CPU. `nil` until a second sample exists.
    var processCPUPercent: Double?
    /// This Mac, 0…100 across all cores. `nil` until a second host sample exists.
    var systemCPUPercent: Double?
    var footprintBytes: UInt64
    var residentBytes: UInt64
    var neuralInFootprintBytes: UInt64
    var neuralReclaimableBytes: UInt64
    var metalAllocatedBytes: UInt64?
    var gpuPercent: Double?
    var gpuSource: GPUMetrics.Source?

    func chartPoint() -> ResourceChartPoint? {
        guard let processCPUPercent else { return nil }
        return ResourceChartPoint(
            date: date,
            cpuPercent: processCPUPercent,
            memoryBytes: footprintBytes,
            residentBytes: residentBytes,
            gpuPercent: gpuPercent,
            gpuSource: gpuSource,
            neuralReclaimableBytes: neuralReclaimableBytes,
            systemCPUPercent: systemCPUPercent,
            metalAllocatedBytes: metalAllocatedBytes
        )
    }
}
