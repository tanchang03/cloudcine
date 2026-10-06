# 云影（cloudcine）长期约定

**两个互不引用的工程**（10-06 定调）：`android/` = ★ **Android / Android TV 正式实现**（原生 Kotlin，包名 `com.cloudcine.tv`）；`lib/ macos/ windows/ pubspec.yaml` = **Flutter PC 端（macOS / Windows）**。
- 细节下沉：**理由/实测证据 → `HOWTO.md`**；逐日经过 → `YYYY-MM-DD.md`；Android 产品文档 → `android/README.md`。本文件只留**红线 + 标识符**。
- ⚠️ 本文件**超约 1.1 万字符即被注入截断** ⇒ 加新条目**先删旧的**。
- 本机通用事实（gvm / `NO_PROXY` / 沙箱 / `ps`→`pgrep` / `git push` 要 `HOME` / **同文件两条 Edit 互相覆盖**）见 `~/.workbuddy-ai/MEMORY.md`。

## 仓库结构（10-06）
- 用户定调：**Android 走原生 Kotlin 独立工程；Flutter 只用于 PC 端**；范围「只需要关心 `android/`」。Flutter 的 Android 宿主（`com.cloudcine.cloudcine`，22 文件）**已整体移出仓库**（备份 `~/.workbuddy-ai/backups/cloudcine-flutter-android-20261006-173700/`）；`git mv prototype/cloudcine android`。
- ⛔ **旧记忆中一切「Flutter 在 Android 上」的结论全部失效**（fvp/ExoPlayer 路由、media_kit 零拷贝、TvOsdView 挂 FlutterView、Dart 主 isolate 中继……），只对 PC 端或历史取证有效。
- ⛔ 根目录 `tool/adb_tv.sh` / `tool/build_android.sh` **已死** ⇒ 用 `android/tool/adb_tv.sh`。⛔ `packages/video_player_android` 仍在仓库根（pubspec path 依赖，删了 `flutter pub get` 失败）。⛔ `applicationId=com.cloudcine.tv` / `versionCode=1` 未改（换包名 = 已装设备变另一应用且丢磁盘缓存）。

## 版本控制
- **攒够一小轮就 commit**；`git clean` 先 `-nd` 干跑（`-df` 删 untracked **救不回**）。
- ⛔ **不代用户 `git add`/`git commit`**。提交前核对 `git diff --cached`：用户中途 `git add` 过快照时会**静默提交一个已废弃但能编译的设计**，修法 `git add -A`。
- ⛔ **别对仓库文件跑 `dart format`**；补救 `git show HEAD:<f>`。

## ★★ 媒体库数据结构 —— 跨端同步的**唯一契约**（依据见 HOWTO §同名章节）
### 1. `cloudcine.sqlite`
- PC 路径 `getApplicationSupportDirectory()/cloudcine.sqlite`；drift `schemaVersion = 16`，写在 SQLite **`user_version`** pragma。
- 7 表（列名 = Dart 字段 snake_case，权威 `lib/data/db/tables.dart`）：`media_items`(PK `id`)·`media_works`(PK `key`)·`subtitle_refs`(PK `id`)·`scan_cursors`(PK `provider`)·`settings`(PK `key`)·`playback_prefs`(PK `itemId`)·`download_tasks`(PK `id`)。
- ⛔ 主键全是**文本**（`provider:fileId` 口径），不是自增。⛔ `media_works.category` 默认**空串**（= 没判定过），`other` 是**判定结果**，不能混。
- ⛔ `resolution`/`container`/`download_tasks.status` 存**枚举名字符串**（存序号会在加档时静默变档）；`flags`/`genres` 是 **JSON 数组字符串**（默认 `'[]'`）；布尔列存 **0/1**；时间列存 **Unix 秒**。
- 迁移 v1→v16 见 `app_database.dart` `onUpgrade`；**有回填的只有 v6/v7/v10/v15**。

