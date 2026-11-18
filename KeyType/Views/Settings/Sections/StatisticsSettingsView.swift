//
//  StatisticsSettingsView.swift
//  KeyType
//
//  The "统计" Settings pane: read-only local telemetry (acceptance/suppression and the
//  end-to-end latency the user actually perceives, broken down by phase + a distribution chart).
//  Split out of SettingsView so each sidebar category lives in its own file.
//

import Charts
import Personalization
import SwiftUI
import UniformTypeIdentifiers

struct StatisticsSettingsView: View {
    let telemetry: CompletionTelemetryStore
    /// Closure that snapshots telemetry + collects device/engine info and returns the JSON payload
    /// the "Export data" button should write to disk. Injected so this view stays decoupled from
    /// `SettingsStore` and from `LatencyExportContext`'s `sysctl`/`Bundle` lookups (which would
    /// pull AppKit/system imports into a pane that's otherwise pure SwiftUI). Returning `nil`
    /// surfaces an inline error in the file picker rather than silently writing an empty file.
    let makeLatencyExport: () -> Data?

    @State private var snapshot: TelemetrySnapshot = TelemetrySnapshot()
    @State private var snapshots: [CompletionTelemetrySnapshotFile] = []
    @State private var selectedSnapshotIDs: Set<String> = []
    @State private var exportDocument: LatencyExportDocument?
    @State private var isExportPresented = false
    @State private var exportError: String?
    @State private var snapshotError: String?
    @State private var snapshotStatus: String?

