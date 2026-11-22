import Foundation
import Combine
import HealthKit
import WatchConnectivity

/// All published properties are updated on the main queue.
@MainActor final class HRVManager: NSObject, ObservableObject {
    static let shared = HRVManager()

    @Published private(set) var snapshot = HRVSnapshot.empty
    private(set) var displaySource = "尚未同步"
    private(set) var status = "准备读取健康数据"
    @Published private(set) var isLoading = false
    private(set) var lastCheckedAt: Date?
    @Published private(set) var isWorkoutInProgress = false
    private(set) var latestObservedHRVAt: Date?

    private let health = HealthKitService()
    private var observers: [HKObserverQuery] = []
    private var hasStarted = false
    private var hasAuthorizationRequested = false
    private var refreshPending = false
    private var pendingHistoryReload = false
    private var activeRefreshCompletions: [() -> Void] = []
    private var queuedRefreshCompletions: [() -> Void] = []
    private var peerInbox = PeerSyncInbox()
    private var localSnapshot: HRVSnapshot?
    private var lastWorkoutHeartbeatAt: Date = .distantPast
    /// Ordered per sending app installation, independent of either device clock.
    /// UserDefaults persists the counter across ordinary app restarts.
    private let senderID: String = {
        let key = "WatchHRV.companion.senderID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()
    private var sendSequence = UserDefaults.standard.integer(forKey: "WatchHRV.companion.sequence")

    private var session: WCSession? { WCSession.isSupported() ? .default : nil }

    private override init() {
        super.init()
        if let session {
            session.delegate = self
            session.activate()
        }
    }

    /// Called at app launch, so observer queries exist for background launches as well.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        authorizeAndObserve()
    }