### 2. 备份包 `.ccbak`（`lib/domain/services/library_backup_service.dart`）
- 结构（全部大端）= `['CCBK'][manifestLen][manifest JSON][dbLen][db 原始字节][posters]`；海报段每文件 `[nameLen][name][dataLen][data]`，末尾 `[0]`。默认目录 **`云影备份`**（`defaultBackupDir`）。
- manifest：`deviceId/deviceName/createdAt/libraryModifiedAt/schemaVersion/fileNames/note`。同名覆盖**先删后传** ⇒ 上传文件名**必须带时间戳**。
- ★★ **同步判据是 `libraryModifiedAt`（库内容最后变更），绝不是 `createdAt`（备份生成时间）**。用 `createdAt` ⇒ 本机永远"新" ⇒ 把网盘好备份冲成空库。空库无此值 ⇒ `effectiveModifiedAt` 退化成 epoch ⇒ 远程自然赢。
- ★ 本地空库（`hasLibraryContent==false`）**让远程赢**；远程空备份**绝不覆盖本地**。冲突：不同设备且时间差 < 60s（`conflictsWith`）。
- ⛔ 不备份网盘凭证（Cookie 会过期，新机器必须重新扫码）。⛔ `includeSettings`/`restoreSettings` 是**空开关**（导出整个 db 原始字节）；UI 三条通道全传 `true`。

## 架构（Flutter PC 端）
`core/` 纯工具 · `domain/` 实体+服务+适配器抽象（**不 import Flutter/drift**）· `data/` 夸克/drift/刮削/凭证 · `ui/` Riverpod 组合根 + go_router + 页面。

## ★★ 4K 卡顿的真因：**播错了档位**（10-06 Mac 实测，`tool/quark_probe.py`）
`黑亚当 2160p`（7490s / 21.9 GiB）：原画 3840×1606 / 21.9 GiB / **3.00 MB/s**；`4k` 3840×1606 / 4.6 GiB / **0.63 MB/s**；`super` 1440×602 / 1.03 GiB / 0.14 MB/s；`high` 960×402 / 678 MiB / 0.09 MB/s。
- ★ 夸克自己的 `default_resolution` 是 `super`；云影默认播**原画** ⇒ 单连接喂不动 ⇒ 靠 8 连接中继 ⇒ 主线程饿死。**这就是全部秘密**（不是解码/渲染面/OSD 画法）。
- ★ 单连接直连实测（Mac 带 Cookie）：`4k` **4.57 MiB/s**、原画 **6.76 MiB/s** ⇒ 够用。「直连只有 1.1 MB/s」**只在电视 WiFi 上成立**。
- ⇒ 治本：**默认播转码档（≥`4k`），不播原画**。Android 现状：`probeThroughput` 测速 → `chooseQuality` 选「带宽扛得住的最清晰档」（留 30% 余量）。

### 直链 Cookie 规则（10-06 四种组合实测，★ 极易踩）
带 `__puus`（新旧都行）→ **206**；有 `__pus` 等会话 Cookie 但**缺** `__puus` → **412**；完全不带 → **206**。
⇒ **「要么不带，要么带全」**；带一半最坏（列表能刷、一播就 412/转圈）。`__puus` 在**每个** API 响应里轮换下发（Flutter `quark_adapter.dart:1285` / Android `PanApi.absorbCookies`）。
- ⛔ `batch/file/play/info` **必须带 `pr=ucpro&fr=pc`**，漏了回 `401 code=31001 require login [guest]`。
- ⚠️ `hls_type` 实测 **`none`** ⇒ 转码档是**普通 MP4**，不是 m3u8。
- ⛔ `HttpURLConnection.useCaches = false` 不能省：地址带签名，命中缓存会拿过期地址（「列目录正常、一播就 403」）。
- ⛔ 解析 `video_list` **必须跳过 `audio_list`**：纯音频流没有分辨率字段，易被当「原画」⇒ 有声音、进度条在走、**没画面、不报错**。

