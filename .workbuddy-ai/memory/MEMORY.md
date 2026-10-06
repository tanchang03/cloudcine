# 云影（cloudcine）长期约定

**两个互不引用的工程**（10-06 定调）：`android/` = ★ **Android / Android TV 正式实现**（原生 Kotlin，`com.cloudcine.tv`）；`lib/ macos/ windows/ pubspec.yaml` = **Flutter PC 端**。
- 细节下沉：**理由/实测证据 → `HOWTO.md`**（§PC-n = 从本文件下沉的 PC 端细节）；逐日经过 → `YYYY-MM-DD.md`；Android 产品文档 → `android/README.md`。本文件只留**红线 + 标识符**。
- ⚠️ 本文件**超约 1.4 万字节即被注入截断**（10-06 实测 15131 字节尾部丢失）⇒ 加新条目**先删旧的**，目标 **≤ 12000 字节**。
- 本机通用事实（gvm / `NO_PROXY` / 沙箱 / `ps`→`pgrep` / `git push` 要 `HOME` / **同文件两条 Edit 互相覆盖**）见 `~/.workbuddy-ai/MEMORY.md`。

## 仓库结构（10-06）
- **Android 走原生 Kotlin 独立工程；Flutter 只用于 PC 端**；范围「只需要关心 `android/`」。Flutter 的 Android 宿主（`com.cloudcine.cloudcine`，22 文件）**已整体移出仓库**（备份 `~/.workbuddy-ai/backups/cloudcine-flutter-android-20261006-173700/`）；`git mv prototype/cloudcine android`。
- ⛔ **旧记忆中一切「Flutter 在 Android 上」的结论全部失效**（fvp/ExoPlayer 路由、media_kit 零拷贝、TvOsdView 挂 FlutterView、Dart 主 isolate 中继、`hwdec`、`platformView`、`tunnel:true`、DV P5……）—— 只对 PC 端或历史取证有效。**完整失效清单 + 证据 → HOWTO §PC-1**。
- ⛔ 根目录 `tool/adb_tv.sh` / `tool/build_android.sh` **已死** ⇒ 用 `android/tool/adb_tv.sh`。⛔ `packages/video_player_android` 仍在仓库根（pubspec path 依赖）。⛔ `applicationId` / `versionCode=1` **别改**（换包名 = 已装设备变另一应用且丢磁盘缓存）。

## 版本控制
- **攒够一小轮就 commit**；`git clean` 先 `-nd` 干跑（`-df` 删 untracked **救不回**）。
- ⛔ **不代用户 `git add`/`git commit`**。提交前核对 `git diff --cached`：用户中途 `git add` 过快照时会**静默提交一个已废弃但能编译的设计**，修法 `git add -A`。
- ⛔ **别对仓库文件跑 `dart format`**；补救 `git show HEAD:<f>`。

## ★★ 媒体库数据结构 —— 跨端同步的**唯一契约**
### 1. `cloudcine.sqlite`
- PC 路径 `getApplicationSupportDirectory()/cloudcine.sqlite`；drift `schemaVersion = 16` → SQLite **`user_version`**。
- 7 表（列名 = Dart 字段 snake_case，权威 `lib/data/db/tables.dart`）：`media_items`(PK `id`)·`media_works`(PK `key`)·`subtitle_refs`(PK `id`)·`scan_cursors`(PK `provider`)·`settings`(PK `key`)·`playback_prefs`(PK `itemId`)·`download_tasks`(PK `id`)。
- ⛔ 主键全是**文本**（`provider:fileId` 口径）。⛔ `media_works.category` 默认**空串**（= 没判定过），`other` 是**判定结果**，不能混。
- ⛔ `resolution`/`container`/`download_tasks.status` 存**枚举名字符串**（存序号会在加档时静默变档）；`flags`/`genres` 是 **JSON 数组字符串**（默认 `'[]'`）；布尔列存 **0/1**；时间列存 **Unix 秒**。迁移 v1→v16 见 `app_database.dart` `onUpgrade`（**有回填的只有 v6/v7/v10/v15**）。
- ★ **drift 的 DDL 两处反直觉**：可空列**显式写 ` NULL`**；主键写在**表尾**（`ADD COLUMN` 同一套规则）。
- **Android 侧** `library/`：`LibrarySchema`（唯一真源，7 条 DDL **逐字一致**，`LibrarySchemaTest` 守着）· `LibraryDb`（打开即补表补列 + 对齐 `user_version`；⛔ **不做 v1→v16 迁移**；补列**必须 `col.copy(notNull = false)`**；⛔ **不用 WAL**，`journal_mode=DELETE`）· `LibraryModels` · `LibraryPaths` · `LibraryBackupService`。
  - ⛔ `rawBytes()` 必须先 `close()`；`replaceWithRawBytes()` 必须先删 `-journal`/`-wal`/`-shm`。⛔ `LibraryItem` 必须带 `dirId`（起播传 `EXTRA_PDIR` 扫同目录字幕）。

