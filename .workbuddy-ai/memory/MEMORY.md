# 云影（cloudcine）长期约定

**两个互不引用的工程**：`android/` = ★ Android / Android TV 正式实现（原生 Kotlin，`com.cloudcine.tv`）；`lib/ macos/ windows/ pubspec.yaml` = Flutter PC 端。
- 细节下沉：**理由/实测证据 → `HOWTO.md`**（PC 端 §PC-1~8，**Android 端 §AND-1**）；逐日经过 → `YYYY-MM-DD.md`；Android 产品文档 → `android/README.md`。本文件只留**红线 + 标识符**。
- ⚠️ 本文件**超约 1.2 万字节即被注入截断** ⇒ 加新条目**先删旧的**，目标 ≤ 11000 字节；**新细节写进 HOWTO，别写这里**。
- 本机通用事实（gvm / `NO_PROXY` / 沙箱 / `ps`→`pgrep` / `git push` 要 `HOME` / **同文件两条 Edit 互相覆盖**）见 `~/.workbuddy-ai/MEMORY.md`。

## 仓库结构
- Android = 原生 Kotlin 独立工程；Flutter 只 PC 端；范围「只关心 `android/`」。Flutter 的 Android 宿主已整体移出（备份 `~/.workbuddy-ai/backups/cloudcine-flutter-android-20261006-173700/`）；`git mv prototype/cloudcine android`。
- ⛔ 旧记忆里一切「Flutter 在 Android 上」的结论**全部失效**（fvp/ExoPlayer 路由、media_kit 零拷贝、TvOsdView 挂 FlutterView、Dart 主 isolate 中继、`hwdec`、`platformView`、`tunnel:true`、DV P5）→ HOWTO §PC-1。
- ⛔ 根 `tool/adb_tv.sh` / `tool/build_android.sh` **已死** ⇒ 用 `android/tool/adb_tv.sh`。⛔ `packages/video_player_android` 仍在仓库根（pubspec path 依赖）。⛔ `applicationId` / `versionCode=1` 别改（换包名 = 丢磁盘缓存）。

## 版本控制
- 攒够一小轮就 commit；`git clean` 先 `-nd` 干跑（`-df` 删 untracked 救不回）。
- ⛔ 不代用户 `git add`/`git commit`。提交前核对 `git diff --cached`（用户中途 `git add` 过快照会**静默提交一个已废弃但能编译的设计**，修法 `git add -A`）。
- ⛔ 别对仓库文件跑 `dart format`；补救 `git show HEAD:<f>`。

## ★★ 媒体库数据结构 = 跨端同步的唯一契约（细节 → HOWTO §1/§2/§AND-1）
- `cloudcine.sqlite`（PC 路径 `getApplicationSupportDirectory()/`）：drift `schemaVersion = 16` → SQLite `user_version`；7 表 `media_items`(PK `id`)·`media_works`(PK `key`)·`subtitle_refs`·`scan_cursors`·`settings`·`playback_prefs`·`download_tasks`（列名 = Dart 字段 snake_case，权威 `lib/data/db/tables.dart`）。
- ⛔ 主键全是**文本**（`provider:fileId`）；⛔ `media_works.category` 默认**空串**（= 没判定过），`other` 是判定结果；⛔ `resolution`/`container`/`download_tasks.status` 存**枚举名字符串**，`flags`/`genres` 是 **JSON 数组字符串**（默认 `'[]'`），布尔 0/1，时间列 **Unix 秒**；迁移 v1→v16 见 `app_database.dart onUpgrade`（**有回填的只有 v6/v7/v10/v15**）。
- 备份包 `.ccbak`（`library_backup_service.dart`）：全大端 `['CCBK'][manifestLen][manifest][dbLen][db][posters]`，⛔ **不是 ZIP**；默认目录 `云影备份`；文件名**必须带时间戳**（同名覆盖先删后传）。
- ★★ 同步判据是 **`libraryModifiedAt`**（**不是** `createdAt`）；空库 `effectiveModifiedAt` 退化成 `createdAt`（**不是 0**）；库变更口径 = `MAX(media_works.updated_at)` ∪ `MAX(media_items.first_seen_at)` ∪ `MAX(media_items.last_played_at)`；本地空库让远程赢、远程空备份绝不覆盖本地；冲突 = 不同设备且差 < 60s。⛔ 不备份网盘凭证；⛔ `includeSettings`/`restoreSettings` 是**空开关**。

