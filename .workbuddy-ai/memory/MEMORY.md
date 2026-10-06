# 云影（cloudcine）项目长期约定

Flutter 3.29 / Dart 3.7 的 macOS / Android TV 网盘媒体库播放器，对接夸克。
- 本机通用事实（gvm/`NO_PROXY`/沙箱/`ps`→`pgrep`/Android 构建/`git push` 要 `HOME`/**同文件两条 Edit 会互相覆盖**）见 `~/.workbuddy-ai/MEMORY.md`。
- **理由、实测证据、标识符细节在 `HOWTO.md`**（`§` 指其章节）；逐日经过在 `YYYY-MM-DD.md`。本文件只留**红线 + 标识符**。
- ⚠️ 本文件**超过约 1.1 万字符就被注入截断**（后半段读不到）⇒ 加新条目**先删旧的**；细节一律下沉 `HOWTO.md`。

## 版本控制
- **攒够一小轮就 commit**；`git clean` 先 `-nd` 干跑（untracked 被 `-df` 删掉**救不回**）。
- ⛔ **不代用户 `git add`/`git commit`**（分别授权）。提交前核对 `git diff --cached`：用户中途 `git add` 存过快照时，会**静默提交一个已废弃但能编译的设计**，修法 `git add -A`。
- ⛔ **别对仓库文件跑 `dart format`**；补救 `git show HEAD:<f>`。

## 架构
`core/` 纯工具 · `domain/` 实体+服务+适配器抽象（**不 import Flutter/drift**）· `data/` 夸克/drift/刮削/凭证 · `ui/` Riverpod 组合根 + go_router + 页面。跨层信号放叶子文件。

## ★★ 4K 卡顿的真因：**播错了档位**（10-06 Mac 实测，`tool/quark_probe.py`）
`黑亚当 2160p`（7490s，原文件 21.9 GiB）实测档位：

| 档位 | 分辨率 | 体积 | **需要带宽** |
|---|---|---|---|
| 原画 | 3840×1606 | 21.9 GiB | **3.00 MB/s** |
| `4k` | 3840×1606 | 4.6 GiB | **0.63 MB/s** |
| `super` | 1440×602 | 1.03 GiB | 0.14 MB/s |
| `high` | 960×402 | 678 MiB | 0.09 MB/s |

- ★ **夸克自己的 `default_resolution` 是 `super`**；云影默认播**原画**（3 MB/s）⇒ 单连接喂不动 ⇒ 靠 8 连接中继 ⇒ 中继跑在 **Dart 主 isolate** ⇒ **UI 饿死 + 加载-播放-加载**。**这就是全部秘密**（不是解码、不是渲染面、不是 OSD 画法）。
- ★ 单连接直连实测（Mac，带 Cookie）：`4k` **4.57 MiB/s**、原画 **6.76 MiB/s** ⇒ 够用。内存里「直连只有 1.1 MB/s」**只在电视 WiFi 上成立**，不是普适结论。
- ⇒ 治本：**默认播转码档（≥`4k`），不播原画**；中继只在用户显式选原画时才需要。
- 电视上夸克 TV 版实测 app 23.5% / `media.codec` 20.5%（≈ 4 核 11%）。

### 直链 Cookie 规则（10-06 四种组合实测，★ 极易踩）
| 请求带的 Cookie | 结果 |
|---|---|
| 带 `__puus`（**新旧都行**） | **206** |
| 有 `__pus` 等会话 Cookie 但**缺** `__puus` | **412** |
| 完全不带 Cookie | **206** |

⇒ **「要么不带，要么带全」**；带一半最坏（列表能刷、一播就 412/转圈）。`__puus` 在**每个** API 响应里轮换下发（`quark_adapter.dart:1285` 已处理）。
- ⛔ `batch/file/play/info` **必须带 `pr=ucpro&fr=pc`**，漏了回 `HTTP 401 code=31001 require login [guest]`（像没登录，其实缺参数）。
- ⚠️ `hls_type` 实测 **`none`** ⇒ 转码档是**普通 MP4**（`video/mp4`），**不是 m3u8**。旧记忆「取链改成 `media.m3u8`」**已过时**。

## 引擎路由 / 硬解（10-04~10-06，§）
- ⛔ `hwdec` 必须写 **`mediacodec,auto-safe`**（逗号=带回退；光写 `mediacodec` 失败只剩软解）。判据：读 `hwdec-current`，带 `copy` = 拷贝档（`isCopyHwdec`，⛔ **空串不算**）。
- ⛔ `VideoControllerConfiguration.hwdec` 与 `PlayerBufferConfig.apply` **必须同值**，且**都排在 media_kit `create()` 之前** → Surface 就绪后要再写一次才生效。
- ⛔⛔ **10-04 那两轮别再走**（§4.5）：① 只加 `VideoViewType.platformView` →「更卡、音画不同步」；② 再加 `tunnel: true` →「**4K 看不到画面，只有声音**」。
- ⚠️ **旧记忆「4K 切 fvp」已过时**：`main.dart:57` 只在 **macOS** 注册 fvp；Android 备用内核是 **`VideoPlayerExoPlaybackEngine()`**（`app_providers.dart:224-228`），`:233` `highResTvRoute` = `Platform.isAndroid && tv`，判据 `playback_engine_router.dart:184` `videoHeight >= 2048`（⛔ 不是 2160）。⇒ **Android TV 上 ≥2048p 与 DV P5 都走 ExoPlayer**（10-06 HUD 实证 `内核 ExoPlayer`/`解码 硬解(直通)`）。`fvp.registerWith` 范围与路由判据**必须一致**。
  - ⛔ `:199` 日志文案写死「切到 fvp（libmdk）」→ 实际 ExoPlayer，**待修**。⚠️ `:190` `_dvEngine ??= factory()` ⇒ Android DV P5 也走 ExoPlayer，与 `docs/ExoPlayer-硬解路线方案.md §2.4` 不一致，**待用户确认**。
  - ⛔ **mpv 在 Android 上做不到零拷贝，是结构性的**：`media_kit_video-1.3.1/android/.../VideoOutput.java` **写死** `createSurfaceProducer()`。调 mpv 参数没用。崩溃证据：`libmdk.so` 的 `strlen→vfprintf`；`SurfaceTextureWrapper.release`（引擎二次释放，**换内核就触发、与 viewType 无关**）。
  - 📌 面板 `ro.boot.mi.panel_resolution=3840x2160`，但 Android 显示层**只有 1920×1080**（`dumpsys display`）⇒ 应用内渲染最高 1080p，由电视倍线。
  - 10-04 的观察（**已被上面取代，只作证据**）：真机 `解码丢帧=0 / 显示丢帧 21s 涨 44`、[中继] 零告警 ⇒ 瓶颈不在解码。证据 `docs/AndroidTV-4K-丢帧-夸克对标.md`，方案 `docs/解决4k片源不卡顿解析方案.md`。

## 本地中继 `data/stream/local_stream_relay.dart`
⛔ **没有 `Isolate`/`compute`**：上游 TLS/解密/HTTP/分块拷贝**全在 Dart isolate**，而 Flutter 的 Dart isolate **就是 Android 主线程**（`/proc/PID/task` 里**没有 `1.ui`**）。
### Range 语义（10-06，★ 卡死首帧的根因）
`core/utils/http_range.dart` = **`sealed class RangeRequest`**（`NoRangeRequest`/`SatisfiableRange`/`UnsatisfiableRange`）+ `parseRangeRequest()`。
- ⛔ **起点越界必须回 416**。旧 `parseRangeHeader` 用**一个 `null`** 同时表达「没要求区间」（→200 整文件）和「起点越界」（→416）；调用方 `clampRange(requested ?? ByteRange(0,total-1), total)` 只能二选一、选了整文件 ⇒ **416 成死代码**；旧单测注释还写「交给 416」—— **契约两半分家，测试一直绿**。
- 后果（`凡人` 4K 3.13 GiB）：播放器问 `bytes=5014520206-`，中继回 `200 bytes 0-3358116481/…`。「对带 Range 的请求回 200」=「这是完整资源」⇒ media3 丢掉前 5.01 GB 去对齐偏移，可整条流只有 3.13 GiB ⇒ 读完才 EOF ⇒ **「正在加载…」永不消失**。判据：`[中继]` 出现 `读取器 #N → 200 bytes 0-<总长-1>/<总长>` 且请求 `Range: bytes=<大于总长>-`。
- ⛔ 别再把「不知道流多长」（→200）与「要不到」（→416）合成一个返回值。`clampRange` 保留但**中继已不再调用**。
### 「块大小 ↔ 首字节延迟」耦合（10-05 血案）
`_fetchChunk` **整块读完才 `cache.put` + `_settle`** ⇒ 首字节延迟 ≈ 单块下载耗时，与 `chunkSize` 成正比。
- ⛔ **`chunkSize` 别放大**。2 MiB→8 MiB 后首块 1.18s→**15~45s**、**零成功播放**、每次换片 `Source error`。✅ 已改回 2 MiB；回归测试 `test/data/stream/local_stream_relay_test.dart`「默认 chunkSize 的首字节预算」（断言 `chunkSize/0.6MiB < 5000ms`）。提速调 `connections`/`prefetchBytes`。
- ⛔ **`Source error` 的真判据不是「首帧 > 8s」**（原型首帧 12.3s 却没错）。`DefaultHttpDataSource` readTimeout 是**单次 socket 读**空闲上限：2 MiB 中继 ~2.8s 出首字节；8 MiB **整块读完才发第一字节**，>8s 零字节 ⇒ 必炸。`warmUpRelay(timeout:2500ms)`/mpv ~5s/ExoPlayer ~20s 都远小于它。
- ⛔ 换源时 `fvp 失败 → 回退 media_kit` 会**再建一个中继会话**（sN/sN+1）⇒ 一次换片 = 2 次首块等待。⚠️ 同窗口有**跨内核陈旧事件**（切回 mpv 后 2.2s 仍收 `ExoPlayer 首次初始化失败`）→ 待查。

## 资源采样：CPU / 内存 / 磁盘（10-04，§）
`core/diagnostics/resource_probe.dart`：`ResourceProbe`（引擎 `open()` 起、`stop()`/`dispose()` 停，两引擎各一）+ 纯解析函数。**fvp 那条路没有视频探针**。
- ⛔ **周期 10 秒**，**故意不与**视频探针的 21 秒相等（会**拍频锁定**；10 与 21 互质）。
- ⛔ **读不到一律留空、整段从日志行消失**，不许退化成 0。⛔ 进程 CPU 是**单核口径**，必须写「折合 N 核」。⛔ 系统 CPU「忙」**不含 iowait**；`/proc/stat` 只认汇总行 `cpu `（**别用 `cpu0`**）。
- ⛔ `/proc/loadavg` 在电视上 `Permission denied`；`/proc/pressure/*` 在 Android 9 不存在。替代 `/proc/stat` 的 `procs_running`/`procs_blocked`（`parseProcStatProcs`，**同文件、不额外读盘**），写「可运行进程=N（4 核，超订 x.xx×）」——⛔ **核数必须一起写**。
- ⛔ `/proc/self/stat` **按最后一个 `)` 切**。⛔ `df` 正则**从左锚定**、不按列 split；用异步 `Process.run`。macOS 无 `/proc`：内存退回 `ProcessInfo.currentRss`，CPU/负载留空属**正常**。

## TV OSD：已换成**原生 View**（10-06，§）
`android/.../TvOsdView.kt`（移植 `prototype/kuake` 的 `KuakeOsdView`，几何常量逐字相同）挂在 `android.R.id.content` 之上，由 `MainActivity.dispatchKeyEvent` 直连。起因是硬读数：**按 MENU → 上屏 524 ms**（原型同口径 0.3~8.3 ms）—— Flutter 版菜单挂在 `ListenableBuilder(listenable: controller)` 里、进度每 tick 重建整页，而中继**全在 Dart 主 isolate**；原生 OSD 与 Dart 彻底解耦，这才是「跟手」的结构性原因（不是画法、不是引擎）。
- ⛔ **行模型只有一份**：`lib/ui/widgets/player_tv_rows.dart`。`PlayerTvOverlay` 降级为**回退路径**（`TvOsdChannel.show` 返回 false 时用），但它 **re-export** 那份模型。
- ⛔ **原生回调只回传「行下标」** ⇒ **枚举顺序就是原生菜单的下标顺序**，动枚举必须同时改 `TvOsdView` 与单测。
- ⛔ 原生 `show` **必须返回 bool**（取不到 `android.R.id.content` 时 false）。⛔ OSD **不能挂进 FlutterView**。
- ⛔ 有硬件视频层时 **`screencap` 全黑** ⇒ 验证只看 logcat tag **`CloudCineOsd`**。
- ★ 云影在电视上**本来就是 ExoPlayer + SurfaceView**（`video_player_exo_playback_engine.dart:238`）⇒「换引擎/换渲染面」**已经是原型方案**，真正缺的只有 OSD。
- 贴底 XY 菜单几何（照夸克）：`PlayerTvSheet` 贴底横排，选中行下面铺 chip 条；`↑↓` 换行（循环）、`←→` 挪光标（不循环、**跳过灰掉的**）、**`OK` 才生效**；`←→` 只在**没有 chip 条**的行回调 `onAdjust`。⛔ **菜单开着时不画控制栏**；⛔ 字幕**抬高**；⛔ `kPlayerTvSheetHeight` 末尾 `+0.8` 是描边算成内边距，删了就溢出。

## 电视上取证（10-06，★ 省一整轮）
1. **应用日志是文件、不是 logcat**：`DiagLog` 同步写 `files/logs/cloudcine-YYYY-MM-DD.log`，读 `adb shell run-as com.cloudcine.cloudcine cat files/logs/cloudcine-<日期>.log`。⛔ logcat `I/flutter` 基本只有引擎启动几行；⛔ **文件 mtime 不涨 = 应用真没做事**。
2. **线程名读 `/proc/<pid>/task/*/comm`**：`top -H` 在 Android 9 全打进程名。⛔ 取字段写 `${12}`/`${13}`；切字段按**最后一个 `)`**。
3. **`exec-out screencap` 被 fvp 的 `Init wrapper sys mutex successful.` 污染** ⇒ 用 `shell screencap -p /sdcard/x.png` + `pull`。
4. **`uiautomator dump` + `input tap X Y` 比猜 DPAD 可靠**。⛔ Flutter 语义树只在无障碍被触发后才暴露，重启后常取不到。
5. **★ 视频真帧率用 SurfaceFlinger 量，别信 HUD**：`dumpsys SurfaceFlinger --list` 找层 → `--latency '<层名>'`（首行=刷新周期 ns，其后 128 帧三列时间戳）。**Flutter UI 帧率**用 `dumpsys gfxinfo <包名>` 两次取差。实测 `activeBuffer=[3840x2160:3840,Unknown 0x13]` 才是**视频层**；`SurfaceView #0` 是 `1920x1080 RGBA`。
6. ⛔ **LMK 会杀掉后台的云影**（电视仅 2.5 GB）⇒ 中继喂原型只有 2~3 分钟窗口；先 `am kill-all` 腾内存。

