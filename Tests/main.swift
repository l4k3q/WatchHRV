import Foundation

let cal = Calendar(identifier: .gregorian)
let now = Date(timeIntervalSince1970: 1_800_000_000)
let today = cal.startOfDay(for: now)
func read(_ value: Double, _ date: Date, _ motion: Int = 1) -> MetricReading {
    MetricReading(value: value, date: date, motion: motion)
}
func day(_ delta: Int, _ hour: Int = 12) -> Date {
    cal.date(byAdding: .day, value: -delta, to: today)!.addingTimeInterval(TimeInterval(hour * 3600))
}
func history(_ days: Int = 10) -> HealthDataBatch {
    var hrv: [MetricReading] = [], hr: [MetricReading] = []
    for d in 1...days {
        hrv.append(read(50, day(d)))
        for h in [9,12,18] { hr.append(read(60, day(d,h))) }
    }
    return HealthDataBatch(hrv: hrv, heartRate: hr, restingRate: [], stepsLast10Minutes: 0)
}
func measure(_ batch: HealthDataBatch, hr: Double = 70, hrAge: TimeInterval = 60,
             motion: Int = 1, hrv: Double? = 45, hrvAge: TimeInterval = 60,
             steps: Double? = 0, mindful: [DateInterval] = [], workout: [DateInterval] = []) -> HealthDataBatch {
    let h = read(hr, now.addingTimeInterval(-hrAge), motion)
    return HealthDataBatch(hrv: batch.hrv + (hrv.map { [read($0, now.addingTimeInterval(-hrvAge))] } ?? []),
                           heartRate: batch.heartRate + [h], restingRate: [],
                           stepsLast10Minutes: steps,
                           mindfulIntervals: mindful, workoutIntervals: workout)
}
var passed = 0
@MainActor func assertTest(_ description: String, _ truth: @autoclosure () -> Bool) {
    guard truth() else { fatalError("FAILED: \(description)") }
    passed += 1
    print("PASS \(passed): \(description)")
}
let h = history()
let normal = StressEstimator.calculate(measure(h), now: now, calendar: cal)
assertTest("base calculation", normal.relativeLoad == 78 && normal.scoredHRVAt != nil)
assertTest("dual-signal score has correct quality", normal.quality == "近时双指标参考")
let unknownMotionWithLowSteps = StressEstimator.calculate(measure(h,motion:0,steps:0),now:now,calendar:cal)
assertTest("motion-unknown low-step HRV score has correct quality",
           unknownMotionWithLowSteps.scoredHRVAt != nil && unknownMotionWithLowSteps.quality == "近时双指标参考")
