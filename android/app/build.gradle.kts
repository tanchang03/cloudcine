import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名：`android/key.properties` 存在就用它，不存在就退回 debug 签名。
//
// **为什么必须有这条分支**：CI 上从零生成的 debug keystore（`~/.android/debug.keystore`）
// 是**每次构建现生成一对新密钥**的 —— 于是每个产物包的签名都不一样，
// 装到同一台设备上会互相覆盖失败（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`），
// 用户得先卸载才能装新版本。要让「发布出来的包能一路升级」，签名必须固定。
//
// `key.properties` 与 `*.jks` 都在 `android/.gitignore` 里，不会被提交。
// 格式（`storeFile` 相对本模块目录，即 `android/app/`）：
//
//     storeFile=cloudcine-release.jks
//     storePassword=…
//     keyAlias=…
//     keyPassword=…
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.cloudcine.cloudcine"
    // ⚠️ **不能只用 `flutter.compileSdkVersion`**（Flutter 3.29 给的是 35）：
    // `media_kit_libs_android_video`（Android 上播放所依赖的原生库）会按较高
    // compileSdk 编，应用侧低于它时 AGP 会告警。
    // 用 `maxOf` 而不是直接写 36：以后 Flutter 把默认值抬到 37 时，这里会跟着走；
    // 只在 Flutter 的默认值**低于** 36 时才用 36 兜底。
    // ⚠️ 前提：本机 / CI 要装 `platforms;android-36`（沙箱里 AGP 不会自动装成功，
    // 得手动 `sdkmanager`）。
    compileSdk = maxOf(flutter.compileSdkVersion, 36)
    // ⚠️ **不能停在 `flutter.ndkVersion`**（Flutter 3.29 给的是 26.3.11579264）：
    // 12 个插件（media_kit_video / sqlite3_flutter_libs / flutter_inappwebview_android …）
    // 都声明依赖 27.0.12077973，停在 26 时每次构建都会打一长串警告，并让 AGP
    // 在需要 NDK 的任务上去解析一个插件并不认的版本。
    // Flutter 自己的提示就是「用最高的那个版本，NDK 向后兼容」。
    // ⚠️ 前提：本机 / CI 要装 `ndk;27.0.12077973`（`sdkmanager --install`），
    // 否则 AGP 会在配置期直接报「NDK not configured」。
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.cloudcine.cloudcine"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // 只有拿到密钥才建这个配置。建一个字段为 null 的配置会让 AGP 在
        // 签名阶段抛异常，而不是干净地退回 debug 签名。
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 没有 key.properties（本机开发、以及没配 secret 的 CI）就用 debug 签名，
            // 这样 `flutter run --release` 依然可用、APK 也依然能侧载。
            // ⚠️ 代价是签名不固定 —— 只在「自己用」的场合可以接受。
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