## Android 原生端（`android/app/src/main/java/com/cloudcine/tv/`）
> 产品文档与全部踩坑见 **`android/README.md`**。
- 形态：`MainActivity` → `LoginActivity`（CAS 扫码，zxing）→ `BrowseActivity`（`ListView`，天生支持 D-pad）→ `PlayerActivity`（ExoPlayer + `SurfaceView` 零拷贝 + 原生 OSD）。`pan/`：`PanHttp`（`HttpURLConnection`，**不引 OkHttp**）/ `PanApi` / `QrLogin`（业务码读 **`bizCode`**：网盘用 `code`、CAS 用 `status`）/ `PanModels` / `CredStore` / `Bg`。
- 取流 `ParallelRangeReader` + `ParallelRangeDataSource`（1 条 Range 拆 8 连接）；缓存 `DiskPrefetcher`（**旁路**预取）+ `PrefetchCache`/`DiskCacheEvictor`/`DiskSpace`。
  - ⛔ 缓存键 = **`quark:<fid>:<画质档 id>`**，**不是 URL**；⛔ **档位 id 不能省**（原画与转码档是不同字节流，只按 fid 会把原画字节喂给转码档解析器 ⇒ **解码乱码且不报错**）。⛔ `cacheKeyFactory` 必须**优先认 `dataSpec.key`**；两边复用同一个 `cacheKeyFor()`。
  - ⛔ **播放器不许写磁盘缓存**（`setCacheWriteDataSinkFactory(null)`）：两个写者撞同一 span ⇒ `SimpleCache.startFile` 抛 `IllegalStateException`，而 `CacheDataSource` 只吞 `IOException` ⇒ 直接崩。写入方只留 `DiskPrefetcher`。
  - ⛔ 预取器**绝不能在预取线程读 `player.currentPosition`**（未捕获异常带走整个进程）；只读主线程刷新的快照。⛔ `bufferedPosition` **必须在 `seekTo` 之前读**。
- `SeekPlan`（纯函数）：拖动中不动进度、**松手才 `seekTo`**（遥控器自动重复 ~20 次/秒 ⇒ seek 风暴）；前 2 秒不加速，之后 ×2/×4/×8/×12；兜底窗口 800 ms **必须大于自动重复间隔**。
- `TvOsdView`（原生 OSD，挂 `android.R.id.content` 之上）。⛔ 回调只回传**行下标**，行数不固定 ⇒ 一律按 `TvOsdView.Row.id` 分派，别 `when(row){0->…}`。
- ⛔ 速率**不能**取 `AnalyticsListener.onBandwidthEstimate`（一次传输完才发一次）⇒ 用 `CountingDataSource` 在 `read()` 上数字节。⛔ 目录判定**只认 `dir` 布尔位**，`file_type` 仅兜底（`0`=目录、`1`=文件，与直觉相反）。
- ⛔ `ListView` 用 `divider = null` 看不出选中项；⛔ XML 注释里不能出现 `--`。调试通道 `Log.i("CloudCine", "[统计] …")` / `[按键] → 下一帧 x.x ms`（`android/tool/adb_tv.sh log`）⛔ **不是调试残留**：有硬件视频层时 `screencap` 拿不到画面、播放中 `uiautomator dump` 也拿不到 UI。
- ⛔⛔ **`UI fps` 不可用于比较**：`StatsOverlay.doFrame` 里 `choreographer.postFrameCallback(this)` 自己重排自己 ⇒ 恒≈刷新率。唯一可比的是**「按键→下一帧」**与 SurfaceFlinger `--latency`。

