import java.io.File
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

// ── 品牌化产物名（APK）──────────────────────────────────────────────────────
//
// **为什么必须在这里做**：`flutter build apk` 的产物名由 Flutter 工具链
// **定死** —— `flutter.groovy:1418-1445` 在 `assembleRelease.doLast` 里把 AGP 的
// 输出 `copy` 到 `outputs/flutter-apk/`，再用 `rename` **强制**改成
// `app-<abi>?-<flavor>?-<mode>.apk`。所以在 Gradle 里改 AGP 的 `outputFileName`
// 是无效的：`outputs/apk/release/` 下会多一个副本，而
// `outputs/flutter-apk/app-release.apk` 纹丝不动 —— 偏偏后者才是
// `flutter build apk` 报给用户、`flutter install` 会去装的那一个。
//
// **做法是「再复制一份」而不是「改名」**：Flutter 工具是按**精确文件名**
// `app-<mode>.apk` 去 `flutter-apk/` 里找产物的（`gradle.dart:132-143` 造名字、
// `:1010-1022` 逐个 `existsSync()`），原文件一旦不在，它会直接报
// 「Gradle build failed to produce an .apk file」。反过来，同一目录里多一个
// **别的名字**的文件对它毫无影响 —— 这条是读过工具源码确认过的。
//
// 用 `finalizedBy` 而不是 `doLast`：doLast 的先后取决于 Flutter 插件注册的
// 时机（它在 `applicationVariants.all` 里注册，而 variant 由 AGP 在
// afterEvaluate 之后才建），而 finalizer 由 Gradle 保证在主任务**完成之后**才跑，
// 那时源文件一定已经就位。
//
// 命名与另外两个平台对齐：
//   macOS    cloudcine-<ver>-macos.dmg / .zip
//   Windows  cloudcine-<ver>-windows-x64.msi / .zip
//   Android  cloudcine-<ver>-b<versionCode>-android.apk   ← 本段
// ⚠️ 只有 Android 多带一个 `-b<versionCode>`：`versionName` 可以不变而
// `versionCode` 必须递增（`pubspec.yaml` 的 `version: X.Y.Z+B`），只带名字会让
// 「同名不同内容」的两个包无法分辨，而这恰恰是 Android 上最常见的发版方式。
// ⚠️ 文件名刻意保持 **ASCII 小写**（与 dmg / msi 一致）：`adb push`、CI 缓存、
// 旧版 Windows 处理中文与空格的方式各不相同，而产物名不需要好看 ——
// 好看的显示名在应用里（`AndroidManifest.xml` 的 `android:label="云影 CloudCine"`）。
//
// 产物落在 `build/app/outputs/flutter-apk/`（与 `app-release.apk` 并排），
// 好处是 `flutter clean` 会一并清掉，CI 里也已经被现有的 artifact glob 覆盖。

listOf("Release", "Debug", "Profile").forEach { capitalized ->
    val buildMode = capitalized.lowercase()
    // 版本号在配置期就取好：与 `defaultConfig` 里用的是同一个源
    // （Flutter 工具从 pubspec 的 `version: X.Y.Z+B` 注入），不二次解析 pubspec。
    val appVersionName = flutter.versionName
    val appVersionCode = flutter.versionCode

    val brandApk = tasks.register("brand${capitalized}Apk") {
        group = "flutter"
        description = "把 $buildMode 的 APK 另存一份品牌名（不替换 app-$buildMode.apk）"
        doLast {
            val apkDir = project.layout.buildDirectory.dir("outputs/flutter-apk").get().asFile
            // Flutter 的命名是 `app-<abi>?-<flavor>?-<mode>.apk`；没有
            // `--split-per-abi` 时就是 `app-$buildMode.apk` 一个。
            val sources = apkDir.listFiles { file ->
                file.isFile && file.name.startsWith("app-") && file.name.endsWith("-$buildMode.apk")
            }.orEmpty()

            if (sources.isEmpty()) {
                logger.lifecycle("brand${capitalized}Apk：$apkDir 下没有 app-*-$buildMode.apk，跳过")
            } else {
                sources.forEach { source ->
                    // 去掉前后缀，剩下的就是 ABI（普通构建为空串）。
                    val abi = source.name.removePrefix("app-").removeSuffix("-$buildMode.apk")
                    val abiSuffix = if (abi.isEmpty()) "" else "-$abi"
                    val branded = File(
                        apkDir,
                        "cloudcine-$appVersionName-b$appVersionCode$abiSuffix-android.apk",
                    )
                    source.copyTo(branded, overwrite = true)
                    logger.lifecycle("品牌产物：${branded.relativeTo(project.rootProject.projectDir)}")
                }
            }
        }
    }

    // 用 matching 而不是 named：AGP 到 afterEvaluate 之后才建 assembleRelease
    // 这些任务，配置期直接 named 会抛「task not found」。
    tasks.matching { it.name == "assemble$capitalized" }.configureEach {
        finalizedBy(brandApk)
    }
}
