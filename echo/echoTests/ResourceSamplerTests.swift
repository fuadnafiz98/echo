import Foundation
import Testing
@testable import echo

@Suite("Resource sampler")
struct ResourceSamplerTests {
    @Test func processCPUIsPercentOfOneLogicalCPU() {
        let previous = ProcessMetrics.Raw(
            cpuTicks: 1_000,
            wallTicks: 10_000,
            residentBytes: 80,
            footprintBytes: 100,
            neuralInFootprintBytes: 0,
            neuralReclaimableBytes: 0,
            host: nil
        )
        var current = previous
        current.cpuTicks = 1_000 + 2_500
        current.wallTicks = 10_000 + 10_000
        #expect(ProcessMetrics.cpuPercent(from: previous, to: current) == 25)

        current.cpuTicks = 1_000 + 20_000
        #expect(ProcessMetrics.cpuPercent(from: previous, to: current) == 200)

        current.wallTicks = 10_000
        #expect(ProcessMetrics.cpuPercent(from: previous, to: current) == nil)
    }

    @Test func systemCPUIsBusyOverAllCores() {
        let previous = ProcessMetrics.HostTicks(user: 10, system: 5, idle: 80, nice: 5)
        let current = ProcessMetrics.HostTicks(user: 20, system: 15, idle: 160, nice: 5)
        #expect(ProcessMetrics.systemCPUPercent(from: previous, to: current) == 20)

        let idle = ProcessMetrics.HostTicks(user: 10, system: 5, idle: 80, nice: 5)
        #expect(ProcessMetrics.systemCPUPercent(from: previous, to: idle) == nil)
    }

    @Test func memoryHeadlineIsFootprintNotRSSOrANE() {
        let raw = ProcessMetrics.Raw(
            cpuTicks: 0,
            wallTicks: 0,
            residentBytes: 210 * 1_048_576,
            footprintBytes: 80 * 1_048_576,
            neuralInFootprintBytes: 12 * 1_048_576,
            neuralReclaimableBytes: 443 * 1_048_576,
            host: nil
        )
        let breakdown = ProcessMetrics.memoryBreakdown(from: raw)
        #expect(breakdown.memoryHeadlineBytes == raw.footprintBytes)
        #expect(breakdown.memoryHeadlineBytes != raw.residentBytes)
        #expect(breakdown.neuralReclaimableBytes == 443 * 1_048_576)
        #expect(breakdown.neuralReclaimableBytes != breakdown.memoryHeadlineBytes)
    }

    @Test func reclaimableNeuralDoesNotGoNegative() {
        #expect(ProcessMetrics.reclaimableNeuralBytes(nofootprint: 443_000_000, compressed: 1_000) == 443_001_000)
        #expect(ProcessMetrics.reclaimableNeuralBytes(nofootprint: -4, compressed: 10) == 10)
        #expect(ProcessMetrics.inFootprintNeuralBytes(footprint: 8, compressed: 2) == 10)
    }

    @Test func persistAtMostOncePerMinuteAndSkipsBaselineTick() {
        var sampler = ResourceSampler()
        let first = ResourceSample(
            date: Date(timeIntervalSince1970: 1_800),
            processCPUPercent: nil,
            systemCPUPercent: nil,
            footprintBytes: 10,
            residentBytes: 8,
            neuralInFootprintBytes: 0,
            neuralReclaimableBytes: 443,
            metalAllocatedBytes: 4,
            gpuPercent: nil,
            gpuSource: nil
        )
        #expect(sampler.persistIfDue(first) == nil)

        let second = ResourceSample(
            date: Date(timeIntervalSince1970: 1_810),
            processCPUPercent: 3.5,
            systemCPUPercent: 18,
            footprintBytes: 12,
            residentBytes: 9,
            neuralInFootprintBytes: 0,
            neuralReclaimableBytes: 443,
            metalAllocatedBytes: 5,
            gpuPercent: 2,
            gpuSource: .process
        )
        let persisted = sampler.persistIfDue(second)
        #expect(persisted?.t == 1_800)
        #expect(persisted?.cpu == 3.5)
        #expect(persisted?.mem == 12)
        #expect(persisted?.nrl == 443)
        #expect(persisted?.src == .process)

        let sameMinute = ResourceSample(
            date: Date(timeIntervalSince1970: 1_850),
            processCPUPercent: 9,
            systemCPUPercent: 20,
            footprintBytes: 13,
            residentBytes: 9,
            neuralInFootprintBytes: 0,
            neuralReclaimableBytes: 400,
            metalAllocatedBytes: 5,
            gpuPercent: 1,
            gpuSource: .process
        )
        #expect(sampler.persistIfDue(sameMinute) == nil)

        let nextMinute = ResourceSample(
            date: Date(timeIntervalSince1970: 1_860),
            processCPUPercent: 4,
            systemCPUPercent: 19,
            footprintBytes: 14,
            residentBytes: 9,
            neuralInFootprintBytes: 0,
            neuralReclaimableBytes: 400,
            metalAllocatedBytes: 5,
            gpuPercent: 1,
            gpuSource: .process
        )
        #expect(sampler.persistIfDue(nextMinute)?.t == 1_860)
    }

