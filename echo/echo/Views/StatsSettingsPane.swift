import Charts
import SwiftUI

struct StatsSettingsPane: View {
    @State private var storedTakes: [UsageTake] = []
    @State private var pendingTakes: [UsageTake] = []
    @State private var range: UsageStatsRange = .days15
    @State private var series: UsageChartSeries = .words
    @State private var clock = Date.now
    @State private var selectedDate: Date?
    @State private var loadTask: Task<Void, Never>?
    @State private var pendingTask: Task<Void, Never>?

    var body: some View {
        let takes = mergedTakes
        let snapshot = UsageStatsAggregator.snapshot(
            takes: takes,
            range: range,
            now: clock,
            calendar: .current
        )
        let lifetime = UsageStatsAggregator.totals(in: takes)
        let lastSTT = UsageStatsAggregator.lastSpeechToTextMilliseconds(in: takes)

        Form {
            Section {
                Picker("Range", selection: $range) {
                    ForEach(UsageStatsRange.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                LabeledContent("Words") {
                    Text(snapshot.totalWords.formatted())
                }
                LabeledContent("Takes") {
                    Text(snapshot.totalTakes.formatted())
                }
                LabeledContent {
                    Text(speechToTextLabel(snapshot.averageSpeechToTextMilliseconds))
                } label: {
                    Text("Average speech-to-text")
                    Text("Stop to transcript")
                }
                LabeledContent {
                    Text(speechToTextLabel(lastSTT.map(Double.init)))
                } label: {
                    Text("Last take")
                    Text("Speech-to-text")
                }
            } header: {
                Text("Usage")
            } footer: {
                Text(usageFooter(lifetime: lifetime))
                    .settingsFooter()
            }

            Section {
                Picker("Series", selection: $series) {
                    ForEach(UsageChartSeries.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Series")

                UsageWordsChart(
                    buckets: snapshot.buckets,
                    series: series,
                    range: range,
                    domain: snapshot.domain,
                    selectedDate: $selectedDate
                )
                .id(range.id)
                .frame(minHeight: 200)
                .animation(nil, value: range)
            } header: {
                Text("Per \(range.bucketTitle)")
            } footer: {
                Text(chartFooter(snapshot: snapshot))
                    .settingsFooter()
            }
        }
        .echoSettingsForm()
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
        .onChange(of: range) {
            selectedDate = nil
            clock = Date.now
        }
    }

    private var mergedTakes: [UsageTake] {
        if pendingTakes.isEmpty { return storedTakes }
        var merged = storedTakes
        merged.append(contentsOf: pendingTakes)
        return merged
    }

    private func usageFooter(lifetime: (words: Int, takes: Int)) -> String {
        let kept = "Echo keeps about \(UsageStatsStore.retentionDays) days of takes."
        let all = "All stored: \(lifetime.words.formatted()) words, \(lifetime.takes.formatted()) takes."
        return "\(all) Speech-to-text is stop to transcript, before paste or rewrite. \(kept)"
    }

    private func chartFooter(snapshot: UsageStatsSnapshot) -> String {
        if snapshot.totalTakes == 0 {
            return "No takes in this range. Empty bars still span \(range.title.lowercased())."
        }
        if let selectedDate,
           let row = snapshot.buckets.min(by: {
               abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
           }) {
            let when = row.date.formatted(range.axisFormat)
            return "\(when): \(row.words.formatted()) words, \(row.takes.formatted()) takes."
        }
        return "Each bar is \(range.bucketTitle). Pick Words or Takes above the chart."
    }

    private func speechToTextLabel(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else { return "—" }
        if milliseconds < 1000 {
            return "\(Int(milliseconds.rounded())) ms"
        }
        let seconds = milliseconds / 1000
        return "\(seconds.formatted(.number.precision(.fractionLength(1...2)))) s"
    }

    private func appear() {
        loadTask?.cancel()
        loadTask = Task {
            await UsageStats.flushPending()
            let next = await UsageStatsStore.shared.allTakes()
            guard !Task.isCancelled else { return }
            storedTakes = next
            pendingTakes = UsageStats.peekPending()
            clock = Date.now
        }

        pendingTask?.cancel()
        pendingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                let next = await UsageStatsStore.shared.allTakes()
                guard !Task.isCancelled else { return }
                storedTakes = next
                pendingTakes = UsageStats.peekPending()
                clock = Date.now
            }
        }
    }

    private func disappear() {
        loadTask?.cancel()
        loadTask = nil
        pendingTask?.cancel()
        pendingTask = nil
        Task.detached(priority: .utility) {
            await UsageStats.flushPending()
        }
    }
}

enum UsageChartSeries: String, CaseIterable, Identifiable {
    case words
    case takes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .words: "Words"
        case .takes: "Takes"
        }
    }

    var axisTitle: String {
        title
    }

    func value(for bucket: UsageChartBucket) -> Int {
        switch self {
        case .words: bucket.words
        case .takes: bucket.takes
        }
    }
}

private struct UsageWordsChart: View {
    let buckets: [UsageChartBucket]
    let series: UsageChartSeries
    let range: UsageStatsRange
    let domain: ClosedRange<Date>
    @Binding var selectedDate: Date?

    var body: some View {
        Chart(buckets) { bucket in
            BarMark(
                x: .value("Time", bucket.date),
                y: .value(series.axisTitle, series.value(for: bucket))
            )
            .foregroundStyle(.tint)

            if let selectedDate,
               nearestBucket(to: selectedDate)?.date == bucket.date {
                RuleMark(x: .value("Selected time", bucket.date))
                    .foregroundStyle(.secondary)
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...yMax)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: range.axisFormat, collisionResolution: .greedy)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel()
            }
        }
        .chartXAxisLabel("Time")
        .chartYAxisLabel(series.axisTitle)
        .accessibilityLabel("\(series.title) over \(range.title)")
    }

    private var yMax: Int {
        max(1, buckets.map { series.value(for: $0) }.max() ?? 0)
    }

    private func nearestBucket(to date: Date) -> UsageChartBucket? {
        buckets.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }
}
