import Foundation
import HealthKit
import Combine

/// A real workout on Apple Watch, not a shortcut for passive/resting HR sampling.
/// Starting this feature creates a workout that is saved in Apple Health when stopped.
@MainActor final class WorkoutHeartRateMonitor: NSObject, ObservableObject {
    static let shared = WorkoutHeartRateMonitor()

    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var bpm: Double?
    @Published private(set) var message = "仅供实际运动时使用；停止后会保存一条“其他”运动记录。"

    private let store = SharedHealthKitStore.store
    private var workout: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var stopping = false
    private var finishing = false
    private var activeGeneration: UUID?
    /// Protect the UI if a HealthKit completion or .stopped callback never arrives.
    private var operationWatchdog: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    /// Renew the peer's workout lease even when heart-rate samples pause.
    private func startHeartbeatTimer() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) }
                catch { break }
                guard let self, self.isRunning else { break }
                HRVManager.shared.heartbeatWorkout()
            }
        }
    }

    private func cancelWatchdog() {
        operationWatchdog?.cancel()
        operationWatchdog = nil
    }

    private func startWatchdog(for generation: UUID, seconds: Double, reason: String) {
        cancelWatchdog()
        operationWatchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            guard let self, self.activeGeneration == generation else { return }
            self.abortStartup(message: reason)
        }
    }

    func start() {
        guard !isBusy && !isRunning && workout == nil else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            message = "当前设备无法使用 HealthKit"
            return
        }
        isBusy = true
        message = "正在请求运动记录权限…"
        let generation = UUID()
        activeGeneration = generation
        startWatchdog(for: generation, seconds: 45,
                      reason: "运动授权等待超时，请重新开始")
        let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [heartRate]) {
            @Sendable [weak self] success, error in
            let errorText = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.activeGeneration == generation else { return }
                guard success, errorText == nil,
                      self.store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
                    self.complete(message: errorText ?? "请在 Apple 健康中允许 WatchHRV 写入运动记录")
                    return
                }
                self.beginWorkout(generation: generation)
            }
        }
    }

    private func beginWorkout(generation: UUID) {
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .indoor
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            let liveBuilder = session.associatedWorkoutBuilder()
            liveBuilder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            session.delegate = self
            liveBuilder.delegate = self
            workout = session
            builder = liveBuilder
            stopping = false
            finishing = false
            bpm = nil
            let started = Date()
            session.startActivity(with: started)
            startWatchdog(for: generation, seconds: 45,
                          reason: "运动采集启动超时，请重新开始")
            liveBuilder.beginCollection(withStart: started) { @Sendable [weak self] success, error in
                let errorText = error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.activeGeneration == generation else { return }
                    // A session may have stopped before beginCollection replied.
                    // Never cancel its finalization watchdog or revive its UI.
                    guard !self.stopping && !self.finishing else { return }
                    self.cancelWatchdog()
                    self.isBusy = false
                    if success {
                        self.isRunning = true
                        self.message = "运动采集中：手表会持续更新心率；停止时保存运动记录。"
                        HRVManager.shared.setWorkoutInProgress(true)
                        self.startHeartbeatTimer()
                    } else {
                        // A failed startup may never trigger the .stopped delegate.
                        self.abortStartup(message: errorText ?? "无法开始运动采集")
                    }
                }
            }
        } catch {
            complete(message: "运动会话启动失败：\(error.localizedDescription)")
        }
    }

    private func abortStartup(message: String) {
        workout?.end()
        complete(message: message)
    }

    /// Apple restarts a workout app after an unexpected termination and asks
    /// its WKApplicationDelegate to reconnect to the still-active HKWorkoutSession.
    /// Reuse HealthKit's session/builder instead of creating a second workout.
    private nonisolated final class RecoveredSession: @unchecked Sendable {
        let value: HKWorkoutSession?
        init(_ value: HKWorkoutSession?) { self.value = value }
    }

    func recoverActiveSession() {
        guard workout == nil, !isBusy else { return }
        isBusy = true
        message = "正在恢复上次运动采集…"
        let generation = UUID()
        activeGeneration = generation
        startWatchdog(for: generation, seconds: 45,
                      reason: "运动恢复超时，请重新开始")
        store.recoverActiveWorkoutSession { @Sendable [weak self] session, error in
            let boxed = RecoveredSession(session)
            let errorText = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activeGeneration == generation else {
                    // Recovery may arrive after the timeout has cleared the UI.
                    // Terminate a still-orphaned recovered session rather than
                    // silently abandoning an active workout in the system.
                    if self.workout == nil { boxed.value?.end() }
                    return
                }
                guard let restored = boxed.value else {
                    self.complete(message: errorText ?? "可开始新的运动采集")
                    return
                }
                self.cancelWatchdog()
                let restoredBuilder = restored.associatedWorkoutBuilder()
                restored.delegate = self
                restoredBuilder.delegate = self
                restoredBuilder.dataSource = HKLiveWorkoutDataSource(
                    healthStore: self.store,
                    workoutConfiguration: restored.workoutConfiguration)
                self.workout = restored
                self.builder = restoredBuilder
                self.stopping = false
                self.finishing = false
                self.bpm = nil
                switch restored.state {
                case .running, .paused:
                    self.isBusy = false
                    self.isRunning = true
                    self.message = restored.state == .paused
                        ? "运动已恢复，当前为暂停状态" : "运动已恢复，继续采集心率"
                    HRVManager.shared.setWorkoutInProgress(true)
                    self.startHeartbeatTimer()
                case .stopped:
                    self.isBusy = true
                    self.finalize(at: Date())
                default:
                    restored.end()
                    self.complete(message: "运动会话已结束，可重新开始采集")
                }
            }
        }
    }

    func stop() {
        guard workout != nil && !stopping else { return }
        requestStop()
    }

    private func requestStop() {
        guard let workout, !stopping else { return }
        stopping = true
        isBusy = true
        message = "正在结束并保存运动记录…"
        workout.stopActivity(with: Date())
        if let generation = activeGeneration {
            startWatchdog(for: generation, seconds: 60,
                          reason: "结束运动超时，请重新开始")
        }
    }

    private func finalize(at date: Date) {
        guard let builder, !finishing, let generation = activeGeneration else { return }
        finishing = true
        // Keep a bounded cleanup path through endCollection and finishWorkout.
        if let generation = activeGeneration {
            startWatchdog(for: generation, seconds: 60,
                          reason: "保存运动记录超时，请重新开始")
        }
        builder.endCollection(withEnd: date) { @Sendable [weak self] success, error in
            let errorText = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.activeGeneration == generation else { return }
                guard success else {
                    self.workout?.end()
                    self.complete(message: errorText ?? "结束运动数据采集失败")
                    return
                }
                guard let currentBuilder = self.builder else {
                    self.workout?.end()
                    self.complete(message: "运动会话已结束")
                    return
                }
                currentBuilder.finishWorkout { @Sendable [weak self] _, error in
                    // Apple may return nil without an error when the Watch is
                    // locked, even though HealthKit saved the workout.
                    let savedSuccessfully = WorkoutSaveResult.saved(errorIsNil: error == nil)
                    let errorText = error?.localizedDescription
                    Task { @MainActor [weak self] in
                        guard let self, self.activeGeneration == generation else { return }
                        self.workout?.end()
                        self.complete(message: savedSuccessfully
                            ? "运动记录已保存至 Apple 健康"
                            : "运动记录未能保存：\(errorText ?? "未知错误")")
                    }
                }
            }
        }
    }

    private func complete(message: String) {
        cancelWatchdog()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        self.message = message
        isRunning = false
        isBusy = false
        stopping = false
        finishing = false
        workout = nil
        builder = nil
        activeGeneration = nil
        HRVManager.shared.setWorkoutInProgress(false)
        HRVManager.shared.refresh()
    }
}