    @Test func firstChartPointWaitsForCPUDelta() throws {
        let baseline = ResourceSample(
            date: Date(timeIntervalSince1970: 10),
            processCPUPercent: nil,
            systemCPUPercent: nil,
            footprintBytes: 80,
            residentBytes: 70,
            neuralInFootprintBytes: 0,
            neuralReclaimableBytes: 443,
            metalAllocatedBytes: nil,
            gpuPercent: nil,
            gpuSource: nil
        )
        #expect(baseline.chartPoint() == nil)

        let ready = ResourceSample(
            date: Date(timeIntervalSince1970: 11),
            processCPUPercent: 4,
            systemCPUPercent: 12,
            footprintBytes: 80,
            residentBytes: 70,
            neuralInFootprintBytes: 0,
            neuralReclaimableBytes: 443,
            metalAllocatedBytes: 3,
            gpuPercent: nil,
            gpuSource: nil
        )
        let point = try #require(ready.chartPoint())
        #expect(point.cpuPercent == 4)
        #expect(point.memoryBytes == 80)
        #expect(point.neuralReclaimableBytes == 443)
        #expect(point.gpuPercent == nil)
    }

    @Test func liveSampleReadsThisProcessWithoutInventingGPUZero() {
        var sampler = ResourceSampler()
        let first = sampler.tick()
        #expect(first != nil)
        #expect(first?.processCPUPercent == nil)
        let second = sampler.tick()
        #expect(second?.processCPUPercent != nil)
        if let gpu = second?.gpuPercent {
            #expect(gpu >= 0)
        } else {
            #expect(second?.gpuPercent == nil)
        }
        #expect((second ?? first)?.footprintBytes ?? 0 > 0)
    }

    @Test func coordinatorDoesNotStartResourceSampling() throws {
        let source = try AppSource.load("EchoCoordinator.swift")
        let start = try #require(AppSource.method(source, named: "start"))
        #expect(!start.contains("ResourceStats"))
        #expect(!start.contains("ResourceSampler"))
        #expect(!start.contains("startBackgroundPersist"))
        #expect(!start.contains("ProcessMetrics"))
        #expect(!start.contains("GPUMetrics"))
        #expect(!source.contains("startBackgroundPersist"))
    }

    @Test func processMetricsAvoidsExpensiveHostProcessorInfo() throws {
        let source = try AppSource.load("Services/Usage/ProcessMetrics.swift")
        #expect(!source.contains("host_processor_info"))
        #expect(source.contains("TASK_ABSOLUTETIME_INFO"))
        #expect(source.contains("phys_footprint"))
        #expect(source.contains("ledger_tag_neural_nofootprint"))
        #expect(source.contains("HOST_CPU_LOAD_INFO"))
    }

    @Test func resourcesTabStopsWhenClosedAndPersistsAtMostOnceAMinute() throws {
        let pane = try AppSource.load("Views/ResourcesSettingsPane.swift")
        let sampler = try AppSource.load("Services/Usage/ResourceSampler.swift")
        let stats = try AppSource.load("Services/Usage/ResourceStats.swift")
        #expect(pane.contains(".seconds(1)"))
        #expect(pane.contains("sampleTask?.cancel()"))
        #expect(pane.contains("onDisappear"))
        #expect(!pane.contains("resources.json"))
        #expect(sampler.contains("persistIfDue"))
        #expect(stats.contains(".seconds(60)"))
        #expect(!stats.contains(".seconds(1)"))
        #expect(!stats.contains("while !Task.isCancelled"))
    }

    @Test func resourcesUIDoesNotHideANE() throws {
        let pane = try AppSource.load("Views/ResourcesSettingsPane.swift")
        #expect(pane.contains("Neural Engine"))
        #expect(pane.contains("phys_footprint"))
        #expect(pane.contains("Reclaimable ANE"))
        #expect(pane.contains("100% = one core"))
        #expect(!pane.contains("ScreenCaptureKit"))
    }
}
