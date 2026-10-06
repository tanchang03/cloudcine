# 云影 Android 端

云影在 **Android / Android TV** 上的**正式实现** —— 原生 Kotlin，全程不含 Flutter。

包名 `com.cloudcine.tv`。

> 仓库根的 Flutter 工程（`lib/` `macos/` `windows/` `pubspec.yaml`）是**PC 端**
> （macOS / Windows）。两个工程互不引用、互不构建对方，可以并存安装。

---

## 一、为什么 Android 不用 Flutter

这不是口味问题，是 2026-10-06 在一台小米电视（Android 9，4 核 / 2.5 GB）上量出来的：

| 结论 | 读数 |
|---|---|
| 瓶颈**不在解码** | 真机 `解码丢帧=0`、`显示丢帧` 却在 21 秒里涨 44 |
| 瓶颈**不在网络总量** | 8 连接聚合稳态 8.03 MiB/s，而 4K 原画只需 3.67 MiB/s |
| 瓶颈**在数据通路** | 夸克对**单条连接**限速 ≈1 MiB/s；Flutter 侧的多连接中继跑在 **Dart 主 isolate**（= Android 主线程） |
| 主线程被占的代价 | 「按 MENU → 菜单上屏」Flutter 实测 **524 ms**，原生同口径 **0.3~8.3 ms** |

所以 Android 端必须原生：**8 连接并行取流 + 磁盘旁路预取 + 原生 View OSD**。
证据见 `docs/AndroidTV-4K-丢帧-夸克对标.md` 与 `docs/解决4k片源不卡顿解析方案.md`。

## 二、它长什么样

```
MainActivity      启动页：只看登录态，转去登录页或文件列表
  └ LoginActivity   扫码登录：二维码画在电视上，手机扫
      └ BrowseActivity  文件列表：遥控器 ↑↓ 选择、OK 进目录/起播、返回 上一层
          └ PlayerActivity 播放页：ExoPlayer + SurfaceView + 原生 OSD
```

`pan/` 包是网盘客户端：`PanHttp`（`HttpURLConnection`）、`PanApi`
（列目录 / 取链）、`QrLogin`（CAS 扫码）、`PanModels`、`CredStore`（凭证）、
`Bg`（后台线程池）。

### 播放页的几块关键拼图

| 文件 | 干什么 |
|---|---|
| `ParallelRangeReader` / `ParallelRangeDataSource` | 一条 HTTP Range 请求拆成 8 条连接并行取，绕开单连接限速 |
| `DiskPrefetcher` | **旁路**预取：不走 loader、不受 `SampleQueue` 约束，暂停时照样往磁盘灌 |
| `PrefetchCache` / `DiskCacheEvictor` / `DiskSpace` | 磁盘缓存单例 + 按可用空间自适应的 LRU 上限 |
| `SeekPlan` | 连续快进的累加 / 夹取 / 加速档位（纯函数，可单测） |
| `TvOsdView` | 原生 OSD（挂在 `android.R.id.content` 之上，与 Dart/主线程彻底解耦） |
| `StatsOverlay` / `ResourceProbe` | 调试浮层与 CPU / 内存 / 磁盘采样 |

## 三、构建

```bash
cd android
export JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home
export ANDROID_HOME=/Users/tandy/Library/Android/sdk

./gradlew :app:assembleDebug      # 自测用
./gradlew :app:assembleRelease    # 发版用（会自动带上单测）
```

或者用封装好的助手（顺带能装包 / 看日志）：

```bash
android/tool/adb_tv.sh build            # release + 单测
android/tool/adb_tv.sh build debug      # debug
android/tool/adb_tv.sh install          # 装到电视
android/tool/adb_tv.sh log              # 只看 CloudCine 这个 tag
```

产物：

| 路径 | 说明 |
|---|---|
| `app/build/outputs/apk/debug/app-debug.apk` | debug |
| `app/build/outputs/apk/release/app-release.apk` | release（AGP 认的原名，**不要改名**） |
| `app/build/outputs/apk/branded/cloudcine-<ver>-b<code>-android.apk` | 品牌化副本，与 PC 端交付物命名对齐 |