## Flutter PC 端红线（逐条理由与实测在 HOWTO，此处只列标识符）
- **引擎/硬解**：`hwdec` = **`mediacodec,auto-safe`**（逗号=回退）；`VideoControllerConfiguration.hwdec` 与 `PlayerBufferConfig.apply` **必须同值**且都在 `create()` 之前；判据 `hwdec-current`（带 `copy` = 拷贝档，空串不算）。⛔ **10-04 那两轮别再走**：① `VideoViewType.platformView` → 更卡、音画不同步；② 再加 `tunnel: true` → 4K 只有声音。`main.dart:57` 只在 macOS 注册 fvp；DV P5 唯一出路 **fvp/libmdk**。契约 `playback_engine.dart` / `playback_engine_router.dart` / `playback_surface.dart`。
- **中继** `data/stream/local_stream_relay.dart`：**无 `Isolate`/`compute`**；只在显式选原画时才需要。`core/utils/http_range.dart` = `sealed class RangeRequest`（`NoRange`/`Satisfiable`/`Unsatisfiable`）+ `parseRangeRequest()`：⛔ **起点越界必须回 416**，别与「不知道流多长」（→200）合成一个返回值（旧实现一个 `null` 表达两件事 ⇒ 416 死代码 ⇒ **「正在加载…」永不消失**）。⛔ **`chunkSize` 别放大**（2→8 MiB 后首块 1.18s→15~45s；断言 `chunkSize/0.6MiB < 5000ms`）；提速调 `connections`/`prefetchBytes`。
- **媒体库三轴（不能互推/合并）**：`MediaKind`（结构，只看文件名 `SxxExx`）· `MediaCategory`（语义，落 `media_works.category`）·「最近播放」（`LibraryFilter.playedOnly`，与 `category` 互斥）。层级**不落库**（现算）：**季在外、部在内**，某层**少于 2 个选项不画**。⛔ **归一 = 打标记**（`mergedInto`）：不删行、不改 `group_key`、**不许链式**；`mergeWorkForUpsert` **无条件取旧值**。⛔ **目录名当系列名**：判定单元是**目录不是文件**（`DirectoryTitle`），**四处调用点都要传 `dirPath`**。⛔ 「已刮削」= **`source==online`**。⛔ `posterFaceX` 与 `posterUrl` **必须成对**。⛔ 路径归一化只在 `core/utils/drive_paths.dart`。⛔ 字幕字节走 `decodeTextBytes`（先 UTF-8 后 GBK）。
- **播放器/页面**：⛔ **两份实现，别只改一个**（`player_window_app.dart` + `player_page.dart`）。⛔ 起播只走 `Media(start:)`（入口 `PlaybackMedia.build`；⚠️ **静默** ⇒ 换源后核对 `RestoreSeek`）。⛔ 进度两列别合并：`resumePositionMs`（起播，看完清）vs `maxPositionMs`（v15，只增不减）。⛔ 落库接 `PlaybackController.onPositionTick`。
- ★ **音效 ≠ 音轨**（**别合并菜单**）：`音轨` = 片源里封着的流（语言，`stream.tracks`）；`音效` = 播放端对输出的处理（`player_audio_effect.dart`：跟随片源/环绕上混/立体声/杜比·DTS 直通）。⛔ `af set` 返回值不能当依据（本库 libmpv 无音频 DSP 滤镜）；⛔ macOS `audio-spdif` 直通必卡死（音频是主时钟 ⇒ **整片冻住**）⇒ macOS `passthroughAvailable == false`。⚠️ **Android 端只有一行、标签写「音效」但内容是音轨**（`buildRows` → `trackRow(ROW_AUDIO,"音效",C.TRACK_TYPE_AUDIO)`），与 PC 端口径不一致。
- **侧栏五项** 媒体库 `/library` · 文件夹 `/folders` · 扫描 · 下载 · 设置：⛔ `app_shell._items` 与 `app_router.branches` **必须同序**（判据是下标）；文件夹读**网盘实时目录**、媒体库读**本地索引**，**搜索词各一份**。
- **目录视图**：三组**目录 → 视频 → 其他文件**（组间顺序是**结构**）。⛔ 入库判据只有 `classifyEntry` 一处。⛔ 下载取链**复用 `adapter.resolveStream`**（别打 `/file/download`，>50MiB 直接 23018）。
- **下载（v16）**：⛔ `.part` 是断点**唯一真源**；服务端**忽略 Range 回 200 必须从 0 重写**；`parse` 读不懂退 **paused**。
- **文件夹模式**：本地索引只做**「已入库」叠加层**，共用 `media_entry_classifier.dart`（镜像判定在视频判定**之前**）。⛔ **绝不清理陈旧记录**、**绝不写续扫游标**、**深度从本次目标算第 0 层**。
- **TV**：`isTvLayout` = android + 逻辑宽≥960（⛔ 判据读 view 宽，页面实得 624，**壳外页实得 960**）。⛔ 页头 `actions` 必须 `Wrap`；⛔ **过扫描内边距只有 `app_shell` 一处**；⛔ 遥控器 **↓ 绝不接管**；⛔ **`SelectableText` 是焦点陷阱** → 用 `TvSelectableText`。
- ⛔ **播放页 OSD 卡顿**：整页 rebuild ≈10 次/秒（`bufferEnd` 没节流）+ `SubtitleViewConfiguration` 无 `operator ==`（内联 new ⇒ 每拍重建）+ `DebugOverlay` 的 `kDebugOverlayEnabled = true` **硬编码**（release 也显示）。

