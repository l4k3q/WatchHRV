//
//  WatchHRVApp.swift
//  WatchHRV Watch App
//
//  Created by limr on 2026/11/14.
//


import SwiftUI
import WatchKit

/// watchOS invokes this after relaunch when a workout survives an app crash.
final class WatchHRVLifecycleDelegate: NSObject, WKApplicationDelegate {
    nonisolated func handleActiveWorkoutRecovery() {
        Task { @MainActor in WorkoutHeartRateMonitor.shared.recoverActiveSession() }
    }
}

@main
struct WatchHRVApp: App {
    @WKApplicationDelegateAdaptor(WatchHRVLifecycleDelegate.self) private var appDelegate

    init() {
        HRVManager.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