assertTest("median odd and even", StressEstimator.median([2,1,3]) == 2 && StressEstimator.median([1,2,3,4]) == 2.5)
assertTest("HR-only reference", StressEstimator.calculate(measure(h,hrv:nil),now:now,calendar:cal).relativeLoad == 73)
assertTest("7h HRV excluded", StressEstimator.calculate(measure(h,hrv:20,hrvAge:7*3600),now:now,calendar:cal).scoredHRVAt == nil)
assertTest("20min HRV used", StressEstimator.calculate(measure(h,hrv:20,hrvAge:20*60),now:now,calendar:cal).scoredHRVAt != nil)
assertTest("35min HRV excluded by separation", StressEstimator.calculate(measure(h,hrv:20,hrvAge:35*60),now:now,calendar:cal).scoredHRVAt == nil)
assertTest("expired HR excluded", StressEstimator.calculate(measure(h,hrAge:16*60),now:now,calendar:cal).relativeLoad == nil)
assertTest("steps activity excluded", StressEstimator.calculate(measure(h,steps:25),now:now,calendar:cal).relativeLoad == nil)
assertTest("unknown motion no steps excluded", StressEstimator.calculate(measure(h,motion:0,steps:nil),now:now,calendar:cal).relativeLoad == nil)
assertTest("requires 7 days", StressEstimator.calculate(measure(history(6)),now:now,calendar:cal).relativeLoad == nil)
assertTest("expired score invalidated", normal.validated(at: now.addingTimeInterval(20*60)).relativeLoad == nil)
var dense = history()
var denseHR = dense.heartRate
for n in 0..<200 { denseHR.append(read(85, day(1, 0).addingTimeInterval(TimeInterval(n * 100)))) }
dense = HealthDataBatch(hrv: dense.hrv, heartRate: denseHR, restingRate: [], stepsLast10Minutes:0)
let denseResult = StressEstimator.calculate(measure(dense,hr:75,hrv:nil),now:now,calendar:cal)
assertTest("one dense day no longer dominates baseline", denseResult.sedentaryHRBaseline == 60)
let mindfulness = DateInterval(start:now.addingTimeInterval(-200),end:now.addingTimeInterval(-30))
let mindful = StressEstimator.calculate(measure(h,hrv:180,hrvAge:60,mindful:[mindfulness]),now:now,calendar:cal)
assertTest("mindfulness reading visible but not scored", mindful.hrv == 180 && mindful.scoredHRVAt == nil && mindful.relativeLoad == 73)
assertTest("mindfulness reading is identified", mindful.latestHRVIsMindful == true)
assertTest("mindfulness overlap recognizes write delay", StressEstimator.isMindfulReading(mindfulness.end.addingTimeInterval(90), intervals:[mindfulness]))
let workoutOld = DateInterval(start:day(1,0),end:day(1,18))
var workoutHistory = h
workoutHistory = HealthDataBatch(hrv:h.hrv,heartRate:h.heartRate + [read(180,day(1,12))],restingRate:[],stepsLast10Minutes:0,workoutIntervals:[workoutOld])
let workoutResult = StressEstimator.calculate(measure(workoutHistory,hr:70,hrv:nil,workout:[workoutOld]),now:now,calendar:cal)
assertTest("workout HR excluded from baseline",workoutResult.sedentaryHRBaseline == 60)
// A dense set of high, sedentary-tagged HR observations immediately after
// exercise must not affect the daily median that enters the resting baseline.
var recoveryHR = h.heartRate
for n in 1...25 { recoveryHR.append(read(160, workoutOld.end.addingTimeInterval(TimeInterval(n * 15)))) }
let recoveryBatch = HealthDataBatch(hrv: h.hrv, heartRate: recoveryHR, restingRate: [],
                                    stepsLast10Minutes: 0, workoutIntervals: [workoutOld])
let recovered = StressEstimator.calculate(measure(recoveryBatch,hr:70,hrv:nil,workout:[workoutOld]),
                                         now:now, calendar:cal)
assertTest("10-minute post-workout HR excluded from baseline", recovered.sedentaryHRBaseline == 60)
assertTest("workout recovery filter excludes 9 min but not 11 min",
           StressEstimator.isWorkoutReading(workoutOld.end.addingTimeInterval(9*60), intervals:[workoutOld]) &&
           !StressEstimator.isWorkoutReading(workoutOld.end.addingTimeInterval(11*60), intervals:[workoutOld]))
