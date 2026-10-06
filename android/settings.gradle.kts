// 云影 Android 端 —— 独立 Android 工程（原生 Kotlin，不含 Flutter）。
//
// ## 定位
//
// 这是云影在 **Android / Android TV** 上的**正式实现**，取代原先的 Flutter 方案。
// Flutter 侧收缩为 PC 端（macOS / Windows），仍在仓库根目录（`lib/` `macos/`
// `windows/` `pubspec.yaml`）。两个工程互不引用、互不构建对方。
//
// ## 为什么 Android 不走 Flutter（2026-10-06 实测结论）
//
// 原来要验证的问题只有一个：**把视频交给 MediaCodec 直出的 SurfaceView、OSD 交给
// 原生 View 之后，这台电视上还剩多少余量**。只要 Flutter 引擎还在同一个进程里跑，
// 「每秒 10 次整页 rebuild」这个变量就撇不干净 —— 而它恰恰是要验证的对照组。
//
// 实测结论（证据见 `docs/AndroidTV-4K-丢帧-夸克对标.md` 与
// `docs/解决4k片源不卡顿解析方案.md`）：瓶颈不在解码、不在渲染面、也不在 OSD 画法，
// 而在**数据通路** ——
//   * 夸克对**单条连接**限速约 1 MiB/s，而 4K 原画要 3.67 MiB/s；
//   * Flutter 侧的多连接中继跑在 **Dart 主 isolate**（即 Android 主线程），
//     实测「按 MENU → 上屏」524 ms（原生同口径 0.3~8.3 ms）。
// 所以 Android 端走原生：8 连接并行取流 + 磁盘旁路预取 + 原生 OSD。
//
// ## 版本
//
// AGP 8.7.0 / Kotlin 2.1.0 / Gradle 8.10.2 / Media3 **1.5.1**。
// 这几个版本在本机 Gradle 缓存里**已经存在**，所以可以 `--offline` 构建。
// 改动前先确认 `~/.gradle/caches/modules-2/files-2.1/androidx.media3/`。
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "cloudcine-android"

include(":app")
