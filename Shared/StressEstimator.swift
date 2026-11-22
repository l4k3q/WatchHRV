import Foundation

// MARK: - Data model (no HealthKit dependency, easy to test)

nonisolated struct MetricReading {
    let value: Double
    let date: Date
    /// 0 = unknown, 1 = sedentary, 2 = active (HealthKit motion-context raw values).
    let motion: Int
}

nonisolated struct HRVDailyPoint: Codable, Identifiable, Equatable {
    let day: Date
    let value: Double
    var id: Date { day }
}

nonisolated struct HRVSnapshot: Codable, Equatable {
    var calculatedAt: Date
    var hrv: Double?
    var hrvAt: Date?
    var heartRate: Double?
    var heartRateAt: Date?
    var heartRateMotion: Int
    var stepsLast10Minutes: Double?
    var hrvBaseline: Double?
    var sedentaryHRBaseline: Double?
    var restingHR: Double?
    var relativeLoad: Int?
    /// Actual HRV sample that participated in the score (nil for heart-rate-only scores).
    var scoredHRVAt: Date?
    var level: String
    var explanation: String
    var quality: String
    var dailyHRV: [HRVDailyPoint]
    /// Optional for compatibility with snapshots sent by older app versions.
    var hrOnlyLoad: Int? = nil
    var latestHRVIsMindful: Bool? = nil
    /// Sleep readings stay visible but are excluded from the waking baseline/score.
    /// Optional fields allow decoding previously synchronized snapshots.
    var latestHRVIsSleep: Bool? = nil
    var sleepSuppressedAt: Date? = nil

    static var empty: HRVSnapshot {
        HRVSnapshot(calculatedAt: .distantPast,
                    hrv: nil, hrvAt: nil, heartRate: nil, heartRateAt: nil,
                    heartRateMotion: 0, stepsLast10Minutes: nil,
                    hrvBaseline: nil, sedentaryHRBaseline: nil, restingHR: nil,
                    relativeLoad: nil, scoredHRVAt: nil, level: "等待数据",
                    explanation: "正在读取健康记录。", quality: "暂无记录", dailyHRV: [])
    }

    /// Last *measurement* date; calculatedAt must not be used as data freshness.
    var lastMeasurementAt: Date? {
        [hrvAt, heartRateAt].compactMap { $0 }.max()
    }

    /// Never show an old score as the user's current physiological state.
    /// The original calculatedAt and sample timestamps remain unchanged for auditability.
    func validated(at now: Date) -> HRVSnapshot {
        guard relativeLoad != nil else { return self }
        var result = self
        guard let hrAt = heartRateAt,
              now.timeIntervalSince(hrAt) <= 15 * 60,
              now.timeIntervalSince(hrAt) >= -120 else {
            result.relativeLoad = nil
            result.level = "评分已过期"
            result.quality = "心率数据超过 15 分钟"
            result.explanation = "请刷新以更新评分。获取最近 15 分钟的心率记录后，将显示新的生理负荷结果；历史 HRV 仍可查看。"
            return result
        }
        if let includedHRVAt = scoredHRVAt,
           (now.timeIntervalSince(includedHRVAt) > StressEstimator.maxScoredHRVAge ||
            abs(includedHRVAt.timeIntervalSince(hrAt)) > StressEstimator.maxHRVHRSeparation) {
            result.scoredHRVAt = nil
            if let hrOnly = hrOnlyLoad {
                result.relativeLoad = hrOnly
                result.level = hrOnly < 36 ? "低于近期常态" :
                    (hrOnly > 65 ? "高于近期常态" : "接近近期常态")
                result.quality = "仅心率粗略参考"
                result.explanation = "当前依据最近心率与个人基线估算生理负荷；新 HRV 记录到达后将更新双指标评分。"
            } else {
                result.relativeLoad = nil
                result.level = "等待评分更新"
                result.quality = "等待近期记录"
                result.explanation = "正在读取近期心率与 HRV 记录。"
            }
        }
        return result
    }

    /// Updating the analysis clock alone is not a new physiological observation.
    func hasDifferentMeasurements(from other: HRVSnapshot) -> Bool {
        hrv != other.hrv || hrvAt != other.hrvAt ||
        heartRate != other.heartRate || heartRateAt != other.heartRateAt ||
        heartRateMotion != other.heartRateMotion ||
        hrvBaseline != other.hrvBaseline ||
        sedentaryHRBaseline != other.sedentaryHRBaseline ||
        restingHR != other.restingHR ||
        stepsLast10Minutes != other.stepsLast10Minutes ||
        relativeLoad != other.relativeLoad || scoredHRVAt != other.scoredHRVAt ||
        dailyHRV != other.dailyHRV || level != other.level || quality != other.quality ||
        hrOnlyLoad != other.hrOnlyLoad || latestHRVIsMindful != other.latestHRVIsMindful ||
        latestHRVIsSleep != other.latestHRVIsSleep || sleepSuppressedAt != other.sleepSuppressedAt
    }
}

