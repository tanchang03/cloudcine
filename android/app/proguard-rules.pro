# 云影 Android 端 —— R8 / ProGuard 规则
#
# ⛔ 目前 `isMinifyEnabled = false`，这份文件**还没被真正用上**。
#    放在这里是为了「打开混淆时不用现想规则」，以及把已经想到的坑记下来。
#
# 打开混淆前必须先跑一遍完整回归（真机）：
#   release 包 → 起播 4K 原画 → 切档 → 拖进度条 → 扫码登录 → 退出重进。
# 只验证「能编译」是不够的 —— 下面这些规则漏一条，表现都是**运行时才炸**
# 或者更糟：**不炸，但某个功能静默失效**。

# ── ExoPlayer / media3 ────────────────────────────────────────────────────
# media3 自带 consumer rules（`META-INF/proguard/`），但那是给「正常使用
# MediaItem + DefaultMediaSourceFactory」的场景。本工程有几处**按名字/反射**
# 的地方，必须显式保留：
#
#   1. `DefaultMediaSourceFactory` 会按 URI 后缀反射选 `Extractor`；
#   2. `MediaCodec` 解码器是按系统给的**组件名字符串**匹配的
#      （本机实测选中 `OMX.MS.DOLBY_VISION.DVHE.STN.Decoder`）；
#   3. `PlayerActivity` 里用 `Class.forName` 之外还有若干 `::class.java.name`
#      的日志分支。
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**

# ── zxing（扫码登录）───────────────────────────────────────────────────────
# 纯 Java 库，但内部有 `Class.forName` 找编码器实现。
-keep class com.google.zxing.** { *; }
-dontwarn com.google.zxing.**

# ── 本工程自己 ────────────────────────────────────────────────────────────
# Activity / View 由 manifest 与 XML 布局引用，R8 会自动保留。
# 但 `TvOsdView` 的回调是**按行下标**分派的（不是反射），无需额外规则。
# 这里只兜住「万一以后加了反射」：
-keepnames class com.cloudcine.tv.** { *; }

# ── 通用 ──────────────────────────────────────────────────────────────────
# 保留行号，崩溃栈才可读（配合 `retrace` 还原）。
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