## 云影 vs 原型的对比**本身不公平**（10-06，★ 别再用它下结论）
- 原型是**原生 Kotlin**，`debuggable` 几乎无代价；云影是 **Flutter `app-debug.apk` = JIT**。实测进程合计 **467%/400%**（主线程 200% + `DartWorker` 199% + `1.raster` 42%，ExoPlayer 只拿 12%）。
- ⚠️ **本机出不了 release/profile 包**：Flutter 的 Android AOT 快照工具是 `darwin-x64` 二进制，Apple Silicon 无 Rosetta ⇒ `gen_snapshot ... incorrect architecture`。解法（需 sudo）：`sudo softwareupdate --install-rosetta --agree-to-license`。
- ⚠️ 引擎切换用 `unawaited(previous.stop())`（fire-and-forget）⇒ 旧内核可能没拆干净。
- ⛔⛔ **两边 `fps` 都不是流畅度，别再互相比较**：云影 `DebugOverlay` 数**引擎实际出帧**；原型 `StatsOverlay.kt:104` 的 `doFrame` 里 `postFrameCallback(this)` **自己重排自己** ⇒ `uiFps` 恒≈刷新率（实测 **100**）。
- ✅ **唯一可比的是「按键→下一帧」与 SurfaceFlinger `--latency`**。10-06 实测视频流畅度两边一样（~25 fps），差的是 **CPU 1.2~3.0% vs ~22%**、**RSS 124 MB vs ~570 MB**、**按键 0.3~3.9 ms vs 524 ms**。