nonisolated struct HealthDataBatch {
    let hrv: [MetricReading]
    let heartRate: [MetricReading]
    let restingRate: [MetricReading]
    let stepsLast10Minutes: Double?
    /// Known Mindfulness sessions, supplied by HealthKit when authorized.
    /// HRV collected during paced breathing must not alter the ordinary HRV baseline.
    var mindfulIntervals: [DateInterval] = []
    /// Completed workouts, used to exclude exercise HR from a resting baseline.
    var workoutIntervals: [DateInterval] = []
    /// Sleep intervals recorded by HealthKit; excluded from waking sedentary baseline.
    var sleepIntervals: [DateInterval] = []

    /// When HealthKit fails, cached step counts are stale and cannot be used
    /// to confirm activity in the current rolling 10-minute window.
    func withoutRecentSteps() -> HealthDataBatch {
        HealthDataBatch(hrv: hrv, heartRate: heartRate, restingRate: restingRate,
                        stepsLast10Minutes: nil, mindfulIntervals: mindfulIntervals,
                        workoutIntervals: workoutIntervals, sleepIntervals: sleepIntervals)
    }
}

/// HealthKit-independent cache merge used for anchored additions and deletions.
/// This isolates the data-integrity rule so it can be regression-tested on Linux.
nonisolated enum IncrementalCacheMerge {
    static func apply<Value>(existing: [UUID: Value],
                             added: [(id: UUID, value: Value)],
                             deleted: [UUID],
                             keep: (Value) -> Bool) -> [UUID: Value] {
        var merged = existing
        for id in deleted { merged.removeValue(forKey: id) }
        for entry in added { merged[entry.id] = entry.value }
        return merged.filter { keep($0.value) }
    }
}

