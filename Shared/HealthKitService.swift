import Foundation
import HealthKit

/// One HealthKit store per app process. iPhone and Watch use their own process-local instance.
nonisolated enum SharedHealthKitStore {
    nonisolated(unsafe) static let store = HKHealthStore()
}

nonisolated final class HealthKitService {
    let store = SharedHealthKitStore.store

    /// Keep the original 30-day window, with a periodic rebuild to prune older data.
    /// Anchored queries also detect late-arriving samples and deletions at ANY date
    /// within the window, instead of assuming everything arrives within 60 minutes.
    /// Anchors capture delayed additions/deletions between rebuilds. A longer
    /// rebuild interval reduces the cost of repeatedly reading full history.
    private let fullHistoryInterval: TimeInterval = 6 * 60 * 60
    private var cachedBatch: HealthDataBatch?
    private var lastFullHistoryAt = Date.distantPast

    private enum SampleKind: CaseIterable {
        case hrv, heart, resting, mindful, workout, sleep
    }
    /// Retain only the information used by the estimator, not heavyweight HKSample objects.
    /// UUIDs must be preserved so anchored-query deletions can update the cache.
    private enum CachedSample {
        case metric(MetricReading)
        case interval(DateInterval)

        var endDate: Date {
            switch self {
            case .metric(let value): return value.date
            case .interval(let value): return value.end
            }
        }
    }
    private struct CachedEntry {
        let id: UUID
        let sample: CachedSample
    }
    private struct Changes {
        let added: [CachedEntry]
        let deleted: [UUID]
        let anchor: HKQueryAnchor?
    }

    /// Callbacks may arrive concurrently. All mutations are protected by a lock;
    /// only the final immutable result is read on the main queue.
    private final class QueryAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var changes: [SampleKind: Changes] = [:]
        private var steps: Double?
        private var firstError: Error?

        func record(_ delta: Changes, for kind: SampleKind, error: Error?) {
            lock.lock()
            changes[kind] = delta
            if firstError == nil { firstError = error }
            lock.unlock()
        }

        func recordSteps(_ count: Double?, error: Error?) {
            lock.lock()
            steps = count
            if let error, (error as? HKError)?.code != .errorNoData,
               firstError == nil { firstError = error }
            lock.unlock()
        }

        func result() -> (changes: [SampleKind: Changes], steps: Double?, error: Error?) {
            lock.lock()
            defer { lock.unlock() }
            return (changes, steps, firstError)
        }
    }
    /// These caches and anchors are committed on the main queue after ALL queries succeed.
    private var samplesByKind: [SampleKind: [UUID: CachedSample]] = [:]
    private var anchors: [SampleKind: HKQueryAnchor] = [:]

    private static func compactSample(_ sample: HKSample, kind: SampleKind) -> CachedSample? {
        switch kind {
        case .hrv, .heart, .resting:
            guard let quantitySample = sample as? HKQuantitySample else { return nil }
            let unit: HKUnit = kind == .hrv
                ? .secondUnit(with: .milli)
                : .count().unitDivided(by: .minute())
            let motion = (quantitySample.metadata?[HKMetadataKeyHeartRateMotionContext] as? NSNumber)?.intValue ?? 0
            return .metric(MetricReading(value: quantitySample.quantity.doubleValue(for: unit),
                                         date: quantitySample.endDate, motion: motion))
        case .mindful, .workout:
            return .interval(DateInterval(start: sample.startDate, end: sample.endDate))
        case .sleep:
            guard let categorySample = sample as? HKCategorySample else { return nil }
            // An 'in bed' period can include waking time. Only exclude
            // samples explicitly marked as sleep, including sleep stages.
            let asleepValues: Set<Int> = [
                HKCategoryValueSleepAnalysis.asleep.rawValue,
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue
            ]
            guard asleepValues.contains(categorySample.value) else { return nil }
            return .interval(DateInterval(start: sample.startDate, end: sample.endDate))
        }
    }

    let hrvType = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
    let heartType = HKObjectType.quantityType(forIdentifier: .heartRate)!
    let restingType = HKObjectType.quantityType(forIdentifier: .restingHeartRate)!
    let stepsType = HKObjectType.quantityType(forIdentifier: .stepCount)!
    let mindfulType = HKObjectType.categoryType(forIdentifier: .mindfulSession)!
    let workoutType = HKObjectType.workoutType()
    let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!

    var readTypes: Set<HKObjectType> {
        [hrvType, heartType, restingType, stepsType, mindfulType, workoutType, sleepType]
    }

    func requestAccess(_ completion: @escaping @Sendable (Error?) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(NSError(domain: "WatchHRV", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "设备不支持 HealthKit"]))
            return
        }
        store.requestAuthorization(toShare: [], read: readTypes) { _, error in
            // HealthKit intentionally does not reveal whether read permission was denied.
            completion(error)
        }
    }

    func enableBackgroundUpdates() {
        #if os(watchOS)
        let frequency: HKUpdateFrequency = .hourly
        #else
        let frequency: HKUpdateFrequency = .immediate
        #endif
        [hrvType, heartType, restingType, sleepType].forEach { type in
            store.enableBackgroundDelivery(for: type, frequency: frequency) { _, error in
                if let error { print("HealthKit background delivery: \(error.localizedDescription)") }
            }
        }
    }

    func queryBatch(forceHistoryReload: Bool = false,
                    _ completion: @escaping (HealthDataBatch, Error?) -> Void) {
        // HRVManager serializes calls on main. Query callbacks use a lock, and
        // cache state is never changed until group.notify on main.
        let now = Date()
        let beginning = now.addingTimeInterval(-30 * 86400)
        // Query and temporarily cache slight future clock-skew samples. The
        // estimator itself excludes readings later than its analysis time.
        let futureBound = now.addingTimeInterval(5 * 60)
        let fullReload = forceHistoryReload || cachedBatch == nil ||
            now.timeIntervalSince(lastFullHistoryAt) >= fullHistoryInterval
        let group = DispatchGroup()
        let accumulator = QueryAccumulator()

        func sampleType(_ kind: SampleKind) -> HKSampleType {
            switch kind {
            case .hrv: return hrvType
            case .heart: return heartType
            case .resting: return restingType
            case .mindful: return mindfulType
            case .workout: return workoutType
            case .sleep: return sleepType
            }
        }

        for kind in SampleKind.allCases {
            group.enter()
            let type = sampleType(kind)
            let predicate = HKQuery.predicateForSamples(withStart: beginning, end: futureBound, options: [])
            let anchor = fullReload ? nil : anchors[kind]
            // No fixed 4,000-record cap. Anchor tracks inserts and deletions,
            // including old samples synchronized after a phone/watch disconnection.
            let query = HKAnchoredObjectQuery(type: type, predicate: predicate,
                                              anchor: anchor, limit: HKObjectQueryNoLimit) {
                _, added, deleted, newAnchor, error in
                // Convert outside the lock: a 30-day full reload may contain many records.
                // Raw HKSample objects never enter the persistent cache.
                let lightweight = (added ?? []).compactMap { sample -> CachedEntry? in
                    guard let value = Self.compactSample(sample, kind: kind) else { return nil }
                    return CachedEntry(id: sample.uuid, sample: value)
                }
                accumulator.record(Changes(added: lightweight,
                                           deleted: (deleted ?? []).map(\.uuid),
                                           anchor: newAnchor), for: kind, error: error)
                group.leave()
            }
            store.execute(query)
        }

        group.enter()
        let stepsPredicate = HKQuery.predicateForSamples(
            withStart: now.addingTimeInterval(-10 * 60), end: now, options: [])
        let stepsQuery = HKStatisticsQuery(quantityType: stepsType,
                                          quantitySamplePredicate: stepsPredicate,
                                          options: .cumulativeSum) { _, result, error in
            // Preserve nil when HealthKit has no step data; failures other than
            // errorNoData still abort the batch transaction.
            accumulator.recordSteps(result?.sumQuantity()?.doubleValue(for: .count()), error: error)
            group.leave()
        }
        store.execute(stepsQuery)

        group.notify(queue: .main) {
            let (changes, steps, firstError) = accumulator.result()
            guard firstError == nil else {
                // Avoid turning an incomplete HealthKit read into a corrupted baseline.
                // Previous step count belongs to an older 10-minute window;
                // never reuse it as evidence of current sedentary activity.
                let previous = self.cachedBatch ?? HealthDataBatch(
                    hrv: [], heartRate: [], restingRate: [], stepsLast10Minutes: nil)
                completion(previous.withoutRecentSteps(), firstError)
                return
            }

            var nextCache = fullReload ? [SampleKind: [UUID: CachedSample]]() : self.samplesByKind
            var nextAnchors = fullReload ? [SampleKind: HKQueryAnchor]() : self.anchors
            for kind in SampleKind.allCases {
                guard let delta = changes[kind] else { continue }
                // Single merge rule for late additions, deletions, replacement
                // and pruning; shared with the non-HealthKit regression tests.
                nextCache[kind] = IncrementalCacheMerge.apply(
                    existing: nextCache[kind] ?? [:],
                    added: delta.added.map { (id: $0.id, value: $0.sample) },
                    deleted: delta.deleted,
                    keep: { $0.endDate >= beginning && $0.endDate <= futureBound })
                if let anchor = delta.anchor { nextAnchors[kind] = anchor }
            }

            func metrics(_ kind: SampleKind) -> [MetricReading] {
                (nextCache[kind] ?? [:]).values.compactMap { value in
                    guard case .metric(let reading) = value else { return nil }
                    return reading
                }
            }
            func intervals(_ kind: SampleKind) -> [DateInterval] {
                (nextCache[kind] ?? [:]).values.compactMap { value in
                    guard case .interval(let interval) = value else { return nil }
                    return interval
                }
            }
            let merged = HealthDataBatch(
                hrv: metrics(.hrv),
                heartRate: metrics(.heart),
                restingRate: metrics(.resting),
                stepsLast10Minutes: steps,
                mindfulIntervals: intervals(.mindful),
                workoutIntervals: intervals(.workout),
                sleepIntervals: intervals(.sleep))
            self.samplesByKind = nextCache
            self.anchors = nextAnchors
            self.cachedBatch = merged
            if fullReload { self.lastFullHistoryAt = now }
            completion(merged, nil)
        }
    }
}
