import Charts
import SwiftUI

struct ResourcesSettingsPane: View {
    @State private var window: ResourceHistoryWindow = .live15
    @State private var latest: ResourceChartPoint?
    @State private var live: [ResourceChartPoint] = []
    @State private var historical: [ResourceChartPoint] = []
    @State private var gpuSource: GPUMetrics.Source?
    @State private var sampleTask: Task<Void, Never>?
    @State private var historyTask: Task<Void, Never>?

    var body: some View {
        let points = chartPoints

        Form {
            Section {
                LabeledContent("CPU") {
                    Text(cpuLabel)
                }
                LabeledContent {
                    Text(memoryLabel)
                } label: {
                    Text("Memory")
                    Text(residentCaption)
                }
                LabeledContent {
                    Text(gpuLabel)
                } label: {
                    Text(gpuTitle)
                    Text(gpuSubtitle)
                }
                Picker("Range", selection: $window) {
                    ForEach(ResourceHistoryWindow.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Now")
            } footer: {
                Text(resourcesFooter)
                    .settingsFooter()
            }

            ResourceMetricSection(
                title: "CPU",
                unit: "%",
                emptyTitle: "Waiting for CPU samples",
                points: points,
                value: { $0.cpuPercent },
                format: Self.percentLabel,
                yDomain: cpuDomain(points),
                xFormat: window.axisFormat
            )

            ResourceMetricSection(
                title: "Memory",
                unit: "MB",
                emptyTitle: "Waiting for memory samples",
                points: points,
                value: { $0.memoryMegabytes },
                format: Self.memoryAxisLabel,
                yDomain: memoryDomain(points),
                xFormat: window.axisFormat
            )

            ResourceMetricSection(
                title: gpuChartTitle,
                unit: "%",
                emptyTitle: gpuEmptyTitle,
                points: points.filter { $0.gpuPercent != nil },
                value: { $0.gpuPercent ?? 0 },
                format: Self.percentLabel,
                yDomain: 0...100,
                xFormat: window.axisFormat
            )
        }
        .echoSettingsForm()
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
        .onChange(of: window) {
            loadHistory()
        }
    }

    private var chartPoints: [ResourceChartPoint] {
        switch window {
        case .live15:
            live
        case .hour, .day, .week, .days90:
            historical
        }
    }

    private var cpuLabel: String {
        guard let latest else { return "—" }
        return Self.percentLabel(latest.cpuPercent)
    }

    private var memoryLabel: String {
        guard let latest else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: latest.memoryBytes), countStyle: .memory)
    }

