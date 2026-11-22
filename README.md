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

# WatchHRV

**个性化心率变异性与生理负荷监测**

WatchHRV 是一款适用于 iPhone 和 Apple Watch 的原生应用，基于 Apple HealthKit 获取心率（HR）和心率变异性（HRV）数据，结合个人历史基线，分析生理负荷变化并展示近期健康趋势。

## 功能特性

- **HRV 监测**：读取和展示 HealthKit 中的心率变异性（SDNN）与心率记录。
- **个性化基线**：根据历史生理数据建立个人参考水平。
- **生理负荷评分**：根据心率与可用 HRV 数据相对基线的偏离程度，生成 0–100 分的评估结果。
- **趋势可视化**：查看近期 HRV 变化趋势。
- **双端协同**：通过 WatchConnectivity 在 iPhone 与 Apple Watch 之间同步数据与展示状态。
- **运动心率监测**：在 Apple Watch 运动会话期间查看实时心率。
- **HealthKit 集成**：经用户授权后读取相关健康记录。

## 工作原理

WatchHRV 目前采用基于规则的个体化统计分析方法：

1. 从 HealthKit 读取心率、HRV 及相关时间信息。
2. 通过历史数据建立个人基线，使用**中位数**和**中位数绝对偏差（MAD）**降低异常采样的影响。
3. 利用**稳健 Z-score** 衡量当前测量值相对于个人基线的偏离程度。
4. 根据可用数据计算生理负荷评分，并展示近期趋势。
5. 结合记录时间与数据可用性更新评分，通过 WatchConnectivity 协同双端状态。

当前版本使用统计模型进行分析；机器学习是后续可探索的方向。

## 技术栈

- Swift
- SwiftUI
- HealthKit
- WatchConnectivity
- Swift Charts
- Xcode

## 本地运行

1. 克隆仓库：

   ```bash
   git clone https://github.com/l4k3q/WatchHRV.git
   ```

2. 在 Xcode 中打开 `WatchHRV.xcodeproj`（按仓库中的实际目录定位）。
3. 在 **Signing & Capabilities** 中配置自己的 Apple Developer Team。
4. 检查 iOS 与 watchOS Target 的 HealthKit 权限配置。
5. 选择 iPhone 或 Apple Watch 作为运行设备，编译并运行。
6. 在设备上按提示授权健康数据访问。

## 项目状态

WatchHRV 正在持续开发中，重点完善生理数据分析、数据同步和 Apple Watch 端体验。

## 作者

由 [l4k3q](https://github.com/l4k3q) 开发。
