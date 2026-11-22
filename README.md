# WatchHRV

**Personalized heart rate variability and physiological load tracking for iPhone and Apple Watch.**

WatchHRV uses Apple HealthKit data to show recent heart rate (HR), heart rate variability (HRV/SDNN), and changes relative to your personal baseline. The iPhone and Apple Watch apps share their latest summaries through WatchConnectivity.

## Features

- **HRV and heart rate:** View your latest available HealthKit readings with measurement times.
- **Personal baseline:** Compare measurements with approximately 30 days of historical data using daily medians and median absolute deviation (MAD).
- **Physiological load score:** Explore changes relative to your own baseline on a 0–100 scale, with availability and freshness checks.
- **HRV trends:** View a recent HRV trend chart on iPhone.
- **iPhone + Apple Watch:** Exchange summaries with WatchConnectivity.
- **Refresh on demand:** Use **读取最新记录** to query newly available HealthKit records.
- **HRV measurement guide:** Use Apple's Mindfulness → Breathe session and return to WatchHRV to view subsequent HRV records.
- **Workout heart rate:** On Apple Watch, start a workout session to view live heart rate and save the workout to HealthKit.

## How it works

WatchHRV builds a personal reference range from historical heart rate and HRV records. It uses robust statistics (median and MAD) to measure how far a recent reading differs from that reference, then produces an interpretable physiological load score.

The app also considers data timestamps and available context such as sleep, mindfulness and workouts when processing measurements. Score behavior depends on the source code version and available HealthKit records.

## Tech stack

- Swift and SwiftUI
- HealthKit
- WatchConnectivity
- Charts (iPhone)
- Xcode 27.2 project with iOS 26.0 and watchOS 26.0 deployment targets

## Getting started

1. Clone the repository:

   ```bash
   git clone https://github.com/l4k3q/WatchHRV.git
   cd WatchHRV
   ```

2. Open `WatchHRV.xcodeproj` in Xcode. If the cloned repository contains an additional `WatchHRV` folder, open the project inside that folder instead.
3. Select your development team under **Signing & Capabilities** for the iPhone and Apple Watch targets.
4. Confirm the HealthKit capability and permission descriptions for both targets.
5. Select an iPhone or Apple Watch run destination and press **⌘R**.
6. Grant requested Health access on the device.

## Project structure

```text
Shared/
  ContentView.swift            # User interface
  HealthKitService.swift       # HealthKit queries and data processing
  HRVManager.swift             # App state and device synchronization
  StressEstimator.swift        # Baselines and scoring
WatchHRV/                     # iOS app entry point and assets
WatchHRV Watch App/           # watchOS app and workout heart-rate collection
Tests/                        # Core logic regression tests
WatchHRV.xcodeproj/           # Xcode project
```

## Development status

WatchHRV is an evolving personal health-data project. Core scoring and synchronization logic have automated tests; full functionality should also be verified on paired iPhone and Apple Watch hardware, especially background delivery and workout recovery.

## Privacy

WatchHRV requests access to HealthKit data for app features. Review the permissions in **Signing & Capabilities** and the HealthKit request logic before running or distributing your own build.
