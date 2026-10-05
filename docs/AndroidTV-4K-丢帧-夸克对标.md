# Android TV 4K 丢帧：夸克 TV 播放器内核逆向对标与解决方案

> 对象：`kuakewangpan/kkwptvb_2.9.1702_dangbei.apk`（夸克网盘 TV 版 2.9.1702，当贝渠道）
> 方法：`unzip` + `jadx 1.5.1` 全量反编译（`kuakewangpan/jadx_out/`）+ 对本仓 `lib/` 与 pub cache 的交叉核对
> 结论日期：2026-10-04
>
> 📌 **本文件是「记录 / 证据」；要落地看的方案在
> [`解决4k片源不卡顿解析方案.md`](./解决4k片源不卡顿解析方案.md)（2026-10-05 起草）。**
> 那份文档基于对 `fvp 0.39.0` / `video_player 2.10.1` 上游源码的复查，
> **修正了本文件 §4 P1 与 §4.5 的三处判断**（见各节的行内提示）。

---

## 0. 一句话结论

**不是解码能力不够，是解码出来的帧多绕了一趟；而这一趟是「起播顺序」逼出来的，不是 mpv 主动选的。**

夸克的 `MediaCodec` 解码后**直接写到 SurfaceView 的显示层**，一次拷贝都没有。
云影的 mpv 在 Android 上却落到了 **`mediacodec-copy`** —— 硬解到 CPU 内存，再 memcpy 进 mpv 的帧、再上传成纹理，最后还要交给 Flutter 合成一次。
4K 一帧 YUV 约 12 MB，24fps 就是 ~300 MB/s 的拷贝 **加上** ~300 MB/s 的上传，电视 SoC 撑不住 41ms 的帧预算；1080P 只有 1/4 像素，所以顺。

**为什么 mpv 会退到拷贝档**（源码级机制，见 §3.5）：不是它拒绝 `mediacodec`，是我们**在解码器定型之前就 `loadfile`** —— 那一刻 VO 还没有 Android surface（`vo=null`），`mediacodec` 直出配不上，逗号列表于是**静默**退回 `mediacodec-copy`，而且这个选择**跟着整条流**，之后 Surface 到位也不会重解析。

真机三条互相独立的证据：

- **`解码丢帧` 恒为 0**、`VO延迟帧=0` —— 解码跟得上，不是解码能力问题
- **`显示丢帧` 随分辨率缩放**：4K 原画 34%~44%/21s，810p 转码 **1.3%** —— 是"像素量 × 拷贝次数"的线性代价
- 同一时段 `[中继]` 零告警 —— 网络也不是瓶颈
- CPU：app ~254% + `media.codec` ~98% + SF 14.5% ≈ **367% / 400% 预算**（`MemTotal 2.6G`、`SwapTotal 0`、`kswapd0` 在跑）—— SoC 已近饱和

---

## 1. 夸克 TV 的播放器内核：逆向结果

### 1.1 三套播放栈并存

| 层 | 包 / 类 | 说明 |
|---|---|---|
| 主内核 | `com.UCMobile.Apollo.*` | UC 浏览器的 **ExoPlayer 分支**（`ApolloSDK` / `MediaPlayer` / `MediaCodec` / `MediaFormat` / `DecoderInfo` / `VideoView`），非原生 ExoPlayer 包名的改写版 |
| 第二内核 | `eskit.sdk.support.player.ijk.*` | 当贝 ESKit 的 **ijkplayer 分支**（`IjkVideoView` / `IjkMediaPlayer` / `IjkMediaCodecInfo`） |
| 原生解码 | **插件化下载** | APK 的 `lib/` 里**只有** `libc++_shared`、`libmarsxlog`、`librsjni`、`libxcrash_eskit`、`liblamemp3` —— **没有任何 ffmpeg / ijk / player 的 `.so`** |

关键旁证：`com/didi/virtualapk/sdk/internal/PluginContentResolver`（滴滴 VirtualAPK 插件化框架）+ `downloadPlugin` + `READER_PLUGIN_SO_*`，而 dex 里出现 `libextplayer.so`、`libvplayer.so`、`libu3player.so`、`libffmpeg.so`、`libapolloffmpeg.so` 等**只在运行时下载**的名字。