let workoutRecent = DateInterval(start:now.addingTimeInterval(-12*60),end:now.addingTimeInterval(-3*60))
let afterWorkout = StressEstimator.calculate(measure(h,hrv:nil,workout:[workoutRecent]),now:now,calendar:cal)
assertTest("10min post-workout score suppressed", afterWorkout.relativeLoad == nil && afterWorkout.level == "运动后恢复")
var remoteNoScore = normal
remoteNoScore.heartRateAt = now
remoteNoScore.hrvAt = now
remoteNoScore.relativeLoad = nil
assertTest("valid local outranks newer invalid companion", StressEstimator.preferLocal(normal,over:remoteNoScore,at:now))
var peerValid = normal
peerValid.heartRateAt = now
assertTest("more recent valid companion wins", !StressEstimator.preferLocal(normal,over:peerValid,at:now))
var localInvalid = normal
localInvalid.relativeLoad = nil
localInvalid.heartRateAt = now.addingTimeInterval(-100)
assertTest("invalid snapshots compare sample timestamps", StressEstimator.preferLocal(localInvalid,over:remoteNoScore,at:now) == false)
assertTest("3-minute HRV age rollover checked", normal.validated(at:now.addingTimeInterval(2*60)).relativeLoad != nil)
// Simulate a stale companion snapshot with an outdated HRV timestamp.
var stalePeer = normal
stalePeer.scoredHRVAt = now.addingTimeInterval(-46 * 60)
let degraded = stalePeer.validated(at: now)
assertTest("stale companion HRV falls back to HR-only", degraded.relativeLoad == normal.hrOnlyLoad && degraded.scoredHRVAt == nil)
assertTest("newer message accepted even after last sample deleted",
           SnapshotSyncPolicy.accepts(issuedAt: now, after: now.addingTimeInterval(-1), now: now))
assertTest("old message rejected independent of measurement timestamp",
           !SnapshotSyncPolicy.accepts(issuedAt: now.addingTimeInterval(-2),
                                      after: now.addingTimeInterval(-1), now: now))
assertTest("stale companion message rejected",
           !SnapshotSyncPolicy.accepts(issuedAt: now.addingTimeInterval(-31*60),
                                      after: .distantPast, now: now))
print("CHECKPOINT: \(passed) estimator tests")

// Exercise the same PeerSyncInbox.receive path used by HRVManager rather than
// only testing the scalar ordering predicate.
var inbox = PeerSyncInbox()
assertTest("peer inbox starts empty", inbox.snapshot(at: now) == nil)
assertTest("peer inbox accepts first snapshot",
           inbox.receive(senderID: "watch-1", sequence: 1, issuedAt: now,
                         hasSnapshot: true, snapshot: normal, workoutActive: false, now: now))
assertTest("peer inbox displays received snapshot", inbox.snapshot(at: now) == normal)
let tenLater = now.addingTimeInterval(10 * 60)
assertTest("placeholder packet accepted",
           inbox.receive(senderID: "watch-1", sequence: 2,
                         issuedAt: tenLater,
                         hasSnapshot: false, snapshot: .empty,
                         workoutActive: true, now: tenLater))
assertTest("placeholder does not erase real snapshot", inbox.snapshot(at: tenLater) == normal)
assertTest("workout lease renews on receiver clock", inbox.workoutInProgress(at: tenLater.addingTimeInterval(4 * 60)))
assertTest("workout lease expires after 5 minutes", !inbox.workoutInProgress(at: tenLater.addingTimeInterval(6 * 60)))
assertTest("duplicate sequence is rejected",
           !inbox.receive(senderID: "watch-1", sequence: 2, issuedAt: now,
                          hasSnapshot: true, snapshot: .empty, workoutActive: false, now: tenLater))
assertTest("earlier sequence cannot override newer state",
           !inbox.receive(senderID: "watch-1", sequence: 1, issuedAt: now,
                          hasSnapshot: true, snapshot: .empty, workoutActive: false, now: tenLater))
let twentyLater = now.addingTimeInterval(20 * 60)
assertTest("small wall-clock offset does not reject newer sequence",
           inbox.receive(senderID: "watch-1", sequence: 3,
                         issuedAt: twentyLater.addingTimeInterval(-2 * 60),
                         hasSnapshot: false, snapshot: .empty,
                         workoutActive: false, now: twentyLater))
assertTest("placeholder does not extend real snapshot 30min TTL",
           inbox.snapshot(at: now.addingTimeInterval(30 * 60 + 1)) == nil)
let thirtyOneLater = now.addingTimeInterval(31 * 60)
assertTest("new actual snapshot accepted after expiration",
           inbox.receive(senderID: "watch-1", sequence: 4, issuedAt: thirtyOneLater,
                         hasSnapshot: true, snapshot: peerValid,
                         workoutActive: false, now: thirtyOneLater))