    private var residentCaption: String {
        guard let latest else { return "Footprint" }
        let resident = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: latest.residentBytes),
            countStyle: .memory
        )
        return "Footprint · resident \(resident)"
    }

    private var gpuLabel: String {
        guard let latest, let percent = latest.gpuPercent else { return "—" }
        return Self.percentLabel(percent)
    }

    private var gpuTitle: String {
        switch gpuSource {
        case .process, nil: "GPU"
        case .system: "System GPU"
        }
    }

    private var gpuSubtitle: String {
        switch gpuSource {
        case .process: "This process"
        case .system: "This Mac, not Echo alone"
        case nil: "Not available"
        }
    }

    private var gpuChartTitle: String {
        switch gpuSource {
        case .process: "GPU"
        case .system: "System GPU"
        case nil: "GPU"
        }
    }

    private var gpuEmptyTitle: String {
        "GPU utilization isn’t available"
    }

    private var resourcesFooter: String {
        let gpu: String
        switch gpuSource {
        case .process:
            gpu = "GPU is Echo’s Metal/AGX time for this process."
        case .system:
            gpu = "GPU is this Mac’s GPU (IOAccelerator device utilization), not Echo alone."
        case nil:
            gpu = "No GPU figure is available — Echo does not show 0 when a sample is missing."
        }
        return "\(gpu) CPU and memory are this process. Charts update once a second while this tab is open. Echo stores one point per minute for about 90 days."
    }

    private func cpuDomain(_ points: [ResourceChartPoint]) -> ClosedRange<Double> {
        let peak = points.map(\.cpuPercent).max() ?? 0
        return 0...max(100, (peak * 1.1).rounded(.up))
    }

    private func memoryDomain(_ points: [ResourceChartPoint]) -> ClosedRange<Double> {
        let peak = points.map(\.memoryMegabytes).max() ?? 0
        return 0...max(8, peak * 1.15)
    }

    private static func percentLabel(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    private static func memoryAxisLabel(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1)))) MB"
    }

    private func appear() {
        loadHistory()
        sampleTask?.cancel()
        sampleTask = Task.detached(priority: .utility) {
            var previousMetrics: ProcessMetrics.Raw?
            var previousGPUTimeNS: UInt64?
            var previousWallNS: UInt64?
            while !Task.isCancelled {
                let now = Date.now
                let raw = ProcessMetrics.read()
                let gpuRaw = GPUMetrics.readRaw()
                var cpu = 0.0
                var memory: UInt64 = 0
                var resident: UInt64 = 0
                let hadPrevious = previousMetrics != nil
                if let raw {
                    if let previousMetrics {
                        cpu = ProcessMetrics.cpuPercent(from: previousMetrics, to: raw)
                    }
                    memory = raw.footprintBytes > 0 ? raw.footprintBytes : raw.residentBytes
                    resident = raw.residentBytes
                    previousMetrics = raw
                }
                let wallNS = ProcessMetrics.nanoseconds(fromMachTicks: mach_absolute_time())
                let reading = ResourceStats.reading(
                    gpuRaw: gpuRaw,
                    previousGPUTimeNS: previousGPUTimeNS,
                    previousWallNS: previousWallNS,
                    wallNS: wallNS
                )
                previousGPUTimeNS = gpuRaw.processGPUTimeNS
                previousWallNS = wallNS
                guard hadPrevious else {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }

                let point = ResourceChartPoint(
                    date: now,
                    cpuPercent: cpu,
                    memoryBytes: memory,
                    residentBytes: resident,
                    gpuPercent: reading?.percent,
                    gpuSource: reading?.source
                )
                await MainActor.run {
                    latest = point
                    gpuSource = reading?.source ?? gpuSource
                    var next = live
                    next.append(point)
                    let cutoff = now.addingTimeInterval(-ResourceHistoryWindow.live15.duration)
                    if next.count > 960 || next.first?.date ?? now < cutoff {
                        next.removeAll { $0.date < cutoff }
                    }
                    live = next
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func disappear() {
        sampleTask?.cancel()
        sampleTask = nil
        historyTask?.cancel()
        historyTask = nil
    }

    private func loadHistory() {
        historyTask?.cancel()
        let selected = window
        historyTask = Task {
            let end = Date.now
            let start = end.addingTimeInterval(-selected.duration)
            let points = await ResourceStatsStore.shared.snapshot(
                from: start,
                to: end,
                maxPoints: selected.chartPointBudget
            )
            guard !Task.isCancelled else { return }
            historical = points
        }
    }
}

private struct ResourceMetricSection: View {
    let title: String
    let unit: String
    let emptyTitle: String
    let points: [ResourceChartPoint]
    var value: (ResourceChartPoint) -> Double
    var format: (Double) -> String
    var yDomain: ClosedRange<Double>
    var xFormat: Date.FormatStyle

    var body: some View {
        Section {
            if points.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "chart.xyaxis.line",
                    description: Text("Samples appear while Resources is open, and once a minute while Echo is running.")
                )
                .frame(minHeight: 140)
            } else {
                ResourceAreaChart(
                    title: title,
                    unit: unit,
                    points: points,
                    value: value,
                    format: format,
                    yDomain: yDomain,
                    xFormat: xFormat
                )
                .frame(minHeight: 156)
            }
        } header: {
            Text(title)
        }
    }
}

private struct ResourceAreaChart: View {
    let title: String
    let unit: String
    let points: [ResourceChartPoint]
    var value: (ResourceChartPoint) -> Double
    var format: (Double) -> String
    var yDomain: ClosedRange<Double>
    var xFormat: Date.FormatStyle
    @State private var selected: Date?

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    y: .value(title, value(point))
                )
                .foregroundStyle(.tint.opacity(0.28))
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", point.date),
                    y: .value(title, value(point))
                )
                .foregroundStyle(.tint)
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }

            if let selected, let nearest = nearest(to: selected) {
                RuleMark(x: .value("Selected time", nearest.date))
                    .foregroundStyle(.secondary)
                PointMark(
                    x: .value("Time", nearest.date),
                    y: .value(title, value(nearest))
                )
                .foregroundStyle(.primary)
                .annotation(position: .top, spacing: 4) {
                    Text(format(value(nearest)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .chartXSelection(value: $selected)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: resolvedXFormat, collisionResolution: .greedy)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel()
            }
        }
        .chartXAxisLabel("Time")
        .chartYAxisLabel(unit)
        .chartYScale(domain: yDomain)
        .accessibilityLabel("\(title) over time")
    }

    private var resolvedXFormat: Date.FormatStyle {
        guard let first = points.first, let last = points.last else { return xFormat }
        if last.date.timeIntervalSince(first.date) < 180 {
            return .dateTime.hour().minute().second()
        }
        return xFormat
    }

    private func nearest(to date: Date) -> ResourceChartPoint? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
}