> 也就是说：**夸克自己的解码器是动态下发的，但它用的硬件解码通路是 Android 系统自带的 MediaCodec** —— 这条不需要自己带 `.so`。

### 1.2 硬解是怎么开的（核心证据）

`eskit/sdk/support/player/ijk/player/IjkVideoView.java:959-972`，方法 `setFastCommonOptions()`：

```java
ijkMediaPlayer.setOption(4, "mediacodec", 1L);                       // 开硬解
ijkMediaPlayer.setOption(4, "mediacodec-all-videos", 1L);            // 所有视频都走 MediaCodec
ijkMediaPlayer.setOption(4, "mediacodec_mpeg4", 1L);
ijkMediaPlayer.setOption(4, "mediacodec-auto-rotate", 0L);
ijkMediaPlayer.setOption(4, "mediacodec-handle-resolution-change", 0L);
ijkMediaPlayer.setOption(4, "framedrop", 1L);                        // 允许丢帧保音画同步
ijkMediaPlayer.setOption(2, "skip_loop_filter", 48L);                // 跳过环路滤波（软解省算力）
ijkMediaPlayer.setOption(1, "probesize", 10240L);
ijkMediaPlayer.setOption(1, "fflags", "fastseek");
ijkMediaPlayer.setOption(4, "max-buffer-size", 1048576L);
```

`mediacodec = 1` + `mediacodec-all-videos = 1` 是 ijkplayer 的**零拷贝**组合：MediaCodec 输出到 `Surface`，不再回读。

### 1.3 画面落在哪里（最关键的一条）

`com/UCMobile/Apollo/VideoView.java:23`

```java
public class VideoView extends SurfaceView implements MediaController.MediaPlayerControl
```

以及 `MediaCodec.java` 的全部 native 方法签名：

```java
private final native void native_configure(String[], Object[], Surface surface, Object, int);
private final native void native_setOutputSurface(Surface surface);
private final native void native_releaseOutputBuffer(int i, boolean z);
```

**解码器持有 `Surface`，输出缓冲直接释放到 surface。全程不经过 Java / CPU 内存。**

### 1.4 它对"硬解还是软解"是有显式模型的

`eskit/.../manager/decode/a.java`：

```java
IJK(0, "硬解IJK"), EXO(1, "软解EXO"), HARDWARE(2, "硬解"), IJK_SOFT(3, "软解IJK");
```

`eskit/.../manager/definition/a.java`：

```java
UNKNOWN(-1), SD(0,"标清"), HD(1,"高清"), FULL_HD(2,"超清720"),
ORIGINAL(3,"原画"), BLUERAY(4,"蓝光"), FOURK(5,"4K");
```

`eskit/.../ijk/player/third/c.java:329` 会在 `onPrepared` 里打日志：

```java
Log.d("ApolloMediaPlayer", "onPrepared 视频解码类型 1:硬解, 0:软解, -1:未知。 结果："
      + this.b.getOption("ro.instance.decode_video_use_mediacodec"));
```

即：**夸克把"这次到底硬解了没有"当成一个可观测、可上报的一等属性**，而不是碰运气。

---

## 2. 与云影的对比

### 2.1 数据路径

```
【夸克】
  MediaCodec ──直写──▶ SurfaceView（独立硬件显示层）
                          └─▶ SurfaceFlinger 直接合成上屏
  拷贝次数：0

【云影 · 现在】
  MediaCodec ──拷回 CPU──▶ mpv 帧缓冲 ──上传──▶ GL 纹理 ──渲染──▶ Flutter SurfaceProducer 纹理
                                                                      └─▶ Flutter/Impeller 再合成一次上屏
  拷贝次数：2（一读一写）+ 1 次全屏合成
```

### 2.2 逐项对照

| 维度 | 夸克 TV | 云影（Android TV） | 差距 |
|---|---|---|---|
| 解码 | MediaCodec（硬） | MediaCodec（硬） | 一致 |
| 输出方式 | **零拷贝，直出 Surface** | `mediacodec-copy`，拷回 CPU | ⚠️ **主要瓶颈** |
| 显示层 | **SurfaceView**（独立硬件层，绕过应用窗口） | **Flutter 外部纹理**（`TextureRegistry.createSurfaceProducer`） | ⚠️ 多一次全屏合成 |
| 硬解档位 | 显式 `mediacodec=1` + `all-videos=1` | `media_kit` 出厂默认 `auto-safe` → `mediacodec-copy` | ⚠️ 默认值就是拷贝档 |
| 可观测性 | `decode_video_use_mediacodec` 上报 | 需自己读 `hwdec-current` | 已补（见 §4） |
| 插件化 | 播放器 `.so` 运行时下载 | 静态打包 libmpv / libmdk | 无关 |