assertTest("valid snapshot has new receiver-clock expiration",
           inbox.snapshot(at: thirtyOneLater.addingTimeInterval(29 * 60)) == peerValid)
assertTest("sender reinstall can reset sequence",
           inbox.receive(senderID: "watch-2", sequence: 1, issuedAt: thirtyOneLater,
                         hasSnapshot: true, snapshot: normal,
                         workoutActive: false, now: thirtyOneLater))
assertTest("delayed message from superseded sender rejected",
           !inbox.receive(senderID: "watch-1", sequence: 5, issuedAt: thirtyOneLater,
                          hasSnapshot: true, snapshot: .empty,
                          workoutActive: false, now: thirtyOneLater))
var legacyInbox = PeerSyncInbox()
assertTest("old version compatible via timestamp",
           legacyInbox.receive(senderID: nil, sequence: nil,
                               issuedAt: now, hasSnapshot: true, snapshot: normal,
                               workoutActive: false, now: now))
assertTest("legacy out-of-order timestamp rejected",
           !legacyInbox.receive(senderID: nil, sequence: nil,
                                issuedAt: now.addingTimeInterval(-1),
                                hasSnapshot: true, snapshot: .empty,
                                workoutActive: false, now: now))
// Replay validation uses the exact inbox receive path used by WCSession.
var restored = PeerSyncInbox()
assertTest("31-minute-old stored context is rejected before sequence advance",
           !restored.receive(senderID: "old-watch", sequence: 10,
                             issuedAt: now.addingTimeInterval(-31*60),
                             hasSnapshot: true, snapshot: normal,
                             workoutActive: true, now: now, replayedContext: true) &&
           restored.snapshot(at: now) == nil && !restored.workoutInProgress(at: now))
assertTest("fresh live message accepted after rejecting replay",
           restored.receive(senderID: "old-watch", sequence: 11,
                            issuedAt: now, hasSnapshot: true, snapshot: normal,
                            workoutActive: false, now: now))
var replayedSixMinutes = PeerSyncInbox()
assertTest("6-minute-old replay can display fresh snapshot but not workout",
           replayedSixMinutes.receive(senderID: "watch", sequence: 1,
                                      issuedAt: now.addingTimeInterval(-6*60),
                                      hasSnapshot: true, snapshot: normal,
                                      workoutActive: true, now: now, replayedContext: true) &&
           replayedSixMinutes.snapshot(at: now) == normal &&
           !replayedSixMinutes.workoutInProgress(at: now))
var replayedTwoMinutes = PeerSyncInbox()
assertTest("2-minute-old replay retains only remaining workout lease",
           replayedTwoMinutes.receive(senderID: "watch", sequence: 1,
                                      issuedAt: now.addingTimeInterval(-2*60),
                                      hasSnapshot: true, snapshot: normal,
                                      workoutActive: true, now: now, replayedContext: true) &&
           replayedTwoMinutes.workoutInProgress(at: now.addingTimeInterval(2*60)) &&
           !replayedTwoMinutes.workoutInProgress(at: now.addingTimeInterval(4*60)))
var futureReplayed = PeerSyncInbox()
assertTest("future-dated replay rejected",
           !futureReplayed.receive(senderID: "watch", sequence: 1,
                                    issuedAt: now.addingTimeInterval(6*60),
                                    hasSnapshot: true, snapshot: normal,
                                    workoutActive: false, now: now, replayedContext: true))
var cachedWithSteps = history()
cachedWithSteps = HealthDataBatch(hrv: cachedWithSteps.hrv,
                                   heartRate: cachedWithSteps.heartRate,
                                   restingRate: [], stepsLast10Minutes: 3,
                                   mindfulIntervals: [mindfulness],
                                   workoutIntervals: [workoutOld],
                                   sleepIntervals: [DateInterval(start: day(1,1), end: day(1,7))])