## 播放页 OSD 卡顿的结构性成因（10-05，§）
⛔ **不是 Flutter 太重**，是三处开销叠在 4 核 SoC 上：
- **整页 rebuild ≈10 次/秒**：`player_page.dart` 的 `ListenableBuilder` 包着整棵树。position 已节流 250ms，但 **`bufferEnd`（mpv `demuxer-cache-time`）没节流** ⇒ 要加节流或拆 `ValueNotifier`。
- ⛔ **`SubtitleViewConfiguration` 无 `operator ==`**（media_kit_video 1.3.1）：页面里内联 new ⇒ `VideoState.didUpdateWidget` 恒判不等 ⇒ 每拍 post-frame 再重建画面子树。⇒ 缓存实例（**现在只有 `_FvpPlaybackSurface` 有**）。
- `PlayerTvOverlay._rows()` 每 build 重算全部选项（含每集 `baseNameOf`）。
- ⛔ `DebugOverlay` 的 `kDebugOverlayEnabled = true` **硬编码**（release 也显示），挂 `MaterialApp.builder`、`refreshInterval = 1 秒` ⇒ **每秒重建整棵应用树**，还每秒 spawn 一个 `df`。

## 夸克方案验证原型（分支 `feature/kuake`，`prototype/kuake/`）
**独立 Android 工程**（不含 Flutter）—— 只要 Flutter 引擎在同一进程，「每秒 10 次整页 rebuild」就撇不干净。
- 形态：`ExoPlayer`（Media3 **1.5.1**）+ `setVideoSurfaceView`（零拷贝）+ **原生 View OSD**（⛔ 故意去掉圆角裁剪/blur 阴影/隐式动画）。
- 10-06 扩成完整原型：`MainActivity`（路由）→ `LoginActivity`（CAS 扫码，zxing）→ `BrowseActivity`（`ListView`，天生支持 D-pad）→ `PlayerActivity`（按 fid 取链）。
- `quark/` 包：`QuarkHttp`（`HttpURLConnection`，**不引 OkHttp**；`useCaches=false` 必开）/ `QuarkApi`（`absorbCookies` 回填轮换 `__puus`）/ `QuarkQrLogin`（业务码读 **`bizCode`**：网盘用 `code`、CAS 用 `status`）/ `QuarkModels` / `Bg`（后台池，主线程只 setText）。
- ⛔ `PlayerActivity` 保留 `-e url` 这条**对照路径**（`StreamSpec`），跑「云影中继 vs 直连」。
- 10-06 新增：`AspectRatioFrameLayout`（按 `VideoSize`+PAR+旋转定界；⛔ **只包 SurfaceView、不包 OSD**，否则菜单被压进画面矩形）；起播前 `probeThroughput` 测速 → `chooseQuality` 选「带宽扛得住的最清晰档」（同分辨率取最省带宽，留 30% 余量）。
- 构建：Gradle 8.10.2 / AGP 8.7.0 / Kotlin 2.1.0 / compileSdk 36 / minSdk 21 / targetSdk 34。⛔ **首次构建必须联网**。⛔ 不引 `media3-ui`/AppCompat/Material/RecyclerView。命令：`JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home ./gradlew assembleDebug` —— ⛔ **别用 Android Studio 的 JBR**（现在是 25，会崩 Kotlin，报错只剩一个版本号）。
- ⛔ Media3 1.5.1 的 `DecoderCounters` 全是 **`int`**，且**没有 `inputBufferCount`** → 用 `queuedInputBufferCount`。
- 取数：`adb logcat -s KuakeProto`（`StatsOverlay` 每秒打同一行，**必需通道**）。
- Mac 侧 API 探针 `tool/quark_probe.py`（扫码登录 → 列目录 → `play/info`/`audioplay` → 测带宽），Cookie 落 `.quark_probe/cookie.json`。⛔ 含凭据，**别提交**（已在 `.gitignore`）。