### 2.3 为什么 `auto-safe` 会落到拷贝档

mpv 的 hwdec 分「安全 / 不安全」两档：

- `mediacodec`（直出 Surface）= **不安全**档（强制 RGB 转换、10bit 降 8bit、非标准色彩空间表现不明）
- `mediacodec-copy`（拷回内存）= **安全**档

`auto-safe` **只从安全列表里挑**，而 `mediacodec` / `mediacodec-copy` 都不在 mpv 的通用安全白名单（d3d11va / videotoolbox / vaapi / nvdec / drm / vulkan）里，于是 Android 上 `auto-safe` 必然落到 `mediacodec-copy`。

而 `media_kit_video` 的出厂默认正是这个值 —— `android_video_controller/real.dart:143`：

```dart
return hw ? 'auto-safe' : 'no';   // getDefaultHwdec()
```

**也就是说：不显式改，云影在 Android 上永远是拷贝档。**

---

## 3. 为什么是 4K 才掉帧

- 4K 4:2:0 一帧 = 3840×2160×1.5 ≈ **12.4 MB**
- 24 fps → 拷贝 **~298 MB/s**，再上传 **~298 MB/s**，合计约 **600 MB/s** 的内存带宽
- 一帧预算 **41.7 ms**，其中纯拷贝+上传就吃掉十几毫秒，还要留给 GL 渲染、Flutter 合成、UI 栅格化
- 1080P 像素量是 1/4（~75 MB/s + 75 MB/s）→ 完全在预算内 → **顺**
- 夸克同样 4K 走零拷贝 → 省掉这两个 300 MB/s → **也顺**

这与真机读数一致：`解码丢帧 = 0`（解码没压力）、`显示丢帧` 线性上涨（显示段掉队）。

### 3.5 真正的机制：是**顺序竞态**，不是 mpv 拒绝 `mediacodec`

> 这一节是本轮源码级定位的结论，它**推翻**了早先"mpv 试了没配上"的猜测。

三条源码事实，缺一不可（`media_kit_video` 1.3.1）：

1. `video_controller/video_controller.dart` —— 构造 `VideoController` 时把
   `AndroidVideoController.create()` 塞进 `WidgetsBinding.instance.addPostFrameCallback`，
   它跑在**首帧之后**。
2. `android_video_controller/real.dart:191-205` —— `create()` 在**同一批** `setProperty`
   里写 `'vo': 'null'` **和** `'hwdec'`（注释：必须先 `vo=null` 才不 SIGSEGV，`--wid`
   必须在 `vo=gpu` 之前赋）。
3. `android_video_controller/real.dart:59-65` `widListener()` —— Surface 到位后才重建
   vo（`vo=null` → `android-surface-size` → `wid` → `vo=voValue`），**从不重设 `hwdec`**。

于是：原来在构造函数之后**立刻** `open()`，`loadfile` 几乎总抢在 `create()` 前面
→ 解码器在「`vo=null`、没有 surface」的状态下定型 → 逗号列表静默退到 `mediacodec-copy`
→ 这个选择**跟着整条流**。

另一条佐证（与 hwdec 无关却很硬）：`widListener()` 结尾那句 `await player.seek(Duration.zero)`
会把起播位置冲成 0，日志里 `起播位置没生效（现在 0s，应为 434s）→ 补发 seek` 就是它干的 ——
**证明 Surface 确实晚于 `loadfile` 才挂上。**

---

## 4. 解决方案（按优先级）

### ⛔ 先看这条：P0 已被真机证伪（10-04 19:49，`cloudcine-log-android-20261004-195015.txt`）

改动全部到位、参数确认送达，mpv 依然只肯给 `mediacodec-copy`：