let fallbackNoSteps = cachedWithSteps.withoutRecentSteps()
assertTest("query error fallback clears stale step evidence",
           fallbackNoSteps.stepsLast10Minutes == nil &&
           fallbackNoSteps.heartRate.count == cachedWithSteps.heartRate.count &&
           fallbackNoSteps.sleepIntervals.count == 1 &&
           fallbackNoSteps.workoutIntervals.count == 1)

// Compare identical history, with/without sleep intervals. Sleep samples
// tagged 'sedentary' must not dilute waking resting HR baseline.
var sleepHR = h.heartRate
var overnight: [DateInterval] = []
for d in 1...10 {
    let start = day(d, 1)
    overnight.append(DateInterval(start: start, end: day(d, 7)))
    for n in 0..<20 { sleepHR.append(read(42, start.addingTimeInterval(Double(n * 15 * 60)))) }
}
let sleepInputWithoutLabels = HealthDataBatch(
    hrv: h.hrv, heartRate: sleepHR + [read(70, now.addingTimeInterval(-60))],
    restingRate: [], stepsLast10Minutes: 0)
let sleepInputWithLabels = HealthDataBatch(
    hrv: sleepInputWithoutLabels.hrv, heartRate: sleepInputWithoutLabels.heartRate,
    restingRate: [], stepsLast10Minutes: 0, sleepIntervals: overnight)
let unfilteredSleepBaseline = StressEstimator.calculate(sleepInputWithoutLabels,now:now,calendar:cal)
let filteredSleepBaseline = StressEstimator.calculate(sleepInputWithLabels,now:now,calendar:cal)
assertTest("unfiltered sleep HR would lower personal baseline",
           unfilteredSleepBaseline.sedentaryHRBaseline == 42)
assertTest("sleep-labeled HR excluded from waking baseline",
           filteredSleepBaseline.sedentaryHRBaseline == 60 &&
           filteredSleepBaseline.relativeLoad == 73)
assertTest("sleep interval boundaries handled",
           StressEstimator.isSleepReading(day(1,3),intervals:overnight) &&
           !StressEstimator.isSleepReading(day(1,9),intervals:overnight))
// Anchored cache integration uses this same merge helper in HealthKitService.
let cacheOld = UUID(), cacheUpdated = UUID(), cacheLate = UUID(), cacheFuture = UUID()
let cached = [cacheOld: day(31), cacheUpdated: day(3)]
let mergedCache = IncrementalCacheMerge.apply(
    existing: cached,
    added: [(id: cacheUpdated, value: day(2)),
            (id: cacheLate, value: day(12)),
            (id: cacheFuture, value: now.addingTimeInterval(6*60))],
    deleted: [cacheOld],
    keep: { $0 >= now.addingTimeInterval(-30*86400) &&
            $0 <= now.addingTimeInterval(5*60) })
assertTest("incremental cache removes deleted sample UUID", mergedCache[cacheOld] == nil)
assertTest("incremental cache replaces updated sample UUID", mergedCache[cacheUpdated] == day(2))
assertTest("incremental cache accepts late-arriving older sample", mergedCache[cacheLate] == day(12))
assertTest("incremental cache rejects out-of-window future sample", mergedCache[cacheFuture] == nil)
// Waking HRV must use waking observations, even when overnight HRV is high.
var mixedHRV = h.hrv
var nights: [DateInterval] = []
for d in 1...10 {
    nights.append(DateInterval(start: day(d, 1), end: day(d, 7)))
    for n in 0..<7 {
        mixedHRV.append(read(95, day(d, 1).addingTimeInterval(Double(n * 30 * 60))))
    }
}
let sleepyHRVData = HealthDataBatch(hrv: mixedHRV + [read(50, now.addingTimeInterval(-60))],
                                    heartRate: h.heartRate + [read(60, now.addingTimeInterval(-60))],
                                    restingRate: [], stepsLast10Minutes: 0, sleepIntervals: nights)