## 取链（10-04，⚠️ 部分已过时，§）
⛔ 鉴权靠 `play/info` 下发的 **`Video-Auth`** cookie（必须进 `knownCookieNames`，否则分片 **404**）。⛔ **HLS 必须走本地中继**：本机 `http_proxy` 会让 ffmpeg 选**未列白名单**的 `httpproxy` → `avformat_open_input() failed`；该故障**护栏会放行** ⇒ 诊断触发必须**独立于** `isRealEnd`。⛔ **TV 的 mpv 只开 `error` 级** ⇒ `Failed to open 127.0.0.1/sN` 只靠中继日志还原。
⚠️ 旧记「`video_list[].video_info.url` 换成了 `media.m3u8`」**已过时**（10-06 实测 `hls_type=none`，转码档是普通 MP4）。

## 电视分支（§）
`isTvLayout`：android + 逻辑宽≥960（⛔ 判据读 view 宽，页面实得 624，**壳外页实得 960**）。⛔ **页头 `actions` 必须 `Wrap`**；⛔ TV 另一套缓冲（`cache=yes` + 硬解参数）；⛔ **过扫描内边距只有 `app_shell` 一处**，壳外页（`/work` `/diagnostics` `/auth/qr`）与**播放器覆盖层**自己加；⛔ 播放器遥控器 **↓ 绝不接管**；⛔ **侧栏方向键靠壳层兜底**（候选**只搜侧栏子树**）。