### 2. 备份包 `.ccbak`（`lib/domain/services/library_backup_service.dart`）
- 结构（全大端）= `['CCBK'][manifestLen][manifest JSON][dbLen][db 原始字节][posters]`；海报段 `[nameLen][name][dataLen][data]`…`[0]`；⛔ **不是 ZIP**。默认目录 **`云影备份`**。
- manifest：`deviceId/deviceName/createdAt/libraryModifiedAt/schemaVersion/fileNames/note`。同名覆盖**先删后传** ⇒ 文件名**必须带时间戳**。
- ★★ **同步判据是 `libraryModifiedAt`（库内容最后变更），绝不是 `createdAt`**。空库无此值 ⇒ `effectiveModifiedAt` **退化成 `createdAt`（不是 0！）**。库变更口径 = `MAX(media_works.updated_at)` ∪ `MAX(media_items.first_seen_at)` ∪ `MAX(media_items.last_played_at)`。
- ★ 本地空库**让远程赢**；远程空备份**绝不覆盖本地**；冲突 = 不同设备且差 < 60s。
- ⛔ 不备份网盘凭证。⛔ `includeSettings`/`restoreSettings` 是**空开关**（导出整个 db 原始字节）。
- **Android 侧** `library/`：`BackupPackage` · `BackupManifest`（含手写 `IsoTime`）· `SyncDecision`（纯函数，**分支顺序不能动**）· `MiniJson`（⛔ `org.json` 在 JVM 单测里是空壳；整数不能写成 `16.0`）。

## ★★ 4K 卡顿的真因：**播错了档位**（10-06 Mac 实测，`tool/quark_probe.py`）
`黑亚当 2160p`（21.9 GiB）所需带宽：原画 **3.00 MB/s** · `4k` **0.63** · `super` 0.14 · `high` 0.09。
- ★ 夸克自己的 `default_resolution` 是 `super`；云影默认播**原画** ⇒ 单连接喂不动 ⇒ 靠 8 连接中继 ⇒ 主线程饿死。**这就是全部秘密**（不是解码、不是渲染面、不是 OSD 画法）。⇒ 治本：**默认播转码档（≥`4k`）**（Android 走 `probeThroughput` → `chooseQuality`，留 30% 余量）。逐档读数 / 四组合实测 / 历史取证 → HOWTO §PC-1。

### 直链 Cookie 规则（★ 极易踩）
带 `__puus`（新旧都行）→ **206**；有 `__pus` 等会话 Cookie 但**缺** `__puus` → **412**；完全不带 → **206**。⇒ **「要么不带，要么带全」**；带一半最坏（列表能刷、一播就 412/转圈）。`__puus` 在**每个** API 响应里轮换下发（PC `quark_adapter.dart:1285` / Android `PanApi.absorbCookies`）。
- ⛔ `batch/file/play/info` **必须带 `pr=ucpro&fr=pc`**，漏了回 `401 code=31001 require login [guest]`。⚠️ `hls_type` 实测 **`none`** ⇒ 转码档是**普通 MP4**，不是 m3u8。
- ⛔ `HttpURLConnection.useCaches = false` 不能省（地址带签名 ⇒「列目录正常、一播就 403」）。⛔ 解析 `video_list` **必须跳过 `audio_list`**（纯音频流没分辨率字段 ⇒ 有声音、进度条在走、**没画面、不报错**）。
- ⛔ **上传收尾是两步**：OSS `CompleteMultipartUpload`（带 `x-oss-callback`）→ `file/upload/finish`（body 只有 `task_id`+`obj_key`）。只做第 2 步回 `43001`。签名串 / XML / Base64 全在 `pan/OssAuth.kt`（纯函数，单测覆盖）；下载 `fileBytes` 走 `audioplay`。