let wakingBaseline = StressEstimator.calculate(sleepyHRVData, now: now, calendar: cal)
assertTest("sleep HRV omitted from waking baseline", wakingBaseline.hrvBaseline == 50)
assertTest("waking HRV available and scored", wakingBaseline.scoredHRVAt != nil && wakingBaseline.relativeLoad == 50)
let noSleepLabels = HealthDataBatch(hrv: sleepyHRVData.hrv,heartRate:sleepyHRVData.heartRate,
                                   restingRate:[],stepsLast10Minutes:0)
assertTest("sleep HRV would bias unfiltered day median", 
           StressEstimator.calculate(noSleepLabels,now:now,calendar:cal).hrvBaseline == 95)
// A sleeping HR remains visible but cannot contribute to a daytime score.
let currentSleep = DateInterval(start: now.addingTimeInterval(-15*60), end: now)
let sleepingHR = HealthDataBatch(hrv: h.hrv + [read(70, now.addingTimeInterval(-120))],
                                  heartRate: h.heartRate + [read(60, now.addingTimeInterval(-10*60)),
                                                             read(45, now.addingTimeInterval(-60))],
                                  restingRate: [],stepsLast10Minutes:0, sleepIntervals: [currentSleep])
let sleepingScore = StressEstimator.calculate(sleepingHR,now:now,calendar:cal)
assertTest("sleeping HR never yields waking load",sleepingScore.relativeLoad == nil &&
           sleepingScore.level == "睡眠记录" && sleepingScore.sleepSuppressedAt == now)
assertTest("latest sleeping HR preserved for display", sleepingScore.heartRate == 45 && sleepingScore.heartRateAt != nil)
assertTest("latest sleep HRV marked for display", sleepingScore.latestHRVIsSleep == true)
let wakeAfterSleep = HealthDataBatch(hrv: sleepingHR.hrv,
                                   heartRate: sleepingHR.heartRate + [read(70,now.addingTimeInterval(-15))],
                                   restingRate: [],stepsLast10Minutes:0, sleepIntervals:[DateInterval(start:currentSleep.start, end:now.addingTimeInterval(-30))])
let awakeScore = StressEstimator.calculate(wakeAfterSleep, now: now, calendar: cal)
assertTest("new waking HR can resume load",awakeScore.sleepSuppressedAt == nil && awakeScore.relativeLoad != nil)
let exercise = DateInterval(start:day(3,9), end:day(3,15))
var exerciseHRV = h.hrv
for n in 0..<8 { exerciseHRV.append(read(180,day(3,10).addingTimeInterval(Double(n*1200)))) }
let exerciseExcluded = StressEstimator.calculate(HealthDataBatch(hrv:exerciseHRV + [read(50,now.addingTimeInterval(-60))],
        heartRate:h.heartRate + [read(60,now.addingTimeInterval(-60))], restingRate:[],
        stepsLast10Minutes:0, workoutIntervals:[exercise]), now:now, calendar:cal)
assertTest("workout HRV excluded from waking baseline",exerciseExcluded.hrvBaseline == 50)
// Full snapshots and absent new optional fields retain backward compatibility.
let encodedSnapshot = try! JSONEncoder().encode(wakingBaseline)
let decodedSnapshot = try! JSONDecoder().decode(HRVSnapshot.self,from:encodedSnapshot)
assertTest("full snapshot JSON roundtrip", decodedSnapshot == wakingBaseline)
var oldFields = try! JSONSerialization.jsonObject(with: encodedSnapshot) as! [String:Any]
oldFields.removeValue(forKey:"latestHRVIsSleep")
oldFields.removeValue(forKey:"sleepSuppressedAt")
let legacyJSON = try! JSONSerialization.data(withJSONObject:oldFields)
let legacySnapshot = try! JSONDecoder().decode(HRVSnapshot.self,from:legacyJSON)
assertTest("old snapshots decode without new optional fields", legacySnapshot.latestHRVIsSleep == nil && legacySnapshot.sleepSuppressedAt == nil)
// The actual companion display reducer also needs adversarial tests.
var remoteScored = wakingBaseline
remoteScored.heartRateAt = now
let peerShouldNotOverrideSleep = StressEstimator.applyingSleepContext(
    to:remoteScored, local:sleepingScore, remote:remoteScored, at:now)