## 不可动摇的设计约束
1. 本地解析永远可用，在线刮削是增强；`LocalFilenameScraper` 排 `ScraperPipeline` 末位。
2. 原画只认 `/file/audioplay` 的 `audio_url`；`play/info` 的 `audio_list` 是纯音频流，当原画会**有声音没画面不报错**（`audioOnlyKeys` 别删）。
3. `ScanPolicy.audioOnly` 默认 `true`；视频库必须显式 `false`。
4. 直链必须带 Cookie（缺则 412）；`__puus` 每响应轮换回填。`PosterCache.headersFor(url)` 每次现取。
5. 字幕字节一律走 `decodeTextBytes`（先 UTF-8 后 GBK）；扫描期只写引用、不下载正文。
6. 起播只走 `Media(start:)` 且每次显式给；入口 `PlaybackMedia.build`；`seek` 只在播放中跳转。⚠️ 它**静默** → 换源后要核对（`RestoreSeek`，§）。
7. 刮削默认不跟扫描跑（`autoScrapeOnScan` 默认 `false`）。
8. 落库接 `PlaybackController.onPositionTick` 回调，不暴露 `Player`。
9. 夸克上传收尾**两步**、备份同步比 `libraryModifiedAt`，各有空守卫；`includeSettings`/`restoreSettings` 是**空开关**。
10. **TV 上 `SelectableText` 是焦点陷阱** → 用 `TvSelectableText`。