## Android 原生端（`android/app/src/main/java/com/cloudcine/tv/`）
> 产品文档与全部踩坑见 **`android/README.md`**。
- 形态：`MainActivity` → `LoginActivity`（CAS 扫码，zxing）→ `BrowseActivity`（`ListView`，天生支持 D-pad）→ `PlayerActivity`（ExoPlayer + `SurfaceView` 零拷贝 + 原生 OSD）；新增 `LibraryActivity`（媒体库浏览 + 备份三入口）。
- `pan/`：`PanHttp`（`HttpURLConnection`，**不引 OkHttp**）/ `PanApi` / `OssAuth` / `QrLogin`（业务码读 **`bizCode`**：网盘用 `code`、CAS 用 `status`）/ `CredStore` / `Bg`。
- 取流 `ParallelRangeReader` + `ParallelRangeDataSource`（1 条 Range 拆 8 连接）；缓存 `DiskPrefetcher`（**旁路**预取）+ `PrefetchCache`/`DiskCacheEvictor`/`DiskSpace`。
  - ⛔ 缓存键 = **`quark:<fid>:<画质档 id>`**，**不是 URL**，且**档位 id 不能省**（原画与转码档是不同字节流 ⇒ 解码乱码且不报错）；`cacheKeyFactory` 必须**优先认 `dataSpec.key`**。
  - ⛔ **播放器不许写磁盘缓存**（`setCacheWriteDataSinkFactory(null)`）：两个写者撞同一 span ⇒ `SimpleCache.startFile` 抛 `IllegalStateException`，而 `CacheDataSource` 只吞 `IOException` ⇒ 直接崩。写入方只留 `DiskPrefetcher`。
  - ⛔ 预取器**绝不能在预取线程读 `player.currentPosition`**；⛔ `bufferedPosition` **必须在 `seekTo` 之前读**。
- `SeekPlan`（纯函数）：拖动中不动进度、**松手才 `seekTo`**；前 2 秒不加速，之后 ×2/×4/×8/×12；兜底窗口 800 ms **必须大于自动重复间隔**。
- `TvOsdView`（原生 OSD，挂 `android.R.id.content` 之上）。⛔ 回调只回传**行下标** ⇒ 一律按 `TvOsdView.Row.id` 分派，别 `when(row){0->…}`。
- ⛔ 速率**不能**取 `AnalyticsListener.onBandwidthEstimate`（一次传输完才发一次）⇒ 用 `CountingDataSource` 在 `read()` 上数字节。⛔ 目录判定**只认 `dir` 布尔位**（`file_type` `0`=目录、`1`=文件，与直觉相反）。
- ⛔ `ListView` 用 `divider = null` 看不出选中项；⛔ XML 注释里不能出现 `--`。调试通道 `Log.i("CloudCine", "[统计] …")` / `[按键] → 下一帧 x.x ms`（`android/tool/adb_tv.sh log`）⛔ **不是调试残留**：有硬件视频层时 `screencap` 拿不到画面、播放中 `uiautomator dump` 也拿不到 UI。
- ⛔⛔ **`UI fps` 不可用于比较**：`StatsOverlay.doFrame` 里 `choreographer.postFrameCallback(this)` 自己重排自己 ⇒ 恒≈刷新率。唯一可比的是**「按键→下一帧」**与 SurfaceFlinger `--latency`。
- 工程约定：minSdk 21 / targetSdk 34 / compileSdk 36 / Media3 **1.5.1**；⛔ 不引 OkHttp / media3-ui / AppCompat / Material / RecyclerView；Activity 直继承 `android.app.Activity`；`Bg` 线程池**不支持 lambda 单参重载**。
- 构建：Gradle 8.10.2 / AGP 8.7.0 / Kotlin 2.1.0；⛔ **首次构建必须联网**；`JAVA_HOME` 用 **JDK 21**；`isMinifyEnabled` 故意 false；品牌化产物落 `outputs/apk/branded/`。
- ⛔ JVM 单测：`unitTests.isReturnDefaultValues = true`；`android.database.sqlite` 不可用；**`org.json` 与 `android.util.Base64` 是空壳** ⇒ 自写 `MiniJson` / `OssAuth.base64`。

