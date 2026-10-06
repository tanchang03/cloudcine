// 云影 TV 端 —— 独立 Android 工程（不含 Flutter）。
//
// ## 为什么是独立工程而不是云影的一个 Activity
//
// 要验证的问题只有一个：**把视频交给 MediaCodec 直出的 SurfaceView、OSD 交给原生
// View 之后，这台电视上还剩多少余量**。只要 Flutter 引擎还在同一个进程里跑，
// 「每秒 10 次整页 rebuild」这个变量就撇不干净 —— 而它恰恰是要验证的对照组。
// 所以这里不引 Flutter、不引云影的任何代码，只有 ExoPlayer + SurfaceView + 原生 OSD。
//
// ## 版本全部对齐云影的 `android/`
//
// AGP 8.7.0 / Kotlin 2.1.0 / Gradle 8.10.2 / Media3 **1.5.1**（与
// `video_player_android` 用的完全同版）。这不只是「保持一致」——
// 这几个版本的本机 Gradle 缓存里**已经存在**，所以原型可以 `--offline` 构建，
// 不依赖网络。改动前先确认 `~/.gradle/caches/modules-2/files-2.1/androidx.media3/`。
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

rootProject.name = "cloudcine-tv"

include(":app")