nonisolated enum StressEstimator {
    static let maxScoredHRVAge: TimeInterval = 45 * 60
    static let maxHRVHRSeparation: TimeInterval = 30 * 60

    /// Conservative comparison with a mindful-session window, including a short
    /// HealthKit write latency after the end of the session.
    static func isMindfulReading(_ date: Date, intervals: [DateInterval]) -> Bool {
        intervals.contains { date >= $0.start && date <= $0.end.addingTimeInterval(120) }
    }

    /// Exclude the immediate post-workout recovery window from both scoring and
    /// sedentary baseline construction. The duration matches the scoring guard.
    static let workoutRecoveryDuration: TimeInterval = 10 * 60

    static func isWorkoutReading(_ date: Date, intervals: [DateInterval]) -> Bool {
        intervals.contains {
            date >= $0.start && date <= $0.end.addingTimeInterval(workoutRecoveryDuration)
        }
    }

    /// A motion-context of sedentary can also occur during sleep, which has
    /// substantially different heart-rate physiology from daytime resting.
    static func isSleepReading(_ date: Date, intervals: [DateInterval]) -> Bool {
        intervals.contains { date >= $0.start && date <= $0.end }
    }

    /// Choosing a newer but invalid companion snapshot must never hide a locally valid score.
    /// Returns true if the local snapshot should be displayed.
    static func preferLocal(_ local: HRVSnapshot, over remote: HRVSnapshot, at now: Date) -> Bool {
        let own = local.validated(at: now)
        let peer = remote.validated(at: now)
        if (own.relativeLoad != nil) != (peer.relativeLoad != nil) {
            return own.relativeLoad != nil
        }
        if own.relativeLoad != nil {
            let ownHeart = own.heartRateAt ?? .distantPast
            let peerHeart = peer.heartRateAt ?? .distantPast
            if ownHeart != peerHeart { return ownHeart > peerHeart }
            if (own.scoredHRVAt != nil) != (peer.scoredHRVAt != nil) {
                return own.scoredHRVAt != nil
            }
        }
        return (own.lastMeasurementAt ?? .distantPast) >= (peer.lastMeasurementAt ?? .distantPast)
    }
    /// The same reducer is used by the live companion merge and Linux tests.
    /// It prevents a still-valid remote waking score from masking recent sleep
    /// evidence. The suppression expires without depending on peer clock offsets.
    static func applyingSleepContext(to candidate: HRVSnapshot,
                                     local: HRVSnapshot?, remote: HRVSnapshot?,
                                     at now: Date) -> HRVSnapshot {
        // Use the newest real sleep observation, not whichever snapshot happened
        // to be refreshed most recently. A clearly newer waking heart rate ends
        // suppression even when an older peer has not yet synchronized.
        let recentSleepAt = [local, remote].compactMap { $0?.sleepSuppressedAt }
            .filter { (0...15 * 60).contains(now.timeIntervalSince($0)) }
            .max()
        guard let sleepAt = recentSleepAt else { return candidate }
        if candidate.relativeLoad != nil, candidate.sleepSuppressedAt == nil,
           let wakingHRAt = candidate.heartRateAt, wakingHRAt > sleepAt {
            return candidate
        }
        var copy = candidate
        copy.relativeLoad = nil
        copy.scoredHRVAt = nil
        copy.level = "睡眠记录"
        copy.quality = "睡眠期间暂停日间评分"
        copy.explanation = "当前展示睡眠期间的生理记录。醒来并获取新的静息心率后，将更新日间生理负荷评分。"
        return copy
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter { $0.isFinite }.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private static func robustScale(_ values: [Double], minimum: Double) -> Double {
        guard let center = median(values) else { return minimum }
        let mad = median(values.map { abs($0 - center) }) ?? 0
        return max(minimum, 1.4826 * mad)
    }

    private static func dayCount(_ readings: [MetricReading], calendar: Calendar) -> Int {
        Set(readings.map { calendar.startOfDay(for: $0.date) }).count
    }

    static func calculate(_ data: HealthDataBatch,
                          now: Date = Date(),
                          calendar: Calendar = .current) -> HRVSnapshot {
        let past30 = now.addingTimeInterval(-30 * 86400)
        let today = calendar.startOfDay(for: now)
        let window = data.hrv.filter { $0.date >= past30 && $0.date <= now && $0.value.isFinite && $0.value > 0 }
        let latestHRV = window.max(by: { $0.date < $1.date })
        // A waking baseline must exclude both paced-breathing and recorded sleep.
        let ordinaryHRV = window.filter {
            !isMindfulReading($0.date, intervals: data.mindfulIntervals) &&
            !isSleepReading($0.date, intervals: data.sleepIntervals)
        }
        let latestOrdinaryHRV = ordinaryHRV.max(by: { $0.date < $1.date })
        let latestHR = data.heartRate.filter {
            $0.date <= now &&
            $0.value.isFinite &&
            $0.value > 0
        }.max(by: { $0.date < $1.date })

        let latestWakingHR = data.heartRate.filter {
            $0.date <= now &&
            $0.value.isFinite &&
            $0.value > 0 &&
            !isSleepReading($0.date, intervals: data.sleepIntervals)
        }.max(by: { $0.date < $1.date })
        let latestRest = data.restingRate.filter { $0.date <= now }.max(by: { $0.date < $1.date })

        let dailyGroups = Dictionary(grouping: ordinaryHRV) { calendar.startOfDay(for: $0.date) }
        let dailyPoints: [HRVDailyPoint] = dailyGroups.compactMap { (day, values) in
            guard let medianValue = median(values.map(\.value)) else { return nil }
            return HRVDailyPoint(day: day, value: medianValue)
        }.sorted { $0.day < $1.day }
        let last7 = dailyPoints.filter { $0.day >= (calendar.date(byAdding: .day, value: -6, to: today) ?? today) }

        // Baselines deliberately exclude today to prevent today's signal moving its own target.
        let historicalHRVDays = dailyPoints.filter { $0.day < today }
        let hrvBaseline = historicalHRVDays.count >= 7
            ? median(historicalHRVDays.map(\.value)) : nil
        let hrvScale = robustScale(historicalHRVDays.map(\.value), minimum: 8)

        // Use strictly sedentary heart-rate readings, NOT resting heart rate (different concepts).
        let sedentaryHistory = data.heartRate.filter {
            $0.date >= past30 &&
            $0.date < today &&
            $0.value.isFinite &&
            $0.value > 0 &&
            !isSleepReading($0.date, intervals: data.sleepIntervals)
        }
        // Give each day one vote: otherwise a day with dense samples can dominate the median.
        let sedentaryGroups = Dictionary(grouping: sedentaryHistory) {
            calendar.startOfDay(for: $0.date)
        }
        let dailyHeartValues = sedentaryGroups.values.compactMap { readings in
            median(readings.map(\.value))
        }
        let hrHistoryValid = sedentaryHistory.count >= 25 && dailyHeartValues.count >= 7
        let hrBaseline = hrHistoryValid ? median(dailyHeartValues) : nil
        let hrScale = robustScale(dailyHeartValues, minimum: 6)

        var snap = HRVSnapshot(
            calculatedAt: now,
            hrv: latestHRV?.value, hrvAt: latestHRV?.date,
            heartRate: latestHR?.value, heartRateAt: latestHR?.date,
            heartRateMotion: latestHR?.motion ?? 0,
            stepsLast10Minutes: data.stepsLast10Minutes,
            hrvBaseline: hrvBaseline, sedentaryHRBaseline: hrBaseline,
            restingHR: latestRest?.value,
            relativeLoad: nil, scoredHRVAt: nil, level: "等待评估",
            explanation: "正在检查数据是否足够新，以及是否处于静息状态。",
            quality: "待评估", dailyHRV: last7
        )

        snap.latestHRVIsMindful = latestHRV.map {
            isMindfulReading($0.date, intervals: data.mindfulIntervals)
        }
        snap.latestHRVIsSleep = latestHRV.map {
            isSleepReading($0.date, intervals: data.sleepIntervals)
        }

        // Sleep samples are a different physiological state from waking baseline.
        // Even if an earlier waking sample is still recent, a newer sleep sample
        // must prevent reusing that pre-sleep score.
        let sleepAtNow = isSleepReading(now, intervals: data.sleepIntervals)
        let freshSleepHR = latestHR.map {
            isSleepReading($0.date, intervals: data.sleepIntervals) &&
            (0...15 * 60).contains(now.timeIntervalSince($0.date))
        } ?? false
        if sleepAtNow || freshSleepHR {
            // When the source is a previously recorded sleeping HR, retain its
            // measurement time. Recalculating must not turn old sleep evidence
            // into a new observation and suppress later waking samples.
            snap.sleepSuppressedAt = sleepAtNow ? now : latestHR?.date
            snap.level = "睡眠记录"
            snap.quality = "睡眠期间暂停日间评分"
            snap.explanation = "当前展示睡眠期间的生理记录。醒来并获取新的静息心率后，将更新日间生理负荷评分。"
            return snap
        }

        guard let hr = latestWakingHR, now.timeIntervalSince(hr.date) >= -120,
              now.timeIntervalSince(hr.date) <= 15 * 60 else {
            snap.level = "等待新心率"
            snap.quality = "心率记录已过期"
            snap.explanation = "等待最新心率数据。当前展示历史 HRV，获取近期心率后更新生理负荷评分。"
            return snap
        }

        guard let baselineHR = hrBaseline else {
            snap.level = "建立个人基线"
            snap.quality = "需要更多历史心率"
            snap.explanation = "需要至少 7 天、累计 25 条静息心率记录，才能与自己的正常水平比较。"
            return snap
        }

        // Relative physiological load, not a diagnosed psychological stress percentage.
        let hrZ = max(-2.5, min(3.5, (hr.value - baselineHR) / hrScale))
        var load = 50.0 + 14.0 * hrZ
        snap.hrOnlyLoad = Int(max(0, min(100, load)).rounded())
        let canUseHRV = latestOrdinaryHRV.map {
            (0...maxScoredHRVAge).contains(now.timeIntervalSince($0.date)) &&
            abs($0.date.timeIntervalSince(hr.date)) <= maxHRVHRSeparation
        } == true && hrvBaseline != nil
        if let hrv = latestOrdinaryHRV?.value, let hrvBase = hrvBaseline, canUseHRV {
            let hrvZ = max(-2.5, min(3.5, (hrvBase - hrv) / hrvScale))
            load += 8.0 * hrvZ
            snap.scoredHRVAt = latestOrdinaryHRV?.date
        }
        snap.relativeLoad = Int(max(0, min(100, load)).rounded())
        let value = snap.relativeLoad ?? 50
        snap.level = value < 36 ? "低于近期常态" : (value > 65 ? "高于近期常态" : "接近近期常态")
        snap.quality = snap.scoredHRVAt != nil ? "近时双指标参考" : "仅心率粗略参考"
        let latestHrvNote: String
        if canUseHRV, let hrv = latestOrdinaryHRV?.value, let base = hrvBaseline, base > 0 {
            let pct = (hrv - base) / base * 100
            latestHrvNote = String(format: "最新 HRV 相对个人基线变化 %+.0f%%。", pct)
        } else {
            latestHrvNote = "本次使用心率进行评分。获得与当前心率时间接近的日常 HRV 后，将纳入计算；呼吸练习数据单独展示。"
        }
        snap.explanation = "当前生理负荷\(snap.level)。依据近 30 天个人静息心率基线评估，并在数据匹配时结合 HRV。\(latestHrvNote)"
        return snap
    }
}

/// Pure, shared rendering policy; used for both foreground refresh and
/// TimelineView's time-driven updates. Testing this same reducer prevents
/// display-only regressions that isolated ranking tests cannot catch.
nonisolated struct DisplayResolution {
    let snapshot: HRVSnapshot
    let source: String
}

nonisolated enum DisplaySnapshotResolver {
    static func resolve(local: HRVSnapshot?, remote: HRVSnapshot?,
                        localWorkout: Bool, remoteWorkout: Bool,
                        at now: Date) -> DisplayResolution {
        var selected: HRVSnapshot
        var source: String
        switch (local, remote) {
        case (nil, nil): selected = .empty; source = "尚未同步"
        case (let s?, nil): selected = s; source = "本机 HealthKit"
        case (nil, let s?): selected = s; source = "配对设备"
        case (let own?, let peer?):
            if StressEstimator.preferLocal(own, over: peer, at: now) {
                selected = own
                source = "本机 HealthKit"
            } else {
                selected = peer
                source = "配对设备同步"
            }
            // Value and classification metadata are inseparable. Carry sleep
            // and mindfulness provenance when using a newer peer HRV sample.
            let latest = [own, peer].filter { $0.hrvAt != nil }
                .max(by: { ($0.hrvAt ?? .distantPast) < ($1.hrvAt ?? .distantPast) })
            if let latest, let at = latest.hrvAt,
               at > (selected.hrvAt ?? .distantPast) {
                selected.hrv = latest.hrv
                selected.hrvAt = at
                selected.latestHRVIsMindful = latest.latestHRVIsMindful
                selected.latestHRVIsSleep = latest.latestHRVIsSleep
                source += " + 跨设备最新 HRV"
            }
        }
        if !localWorkout && !remoteWorkout {
            selected = StressEstimator.applyingSleepContext(
                to: selected, local: local, remote: remote, at: now)
        }
        return DisplayResolution(snapshot: selected.validated(at: now), source: source)
    }
}

/// HealthKit can successfully finish a workout while returning no HKWorkout
/// object when the device is locked. Success must follow the error result.
nonisolated enum WorkoutSaveResult {
    static func saved(errorIsNil: Bool) -> Bool { errorIsNil }
}

/// Order companion messages by the sender's publication time, independent of
/// physiological sample timestamps (which legitimately move backward on deletion).
nonisolated enum SnapshotSyncPolicy {
    static let maxAge: TimeInterval = 30 * 60
    static let futureClockTolerance: TimeInterval = 5 * 60

    static func accepts(issuedAt: Date, after previous: Date, now: Date) -> Bool {
        issuedAt > previous &&
        now.timeIntervalSince(issuedAt) <= maxAge &&
        issuedAt.timeIntervalSince(now) <= futureClockTolerance
    }

    /// All packets must be fresh before their sequence is consumed. A delayed
    /// live packet should not be granted a brand new workout lease, either.
    static func replayIsFresh(issuedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(issuedAt) <= maxAge &&
        issuedAt.timeIntervalSince(now) <= futureClockTolerance
    }
}

// MARK: - Companion message order (testable without WatchConnectivity)

/// Tracks the newest message per sender installation. Each sender saves its
/// sequence in UserDefaults. A new sender identity (e.g. reinstall) may reset
/// the counter; messages from already superseded identities are ignored.
nonisolated struct PeerMessageOrder {
    private var activeSenderID: String?
    private var lastSequence = 0
    private var supersededIDs: Set<String> = []
    private var lastLegacyIssuedAt: Date = .distantPast

    mutating func accept(senderID: String?, sequence: Int?,
                         legacyIssuedAt: Date, now: Date) -> Bool {
        if let id = senderID, !id.isEmpty, let sequence, sequence > 0 {
            if activeSenderID == id {
                guard sequence > lastSequence else { return false }
            } else {
                // Once an identity was replaced, delayed packets from it cannot
                // roll back the latest state. Unseen identities can reset sequence.
                guard !supersededIDs.contains(id) else { return false }
                if let old = activeSenderID { supersededIDs.insert(old) }
                activeSenderID = id
            }
            lastSequence = sequence
            return true
        }
        // Legacy releases without a persistent counter remain compatible.
        // Once a sequence-enabled sender is observed, don't let legacy messages
        // overwrite its state.
        guard activeSenderID == nil,
              SnapshotSyncPolicy.accepts(issuedAt: legacyIssuedAt,
                                         after: lastLegacyIssuedAt, now: now) else { return false }
        lastLegacyIssuedAt = legacyIssuedAt
        return true
    }
}


/// State used by the *actual receive path* and by unit tests. All expirations
/// use the receiver's local time, so clock drift cannot extend a peer lease.
nonisolated struct PeerSyncInbox {
    private var order = PeerMessageOrder()
    private var storedSnapshot: HRVSnapshot?
    private var snapshotExpiresAt: Date?
    private var activeWorkout = false
    private var workoutExpiresAt: Date?

    @discardableResult
    mutating func receive(senderID: String?, sequence: Int?, issuedAt: Date,
                          hasSnapshot: Bool, snapshot: HRVSnapshot,
                          workoutActive: Bool, now: Date,
                          replayedContext: Bool = false) -> Bool {
        // Both delayed live packets and replayed context are historical state.
        // Validate age before consuming their sequence (fresh packets may follow).
        guard SnapshotSyncPolicy.replayIsFresh(issuedAt: issuedAt, now: now) else {
            return false
        }
        guard order.accept(senderID: senderID, sequence: sequence,
                           legacyIssuedAt: issuedAt, now: now) else { return false }
        // Sender time can be ahead of receiver time by a small clock offset;
        // leases never begin in the future or outlive the original publication.
        let effectiveStart = min(issuedAt, now)
        if hasSnapshot {
            storedSnapshot = snapshot
            snapshotExpiresAt = effectiveStart.addingTimeInterval(SnapshotSyncPolicy.maxAge)
        }
        activeWorkout = workoutActive
        // A launch replay that is 8 minutes old cannot resurrect a 5-minute
        // workout lease, even if its snapshot remains recent enough to display.
        workoutExpiresAt = effectiveStart.addingTimeInterval(5 * 60)
        return true
    }

    mutating func snapshot(at now: Date) -> HRVSnapshot? {
        guard let expiry = snapshotExpiresAt, now < expiry else {
            storedSnapshot = nil
            snapshotExpiresAt = nil
            return nil
        }
        return storedSnapshot
    }

    func workoutInProgress(at now: Date) -> Bool {
        activeWorkout && (workoutExpiresAt.map { now < $0 } ?? false)
    }
}
