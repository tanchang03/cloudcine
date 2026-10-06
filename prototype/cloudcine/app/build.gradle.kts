plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// ⛔ 刻意**不引 `androidx.media3:media3-ui`**：本机缓存里没有它（只有
// exoplayer / exoplayer-hls / common / datasource / decoder / extractor …），
// 引了就必须联网。而 OSD 是本工程自己用原生 View 画的 —— 那正是要验证的东西，
// 用 `PlayerView` 反而会把「原生 OSD 到底贵不贵」这个变量搅浑。
//
// ⛔ 也**不引 AppCompat / Material**：Activity 直接继承 `android.app.Activity`，
// 全部控件用 `android.widget.*`。少一层主题继承，也少两个要联网的依赖。
android {
    namespace = "com.cloudcine.tv"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.cloudcine.tv"
        // media3 1.5.1 的下限就是 21。
        minSdk = 21
        // 与云影主工程同档（目标机是 Android 9 / API 28）。
        targetSdk = 34
        versionCode = 1
        versionName = "1.0.0"
    }

    buildTypes {
        // 原型只出 debug：要的是「装上去能测」，不是发版。
        // debug 签名在本机 `~/.android/debug.keystore` 已有（云影构建时生成过），
        // 不指定 signingConfig 时 AGP 会自己用它。
        getByName("debug") {
            isMinifyEnabled = false
        }
    }

    testOptions {
        // ⛔ 必须开：`ParallelRangeReader` / `ParallelProbe` 里都调了
        //    `android.util.Log`，而 JVM 单测跑的是 android.jar 的**空壳实现**
        //    —— 默认行为是**抛异常**（`RuntimeException: Method i in
        //    android.util.Log not mocked`），每个用例都会挂。
        //    开这个开关后它们退化成「返回默认值」（`Log.i` 返回 0），
        //    于是纯逻辑单测能跑，而不必引 Robolectric。
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    // 版本必须与 `video_player_android-2.8.15/android/build.gradle:43` 的
    // `exoplayer_version` 一致 —— 那个版本是本机缓存里有的那一个。
    val media3 = "1.5.1"
    implementation("androidx.media3:media3-exoplayer:$media3")
    implementation("androidx.media3:media3-exoplayer-hls:$media3")

    // 二维码（扫码登录用）。**纯 Java jar**，不引任何 Android 组件。
    // ⛔ 不自己写 QR 编码器：掩码/纠错级别选错时**不报错**，只是「有些手机
    //    扫不出来」，在电视上排查一次要十分钟。
    implementation("com.google.zxing:core:3.5.3")

    // ── 单测 ──────────────────────────────────────────────────────────
    // 只测**纯逻辑**：`RangePlan`（分块边界，错了不崩、只静默少下几个字节）
    // 与 `ParallelRangeReader`（顺序 / 背压 / EOF / 重试续传，靠 JDK 自带的
    // `com.sun.net.httpserver` 起一个支持 Range 的本地服务）。
    //
    // ⛔ 本机 Gradle 缓存里**只有 `junit-bom`（一个 pom），没有 jar**
    //    ⇒ 首次构建**必须联网**拉 `junit:junit` + `hamcrest-core`（各几百 KB）。
    //    拉过一次就进缓存了，之后仍可 `--offline`。
    testImplementation("junit:junit:4.13.2")
}
