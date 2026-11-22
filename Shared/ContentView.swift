import SwiftUI
#if os(iOS)
import Charts
#endif

struct ContentView: View {
    @ObservedObject private var manager = HRVManager.shared
    @Environment(\.scenePhase) private var scenePhase
    #if os(watchOS)
    @ObservedObject private var workout = WorkoutHeartRateMonitor.shared
    #endif

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let current = manager.visibleSnapshot(at: context.date)
            let expired = manager.snapshot.relativeLoad != nil && current.relativeLoad == nil
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "heart.text.square.fill")
                            .foregroundStyle(.red)
                        Text("WatchHRV").font(.headline)
                        Spacer(minLength: 4)
                        if manager.isLoading { ProgressView().controlSize(.small) }
                    }

                    Text("个人生理负荷 · 近期趋势")
                        .font(.caption).foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 7) {
                        Text(current.relativeLoad.map { "\($0) / 100" } ?? "-- / 100")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Label(current.level, systemImage: "waveform.path.ecg")
                            .font(.headline)
                        if expired {
                            Label("先前评分已失效", systemImage: "clock.badge.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if let load = current.relativeLoad {
                            ProgressView(value: Double(load), total: 100)
                                .tint(load > 65 ? .orange : .teal)
                        }
                        Text("质量：\(current.quality)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

                    HStack(alignment: .top, spacing: 12) {
                        metric("心率", number(current.heartRate), "bpm",
                               date: current.heartRateAt, now: context.date)
                        metric("HRV", number(current.hrv), "ms",
                               date: current.hrvAt, now: context.date,
                               note: current.latestHRVIsMindful == true ? "正念呼吸记录" :
                                    (current.latestHRVIsSleep == true ? "睡眠期间记录" : nil))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        metric("HRV 基线", number(current.hrvBaseline), "ms",
                               date: nil, now: context.date)
                        metric("心率个人基线", number(current.sedentaryHRBaseline), "bpm",
                               date: nil, now: context.date)
                    }

                    #if os(iOS)
                    if !current.dailyHRV.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("近 7 天 HRV 中位数").font(.headline)
                            Chart(current.dailyHRV) { item in
                                LineMark(x: .value("日期", item.day),
                                         y: .value("HRV", item.value))
                                PointMark(x: .value("日期", item.day),
                                          y: .value("HRV", item.value))
                            }
                            .frame(height: 150)
                        }
                    }
                    #endif

                    manualHRVSection

                    #if os(watchOS)
                    liveWorkoutSection
                    #endif

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    // Anchored queries update all metrics, baselines and trends,
                    // including late arrivals, without re-reading 30 days each tap.
                    manager.refresh()
                } label: {
                    Label("读取最新记录", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.isLoading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial)
            }
        }
        .task(id: scenePhase) {
            // Foreground-only polling. This checks HealthKit for newly SAVED
            // samples; it does not instruct Apple Watch to take new readings.
            // Task cancellation stops the loop when the app leaves foreground.
            guard scenePhase == .active else { return }
            manager.refresh()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(120))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                manager.refresh()
            }
        }
    }

    private var manualHRVSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("手动 HRV 测量指引", systemImage: "waveform.path")
                .font(.headline)
            Text("前往 Apple Watch「正念」→「呼吸」，坐姿完成约 1 分钟练习，再返回 WatchHRV 查看新 HRV 记录。")
                .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    #if os(watchOS)
    private var liveWorkoutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("运动时实时心率", systemImage: "heart.circle")
                .font(.headline)
            Text("运动期间实时采集心率，结束后保存运动记录。")
                .font(.caption2).foregroundStyle(.secondary)
            Text(workout.bpm.map { String(format: "%.0f bpm", $0) } ?? "-- bpm")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(workout.message)
                .font(.caption2).foregroundStyle(.secondary)
            if workout.isBusy { ProgressView().controlSize(.small) }
            Button {
                if workout.isRunning { workout.stop() } else { workout.start() }
            } label: {
                Label(workout.isRunning ? "结束并保存运动" : "开始运动心率", systemImage:
                        workout.isRunning ? "stop.circle" : "play.circle")
            }
            .disabled(workout.isBusy)
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    #endif

    private func metric(_ title: String, _ value: String, _ unit: String,
                        date: Date?, now: Date, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text("\(value) \(unit)").font(.headline).minimumScaleFactor(0.65).lineLimit(1)
            if let date {
                Text(age(date, now: now))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func number(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f", value)
    }

    private func age(_ date: Date?, now: Date) -> String {
        guard let date else { return "无记录" }
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 { return "不到 1 分钟前" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) 分钟前" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600)) 小时前" }
        return "\(Int(elapsed / 86400)) 天前"
    }
}
