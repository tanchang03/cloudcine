import java.time.Duration
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// ⛔ 刻意**不引 `androidx.media3:media3-ui`**：OSD 是本工程自己用原生 View 画的 ——
// 用 `PlayerView` 会把它自带的那套控制栏一起带进来，与 `PlayerControlsView` 打架。
//
// ⛔ 也**不引 AppCompat / Material**：Activity 直接继承 `android.app.Activity`，
// 全部控件用 `android.widget.*`。少一层主题继承，也少两个依赖。
android {
    namespace = "com.cloudcine.tv"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        // 本工程的源文件（含单测里那份 `android.text.TextUtils` 替身）注释全是
        // 中文，这里显式钉住 UTF-8，别依赖构建机的平台默认编码。
        // ⛔ 用的是 AGP 的 `compileOptions.encoding`（会下发到所有 Java 编译任务，
        //    含 `compileDebugUnitTestJavaWithJavac`），不是
        //    `tasks.withType<JavaCompile>` —— 后者会被 AGP 覆盖掉。
        encoding = "UTF-8"
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.cloudcine.tv"
        // media3 1.5.1 的下限就是 21。
        minSdk = 21
        // 目标机是 Android 9 / API 28，按 34 编译。
        targetSdk = 34
        // ⚠️ 发版前**手动**改这两个值。`versionCode` 必须单调递增，
        //    否则已装设备会报「应用未安装」。
        versionCode = 1
        versionName = "1.0.0"
    }

    // ── 发布签名 ────────────────────────────────────────────────────────────
    // 取值顺序：`android/keystore.properties` → 环境变量 → 退回 debug 签名。
    // ⛔ 密钥与口令**绝不进版本库**（`keystore.properties` / `*.jks` 已在 .gitignore）。
    //    模板见同目录 `keystore.properties.example`。
    //
    // ⚠️ 没配发布签名时 `release` 会退回 **debug 签名**：能装、能自测，
    //    但**每个构建的签名都不同**，覆盖安装会报「应用未安装」，且不能上架。
    //    这是有意保留的兜底 —— 宁可出个能装的包，也不要因为缺密钥直接构建失败。
    val keystoreProps = Properties().apply {
        val f = rootProject.file("keystore.properties")
        if (f.exists()) f.inputStream().use { load(it) }
    }

    fun secret(key: String, env: String): String? =
        keystoreProps.getProperty(key)?.takeIf { it.isNotBlank() }
            ?: System.getenv(env)?.takeIf { it.isNotBlank() }

    val storePath = secret("storeFile", "ANDROID_KEYSTORE_PATH")
    val storePass = secret("storePassword", "ANDROID_KEYSTORE_PASSWORD")
    val alias = secret("keyAlias", "ANDROID_KEY_ALIAS")
    val keyPass = secret("keyPassword", "ANDROID_KEY_PASSWORD")
    val hasReleaseSigning =
        storePath != null && storePass != null && alias != null && keyPass != null

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(storePath!!)
                storePassword = storePass
                keyAlias = alias
                keyPassword = keyPass
            }
        }
    }

    buildTypes {
        getByName("debug") {
            isMinifyEnabled = false
        }
        getByName("release") {
            // ⛔ 混淆**暂时关着**，这是有意的取舍：
            //    `isMinifyEnabled = true` 会让 R8 重写 `androidx.media3` 的
            //    extractor / renderer 内部类名，而它们有一部分是**反射按名加载**的
            //    （`Extractor` 工厂、`MediaCodec` 组件名匹配）。规则写在
            //    `proguard-rules.pro` 里了，但**没有在真机上跑过完整播放回归** ——
            //    在验证过之前不要打开。打开前至少要跑：
            //      release 包 → 起播 4K 原画 → 切档 → 拖进度条 → 扫码登录。
            isMinifyEnabled = false
            isShrinkResources = false
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    lint {
        // media3 把一大半 API（`DataSource.Factory`、`CacheDataSource`、
        // `DefaultMediaSourceFactory` 的构造…）都标了 `@UnstableApi`。
        // 那个标记的意思是「**签名可能变**」，不是「别用」—— 本工程要能自定义
        // 数据源，绕不开它们。
        //
        // 所以这里只关这一条，并**不关** `abortOnError`：
        //   * media3 **钉在 1.5.1**，升级是显式动作；真升级时该看的是 CHANGELOG，
        //     不是这条 lint —— 留着它只会让 `lintDebug` 永远红着，进而没人看。
        //   * 其它 Error（最典型的是 `NewApi`：用了高于 minSdk 的 API）
        //     **仍然会让构建失败**。2026-10-06 就是靠它抓到
        //     `PanHttp` 里的 `contentLengthLong`（要 API 24，而 minSdk 是 21）。
        disable += "UnsafeOptInUsageError"
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

    // ── 挡掉 Flutter 工具误生成的插件注册表 ─────────────────────────────────
    //
    // ⛔ 仓库根还有一份 `pubspec.yaml`（PC 端），而 `android/` 这个名字正好是
    //    Flutter 约定的 Android 宿主位置。于是**任何** `flutter pub get` /
    //    `flutter test` 都会往 `app/src/main/java/io/flutter/plugins/` 写一份
    //    `GeneratedPluginRegistrant.java`，内容是 PC 端那套插件
    //    （`video_player_android` / `wakelock_plus` / `volume_controller` …）。
    //
    //    本工程是**原生 Kotlin 独立工程**，`settings.gradle.kts` 不加载 Flutter
    //    插件 ⇒ 那些类根本不存在 ⇒ `compileDebugJavaWithJavac` 直接 35 个
    //    「找不到符号」、整个 Android 构建挂掉（2026-10-07 踩过，见
    //    `android/.gitignore` 里同一件事的说明）。
    //
    //    排除而不是「构建前删掉」：Flutter 工具会在任意时刻重写它，删了还会
    //    回来；排除是**声明式**的，重生成多少次都不影响编译。真要删是人工的
    //    一次性清理，不该藏在构建脚本里。
    //
    // ⚠️ 走 `JavaCompile` 任务而不是 `sourceSets.main.java.filter.exclude`：
    //    后者在 Kotlin DSL 里与 `Iterable.filter` 撞名（AGP 的
    //    `AndroidSourceDirectorySet` 没有可用的 `filter` 属性），脚本编译不过。
    //    这里的 `exclude` 是 `SourceTask` 的，按**源根相对路径**匹配。
    tasks.withType<JavaCompile>().configureEach {
        exclude("io/flutter/plugins/GeneratedPluginRegistrant.java")
    }
}

// ── 发布产物另存一份品牌名 ──────────────────────────────────────────────────
// 与 PC 端的交付物命名对齐（`cloudcine-<ver>-macos.dmg` /
// `cloudcine-<ver>-windows-x64.msi`），下载页上一眼能看出是哪个平台的包。
//
// ⛔ 原文件 `app-release.apk` **必须保留**：AGP 自己、`lintVitalRelease`、
//    以及各家的安装/校验脚本默认认的都是它 —— 所以这里只**复制**不改名。
// ⛔ 品牌化产物**不能写回 `outputs/apk/release/`**：那个目录是
//    `createReleaseApkListingFileRedirect` 等任务的声明输出，往里写会触发
//    Gradle 的「隐式依赖」校验而直接构建失败（踩过）。所以另开一个目录。
val brandedApkName =
    "cloudcine-${android.defaultConfig.versionName}-b${android.defaultConfig.versionCode}-android.apk"
val brandReleaseApk = tasks.register<Copy>("brandReleaseApk") {
    val src = layout.buildDirectory.dir("outputs/apk/release")
    val dst = layout.buildDirectory.dir("outputs/apk/branded")
    from(src) {
        include("app-release.apk")
        rename { brandedApkName }
    }
    into(dst)
    doLast { logger.lifecycle("品牌化产物：${dst.get().asFile}/$brandedApkName") }
}
tasks.matching { it.name == "assembleRelease" }.configureEach { finalizedBy(brandReleaseApk) }

// ── 单测兜底超时：把「永远挂着」变成「明确失败」 ──────────────────────────
//
// ⛔ 起因（2026-10-07 实测）：JVM 单测跑的是 AGP 生成的 `mockable-android-*.jar`
//    （全是空壳），而工程开了 `unitTests.isReturnDefaultValues = true`，
//    于是框架方法**静默返回默认值**。Media3 的
//    `WebvttParser.parse` 里有一句
//
//        while (!TextUtils.isEmpty(parsableWebvttData.readLine())) { ... }
//
//    `isEmpty` 恒返回 `false` ⇒ `while (true)`，`readLine()` 读到头后一直返回
//    `null` ⇒ **死循环**。实测 `ExternalSubtitleTest.VTT 能解析` 单条用例
//    371 秒里烧了 367 秒 CPU，整条 `testDebugUnitTest` 永远不返回，
//    `assembleRelease`（依赖单测）跟着挂死，最后是被系统 SIGKILL 掉的。
//
//    真正的修法是给 `TextUtils` 补真实现（见
//    `src/test/java/android/text/TextUtils.java`）；这个上限是**第二道保险** ——
//    下一个「空壳返回默认值」引发死循环时，构建会红着退出并指向测试报告，
//    而不是安静地挂在那儿让人以为「是不是卡死了」。
//
//    正常全套单测 < 1 分钟，5 分钟是宽松上限。
tasks.withType<Test>().configureEach {
    // ⛔ 必须写 `Duration.ofMinutes` 而**不是** `java.time.Duration.ofMinutes`：
    //    Kotlin DSL 的脚本作用域里 `java` 是 Gradle 的 Java 插件扩展，
    //    `java.time` 会被解析成它的 `time` 属性 ⇒ `Unresolved reference: time`。
    timeout.set(Duration.ofMinutes(5))
}

dependencies {
    // ⛔ 版本必须与仓库根 Flutter 侧 `packages/video_player_android/android/build.gradle`
    //    的 `exoplayer_version` 保持一致 —— 两台机器上装的是同一套 media3，
    //    行为（尤其是硬解 / DV 的选路）才可比。
    val media3 = "1.5.1"
    implementation("androidx.media3:media3-exoplayer:$media3")
    implementation("androidx.media3:media3-exoplayer-hls:$media3")

    // 二维码（扫码登录用）。**纯 Java jar**，不引任何 Android 组件。
    // ⛔ 不自己写 QR 编码器：掩码/纠错级别选错时**不报错**，只是「有些手机
    //    扫不出来」，在电视上排查一次要十分钟。
    implementation("com.google.zxing:core:3.5.3")

    // ── 单测 ──────────────────────────────────────────────────────────
    // 只测**纯逻辑**：`SeekPlan`（连续快进的累加 / 夹取 / 加速档位）、
    // `RangePlan`（分块边界，错了不崩、只静默少下几个字节）、
    // `DiskCachePlan` / `DiskSpace` / `BufferPlan`（预算与区间换算）、
    // 以及 `ParallelRangeReader`（顺序 / 背压 / EOF / 重试续传，靠 JDK 自带的
    // `com.sun.net.httpserver` 起一个支持 Range 的本地服务）。
    //
    // ⛔ 本机 Gradle 缓存里**只有 `junit-bom`（一个 pom），没有 jar**
    //    ⇒ 首次构建**必须联网**拉 `junit:junit` + `hamcrest-core`（各几百 KB）。
    //    拉过一次就进缓存了，之后仍可 `--offline`。
    testImplementation("junit:junit:4.13.2")
}