⛔ `JAVA_HOME` 必须是 **JDK 21**。用 Android Studio 自带的 JBR（25）时 Kotlin 编译会失败。

### 发布签名

取值顺序：`android/keystore.properties` → 环境变量 → **退回 debug 签名**。

```bash
cp keystore.properties.example keystore.properties   # 填进去，别提交
```

环境变量版本（CI 用）：`ANDROID_KEYSTORE_PATH` / `ANDROID_KEYSTORE_PASSWORD`
/ `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD`。

⚠️ 没配发布签名时也能出包，但**每个构建的签名都不同** —— 覆盖安装会报
「应用未安装」，且不能上架。这是有意保留的兜底（宁可出个能装的包，也不要
因为缺密钥直接构建失败）。

### 关于 `--offline`

**首次构建必须联网**，这几条不在本机 Gradle 缓存里：

* `androidx.annotation:annotation-jvm:1.6.0`（新版的 KMP 命名）
* `androidx.lifecycle:lifecycle-runtime:2.3.1`
* `com.google.zxing:core:3.5.3`（二维码）
* `junit:junit:4.13.2` + `hamcrest-core`（单测）

拉过一次之后就可以 `--offline` 了。

AGP 8.7.0 / Kotlin 2.1.0 / Gradle 8.10.2 / Media3 **1.5.1**。
⛔ 不要引 `androidx.media3:media3-ui`：`PlayerView` 自带一套控制栏，会和
`PlayerControlsView` 打架。⛔ 也不要引 AppCompat / Material / RecyclerView。

## 四、遥控器操作

| 页 | 键 | 行为 |
|---|---|---|
| 登录 | — | 手机扫码即可，电视上不用按键 |
| 列表 | ↑↓ | 选择 |
| 列表 | OK | 目录→进入；视频→起播 |
| 列表 | 返回 | 上一层（根目录时退出） |
| 列表 | 菜单 | 退出登录（清凭证回登录页） |
| 播放 | 菜单 / ↑ | 打开 OSD |
| 播放 | ↑↓ | 切行（画质 / 连接数 / 音轨 / 音效 / 字幕 / 倍速 / 调试） |
| 播放 | ←→ | 在选项里挪（撞到两端就停，跳过灰掉的） |
| 播放 | OK | 应用。**画质 / 音效**会收菜单（两者都要重建播放链路）；音轨/字幕/倍速/调试**留在菜单里** |
| 播放 | ←→（OSD 关着时） | 快退 / 快进。**按住会加速**（见下） |
| 播放 | 返回（OSD 开着） | 关 OSD |
| 播放 | 返回（控制栏亮着） | 收控制栏，回到全屏播放 |
| 播放 | 返回（已全屏） | 弹「要退出播放吗？」确认框 |
| 播放 | OK（OSD 关着时） | 播放 / 暂停 |

### 快进的三个约定（`SeekPlan`）

1. **拖动过程中不动播放进度** —— 按键只累加目标位置并立刻把进度条挪过去，
   **松手（`ACTION_UP`）后才真正 `seekTo`**。否则遥控器的自动重复（约 20 次/秒）
   会变成 seek 风暴：每次 `seekTo` 都要重建数据源、一次性分配 16 MiB，
   实测 2 秒内 28 次 seek 直接把 Java 堆打满 → `OutOfMemoryError`。
2. **前 2 秒不加速**，之后 `×2 / ×4 / ×8 / ×12` 逐级上升，2 小时的片子约 9 秒到底。
3. 兜底窗口 800 ms **必须大于遥控器的自动重复间隔**（有些遥控器 ~500 ms），
   否则按住时每按一下就提交一次。

## 五、左上角浮层怎么读

**默认关闭**（全局参数，存 `cloudcine_prefs`，跨片跨重启都记得）：
播放页 → 菜单 → 调试 → 开启。