## 其余模块（细节见 `HOWTO.md`，此处只留红线）
- **侧栏（10-03）**：五项 媒体库 `/library` · 文件夹 `/folders` · 扫描 · 下载 · 设置；`app_shell._items` 与 `app_router.branches` **必须同序**（判据是下标）。⛔ 文件夹读**网盘实时目录**、媒体库读**本地索引**，两者并列；**搜索词各一份**。
- **文件夹模式（10-01）**：本地索引只做**「已入库」叠加层**。与全盘扫描共用 `media_entry_classifier.dart`（镜像判定必须在视频判定**之前**）、`work_builder.dart`、`request_throttle.dart`。⛔ **绝不清理陈旧记录**、**绝不写续扫游标**、**深度从本次目标算第 0 层**。发现让着扫描（`DiscoveryController.canStart`）。
- **目录视图**：三组**目录 → 视频 → 其他文件**（组间顺序是**结构**）。⛔ 分组只管排布，**入库判据仍只有 `classifyEntry` 一处**。⛔ 下载取链**复用 `adapter.resolveStream`**（别打 `/file/download`，>50MiB 直接 23018）。⛔ `FolderSortMode`/`ItemSortMode` **各一份设置键**、**渲染时**排、**只改显示不改 `primary`**。视频行**整行可点=播**。⛔ 多选：`folderSelectionProvider` 键=fid、**换目录清空**、**全选只勾当前可见**。
- **下载（v16）**：表 `download_tasks`（主键 `provider:fileId`）。⛔ `.part` 是断点**唯一真源**；服务端**忽略 Range 回 200 必须从 0 重写**；`parse` 读不懂退 **paused**。⛔ `downloadQueueProvider` **不能 autoDispose**、`settingsProvider` 用 `listen` 不用 `watch`。多连接 8×2 MiB、writer 顺序落盘。
- **播放器（两份实现，别只改一个）**：`player_window_app.dart` + `player_page.dart`。**键位表、菜单、偏好还原、换流提示、hover 唤醒都要改两处**；⛔ 独立窗口要 `mouseTrackingMode=.always` + `onEnter`；菜单统一走 `anchored_menu.dart`。`buffered_slider.dart` 是 **0..1 比例**（⛔ `demuxer-cache-time` 是**绝对时间戳**）。音轨过 `TrackLabels.realTracks`；搜索走 `subtitle_query.dart`（⛔ 别拿 `displayTitle`）。**音效 ≠ 音轨**：⛔ 无可用 Avfilter、**`af set` 返回值不能当依据**；⛔ macOS `audio-spdif` 直通必卡死。`playback_prefs`（v14）**写整条覆盖**；进度两列 `resumePositionMs`（起播，看完清）vs `maxPositionMs`（显示，v15，只增不减）⛔ 别合并。**DV P5**：⛔ macOS libmpv **架构上做不到**（`gpu-next` 零命中）→ 唯一出路 **fvp/libmdk**；契约 `PlaybackEngine` 在 `playback_engine.dart`、选引擎走 `playback_engine_router.dart`（**开播前探头部字节**）、画面走 `playback_surface.dart`。
- **媒体库三轴（不能互推/合并）**：`MediaKind`（结构，只看文件名 `SxxExx`）· `MediaCategory`（语义，落库 `media_works.category`，空串≠other）·「最近播放」（视图，`LibraryFilter.playedOnly`，与 `category` 互斥）。`MediaCategoryGuesser.guess` 序：TMDB genres→目录路径→片名+文件名→结构兜底。**交互**：`PlayTarget.resolve` 三档；`playItem()` 唯一起播入口。⛔ 路径归一化只在 `core/utils/drive_paths.dart`。
- **季/部/归一**：`MediaItem`+`part/partLabel`（v9）· `MediaWork`+`seasonCount`（v10）+`mergedInto`（v11）。层级**不落库**（现算）：**季在外、部在内**，某层**少于 2 个选项不画**；`seasonCount` 是 `COUNT(DISTINCT)` **不能相加**。**目录名当系列名**：判定单元是**目录不是文件**（`DirectoryTitle`），**四处调用点都要传 `dirPath`**。自动归一：只认 `onlineId` 相同 + `source==online` + kind 相同；**本地片名相似度绝不参与**。⛔ **归一 = 打标记**：不删行、不改 `group_key`；滤 `merged_into IS NULL`、`itemsForWork` 取并集、**不许链式**。⚠️ `mergeWorkForUpsert` 里**无条件取旧值**；搜索穿透折叠内层表**必须起别名**；⛔ `_unionStats` 别改回 JOIN 里的 `OR`。
- **筛选/封面刮削**：⛔ 筛选「已刮削」判据 = **`source==online`**（不是 `isScraped`），且**进 `_facetScope`**。⛔ `==`/`hashCode` 按**集合内容**比（`setEquals`+`Object.hashAllUnordered`）。⛔ `posterFaceX` 与 `posterUrl` **必须成对**；熔断只计**网络层**失败。**TMDB `/search/*` 必须过 `ScrapeMatch` 闸门**。⛔ 手动刮削通道三条交互不许改；**「自定义」** `customizeWork` **整行写、不过 merge**。**候选链** `ScrapeQuery.fallbacks` = 文件名 → 目录名逐级向上、串行命中即停；⛔ 本地兜底只用主查询、⛔ 两个调用点都要传 `dirPath`。⚠️ 待办 `DirectoryTitle._clean` 清年份/画质标记（⛔ 别用 `_parseDotted`）。
- **Android 产物名（10-03）**：⛔ 产物名由 Flutter 工具链**定死**，改 AGP `outputFileName` 无效；做法是给 `assemble<Mode>` 挂 **finalizer**（⛔ 别 doLast）**复制**成 `cloudcine-<versionName>-b<versionCode>-android.apk`。⛔ **别信产物文件名**：**只有通用的 `app-debug.apk` 会被重新构建**，per-ABI 那份停在旧 mtime ⇒ `-b1006-` 与 `-b1007-` **内容完全一样**；装前 `aapt2 dump badging <apk> | grep -E "^package|native-code"`。⛔ **`adb install` 被中途打断会留下装了一半的包**；装完复核 `dumpsys package … | grep versionCode`。
- **Windows MSI（10-05）**：`windows/packaging/cloudcine.wxs` + `build_package.ps1`（per-user 装到 `%LOCALAPPDATA%\Programs\CloudCine`，`InstallerVersion=500`）。⛔ **启动条件绝不能写 `VersionNT >= 1000`**：Windows Installer 把 VersionNT **钳在 603** ⇒ 该条件**在任何真实 Windows 上都失败**；判据用 **`WindowsBuild >= 10240`** + `Installed OR`（微软 KB3202260）。⚠️ **MSI 条件语法不支持括号**。⛔ `-sice` 只压 ICE38/ICE64/ICE91，**别换成 `-sval`**。
- **macOS 签名与凭证**：⛔ 不许写 `keychain-access-groups`（→ **启动即 SIGKILL**）；`app-sandbox` 必须 **`false`**；两份都要 `network.client/server`·`files.user-selected.read-write`；`DebugProfile` 另加 `get-task-allow`。凭证 macOS 走 `EncryptedFileSecretBackend`（⛔ 别再试钥匙串，其余平台 `flutter_secure_storage`），密钥由 `IOPlatformUUID` 派生（**别掺易变环境值**）。
- **测试取向**：纯函数优先；断言写「为什么重要」。⛔ **每个需求只跑相关单测，不回归全量**（用户 10-04 定的）。修并发/竞态 bug **先加测试确认红**再加修复。⚠️ 用户常**边改边跑**，判据=红的在不在我改的文件里。