```
19:49:20.467 [缓冲] hwdec=mediacodec,auto-safe            ← 值下发到位
19:49:23.080 [硬解] 等视频 Surface 超时（2000ms）          ← rect 一直是 null
19:49:26.607 [硬解] 仍是拷贝档（hwdec-current=mediacodec-copy）—— 重建解码器再试一次
19:49:32.901 [硬解] 重建后 hwdec-current=mediacodec-copy（仍在拷贝档：这条路走不通）
19:49:47.141 [解码] 解码器=mediacodec-copy 解码丢帧=0 显示丢帧=108
```

结论：**在这台设备 + 这个 libmpv 构建上，`mediacodec`（零拷贝）拿不到**，再调 mpv 参数是浪费时间。P0 到此为止，别再重试第三次。

#### 同一份日志里最有价值的一条对照

| 片源 | 显示丢帧（每 21s 一拍） | 观感 |
|---|---|---|
| 3840×2160 原画 | 0 → **141** → 2 → **111** → **341** | 卡 |
| 1440×810 转码（`super` 档） | 0 → 0 → **7** | **顺** |

同一台设备、同一时段、同一条中继链路 —— 唯一的变量是像素量。**这不是猜测，是这台机器给出的答案：它扛得住 810p，扛不住 2160p。**

（`实测帧率=25.000000` 与标称帧率一致，`VO延迟帧=0` —— 排除了「帧率不匹配导致的 judder」，丢的是真帧。）

#### 还有一个日志盲区要补

我们记的 `vo=gpu` 是**配置值**（media_kit `configuration.vo ?? 'gpu'`），不是 mpv 实际在用的 VO。media_kit 在 `create()` 时写的是 **`vo: 'null'`**（它自己的注释：`--wid must be assigned before vo=gpu is set`），之后 `widListener` 才在 `wid != 0` 时切成 `gpu`。所以「Surface 到底挂上没有」我们**一次都没验证过** —— 下次取证第一件事是读 **`current-vo`**（不是 `vo`）和 `wid`。

---

### P0 · 把硬解档位从"拷贝"换成"直出" —— ⛔ 已证伪，保留作档案

`lib/core/utils/player_buffer_config.dart`：

```dart
static const String tvHwdec = 'mediacodec,auto-safe';
```

逗号列表带自动回退：先试零拷贝直出，配不上再退回拷贝档 —— **最坏情况等于没改**（⛔ 别写成光秃秃的 `mediacodec`，那样失败只剩软解）。

但**光改这个值不够** —— 真正的修复是 `open()` 里的三步，**顺序本身就是修复**：

```dart
await _awaitVideoSurface();              // 等 videoController.rect != null（+120ms settle）
await _reapplyHwdec();                   // 读回 hwdec 再写一遍，让它成为 mpv 最后一次写
await _player.open(...);                 // 这时 loadfile 建解码器，零拷贝才配得上
unawaited(_verifyZeroCopyHwdec());       // 兜底 + 取证（起播 20s 内、只动一次）
```

配套的四个要点：

1. **两处必须同值**。`VideoControllerConfiguration.hwdec` 与 `PlayerBufferConfig.apply` 都会给 mpv 写 `hwdec`，只改一处会被另一处覆盖。
2. **Surface 判据用 `rect`**。Java 侧每次表面变化发 `VideoOutput.Resize`，Dart 侧在同一个回调里同时写 `rect`/`id`/`wid`；`wid` 是私有的，而 `rect` 经 `VideoController.rect` **公开** —— 所以「`rect != null`」就是「Surface 已挂上」，不必 import media_kit 的内部路径。
3. **兜底的 kick 必须"改一次再改回来"**。mpv 只在 `hwdec` **变化**时重建解码器，写同值是空操作；所以先写过渡值 `auto-safe`、400ms 后再写回目标值。⛔ 过渡值**不能是 `no`**（会把 4K 拽到软解）。判据抽在纯函数 `MediaKitPlaybackEngine.shouldKickHwdec()`，有单测。
4. **必须读回来验证**。起播后读 `hwdec-current`：
   - `mediacodec` → ✅ 零拷贝生效
   - `mediacodec-copy` → ❌ 仍在拷贝档（判据：名字含 `copy`；⛔ **空串不算**，那只是解码器还没起来）
   - `no` / 空 → 退到软解了

> ⚠️ 代价（mpv 手册明说）：`mediacodec` 是不安全档，**强制 RGB 转换**、**10bit 降到 8bit**、非标准色彩空间表现不明。当前这台是 1080p SDR 面板，不构成损失；将来上 HDR 屏要回来重看这一条。