每秒把同一行 `Log.i(TAG, "[统计] …")` 打出去，按键时打 `[按键] → 下一帧 x.x ms`。
tag 是 `CloudCine`：

```bash
android/tool/adb_tv.sh log          # 等价于 adb logcat -s CloudCine
```

⛔ **这不是调试残留，是必需通道**：有硬件视频层时 `screencap` 拿不到画面
（视频层不进 framebuffer 快照），播放中 `uiautomator dump` 也拿不到 UI
（永不 idle），logcat 是唯一的出口。

| 行 | 含义 |
|---|---|
| 片源 | 实际解码出的宽高 / 帧率 / 编码 |
| 解码器 | `c2.xxx` / `OMX.MS.*` = 硬件，`OMX.google` / `sw` = 软件。**这是关键证据** |
| 渲染 / 丢帧 / 已解码 | 来自 `VideoDecoderCounters`，与 PC 端 `[解码]` 同一口径 |
| 进程CPU | **单核口径**，括号里写明折合 N 核（4 核盒子要 400% 才叫满载） |
| 系统可用内存 | 用来对照「2.5 GB 机器 + 150 MB 进程」的内存压力 |
| 磁盘 本片 / 目录 | 本片在盘上覆盖了多少（几段、最远到哪）／整个缓存目录的占用与上限 |
| 预取 第 N 块 · 领先 | 旁路预取下到第几块、领先播放头多少字节 |
| UI fps / 最大帧间隔 | ⛔ **`UI fps` 是自续帧回调数出来的，恒≈刷新率，不是性能**（见下） |
| **按键→下一帧** | 从按键被吃掉到下一帧开始。**这才是「跟手」的直接读数** |

⛔⛔ **`UI fps` 不可用于比较**：`StatsOverlay.doFrame` 里
`choreographer.postFrameCallback(this)` **自己重新排自己**，于是每个 vsync
都被叫到，`uiFps` 恒≈刷新率（实测 100~101，**还没出第一帧时就已经报 90+**）。
唯一可比的是 **「按键→下一帧」** 和 SurfaceFlinger `--latency`。

## 六、音轨 / 音效 / 字幕

### 音轨 ≠ 音效（菜单里是**两行**，别合并）

| 行 | 是什么 | 数据来源 | 选项长什么样 |
|---|---|---|---|
| **音轨** | 片源里**封着的流** | `Player.Listener.onTracksChanged` | `韩语 · 立体声 · 杜比+` |
| **音效** | **播放端对输出的处理** | `AppPrefs.audioEffect` | `跟随片源` / `强制立体声` |

⛔ 2026-10-06 之前「音轨」那一行的标签写的是**「音效」**，于是菜单里出现
「音效 → 韩语 · 立体声 · 杜比+」这种自相矛盾的组合，用户的反馈是
「音效感觉像是音轨，找不到音轨在哪」。PC 端的 `player_audio_effect.dart`
里早就写着这条后果（「用户会以为『音效』里那一列就是能选的音轨」）——
两端是同一个坑，所以标签不许再写错。

⛔ 「立体声 / 杜比」**不是音效**，是**音轨自带的属性**（发布组压制时定的）。
真正能切的「音效」只有 `AudioEffect` 里那两档，实现见 `AudioEffect.kt`。

### 音轨 / 字幕

「音轨」「字幕」两行**直接来自 `Player.Listener.onTracksChanged`**，
不轮询、不缓存。判定有没有切成功的唯一办法是看日志：

* `轨道变化：` —— 每次轨道表变化打一份，条目后面带 `← 选中` 的那个才是当前生效的；
* `菜单内容：` —— 每次重绑菜单打一份，`[方括号]` 里的是光标所在项。

⛔ 换画质档会换掉整个 media source，字幕/音轨随之重来 —— `playQuality()` 里
`resetTrackOverrides()` 会把逐文件的轨道选择清掉（**不动**跨片的语言偏好）。

### 音效为什么切换时会黑一下