    var body: some View {
        Form {
            Section("总延迟分布") {
                LatencyDistributionChart(series: chartSeries)
                    .frame(minHeight: 180)
                snapshotMenu
            }
            
            Section("本地统计") {
                statRow(
                    "建议接受率",
                    detail: "每条建议最多计一次接受。从新版开始统计。",
                    value: { sample in
                        guard sample.trackedShownCount > 0 else { return "暂无样本" }
                        return "\(percent(sample.acceptanceRate))（\(sample.uniqueAcceptedCount)/\(sample.trackedShownCount)）"
                    }
                )
                statRow(
                    "累计补全记录",
                    detail: "含旧版数据。同一条建议可分多次接受。",
                    value: { "接受 \($0.acceptedCount) 次 / 显示 \($0.shownCount) 条" }
                )
                statRow(
                    "过滤率",
                    detail: "过滤 \(snapshot.suppressedCount) 次，生成 \(snapshot.generatedCount) 次",
                    value: { percent($0.suppressionRate) }
                )
            }

            Section("端到端延迟") {
                let e2e = snapshot.endToEnd
                let totalsDetail = e2e.sampleCount > 0
                    ? "\(e2e.sampleCount) 次已显示的补全，平均 \(ms(e2e.total.mean))"
                    : "暂无已显示的补全。请在支持的应用中输入文字。"
                statRow(
                    "总耗时（从捕获到显示）",
                    detail: totalsDetail,
                    value: { percentilePair($0.endToEnd.total, sampleCount: $0.endToEnd.sampleCount) }
                )
                statRow(
                    "构建提示词",
                    detail: "从获取无障碍快照到构建提示词（主线程）",
                    value: { percentilePair($0.endToEnd.promptBuild, sampleCount: $0.endToEnd.sampleCount) }
                )
                statRow(
                    "输入停顿等待",
                    detail: "开始生成前用于合并连续输入的等待",
                    value: { percentilePair($0.endToEnd.debounce, sampleCount: $0.endToEnd.sampleCount) }
                )
                statRow(
                    "模型生成",
                    detail: "本地模式记录模型解码耗时。API 模式包含网络往返和服务端生成。",
                    value: { percentilePair($0.endToEnd.generation, sampleCount: $0.endToEnd.sampleCount) }
                )
                statRow(
                    "显示灰字",
                    detail: "过滤、定位并绘制灰字的耗时",
                    value: { percentilePair($0.endToEnd.present, sampleCount: $0.endToEnd.sampleCount) }
                )

                HStack {
                    Button("刷新统计") { refreshStats() }
                    Button("导出数据…") { beginExport() }
                        .help("将原始延迟样本和设备信息保存为 JSON，以便共享给 KeyType 的维护者。")
                    Button("保存统计快照") { snapshotStats() }
                        .help("将当前统计保存为本地快照，供对比使用，然后重置当前统计。")
                    Spacer()
                }
                .font(.footnote)

                if let exportError {
                    Text(exportError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if let snapshotError {
                    Text(snapshotError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if let snapshotStatus {
                    Text(snapshotStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { refreshStats() }
        .fileExporter(
            isPresented: $isExportPresented,
            document: exportDocument,
            contentType: .json,
            defaultFilename: LatencyExporter.suggestedFilename()
        ) { result in
            switch result {
            case .success:
                exportError = nil
            case let .failure(error):
                exportError = "无法保存导出文件。\(error.localizedDescription)"
            }
            exportDocument = nil
        }
    }

    private var selectedSnapshots: [CompletionTelemetrySnapshotFile] {
        snapshots.filter { selectedSnapshotIDs.contains($0.id) }
    }

    private var metricSeries: [LatencyMetricSeries] {
        var series = [
            LatencyMetricSeries(
                id: "current",
                label: "当前",
                color: .orange,
                snapshot: snapshot
            )
        ]
        for (index, archive) in selectedSnapshots.enumerated() {
            series.append(
                LatencyMetricSeries(
                    id: archive.id,
                    label: snapshotLabel(for: archive),
                    color: Self.snapshotColors[index % Self.snapshotColors.count],
                    snapshot: archive.snapshot
                )
            )
        }
        return series
    }

    private var chartSeries: [LatencyDistributionSeries] {
        metricSeries.map {
            LatencyDistributionSeries(
                id: $0.id,
                label: $0.label,
                color: $0.color,
                samples: $0.snapshot.endToEnd.totalSamples
            )
        }
    }

    private var snapshotSelectionSummary: String {
        if snapshots.isEmpty { return "尚未保存统计快照" }
        return "已选 \(selectedSnapshotIDs.count) 项，最多 2 项"
    }

    private var snapshotMenu: some View {
        HStack {
            Menu {
                if snapshots.isEmpty {
                    Text("没有快照")
                } else {
                    ForEach(snapshots) { archive in
                        Toggle(isOn: snapshotSelectionBinding(for: archive)) {
                            Text(snapshotLabel(for: archive))
                        }
                        .disabled(!selectedSnapshotIDs.contains(archive.id) && selectedSnapshotIDs.count >= 2)
                    }
                    Divider()
                }
                Button("刷新快照") { reloadSnapshots() }
            } label: {
                Label("对比快照", systemImage: "chart.bar.xaxis")
            }
            Text(snapshotSelectionSummary)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.footnote)
    }

    private static let snapshotColors: [Color] = [.blue, .purple]

    private static let snapshotLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private func refreshStats() {
        snapshot = telemetry.snapshot()
        reloadSnapshots()
    }

    private func reloadSnapshots() {
        snapshots = telemetry.archivedSnapshots()
        let validIDs = Set(snapshots.map(\.id))
        selectedSnapshotIDs.formIntersection(validIDs)
    }

    private func snapshotSelectionBinding(for archive: CompletionTelemetrySnapshotFile) -> Binding<Bool> {
        Binding(
            get: { selectedSnapshotIDs.contains(archive.id) },
            set: { isSelected in
                if isSelected {
                    guard selectedSnapshotIDs.count < 2 || selectedSnapshotIDs.contains(archive.id) else {
                        return
                    }
                    selectedSnapshotIDs.insert(archive.id)
                } else {
                    selectedSnapshotIDs.remove(archive.id)
                }
            }
        )
    }

    private func snapshotLabel(for archive: CompletionTelemetrySnapshotFile) -> String {
        if let createdAt = archive.createdAt {
            return Self.snapshotLabelFormatter.string(from: createdAt)
        }
        return archive.filename
    }

    /// Build the JSON payload, refresh the on-screen snapshot so the percentile rows match the
    /// file the user just produced, then trigger the save panel. Doing the encode synchronously
    /// up-front means the panel only opens when there's something real to write.
    private func beginExport() {
        guard let data = makeLatencyExport() else {
            exportError = "无法将延迟数据编码为导出文件。"
            return
        }
        snapshot = telemetry.snapshot()
        exportError = nil
        exportDocument = LatencyExportDocument(data: data)
        isExportPresented = true
    }

    private func snapshotStats() {
        do {
            let archive = try telemetry.snapshotCurrentStats()
            snapshot = telemetry.snapshot()
            reloadSnapshots()
            var selected = selectedSnapshotIDs
            selected.insert(archive.id)
            if selected.count > 2 {
                let ordered = [archive.id] + snapshots.map(\.id).filter {
                    $0 != archive.id && selected.contains($0)
                }
                selected = Set(ordered.prefix(2))
            }
            selectedSnapshotIDs = selected
            snapshotError = nil
            snapshotStatus = "已保存 \(archive.filename)，并重置当前统计。"
        } catch {
            snapshotStatus = nil
            snapshotError = "无法保存统计快照。\(error.localizedDescription)"
        }
    }

    private func statRow(
        _ title: String,
        detail: String,
        value: @escaping (TelemetrySnapshot) -> String
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            metricValues(value)
        }
    }

    @ViewBuilder
    private func metricValues(_ value: @escaping (TelemetrySnapshot) -> String) -> some View {
        let series = metricSeries
        if series.count == 1, let current = series.first {
            Text(value(current.snapshot))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(series) { item in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 7, height: 7)
                        Text(item.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(value(item.snapshot))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 82, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private func ms(_ value: Double) -> String {
        // Sub-millisecond figures (prompt build / present on a fast machine) round to "0 ms" with a
        // bare `%.0f`, which reads as "nothing happened". Keep one decimal under 10 ms so the row
        // still shows that the phase exists and ran in well under a millisecond.
        value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
    }

    private func percentilePair(_ stats: LatencyPhaseStats, sampleCount: Int) -> String {
        guard sampleCount > 0 else { return "—" }
        return "P50 \(ms(stats.p50)) · P95 \(ms(stats.p95))"
    }
}

private struct LatencyMetricSeries: Identifiable {
    let id: String
    let label: String
    let color: Color
    let snapshot: TelemetrySnapshot
}

// MARK: - Distribution chart

private struct LatencyDistributionSeries: Identifiable {
    let id: String
    let label: String
    let color: Color
    let samples: [Double]
}

/// Bar histogram of recent end-to-end latency samples. Designed to surface skew and the long tail
/// the percentile rows above hide — if the bulk of bars sit far left of `p95`, the slowness is rare
/// rather than typical, which is the most common KeyType latency shape.
private struct LatencyDistributionChart: View {
    let series: [LatencyDistributionSeries]

    var body: some View {
        if series.allSatisfy({ $0.samples.isEmpty }) {
            ContentUnavailableView(
                "暂无延迟样本",
                systemImage: "chart.bar.xaxis",
                description: Text("显示补全后，这里会绘制从捕获到显示的延迟分布。")
            )
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            chart
        }
    }

    private var chart: some View {
        let activeSeries = series.filter { !$0.samples.isEmpty }
        let bins = LatencyHistogram.bins(for: activeSeries)
        let currentBins = bins.filter(\.isCurrent)
        let outlinePoints = LatencyHistogram.outlinePoints(for: bins, comparesSeries: activeSeries.count > 1)
        let domain = LatencyHistogram.domain(for: bins)
        let comparesSeries = activeSeries.count > 1
        // Use RectangleMark, not BarMark, for a fixed-bin histogram. BarMark's three-bound form
        // `(xStart:xEnd:y:)` reads the numeric `y` as a *position* and draws a thin horizontal
        // stripe at that height (the "floating pills" bug). BarMark has no 4-bound form; the
        // canonical primitive for a histogram with explicit bin boundaries is a rectangle from
        // (lowerBound, 0) to (upperBound, count).
        return Chart {
            ForEach(currentBins) { bin in
                RectangleMark(
                    xStart: .value("起点", bin.lowerBound),
                    xEnd: .value("终点", bin.upperBound),
                    yStart: .value("零点", 0),
                    yEnd: .value(comparesSeries ? "占比" : "次数", bin.yValue(comparesSeries: comparesSeries))
                )
                .foregroundStyle(by: .value("系列", bin.seriesLabel))
                .opacity(0.82)
            }

            ForEach(outlinePoints) { point in
                LineMark(
                    x: .value("延迟", point.x),
                    y: .value(comparesSeries ? "占比" : "次数", point.y),
                    series: .value("系列", point.seriesLabel)
                )
                .foregroundStyle(by: .value("系列", point.seriesLabel))
                .lineStyle(StrokeStyle(lineWidth: 2.25, lineCap: .butt, lineJoin: .round))
                .interpolationMethod(.linear)
            }
        }
        .chartXScale(domain: domain)
        .chartForegroundStyleScale(
            domain: activeSeries.map(\.label),
            range: activeSeries.map(\.color)
        )
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let ms = value.as(Double.self) {
                        Text(LatencyHistogram.axisLabel(forMilliseconds: ms))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if comparesSeries, let share = value.as(Double.self) {
                        Text("\(Int(share))%")
                    } else if let count = value.as(Double.self) {
                        Text("\(Int(count))")
                    }
                }
            }
        }
        .chartXAxisLabel("延迟（毫秒）")
        .chartYAxisLabel(comparesSeries ? "样本占比" : "补全次数")
    }
}

// MARK: - Histogram bucketing

private struct LatencyHistogramBin: Identifiable {
    let seriesID: String
    let seriesLabel: String
    let lowerBound: Double
    let upperBound: Double
    let count: Int
    let sampleCount: Int
    let isCurrent: Bool

    var id: String { "\(seriesID)-\(lowerBound)" }
    var sharePercent: Double {
        sampleCount > 0 ? Double(count) / Double(sampleCount) * 100 : 0
    }
    func yValue(comparesSeries: Bool) -> Double {
        comparesSeries ? sharePercent : Double(count)
    }
}

private struct LatencyHistogramOutlinePoint: Identifiable {
    let seriesID: String
    let seriesLabel: String
    let index: Int
    let x: Double
    let y: Double

    var id: String { "\(seriesID)-\(index)" }
}

private struct LatencyHistogramSeriesKey: Hashable {
    let id: String
    let label: String

    init(_ bin: LatencyHistogramBin) {
        self.id = bin.seriesID
        self.label = bin.seriesLabel
    }
}

private enum LatencyHistogram {
    /// Bucket latency samples into roughly `desiredBinCount` equal-width bins between the observed
    /// min and max. Falls back to a single bin when the samples are degenerate (all equal, or one
    /// sample) so the chart still renders meaningfully instead of dividing by zero.
    static func bins(for samples: [Double], desiredBinCount: Int = 18) -> [LatencyHistogramBin] {
        bins(
            for: [
                LatencyDistributionSeries(
                    id: "current",
                    label: "当前",
                    color: .accentColor,
                    samples: samples
                )
            ],
            desiredBinCount: desiredBinCount
        )
    }

    static func bins(
        for series: [LatencyDistributionSeries],
        desiredBinCount: Int = 18
    ) -> [LatencyHistogramBin] {
        let allSamples = series.flatMap(\.samples)
        guard !allSamples.isEmpty else { return [] }
        let lo = allSamples.min() ?? 0
        let hi = allSamples.max() ?? lo
        let span = hi - lo
        let maxSampleCount = series.map(\.samples.count).max() ?? allSamples.count
        guard span > .ulpOfOne else {
            return series.flatMap { item in
                guard !item.samples.isEmpty else { return [LatencyHistogramBin]() }
                return [
                    LatencyHistogramBin(
                        seriesID: item.id,
                        seriesLabel: item.label,
                        lowerBound: lo,
                        upperBound: lo + 1,
                        count: item.samples.count,
                        sampleCount: item.samples.count,
                        isCurrent: item.id == "current"
                    )
                ]
            }
        }
        let binCount = max(1, min(desiredBinCount, maxSampleCount))
        let width = span / Double(binCount)
        return series.flatMap { item in
            guard !item.samples.isEmpty else { return [LatencyHistogramBin]() }
            var counts = Array(repeating: 0, count: binCount)
            for sample in item.samples {
                // The last bin is inclusive on the upper bound so the observed max isn't dropped.
                let raw = Int(((sample - lo) / width).rounded(.down))
                let index = min(max(raw, 0), binCount - 1)
                counts[index] += 1
            }
            return (0..<binCount).map { i in
                LatencyHistogramBin(
                    seriesID: item.id,
                    seriesLabel: item.label,
                    lowerBound: lo + Double(i) * width,
                    upperBound: lo + Double(i + 1) * width,
                    count: counts[i],
                    sampleCount: item.samples.count,
                    isCurrent: item.id == "current"
                )
            }
        }
    }

    static func outlinePoints(
        for bins: [LatencyHistogramBin],
        comparesSeries: Bool
    ) -> [LatencyHistogramOutlinePoint] {
        let snapshotBins = bins.filter { !$0.isCurrent }
        let grouped = Dictionary(grouping: snapshotBins, by: LatencyHistogramSeriesKey.init)
        return grouped.keys.sorted { $0.label < $1.label }.flatMap { key in
            let sortedBins = (grouped[key] ?? []).sorted {
                if $0.lowerBound == $1.lowerBound {
                    return $0.upperBound < $1.upperBound
                }
                return $0.lowerBound < $1.lowerBound
            }
            guard let first = sortedBins.first, let last = sortedBins.last else {
                return [LatencyHistogramOutlinePoint]()
            }

            var points: [LatencyHistogramOutlinePoint] = [
                LatencyHistogramOutlinePoint(
                    seriesID: key.id,
                    seriesLabel: key.label,
                    index: 0,
                    x: first.lowerBound,
                    y: 0
                )
            ]
            var index = 1
            for bin in sortedBins {
                let y = bin.yValue(comparesSeries: comparesSeries)
                points.append(
                    LatencyHistogramOutlinePoint(
                        seriesID: key.id,
                        seriesLabel: key.label,
                        index: index,
                        x: bin.lowerBound,
                        y: y
                    )
                )
                index += 1
                points.append(
                    LatencyHistogramOutlinePoint(
                        seriesID: key.id,
                        seriesLabel: key.label,
                        index: index,
                        x: bin.upperBound,
                        y: y
                    )
                )
                index += 1
            }
            points.append(
                LatencyHistogramOutlinePoint(
                    seriesID: key.id,
                    seriesLabel: key.label,
                    index: index,
                    x: last.upperBound,
                    y: 0
                )
            )
            return points
        }
    }

    /// Axis label that switches to seconds once the value crosses 1 s so two- and three-digit
    /// millisecond labels don't crowd the axis on slow-machine outliers.
    static func axisLabel(forMilliseconds value: Double) -> String {
        if value >= 1_000 {
            return String(format: "%.1fs", value / 1_000)
        }
        return String(format: "%.0f", value)
    }

    /// X-axis domain that hugs the observed range. Without this, Swift Charts anchors the
    /// continuous x scale at 0, which produces an empty 0–lo stretch on the left of the chart
    /// (KeyType's `total` is never near zero — there's always at least the debounce wait). The
    /// padding term keeps the leftmost / rightmost bars from sitting flush against the axis.
    static func domain(for bins: [LatencyHistogramBin]) -> ClosedRange<Double> {
        guard let first = bins.first, let last = bins.last else { return 0...1 }
        let span = max(last.upperBound - first.lowerBound, 1)
        let pad = span * 0.02
        return (first.lowerBound - pad)...(last.upperBound + pad)
    }
}

// MARK: - Export document

/// Trivial `FileDocument` wrapper that hands the pre-encoded latency JSON to SwiftUI's
/// `.fileExporter` save panel. Read-side decoding is implemented for completeness so the type
/// satisfies `FileDocument`'s symmetry contract, but KeyType never opens its own exports — the
/// data is intended to flow outward to the maintainers, not back into the app.
struct LatencyExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