## 运维速查（细节全在 HOWTO，此处只留判据）
- **采样**：⛔ 周期 **10 秒**（不与视频探针的 21 秒相等 ⇒ **拍频锁定**）；**读不到一律留空**，不许退化成 0。⛔ 进程 CPU 是**单核口径**（须写「折合 N 核」）；系统 CPU「忙」**不含 iowait**。⛔ 电视上 `/proc/loadavg` 会 `Permission denied` ⇒ 用 `procs_running`/`procs_blocked`；⛔ `/proc/self/stat` **按最后一个 `)` 切**；⛔ `df` 正则**从左锚定**。
- **日志/帧率**：应用日志是**文件不是 logcat** —— `DiagLog` 写 `files/logs/cloudcine-YYYY-MM-DD.log`（mtime 不涨 = 真没做事）；**线程名读 `/proc/<pid>/task/*/comm`**；⛔ `exec-out screencap` 会被引擎日志污染 ⇒ `shell screencap -p` + `pull`。**★ 真帧率用 SurfaceFlinger 量，别信 HUD**（`--list` → `--latency '<层名>'`）；⛔ LMK 会杀后台应用（电视仅 2.5 GB）⇒ 先 `am kill-all`。
- **打包**：⛔ MSI 启动条件绝不能写 `VersionNT >= 1000`（Windows Installer 把 VersionNT **钳在 603**）⇒ 用 **`WindowsBuild >= 10240`** + `Installed OR`（MSI 条件语法**不支持括号**）。⛔ macOS 不许写 `keychain-access-groups`（→ 启动即 SIGKILL）、`app-sandbox` 必须 **`false`**；凭证走 `EncryptedFileSecretBackend`（密钥由 `IOPlatformUUID` 派生，⛔ 别再试钥匙串）。⚠️ 本机**出不了 Flutter release/profile 包**（`gen_snapshot ... incorrect architecture`）。
- **Android 构建**：Gradle 8.10.2 / AGP 8.7.0 / Kotlin 2.1.0 / compileSdk 36 / minSdk 21 / targetSdk 34 / Media3 **1.5.1**；⛔ **首次构建必须联网**；`JAVA_HOME` 必须 **JDK 21**（JBR 25 会崩 Kotlin）；⛔ 不引 `media3-ui`/AppCompat/Material/RecyclerView；`isMinifyEnabled` 故意 false；品牌化产物落 `outputs/apk/branded/`。

## 测试取向
- 纯函数优先、断言写「为什么重要」。⛔ **每个需求只跑相关单测，不回归全量**（用户 10-04 定）。修并发/竞态 bug **先加测试确认红**再加修复。⚠️ 用户常**边改边跑**，判据 = 红的在不在我改的文件里。Android：`./gradlew :app:testDebugUnitTest`（107 例 0 失败基线）。