assertTest("sleep evidence prevents remote waking-score override",
           peerShouldNotOverrideSleep.relativeLoad == nil && peerShouldNotOverrideSleep.level == "睡眠记录")
let oldSleepNoLongerBlocks = StressEstimator.applyingSleepContext(
    to:remoteScored, local:sleepingScore, remote:remoteScored, at:now.addingTimeInterval(16*60))
assertTest("sleep suppression lease expires", oldSleepNoLongerBlocks.relativeLoad == remoteScored.relativeLoad)
let nonSleepCompanion = StressEstimator.applyingSleepContext(
    to:remoteScored, local:awakeScore, remote:remoteScored, at:now)
assertTest("waking score unaffected without sleep context",nonSleepCompanion.relativeLoad == remoteScored.relativeLoad)
// Score invariants under a range of plausible HR/HRV readings.
let hrvOnlySequence = stride(from: 20.0, through: 120.0, by: 5).map {
    StressEstimator.calculate(measure(h,hr:70,hrv:$0),now:now,calendar:cal).relativeLoad!
}
assertTest("higher HRV does not increase load at fixed HR",
           zip(hrvOnlySequence,hrvOnlySequence.dropFirst()).allSatisfy { $0 >= $1 })
let hrOnlySequence = stride(from: 40.0, through: 150.0, by: 5).map {
    StressEstimator.calculate(measure(h,hr:$0,hrv:nil),now:now,calendar:cal).relativeLoad!
}
assertTest("higher HR does not decrease load at fixed HRV",
           zip(hrOnlySequence,hrOnlySequence.dropFirst()).allSatisfy { $0 <= $1 })
assertTest("scores remain bounded 0 to 100",(hrOnlySequence + hrvOnlySequence).allSatisfy { (0...100).contains($0) })
// Regression suite for the actual display reducer used by HRVManager.
// The sender's latest HRV metadata must travel together with the value.
var peerSleepHRV = normal
peerSleepHRV.hrvAt = now
peerSleepHRV.hrv = 110
peerSleepHRV.latestHRVIsSleep = true
peerSleepHRV.latestHRVIsMindful = false
peerSleepHRV.relativeLoad = nil
let mergedPeerSleepHRV = DisplaySnapshotResolver.resolve(
    local: normal, remote: peerSleepHRV,
    localWorkout: false, remoteWorkout: false, at: now).snapshot
assertTest("peer sleep-HRV value and metadata merge together",
           mergedPeerSleepHRV.hrv == 110 && mergedPeerSleepHRV.latestHRVIsSleep == true &&
           mergedPeerSleepHRV.latestHRVIsMindful == false && mergedPeerSleepHRV.relativeLoad != nil)
var peerMindfulHRV = peerSleepHRV
peerMindfulHRV.latestHRVIsMindful = true
peerMindfulHRV.latestHRVIsSleep = false
let mergedMindful = DisplaySnapshotResolver.resolve(local: normal, remote: peerMindfulHRV,
                                localWorkout: false, remoteWorkout: false, at: now).snapshot
assertTest("peer mindful-HRV provenance remains paired with newest value",
           mergedMindful.latestHRVIsMindful == true && mergedMindful.latestHRVIsSleep == false)
let activeWorkoutDisplay = DisplaySnapshotResolver.resolve(
    local: normal, remote: nil, localWorkout: false, remoteWorkout: true, at: now).snapshot
assertTest("peer workout lease suppresses local score",
           activeWorkoutDisplay.relativeLoad == nil && activeWorkoutDisplay.level == "运动采集中")