## ★★ Android 端红线（→ HOWTO §AND-1）
- ⛔⛔ 电视上 **`AbsListView.OnItemClickListener` 按 OK 不触发** ⇒ 必须在 `dispatchKeyEvent` 自管 OK，**DOWN 与 UP 都要吞**（只吞 DOWN = 一按播两遍）。
- ⛔ `applyWorks` 无条件 `requestFocus()` = 一级导航「点不动」；⛔ **光标态与生效态分离**（←→ 只移 `navIndex`，OK 才 `applyTab()`）。
- ★ `PlayTarget.resolve`（取片：续播点 → 看完仍播那集 → 第一条；先滤花絮）、`PosterNaming`（海报名 `{sanitize(key)}_{FNV-1a32(url) 8位}.jpg` 现算）、分类口径 `(category IS NULL OR category='')`、`genres` 用 `LIKE '%"动画"%'`、分面角标不含自身维度 —— 判据全在 HOWTO §AND-1。
- ★★ 深色 UI 的层次靠**实心面明度**，不靠描边（用户两次点名「线框不高级」）：选中态 = 实心圆角块 + 左侧 4dp 竖条（`MenuRow.kt`）；⛔ 导航带不画整体贯通外框。
- ★★ 播放器 OSD：画质 chip **只放短名**（`原画`/`4K`/`超清`/`高清`/`标清`/`流畅`，来自 `PanApi.tierLabel`）；分辨率/码率/需带宽改走 `Log.i("CloudCine","画质档位：…")`；chip 有 `maxWidth = MAX_CHIP_W`(160dp) + `ellipsize`，防超长档位 id 撑破面板。
- `library/`：`LibrarySchema` = 唯一真源（7 条 DDL 与 Dart 逐字一致，`LibrarySchemaTest` 守着）；`LibraryDb` 只补表补列、⛔ **不做 v1→v16 迁移**、补列必须 `col.copy(notNull = false)`、⛔ **不用 WAL**（`journal_mode=DELETE`）；`LibraryItem` 必须带 `dirId`。
- `pan/`：`PanHttp`（`HttpURLConnection`，不引 OkHttp）/`PanApi`/`OssAuth`/`QrLogin`（业务码读 `bizCode`）/`CredStore`/`Bg`。⛔ 速率用 `CountingDataSource` 数字节，不用 `onBandwidthEstimate`；⛔ 目录判定只认 `dir` 布尔位（`file_type` `0`=目录、`1`=文件）。
- `TvOsdView` 挂 `android.R.id.content` 之上；⛔ 回调只回传**行下标** ⇒ 按 `Row.id` 分派。⛔ `SeekPlan`：松手才 `seekTo`；兜底窗口 800 ms 必须大于自动重复间隔。
- ⛔ `UI fps` 不可用于比较（`StatsOverlay` 自己重排自己）；⛔ JVM 单测里 `org.json`/`android.util.Base64` 是空壳 ⇒ 用 `MiniJson`/`OssAuth.base64`；⛔ 长串断言先钉长度（`ComparisonCompactor` 只留 20 字符）。
- 工程约定：minSdk 21 / targetSdk 34 / compileSdk 36 / Media3 1.5.1；⛔ 不引 OkHttp / media3-ui / AppCompat / Material / RecyclerView；`Bg` 不支持 lambda 单参重载。
- 构建：Gradle 8.10.2 / AGP 8.7.0 / Kotlin 2.1.0；**`JAVA_HOME` 用 JDK 21**（`/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home`；默认 `jdk-17.0.2.jdk` 是 x86 壳 ⇒ `Bad CPU type in executable`）。

## ★★ 4K 卡顿的真因：播错了档位（`tool/quark_probe.py` 实测）
`黑亚当 2160p`（21.9 GiB）所需带宽：原画 **3.00 MB/s** · `4k` **0.63** · `super` 0.14 · `high` 0.09。
- ★ 夸克自己的默认档是 `super`，云影默认播**原画** ⇒ 单连接喂不动 ⇒ 8 连接中继 ⇒ 主线程饿死。**不是解码、不是渲染面、不是 OSD 画法**。⇒ 治本：默认播转码档（≥`4k`，Android 走 `probeThroughput` → `chooseQuality`，留 30% 余量）。逐档读数 → HOWTO §PC-1。

### 直链 Cookie 规则（★ 极易踩）
带 `__puus`（新旧都行）→ **206**；有 `__pus` 等会话 Cookie 但缺 `__puus` → **412**；完全不带 → **206** ⇒「**要么不带，要么带全**」。`__puus` 在**每个**响应里轮换下发（PC `quark_adapter.dart:1285` / Android `PanApi.absorbCookies`）。
- ⛔ `batch/file/play/info` **必须带 `pr=ucpro&fr=pc`**（漏了回 `401 code=31001`）。⚠️ `hls_type` 实测 `none` ⇒ 转码档是普通 MP4。⛔ `useCaches = false` 不能省；⛔ 解析 `video_list` **必须跳过 `audio_list`**（否则有声音、进度条在走、**没画面、不报错**）。
- ⛔ 上传收尾是**两步**：OSS `CompleteMultipartUpload`（带 `x-oss-callback`）→ `file/upload/finish`（body 只有 `task_id`+`obj_key`）。签名串/XML/Base64 全在 `pan/OssAuth.kt`（纯函数，单测覆盖）。