⛔ 音效是靠给 `AudioSink` 装一个 `ChannelMixingAudioProcessor` 实现的，而它的
**输出声道数在 `onConfigure()` 里就定死了**；`AudioSink` 又只在**建播放器时**
由 `DefaultRenderersFactory.buildAudioSink()` 造出来，media3 1.5.1 没有运行期
换它的接口 ⇒ **改音效只能重建播放器**（`applyAudioEffect()`）。

代价与「换档」同级：黑一下、从当前位置重新缓冲。位置、播放态、倍速，以及
**用户选过的音轨与字幕**（按标签，`restorePendingTracks()`）都会带过去。

⛔ 别为了「不黑一下」去改成 `setMediaItem()`：那**不一定**会重新配置 AudioSink
（解码器可能被复用，`onOutputFormatChanged` 就不回调），表现是「切了没反应」。
⛔ 也别去打开浮点输出（`enableFloatOutput`）：`ChannelMixingAudioProcessor`
只吃 16 bit 整数 PCM，浮点会让它当场抛异常 —— **整部片没声音**。

⚠️ **已知限制**：片源是 AC-3 / DTS 且设备走了直通（HDMI 功放）时，码流不过
解码器，「强制立体声」不起作用。不强行砍 `AudioCapabilities` 来逼解码 ——
那会让**没有 AC-3 解码器**的机器从「有声音」直接变成「没声音」。

## 七、量真帧率（别信浮层）

```bash
L="SurfaceView - com.cloudcine.tv/com.cloudcine.tv.PlayerActivity#0"
adb shell dumpsys SurfaceFlinger --list | grep cloudcine      # 找层名
adb shell "dumpsys SurfaceFlinger --latency '$L'"              # 首行=刷新周期ns，其后 128 帧三列时间戳
```

有效帧跨度反推 fps。实测：**25.2 fps、帧间隔中位 40.3ms、>100ms 卡顿 0 次**。

## 八、磁盘缓存

播放页的磁盘缓存**跨会话可复用**，这是「同一部片第二次打开不用重新缓冲」的前提。

⛔ 缓存键**不是 URL**。夸克直链是每次起播现取的带签名临时地址，按 URL 做键
等于「每次会话都是新片」。键的构成是 `quark:<fid>:<画质档 id>`：

* `fid` —— 来源文件 id（`EXTRA_FID`）；
* **画质档 id 不能省** —— 原画与各转码档是**完全不同的字节流**，只按 `fid`
  做键会把原画的字节喂给转码档的解析器，**解码出乱码而且不报错**。

实测：强杀重开后播同一部片，起播第一秒就读到 `磁盘 本片 1.54 GiB · 17 段`，
而本次预取器才写完 1 块（128 MiB）—— 多出来的全部来自上一个会话。

⚠️ 缓存上限按**可用空间**自适应（给系统留 2048 MiB 后取一半），所以别的 App
占盘时它会自动收缩，LRU 会淘汰旧片。这是有意的让路行为，不是 bug。

## 九、对照路径：直接给 URL（不经过登录/列表）

`PlayerActivity` 保留 `--es url` 这条入口，用来跑「PC 端中继 vs 直连」对比：

```bash
adb shell am start -n com.cloudcine.tv/.PlayerActivity \
  --es url "http://127.0.0.1:44151/s2"
```

可选参数：

| 参数 | 默认 | 用途 |
|---|---|---|
| `--es headers "Cookie: …\nUser-Agent: …"` | 空 | 直连 CDN 时才需要 |
| `--ei connectMs 30000` | 8000 | 验证「是不是超时卡掉了 ExoPlayer」 |
| `--ei readMs 30000` | 8000 | 同上 |

同理 `--es fid <fid>` 可以跳过列表页直接起播某一部片（测缓存键时很有用）。

## 十、踩过的坑（改代码前先看这里）

