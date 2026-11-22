//
//  WatchHRVApp.swift
//  WatchHRV
//
//  Created by limr on 2026/11/14.
//


import SwiftUI

@main
struct WatchHRVApp: App {

    init() {
        HRVManager.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