## Flutter PC 端红线（索引；理由与判据 → HOWTO §PC-2~8）
> 分层：`core/` 纯工具 · `domain/` 实体+服务+适配器抽象（**不 import Flutter/drift**）· `data/` 夸克/drift/刮削/凭证 · `ui/` Riverpod + go_router。
- 中继 `data/stream/local_stream_relay.dart`：无 `Isolate`/`compute`；`core/utils/http_range.dart` = `sealed class RangeRequest`：⛔ 起点越界必须回 **416**（别与「不知道流多长」→200 合并）；⛔ `chunkSize` 别放大（2→8 MiB ⇒ 零成功播放）。
- 三轴不能互推/合并：`MediaKind`（只看文件名 `SxxExx`）· `MediaCategory`（落 `category`）·「最近播放」（`playedOnly`，与 `category` 互斥）；层级**不落库**（<2 个选项不画）；⛔ 归一 = `mergedInto` 打标记（不删行/不许链式）；⛔ 目录名当系列名（四处调用点都要传 `dirPath`）；⛔「已刮削」= `source==online`；⛔ `posterFaceX` 与 `posterUrl` **成对**；⛔ 字幕走 `decodeTextBytes`（先 UTF-8 后 GBK）。
- 播放器：⛔ 两份实现别只改一个（`player_window_app.dart` + `player_page.dart`）；⛔ 起播只走 `Media(start:)`；⛔ 进度两列别合并（`resumePositionMs` vs `maxPositionMs`）；★ 音效 ≠ 音轨；⛔ macOS `audio-spdif` 直通必卡死 ⇒ `passthroughAvailable == false`。
- 导航/下载：⛔ `app_shell._items` 与 `app_router.branches` **必须同序**（判据是**下标**）；⛔ 入库判据只有 `classifyEntry`；⛔ 下载复用 `adapter.resolveStream`（>50MiB 打 `/file/download` 直接 23018）；⛔ `.part` 是断点**唯一真源**；文件夹模式只做「已入库」叠加层（⛔ 绝不清理陈旧记录、绝不写续扫游标）。
- TV：`isTvLayout` = android + 逻辑宽≥960（⛔ 读 **view 宽**）；⛔ 页头 `actions` 必须 `Wrap`；⛔ 遥控器 **↓ 绝不接管**；⛔ `SelectableText` 是焦点陷阱 → `TvSelectableText`；⛔ 播放页 OSD 卡顿 = `bufferEnd` 没节流 + `SubtitleViewConfiguration` 无 `operator ==` + `kDebugOverlayEnabled` 硬编码。

## 运维 / 打包 / 测试（判据 → HOWTO §PC-8、§3）
- 采样：⛔ 周期 **10 秒**（不与探针 21 秒相等 ⇒ **拍频锁定**）；**读不到一律留空**；⛔ 进程 CPU 是**单核口径**；`/proc/loadavg` 在电视上 `Permission denied` ⇒ 用 `procs_running`/`procs_blocked`。取证：应用日志是**文件**（`DiagLog` 写 `files/logs/cloudcine-YYYY-MM-DD.log`，**mtime 不涨 = 真没做事**）；★ 真帧率用 SurfaceFlinger 量。
- 打包：⛔ MSI 条件不能写 `VersionNT >= 1000`（钳在 603）⇒ 用 `WindowsBuild >= 10240` + `Installed OR`（**不支持括号**）；⛔ macOS 不许写 `keychain-access-groups`、`app-sandbox` 必须 **`false`**；⚠️ 本机**出不了 Flutter release 包**。
- 测试：纯函数优先、断言写「为什么重要」；⛔ **每个需求只跑相关单测，不回归全量**（10-04 定）；修并发/竞态 bug **先加测试确认红**。Android 跑 `./gradlew :app:testDebugUnitTest`（JDK 21）；⛔ 模块编译被并发会话改红时 rsync 到 `/tmp` + `git show HEAD:` 还原（HOWTO §3）。
- 电视真机：`MiTV-MFTP0`，Android 28，1920×1080，`192.168.5.169:5555`；装机/日志/按键/截图一律走 `android/tool/adb_tv.sh`。
