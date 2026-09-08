import Charts
import SwiftUI

struct StatsSettingsPane: View {
    @State private var snapshot = UsageStatsSnapshot.empty
    @State private var range: UsageStatsRange = .last7
    @State private var series: UsageChartSeries = .words
    @State private var pendingWords = 0
    @State private var pendingTakes = 0
    @State private var selectedDay: Date?
    @State private var loadTask: Task<Void, Never>?
    @State private var pendingTask: Task<Void, Never>?

    var body: some View {
        let visible = displayedSnapshot
        let totals = visible.totals(for: range)
        let perDay = visible.averageWordsPerDay(for: range)
        let days = visible.chartDays(for: range)

        Form {
            Section {
                LabeledContent("Words spoken") {
                    Text(visible.totalWords.formatted())
                }
                LabeledContent("Takes") {
                    Text(visible.totalTakes.formatted())
                }
                Picker("Range", selection: $range) {
                    ForEach(UsageStatsRange.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                LabeledContent("Words") {
                    Text(totals.words.formatted())
                }
                LabeledContent("Takes") {
                    Text(totals.takes.formatted())
                }
                LabeledContent("Per day") {
                    Text(perDay.formatted(.number.precision(.fractionLength(0...1))))
                }
            } header: {
                Text("Totals")
            } footer: {
                Text("Word counts update after Echo pastes a take. Echo keeps about 120 days of daily totals.")
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

                if days.allSatisfy({ $0.words == 0 && $0.takes == 0 }) {
                    ContentUnavailableView(
                        "No takes in this range",
                        systemImage: "chart.bar",
                        description: Text("Paste a take and the bars show up here.")
                    )
                    .frame(minHeight: 160)
                } else {
                    UsageWordsChart(
                        days: days,
                        series: series,
                        selectedDay: $selectedDay
                    )
                    .frame(minHeight: 200)
                }
            } header: {
                Text("Per day")
            } footer: {
                Text(chartFooter(days: days))
                    .settingsFooter()
            }
        }
        .echoSettingsForm()
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
    }

    private var displayedSnapshot: UsageStatsSnapshot {
        snapshot.addingPending(
            words: pendingWords,
            takes: pendingTakes,
            today: UsageCalendar.dayKey(for: .now, calendar: .current)
        )
    }

    private func chartFooter(days: [UsageChartDay]) -> String {
        if let selectedDay,
           let row = days.min(by: { abs($0.date.timeIntervalSince(selectedDay)) < abs($1.date.timeIntervalSince(selectedDay)) }) {
            let day = row.date.formatted(.dateTime.month(.abbreviated).day())
            return "\(day): \(row.words.formatted()) words, \(row.takes.formatted()) takes."
        }
        return "Each bar is one day. Pick Words or Takes above the chart."
    }

    private func appear() {
        loadTask?.cancel()
        loadTask = Task {
            await UsageStats.flushPending()
            let next = await UsageStatsStore.shared.snapshot()
            guard !Task.isCancelled else { return }
            snapshot = next
            let pending = UsageStats.peekPending()
            pendingWords = pending.words
            pendingTakes = pending.takes
        }

        pendingTask?.cancel()
        pendingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                let pending = UsageStats.peekPending()
                pendingWords = pending.words
                pendingTakes = pending.takes
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

    func value(for day: UsageChartDay) -> Int {
        switch self {
        case .words: day.words
        case .takes: day.takes
        }
    }
}

private struct UsageWordsChart: View {
    let days: [UsageChartDay]
    let series: UsageChartSeries
    @Binding var selectedDay: Date?

    var body: some View {
        Chart(days) { day in
            BarMark(
                x: .value("Day", day.date, unit: .day),
                y: .value(series.axisTitle, series.value(for: day))
            )
            .foregroundStyle(.tint)

            if let selectedDay, Calendar.current.isDate(day.date, inSameDayAs: selectedDay) {
                RuleMark(x: .value("Selected day", day.date, unit: .day))
                    .foregroundStyle(.secondary)
            }
        }
        .chartXSelection(value: $selectedDay)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), collisionResolution: .greedy)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel()
            }
        }
        .chartXAxisLabel("Day")
        .chartYAxisLabel(series.axisTitle)
        .chartYScale(domain: .automatic(includesZero: true))
        .accessibilityLabel("\(series.title) per day")
    }
}