extension WorkoutHeartRateMonitor: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {
        // Only a Sendable identity token crosses into MainActor.
        let identity = ObjectIdentifier(workoutSession)
        Task { @MainActor [weak self] in
            guard let self, let active = self.workout,
                  ObjectIdentifier(active) == identity else { return }
            if toState == .stopped {
                self.finalize(at: date)
            } else if toState == .paused {
                self.message = "运动已暂停，可结束并保存当前运动记录"
            } else if toState == .running && self.isRunning {
                self.message = "运动采集中：手表持续更新心率"
            } else if toState == .ended && !self.finishing {
                self.complete(message: "运动会话已结束，请重新启动采集")
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let identity = ObjectIdentifier(workoutSession)
        let errorText = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, let active = self.workout,
                  ObjectIdentifier(active) == identity else { return }
            self.abortStartup(message: "运动会话失败：\(errorText)")
        }
    }
}

extension WorkoutHeartRateMonitor: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                        didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard let hrType = HKObjectType.quantityType(forIdentifier: .heartRate),
              collectedTypes.contains(hrType),
              let value = workoutBuilder.statistics(for: hrType)?
                .mostRecentQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        else { return }
        let identity = ObjectIdentifier(workoutBuilder)
        Task { @MainActor [weak self] in
            guard let self, let active = self.builder,
                  ObjectIdentifier(active) == identity else { return }
            self.bpm = value
            HRVManager.shared.heartbeatWorkout()
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
