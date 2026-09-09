import Charts
import SwiftUI

struct ResourcesSettingsPane: View {
    @State private var window: ResourceHistoryWindow = .live15
    @State private var latest: ResourceSample?
    @State private var live: [ResourceChartPoint] = []
    @State private var historical: [ResourceChartPoint] = []
    @State private var gpuSource: GPUMetrics.Source?
    @State private var sampleTask: Task<Void, Never>?
    @State private var historyTask: Task<Void, Never>?

    var body: some View {
        let points = chartPoints

        Form {
            Section {
                LabeledContent {
                    Text(processCPULabel)
                        .monospacedDigit()
                } label: {
                    Text("CPU")
                    Text("This process · 100% = one core")
                }
                LabeledContent {
                    Text(systemCPULabel)
                        .monospacedDigit()
                } label: {
                    Text("This Mac")
                    Text("All cores · host load")
                }
                LabeledContent {
                    Text(memoryLabel)
                        .monospacedDigit()
                } label: {
                    Text("Memory")
                    Text(memoryCaption)
                }
                LabeledContent {
                    Text(residentLabel)
                        .monospacedDigit()
                } label: {
                    Text("Resident")
                    Text("RSS · pages still mapped")
                }
                LabeledContent {
                    Text(neuralLabel)
                        .monospacedDigit()
                } label: {
                    Text("Neural Engine")
                    Text(neuralCaption)
                }
                LabeledContent {
                    Text(gpuLabel)
                        .monospacedDigit()
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
                unit: "% of one core",
                emptyTitle: "Waiting for CPU samples",
                points: points,
                value: { $0.cpuPercent },
                format: Self.percentLabel,
                yDomain: cpuDomain(points),
                xFormat: window.axisFormat
            )

            ResourceMetricSection(
                title: "Memory",
                unit: "MB footprint",
                emptyTitle: "Waiting for memory samples",
                points: points,
                value: { $0.memoryMegabytes },
                format: Self.memoryAxisLabel,
                yDomain: memoryDomain(points),
                xFormat: window.axisFormat
            )

            ResourceMetricSection(
                title: "Neural Engine",
                unit: "MB reclaimable",
                emptyTitle: "No ANE samples yet",
                points: points,
                value: { $0.neuralMegabytes },
                format: Self.memoryAxisLabel,
                yDomain: neuralDomain(points),
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

    private var processCPULabel: String {
        guard let value = latest?.processCPUPercent else { return "—" }
        return Self.percentLabel(value)
    }

    private var systemCPULabel: String {
        guard let value = latest?.systemCPUPercent else { return "—" }
        return Self.percentLabel(value)
    }

    private var memoryLabel: String {
        guard let latest else { return "—" }
        return Self.bytesLabel(latest.footprintBytes)
    }

    private var memoryCaption: String {
        guard let latest else { return "phys_footprint · Activity Monitor Memory" }
        if latest.neuralInFootprintBytes > 0 {
            return "phys_footprint · includes \(Self.bytesLabel(latest.neuralInFootprintBytes)) ANE in footprint"
        }
        return "phys_footprint · Activity Monitor Memory"
    }

    private var residentLabel: String {
        guard let latest else { return "—" }
        return Self.bytesLabel(latest.residentBytes)
    }

    private var neuralLabel: String {
        guard let latest else { return "—" }
        return Self.bytesLabel(latest.neuralReclaimableBytes)
    }

    private var neuralCaption: String {
        "Reclaimable ANE · not in Memory above"
    }

    private var gpuLabel: String {
        guard let latest, let percent = latest.gpuPercent else { return "—" }
        return Self.percentLabel(percent)
    }

    private var gpuTitle: String {
        switch gpuSource {
        case .process, nil: "GPU"
        case .system: "This Mac GPU"
        }
    }

    private var gpuSubtitle: String {
        let metal: String
        if let bytes = latest?.metalAllocatedBytes {
            metal = "Metal allocated \(Self.bytesLabel(bytes))"
        } else {
            metal = "Metal allocated —"
        }
        switch gpuSource {
        case .process:
            return "This process Metal/AGX time · \(metal)"
        case .system:
            return "This Mac, not Echo alone · \(metal)"
        case nil:
            return "No GPU time yet · \(metal)"
        }
    }

    private var gpuChartTitle: String {
        switch gpuSource {
        case .process: "GPU"
        case .system: "This Mac GPU"
        case nil: "GPU"
        }
    }

    private var gpuEmptyTitle: String {
        "GPU time isn’t available"
    }

    private var resourcesFooter: String {
        let gpu: String
        switch gpuSource {
        case .process:
            gpu = "GPU % is Echo’s Metal/AGX time for this process."
        case .system:
            gpu = "GPU % is this Mac’s GPU (IOAccelerator), not Echo alone."
        case nil:
            gpu = "No GPU time is available — Echo does not show 0 when a sample is missing."
        }
        return """
        CPU is this process: 100% means Echo fully used one logical CPU for the last second. \
        This Mac is host load across all cores. \
        Memory is phys_footprint (Activity Monitor Memory). Resident is RSS. \
        Neural Engine is reclaimable ANE — Parakeet can hold hundreds of MB here that Memory does not include. \
        \(gpu) \
        Charts update once a second while this tab is open. Sampling stops when you leave. \
        Echo stores at most one point per minute from those samples, for about 90 days.
        """
    }

    private func cpuDomain(_ points: [ResourceChartPoint]) -> ClosedRange<Double> {
        let peak = points.map(\.cpuPercent).max() ?? 0
        return 0...max(100, (peak * 1.1).rounded(.up))
    }

    private func memoryDomain(_ points: [ResourceChartPoint]) -> ClosedRange<Double> {
        let peak = points.map(\.memoryMegabytes).max() ?? 0
        return 0...max(8, peak * 1.15)
    }

    private func neuralDomain(_ points: [ResourceChartPoint]) -> ClosedRange<Double> {
        let peak = points.map(\.neuralMegabytes).max() ?? 0
        return 0...max(8, peak * 1.15)
    }

    private static func percentLabel(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    private static func memoryAxisLabel(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1)))) MB"
    }

    private static func bytesLabel(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    private func appear() {
        loadHistory()
        sampleTask?.cancel()
        sampleTask = Task.detached(priority: .utility) {
            var sampler = ResourceSampler()
            while !Task.isCancelled {
                let sample = sampler.tick()
                let persist = sample.flatMap { sampler.persistIfDue($0) }
                if let sample {
                    await MainActor.run {
                        applyLive(sample)
                    }
                }
                if let persist {
                    await ResourceStatsStore.shared.upsert(persist)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @MainActor
    private func applyLive(_ sample: ResourceSample) {
        latest = sample
        if let source = sample.gpuSource {
            gpuSource = source
        }
        guard let point = sample.chartPoint() else { return }
        var next = live
        next.append(point)
        let cutoff = sample.date.addingTimeInterval(-ResourceHistoryWindow.live15.duration)
        if next.count > 960 || next.first?.date ?? sample.date < cutoff {
            next.removeAll { $0.date < cutoff }
        }
        live = next
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
                    description: Text("Samples appear while this tab is open. Echo stores at most one point per minute from those samples.")
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