### P1 · 换渲染面：4K 原画走 fvp(libmdk) + `VideoViewType.platformView`

这是**与夸克完全同构**的做法，而且依赖已经在产物里。

`fvp-0.39.0/android/.../FvpVideoView.java` 的类注释直接就是为这个场景写的：

```java
/**
 * SurfaceView video output, used when the app requests VideoViewType.platformView.
 *
 * Unlike the Texture path (ImageReader buffers composited inside the app window),
 * a SurfaceView gets its own display layer. ... It is also the only surface type
 * that can display tunneled (sideband) playback.
 */
```

并且 libmdk 在 Android 上的默认解码器列表（`video_player_mdk.dart:210`）是：

```dart
'android': ['AMediaCodec', 'FFmpeg', 'dav1d'],   // AMediaCodec 排第一
```

`libfvp.so` 里的解码器名也印证：`AMediaCodec:dv=1:image=0:surface=` —— **`surface=` 即直出 Surface**。

落地要点：

- `main.dart` 的 `fvp.registerWith(options: {'platforms': [...]})` 目前**只有 `macos`**，要加 `android`。
- `PlaybackEngineRouter` 现在只在 DV P5 时换内核；扩一条规则：**Android TV 上 4K/高码率原画也换到 fvp**。
- 创建播放器时用 `VideoViewType.platformView`（`MdkVideoPlayerPlatform` 只在 `Platform.isAndroid` 时尊重它）。
- `PlaybackSurface` 已经按引擎分派（`FvpPlaybackEngine` → `vp.VideoPlayer`）。
  ⛔ **但这一句后来被证伪了**（2026-10-05 复查）：对 `textureView` 成立，
  对 `platformView` **不成立** —— 那条分支不能再套 `AspectRatio`、必须保留
  `controller == null` 守卫、还必须与高频重建隔离。详见
  [`解决4k片源不卡顿解析方案.md`](./解决4k片源不卡顿解析方案.md) §4.1。
- ⚠️ fvp 的代价要提前认：音效灰掉（mdk 无 Avfilter 对等物）、字幕由 mdk/libass 自绘不走 Flutter 样式、`VideoControlsBuilder` 无效、`BoxFit` 只有 `contain`。这些都已在 `PlaybackSurface` / `EngineCapabilities` 里建模，UI 会置灰而不是静默失效。

### P2 · 把渲染目标钳到面板分辨率（1080p 屏上尤其值）

现在 mpv 是按**视频原始分辨率**渲染（`VideoOutputManager.SetSurfaceSize` 传的是视频宽高），在 1080p 面板上渲染 4K 是纯浪费。

fvp 提供 `maxWidth` / `maxHeight`（`registerVideoPlayerPlatformsWith` 的 options），`MdkVideoPlayerPlatform._create` 在 `platformView` 路径下会做等比钳制。给 1080p 面板传 `1920×1080` 即可 —— **scale 交给硬件合成器在 scanout 时做，与夸克 SurfaceView 那条路完全一样。**

（`_maxWidth` 的注释还说得很实在：full 4K RGBA 会把弱 GPU 上的 SurfaceFlinger 推进 GPU 合成。）

### P3 · tunnel（隧道）模式

`FvpVideoView` / `nativeSetSurface(..., tunnel)` 支持。**这是唯一能显示 sideband（旁路）播放的 surface 类型** —— 解码器输出直接进硬件合成器，连 GL 渲染都省掉。适合极弱 SoC 的 4K 原画兜底。

⚠️ 但 tunnel 有硬约束（无法截帧、无法做 OSD/字幕叠加、seek 行为不同），**只适合作为"原画实在扛不住"的开关**，不要当默认。

### 明确不要做的（反模式）

| 想法 | 为什么不解决问题 |
|---|---|
| 继续调大 `tvBufferSize` | 数据早就到位了（`解码丢帧=0`、中继零告警），瓶颈在解码后的搬运 |
| 改 `video-sync` | `audio` 是对的；`display-resample` 是给固定刷新率桌面显示器用的，TV 播 24p 反而抖 |
| 照搬 `skip_loop_filter=48` | 那是**软解**省算力的招，走硬解时完全无效 |
| 写死 `hwdec=mediacodec` | 配不上就只剩软解，4K 直接不能看 |
| 指望换 mpv 参数修好 DV P5 | macOS 上 `gpu-next` 架构不可达（`libmpv` 零命中），那是另一条路（fvp）的事 |