    private func authorizeAndObserve() {
        guard !hasAuthorizationRequested else { return }
        hasAuthorizationRequested = true
        status = "请求读取心率、HRV、静息心率和步数"
        health.requestAccess { @Sendable [weak self] error in
            let errorText = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let errorText {
                    self.hasAuthorizationRequested = false
                    self.status = "HealthKit: \(errorText)"
                    return
                }
                self.startObservers()
                self.health.enableBackgroundUpdates()
                self.refresh()
            }
        }
    }

    func setWorkoutInProgress(_ running: Bool) {
        isWorkoutInProgress = running
        updateDisplayedSnapshot()
        // Synchronize workout suppression on both screens, not only on the Watch.
        lastWorkoutHeartbeatAt = .distantPast
        sendToCompanionIfChanged(localSnapshot ?? .empty, force: true)
    }

    /// During a real workout, renew the companion's status lease at most once/minute.
    /// Call this from live heart-rate collection, including with the screen dimmed.
    func heartbeatWorkout() {
        guard isWorkoutInProgress else { return }
        let now = Date()
        guard now.timeIntervalSince(lastWorkoutHeartbeatAt) >= 60 else { return }
        lastWorkoutHeartbeatAt = now
        sendToCompanionIfChanged(localSnapshot ?? .empty, force: true)
    }

    func refresh(forceHistoryReload: Bool = false, completion: (() -> Void)? = nil) {
        // Actor isolation guarantees that cache commits and published state changes
        // happen on MainActor; observer delegates hop to MainActor before entering.
        // A transient authorization error may be retried with the global refresh button.
        guard !observers.isEmpty else {
            if !hasAuthorizationRequested { authorizeAndObserve() }
            completion?()
            return
        }
        guard !isLoading else {
            if let completion { queuedRefreshCompletions.append(completion) }
            refreshPending = true
            pendingHistoryReload = pendingHistoryReload || forceHistoryReload
            return
        }
        if let completion { activeRefreshCompletions.append(completion) }
        isLoading = true
        status = "正在更新健康数据"
        health.queryBatch(forceHistoryReload: forceHistoryReload) { [weak self] batch, error in
            guard let self else { return }
            var next = StressEstimator.calculate(batch)
            // Polling the same samples is NOT a fresh measurement or a new
            // physiological conclusion. Preserve the original decision time.
            let changed = self.localSnapshot.map {
                next.hasDifferentMeasurements(from: $0)
            } ?? true
            if !changed, let original = self.localSnapshot {
                next.calculatedAt = original.calculatedAt
            }
            self.localSnapshot = next
            self.updateDisplayedSnapshot()
            self.isLoading = false
            self.lastCheckedAt = Date()
            if let error {
                self.status = "部分健康数据不可用：\(error.localizedDescription)"
            } else {
                self.status = changed ? "检测到新数据或状态变化" : "检查完成：没有新的有效生理数据"
            }
            self.sendToCompanionIfChanged(next)

            // Finish HealthKit observer work before invoking its completion handler.
            let callbacks = self.activeRefreshCompletions
            self.activeRefreshCompletions.removeAll()
            callbacks.forEach { $0() }
            if self.refreshPending {
                self.refreshPending = false
                let full = self.pendingHistoryReload
                self.pendingHistoryReload = false
                // A second observer event belongs to the follow-up query,
                // not the batch that was already in progress when it arrived.
                self.activeRefreshCompletions = self.queuedRefreshCompletions
                self.queuedRefreshCompletions.removeAll()
                self.refresh(forceHistoryReload: full)
            }
        }
    }

    /// One-shot completion protects the HealthKit wake-up contract when the
    /// observer callback crosses from a system queue into MainActor.
    nonisolated private final class ObserverCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var called = false
        private let callback: () -> Void

        init(_ callback: @escaping () -> Void) { self.callback = callback }

        func finish() {
            lock.lock()
            let shouldCall = !called
            called = true
            lock.unlock()
            if shouldCall { callback() }
        }
    }

    private func startObservers() {
        guard observers.isEmpty else { return }
        for type in [health.hrvType, health.heartType, health.restingType,
                     health.sleepType, health.mindfulType, health.workoutType] {
            let query = HKObserverQuery(sampleType: type, predicate: nil) {
                @Sendable [weak self] _, completion, error in
                let done = ObserverCompletion(completion)
                if let error {
                    print("Observer error: \(error.localizedDescription)")
                    done.finish()
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else { done.finish(); return }
                    // The observer completion runs only after the query batch completes.
                    self.refresh(completion: { done.finish() })
                }
            }
            observers.append(query)
            health.store.execute(query)
        }
    }

    // MARK: - Best known snapshot
    /// Always re-evaluate both peers against the current clock. A TimelineView
    /// can outlive a peer lease without receiving a HealthKit observer event.
    func visibleSnapshot(at now: Date) -> HRVSnapshot {
        resolvedDisplay(at: now).snapshot
    }

    private func resolvedDisplay(at now: Date) -> DisplayResolution {
        DisplaySnapshotResolver.resolve(
            local: localSnapshot, remote: peerInbox.snapshot(at: now),
            localWorkout: isWorkoutInProgress,
            remoteWorkout: peerInbox.workoutInProgress(at: now), at: now)
    }

    private func updateDisplayedSnapshot() {
        let resolved = resolvedDisplay(at: Date())
        snapshot = resolved.snapshot
        displaySource = resolved.source
        latestObservedHRVAt = resolved.snapshot.hrvAt
    }

    // MARK: - WatchConnectivity
    private var lastSent: HRVSnapshot?

    private func sendToCompanionIfChanged(_ next: HRVSnapshot, force: Bool = false) {
        if !force, let previous = lastSent, !next.hasDifferentMeasurements(from: previous) { return }
        guard let session, session.activationState == .activated else { return }
        guard let encoded = try? JSONEncoder().encode(next) else { return }
        sendSequence += 1
        UserDefaults.standard.set(sendSequence, forKey: "WatchHRV.companion.sequence")
        let issuedAt = Date().timeIntervalSince1970
        let payload: [String: Any] = ["kind": "watchhrv.v3.snapshot", "data": encoded,
                                      "hasLocalSnapshot": localSnapshot != nil,
                                      "snapshotIssuedAt": issuedAt,
                                      "senderID": senderID,
                                      "sequence": sendSequence,
                                      "workoutActive": isWorkoutInProgress,
                                      "workoutStateAt": issuedAt]
        do {
            // Only the latest state is needed. This will deliver opportunistically.
            try session.updateApplicationContext(payload)
            // Mark as sent only after context publication succeeds. If the
            // session is unavailable or publishing fails, retry next refresh.
            lastSent = next
        } catch {
            print("WatchConnectivity context failed: \(error.localizedDescription)")
        }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { error in
                print("WatchConnectivity live message failed: \(error.localizedDescription)")
            }
        }
    }

    /// Decode on MainActor after converting the untyped WCSession property-list
    /// dictionary to immutable Sendable Data on the background delegate queue.
    private func receiveWireData(_ wireData: Data, isContext: Bool) {
        guard let dict = (try? PropertyListSerialization.propertyList(
            from: wireData, options: [], format: nil)) as? [String: Any] else { return }
        receive(dict, isContext: isContext)
    }

    nonisolated private static func wireData(_ dict: [String: Any]) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: dict,
                                            format: .binary, options: 0)
    }

    private func receive(_ dict: [String: Any], isContext: Bool) {
        guard dict["kind"] as? String == "watchhrv.v3.snapshot",
              let data = dict["data"] as? Data,
              let value = try? JSONDecoder().decode(HRVSnapshot.self, from: data)
        else { return }
        let issuedAt = (dict["snapshotIssuedAt"] as? Double)
            .map(Date.init(timeIntervalSince1970:))
            ?? (dict["workoutStateAt"] as? Double).map(Date.init(timeIntervalSince1970:))
            ?? .distantPast
        let now = Date()
        // Modern senders are ordered by their persistent sequence, so changes
        // to either device's wall clock cannot suppress subsequent updates.
        // Older versions still use the timestamp-based compatibility path.
        guard peerInbox.receive(senderID: dict["senderID"] as? String,
                                sequence: dict["sequence"] as? Int,
                                issuedAt: issuedAt,
                                hasSnapshot: dict["hasLocalSnapshot"] as? Bool ?? true,
                                snapshot: value,
                                workoutActive: dict["workoutActive"] as? Bool ?? false,
                                now: now, replayedContext: isContext) else { return }
        updateDisplayedSnapshot()
    }

}

extension HRVManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error { print("WatchConnectivity activation: \(error.localizedDescription)") }
        guard activationState == .activated else { return }
        let initial = Self.wireData(session.receivedApplicationContext)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let initial { self.receiveWireData(initial, isContext: true) }
            self.lastSent = nil
            self.sendToCompanionIfChanged(self.localSnapshot ?? .empty, force: true)
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = Self.wireData(applicationContext) else { return }
        Task { @MainActor [weak self] in self?.receiveWireData(data, isContext: true) }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any]) {
        guard let data = Self.wireData(message) else { return }
        Task { @MainActor [weak self] in self?.receiveWireData(data, isContext: false) }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) { }
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