## Flutter PC 端红线（**索引**；理由与完整判据 → HOWTO §PC-2~8）
> 分层：`core/` 纯工具 · `domain/` 实体+服务+适配器抽象（**不 import Flutter/drift**）· `data/` 夸克/drift/刮削/凭证 · `ui/` Riverpod 组合根 + go_router + 页面。
- **中继** `data/stream/local_stream_relay.dart`：**无 `Isolate`/`compute`**；只在显式选原画时才需要。`core/utils/http_range.dart` = `sealed class RangeRequest`：⛔ **起点越界必须回 416**，别与「不知道流多长」（→200）合成一个返回值。⛔ **`chunkSize` 别放大**（2→8 MiB ⇒ 首块 1.18s→15~45s、零成功播放）。
- **媒体库三轴**（不能互推/合并）：`MediaKind`（结构，只看文件名 `SxxExx`）· `MediaCategory`（落 `media_works.category`）·「最近播放」（`playedOnly`，与 `category` 互斥）。层级**不落库**（季在外、部在内；**<2 个选项不画**）。⛔ **归一 = `mergedInto` 打标记**（不删行 / 不改 `group_key` / **不许链式**）。⛔ 目录名当系列名（判定单元是**目录**，四处调用点都要传 `dirPath`）。⛔ 「已刮削」= **`source==online`**；⛔ `posterFaceX` 与 `posterUrl` **成对**；⛔ 字幕走 `decodeTextBytes`（先 UTF-8 后 GBK）。
- **播放器/页面**：⛔ **两份实现别只改一个**（`player_window_app.dart` + `player_page.dart`）。⛔ 起播只走 `Media(start:)`。⛔ 进度两列别合并：`resumePositionMs`（起播，看完清）vs `maxPositionMs`（v15，只增不减）。★ **音效 ≠ 音轨**（别合并菜单）；⛔ macOS `audio-spdif` 直通必卡死 ⇒ `passthroughAvailable == false`。
- **导航/目录视图/下载**：⛔ `app_shell._items` 与 `app_router.branches` **必须同序**（判据是**下标**）；文件夹读**实时目录**、媒体库读**本地索引**，**搜索词各一份**。⛔ 入库判据只有 `classifyEntry`；⛔ 下载取链**复用 `adapter.resolveStream`**（>50MiB 打 `/file/download` 直接 23018）；⛔ `.part` 是断点**唯一真源**。文件夹模式只做**「已入库」叠加层**：⛔ **绝不清理陈旧记录**、**绝不写续扫游标**。**全文 → HOWTO §PC-6**。
- **TV**：`isTvLayout` = android + 逻辑宽≥960（⛔ 判据读 **view 宽**）。⛔ 页头 `actions` 必须 `Wrap`；⛔ 遥控器 **↓ 绝不接管**；⛔ **`SelectableText` 是焦点陷阱** → 用 `TvSelectableText`。⛔ **播放页 OSD 卡顿**：`bufferEnd` 没节流 + `SubtitleViewConfiguration` 无 `operator ==` + `kDebugOverlayEnabled = true` **硬编码**。**全文 → HOWTO §PC-7**。

## 运维速查（**判据全文 → HOWTO §PC-8**）
- **采样**：⛔ 周期 **10 秒**（不与视频探针的 21 秒相等 ⇒ **拍频锁定**）；**读不到一律留空**，不许退化成 0；⛔ 进程 CPU 是**单核口径**（写「折合 N 核」）；系统 CPU「忙」**不含 iowait**；`/proc/loadavg` 在电视上 `Permission denied` ⇒ 用 `procs_running`/`procs_blocked`。
- **取证**：应用日志是**文件不是 logcat**（`DiagLog` 写 `files/logs/cloudcine-YYYY-MM-DD.log`；**mtime 不涨 = 真没做事**）；**★ 真帧率用 SurfaceFlinger 量，别信 HUD**；⛔ LMK 会杀后台应用（电视仅 2.5 GB）⇒ 先 `am kill-all`。
- **打包**：⛔ MSI 条件不能写 `VersionNT >= 1000`（钳在 603）⇒ 用 **`WindowsBuild >= 10240`** + `Installed OR`（**不支持括号**）。⛔ macOS 不许写 `keychain-access-groups`（→ 启动即 SIGKILL）、`app-sandbox` 必须 **`false`**。⚠️ 本机**出不了 Flutter release/profile 包**。

## 测试取向
- 纯函数优先、断言写「为什么重要」。⛔ **每个需求只跑相关单测，不回归全量**（用户 10-04 定）。修并发/竞态 bug **先加测试确认红**再加修复。⚠️ 用户常**边改边跑**，判据 = 红的在不在我改的文件里。
- Android：`./gradlew :app:testDebugUnitTest`。⛔ **并发会话把模块编译改红时**：`rsync` 复制 `android/` 到 `/tmp`，把**他们改过的**文件用 `git show HEAD:` 还原，在那里构建（做法见 HOWTO §3）—— 仓库零改动。