---

## 4.5 ⛔ 试过并且**已回退**：Android TV 高分辨率走 fvp（libmdk）+ SurfaceView

按「对标夸克」实施过（2026-10-04），**两轮真机都失败，代码已全部撤掉**。
留在这里是因为它是一次有完整证据的否定结论 —— 下次别再走一遍。

### 第一轮：只加 SurfaceView（`viewType: platformView`）

改 `main.dart` 的 `platforms` 加上 `android`、TV 上装配 fvp 引擎工厂 +
`highResolutionEngine: tv`、路由加第二条触发线（阈值 1440p）、引擎指定
`viewType: VideoViewType.platformView`。

**结果**：用户报「比之前版本卡的更厉害了，音画都不同步了」。
（`cloudcine-log-android-20261004-205646.txt`）

### 第二轮：再加零拷贝（`tunnel: true`）

读 fvp 源码后判断「`platformView` 只决定出到 SurfaceView 还是纹理，
mdk 仍要跑一遍 GL 渲染器」→ 补上 `tunnel: true`（`AMediaCodec` 直出，
无 GL 渲染器、无 GPU 拷贝）。

**结果**：用户报「**4k 看不到画面了，只有声音**」。
（`cloudcine-log-android-20261004-213519.txt`）

### 为什么回退 —— 三条证据

1. **解码在跑，屏上没东西。** 中继读取器一路推进（2 MB → 24 MB → 62 MB），
   `[资源]` 显示进程 CPU **225% → 326%**（单核口径，4 核折合 56% → 82%），
   说明 mdk 确实在解码；但用户看不到任何画面。
2. **进程被原生崩溃打挂。** `logcat -b crash` 里同一时段有两处：
   - `libmdk.so` 的 `strlen → __vfprintf → vsnprintf`（mdk 自己的工作线程
     `Thread-7`）—— 崩溃点在**日志格式化**里，不是解码逻辑。
   - 反复出现的 `SurfaceTextureWrapper.release → SurfaceTexture_release
     → ConsumerBase::onLastStrongRef`（`FinalizerDaemon`）。这是 Flutter
     引擎在 `SurfaceProducer` 被释放后**二次释放**，**换内核就会触发，
     与 `viewType` 无关** —— 也就是说只要在 Android 上换内核就有这个风险。
3. **mpv 那条路的「零拷贝」在 media_kit 里做不到。** 读
   `media_kit_video-1.3.1/android/.../VideoOutput.java` 确认：它**写死**
   `textureRegistry.createSurfaceProducer()`，永远是 Flutter 纹理，没有
   `platformView` / `SurfaceView` 选项。所以 mpv 只能 `mediacodec-copy`
   （解到 CPU 再拷回），这是**结构性**的，不是参数问题。

### 面板事实（顺带记下，以后判断「要不要 4K」用得上）

`ro.boot.mi.panel_resolution=3840x2160`（65 寸 4K 面板），但 Android 的显示层
**只有 1920×1080**（`dumpsys display`：`real 1920 x 1080`，唯一 mode 也是
1920×1080@60）。所以：
- 应用内渲染（纹理 / Flutter 合成）**最高只有 1080p**，由电视自己倍线到 4K；
- 只有 **SurfaceView**（独立显示层 + `setFixedSize`）才有机会真正 4K 扫描输出
  —— 这正是当初想走 fvp 的理由，也是这条路唯一还值得再看一眼的地方。

### 下次要查的第一个假设（**未证实**）

fvp 的 tunnel 分支**显式跳过** `maxWidth/maxHeight` 钳制
（`lib/src/video_player_mdk.dart:392` 原文 *`if (_tunnel ?? false) { /* native size,
no clamp */ }`* —— ⚠️ **钳制的开关在 Dart 侧，不在 native**；`fvp_plugin.cpp` 里的
`if (tunnel)` 是选 `setDecoders(...surface=...)` 还是 `updateNativeSurface(...)`，
与钳制无关）。于是 `FvpVideoView` 的 `setFixedSize` 拿到的是**视频原生**尺寸
3840×2160，而 Android 显示层只有 1920×1080。若 SurfaceFlinger 拒绝合成一个比显示层
还大的 SurfaceView 层，就会表现成「有声音没画面」。**这条没有验证过**，
下次先试 `platformView` + **不开** tunnel + `maxWidth: 1920, maxHeight: 1080`。