let noPeerDisplay = DisplaySnapshotResolver.resolve(local: normal, remote: nil,
                      localWorkout: false, remoteWorkout: false, at: now).snapshot
assertTest("peer expiration falls back to valid local snapshot", noPeerDisplay.relativeLoad == normal.relativeLoad)
let peerOnlyDisplay = DisplaySnapshotResolver.resolve(local: nil, remote: normal,
                       localWorkout: false, remoteWorkout: false, at: now).snapshot
assertTest("peer-only display retains valid score", peerOnlyDisplay.relativeLoad == normal.relativeLoad)
let allGoneDisplay = DisplaySnapshotResolver.resolve(local: nil, remote: nil,
                      localWorkout: false, remoteWorkout: false, at: now).snapshot
assertTest("all expired peer and local data clears UI", allGoneDisplay.relativeLoad == nil)
// A *measured* waking HR supersedes older sleep evidence from either side.
var newerAwakeScore = normal
newerAwakeScore.heartRateAt = now.addingTimeInterval(-30)
var oldSleepEvidence = sleepingScore
oldSleepEvidence.sleepSuppressedAt = now.addingTimeInterval(-5*60)
let resumedFromSleep = DisplaySnapshotResolver.resolve(
    local: newerAwakeScore, remote: oldSleepEvidence,
    localWorkout: false, remoteWorkout: false, at: now).snapshot
assertTest("newer waking heart rate overrides older peer sleep indication",
           resumedFromSleep.relativeLoad == newerAwakeScore.relativeLoad)
let sleepStillNewer = DisplaySnapshotResolver.resolve(
    local: normal, remote: sleepingScore,
    localWorkout: false, remoteWorkout: false, at: now).snapshot
assertTest("new sleep observation suppresses older local score",
           sleepStillNewer.relativeLoad == nil && sleepStillNewer.level == "睡眠记录")
// Delayed live messages are not granted fresh leases or allowed to consume order.
var lateLiveInbox = PeerSyncInbox()
assertTest("two-hour-old live workout packet rejected",
           !lateLiveInbox.receive(senderID: "watch", sequence: 12,
             issuedAt: now.addingTimeInterval(-2*3600), hasSnapshot: true,
             snapshot: normal, workoutActive: true, now: now) &&
             !lateLiveInbox.workoutInProgress(at: now))
assertTest("fresh packet accepted after rejected stale high sequence",
           lateLiveInbox.receive(senderID: "watch", sequence: 1,
             issuedAt: now, hasSnapshot: true, snapshot: normal,
             workoutActive: false, now: now))
var delayedWorkoutInbox = PeerSyncInbox()
assertTest("six-minute delayed live packet cannot resurrect workout lease",
           delayedWorkoutInbox.receive(senderID: "watch", sequence: 1,
             issuedAt: now.addingTimeInterval(-6*60), hasSnapshot: true,
             snapshot: normal, workoutActive: true, now: now) &&
             !delayedWorkoutInbox.workoutInProgress(at: now))
assertTest("small clock skew cannot extend remote workout lease",
           delayedWorkoutInbox.receive(senderID: "watch", sequence: 2,
             issuedAt: now.addingTimeInterval(-60), hasSnapshot: false,
             snapshot: .empty, workoutActive: true, now: now) &&
             !delayedWorkoutInbox.workoutInProgress(at: now.addingTimeInterval(4*60)))
assertTest("future-dated live packet beyond tolerance rejected",
           !delayedWorkoutInbox.receive(senderID: "watch", sequence: 3,
             issuedAt: now.addingTimeInterval(6*60), hasSnapshot: true,
             snapshot: normal, workoutActive: true, now: now))
assertTest("HealthKit success may include nil saved object when device locked",
           WorkoutSaveResult.saved(errorIsNil: true) && !WorkoutSaveResult.saved(errorIsNil: false))
print("SUCCESS: \(passed) total tests")