- ⛔ **XML 注释里不能出现 `--`**（写 `am start --es url` 会让 manifest 直接解析失败）。
- ⛔ **CAS 端点的业务码字段是 `status`，不是 `code`**（`{"status":50004001}`）。
  只读 `code` 会一律得到 `-1`，于是「还没扫码」这个**正常态**被当成异常。
  `PanResponse.bizCode` 兼容两套信封。
- ⛔ `batch/file/play/info` **必须带 `pr=ucpro&fr=pc`**，漏了回
  `HTTP 401 code=31001 require login [guest]`（看起来像没登录，其实是缺参数）。
- ⛔ **CDN 直链的 Cookie 规则是「要么不带，要么带全」**：
  带 `__puus`（新旧都行）→ 206；有 `__pus` 但**缺** `__puus` → **412**；
  完全不带 → 206。所以 `PlayerActivity.headersForCdn()` 在凭证里没有 `__puus` 时
  **主动不带 Cookie**。`PanApi.absorbCookies` 负责把每个响应里轮换的 `__puus` 回填。
- ⛔ `HttpURLConnection.useCaches = false` 不能省：每次返回的播放地址都带签名，
  命中缓存会拿到过期地址 —— 表现是「列目录正常、一播就 403」。
- ⛔ 解析 `video_list` 时**必须跳过 `audio_list`**：那条是纯音频流，没有分辨率字段，
  很容易被当成「原画」—— 而原画永远排最前，于是默认播一条**没有视频轨**的流：
  有声音、进度条在走、**没有画面、不报任何错**。
- ⛔ 目录判定**只认 `dir` 布尔位**，`file_type` 仅兜底（`0`=目录、`1`=文件，与直觉相反）。
- ⛔ `ListView` 用 `divider = null` 时**看不出选中项**，得自己给行加高亮背景，
  否则遥控器上「按了没反应」。
- ⛔ 原生 OSD 只回传**行下标**，而行数不固定（没有画质行、没有字幕行都会少一行）。
  回调一律按 `TvOsdView.Row.id` 分派，别 `when (row) { 0 -> … }`。
- ⛔ 速率**不能**取 `AnalyticsListener.onBandwidthEstimate`：那个回调一次传输
  结束才发一次，渐进式 MP4 一次 load 好几秒 ⇒ 界面上只剩「缓冲中」。改用
  `CountingDataSource` 在 `DataSource.read()` 上数字节。
- ⛔ **播放器不许写磁盘缓存**（`setCacheWriteDataSinkFactory(null)`）：两个写者
  撞上同一个 span 时 `SimpleCache.startFile` 抛的是 `IllegalStateException`，
  而 `CacheDataSource` 只吞 `IOException` ⇒ 直接崩。写入方只留 `DiskPrefetcher` 一个。
- ⛔ 预取器**绝不能在预取线程里读 `player.currentPosition`**
  （`IllegalStateException: Player is accessed on the wrong thread`，
  未捕获异常会带走整个进程，用户看到的是「无法打开影片」）。只能读主线程刷新的快照。
- ⛔ `bufferedPosition` **必须在 `seekTo` 之前读**：之后会被夹到 ≥ target，
  于是「命中内存缓冲」恒为真，磁盘缓存那支变成死代码。

## 十一、开发工具

| 位置 | 用途 |
|---|---|
| `android/tool/adb_tv.sh` | 本工程的连设备 / 装包 / 看日志 / 按遥控器键 / 截屏 |
| `../tool/quark_probe.py` | Mac 侧 API 探针：先把服务端真实响应形状拿下来，再照着写 Kotlin |

```bash
python ../tool/quark_probe.py login          # 出二维码（PNG + 终端字符画），扫码
python ../tool/quark_probe.py list [fid]     # 列目录
python ../tool/quark_probe.py play <fid>     # play/info + audioplay + 实测单连接带宽
```

真机迭代一轮要几分钟，这里改一行跑一次是秒级。
Cookie 落在 `../.quark_probe/cookie.json`。⛔ **该目录含真实凭据，已在
`.gitignore` 里，不要提交。**