📌 这一步的**具体改法、判据、以及「第 1 轮为什么更卡」的源码级机制**（不开 tunnel
时 `w,h` 保持原生 4K → GL 渲染器在 4K 上渲染），见
[`解决4k片源不卡顿解析方案.md`](./解决4k片源不卡顿解析方案.md) §1.2 / §3 阶段 1。

### 回退后 4K 怎么办

4K 回到 mpv：**有画面，但 `mediacodec-copy` 的卡顿仍在**（每 21 秒丢
100~340 帧）。当前可选的路只有两条，都是取舍：

- 用夸克的 **`super`(810p) 转码档**（同机实测只丢 0~7 帧，流畅，但降画质）；
- 接受 4K 原画的卡顿。

真要走通 4K 直出，得先解决上面那个「SurfaceView 层 > 显示层」的假设，
或者给 fvp / media_kit 打补丁。

---

## 5. 怎么确认改好了

真机基线（改之前，`193049.txt`）—— 拿去和改之后比：

| 采样 | 区间 | 显示丢帧增量 | 速率 |
|---|---|---|---|
| 4K 原画 | 6s→21s | 0→141 | **37.6%** |
| 4K 原画 | 21s→42s | 0→179 | **34.1%** |
| 4K 原画 | 42s→63s | 2→111 | **20.8%** |
| 4K 原画 | 63s→84s | 111→341 | **43.8%** |
| 810p 转码 | 21s→42s | 0→7 | **1.3%** |

每一拍 `解码丢帧=0`、`VO延迟帧=0`。源 3840×2160@25.000fps；面板 **1920×1080@60Hz 且只支持这一个模式**（`supportedModes` 只有 `{1920x1080, 60.000004}`）→ OS 刷新率切换这条路不存在。

验收只看三个数：

1. **`hwdec-current`** = `mediacodec`（不是 `mediacodec-copy`）—— 零拷贝生效
2. **`frame-drop-count`（显示丢帧）** 不再随分辨率缩放 —— 应向 810p 那个 1.3% 靠拢
3. **CPU**：`media.codec` + app 合计应从 ~367% 明显下降

⚠️ 跨会话比 `显示丢帧` 之前，**先确认两次起播条件一致**（冷启动 / 换集 / 双 seek 都会污染这个数）。原画 4K 最近两次是 0~4 帧（旧版本同片源 14→58），但**解码器没变**，所以那一拍不能算"改好了"。

⛔ **若重建后 `hwdec-current` 仍是 `-copy`**，说明 mpv 的 `mediacodec` 在 media_kit 那块 Surface 上确实绑不上 —— **那时才轮到下面的 P1（fvp/libmdk）**，别继续在 mpv 参数上试。

诊断页里已有的「硬解」分类日志（`下发 / vo / video-sync / 面板帧率`）就是为这个准备的。⚠️ `面板帧率=?` 是因为 mpv **没有 `display-fps`**（media_kit 默认属性表里没有这一项），不是读失败。

---

## 附：逆向产物索引

```
kuakewangpan/
  kkwptvb_2.9.1702_dangbei.apk
  _x/                        # unzip 解包（含 AndroidManifest.xml / classes*.dex / lib/）
  jadx_out/sources/          # jadx 全量反编译
    com/UCMobile/Apollo/     # ExoPlayer 分支内核（VideoView / MediaCodec / MediaPlayer / ApolloOptionKey）
    eskit/sdk/support/player/ijk/player/IjkVideoView.java   # ★ 硬解选项（第 959-972 行）
    eskit/sdk/support/player/manager/decode/a.java          # ★ 解码模式枚举
    eskit/sdk/support/player/manager/definition/a.java      # ★ 清晰度枚举
```

复现命令：

```bash
unzip -o -q kkwptvb_2.9.1702_dangbei.apk -d _x
JAVA_HOME=/Users/tandy/work/javatools/jdk-17.0.2.jdk/Contents/Home \
  /Users/tandy/work/javatools/jadx-1.5.1/bin/jadx -d jadx_out --no-res --show-bad-code \
  kkwptvb_2.9.1702_dangbei.apk
```
