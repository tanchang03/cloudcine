pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.7.0" apply false
    // ⚠️ **不能退回 1.8.22**（Flutter 3.29 模板的默认值）。
    // `media_kit_video` 会把 `screen_brightness_android` 拖进来，而它 2.1.6 的
    // `build.gradle.kts` 用的是 Kotlin Gradle Plugin **2.x 才有的**
    // `compilerOptions { }` DSL（`project.extensions.configure(
    //   KotlinAndroidProjectExtension::class.java) { compilerOptions { ... } }`）。
    // 停在 1.8.22 时 Gradle 会在评估那个子项目时直接失败：
    //   'void KotlinAndroidProjectExtension.compilerOptions(Function1)'
    // 也就是「方法不存在」—— 报的是 DSL 找不到，看不出是版本问题。
    // 2.1.0 是 2.x 的稳定线，与 AGP 8.7.0 / Gradle 8.10.2 配套；
    // 不要跳到 2.2：它删掉了一批 2.1 里只是弃用的 API（如 `kotlinOptions`），
    // 本仓库 `app/build.gradle.kts` 还在用。
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
}

include(":app")
