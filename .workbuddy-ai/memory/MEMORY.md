# 云影（cloudcine）项目长期约定

Flutter 3.29 / Dart 3.7 的 macOS / Android TV 网盘媒体库播放器，对接夸克。
- 本机通用事实（gvm/`NO_PROXY`/沙箱/`ps`→`pgrep`/同文件两条 Edit/Android 构建）见 `~/.workbuddy-ai/MEMORY.md`。
- **理由、实测证据、标识符细节都在 `HOWTO.md`**（`§` 指其章节）；逐日经过在 `YYYY-MM-DD.md`。
- 本文件上限 **80000 字符**（10-04 用户改，原 8000）。细节仍优先下沉到 `HOWTO.md`，但**不必为省字数删红线**。

## 版本控制
- **攒够一小轮就 commit**；`git clean` 先 `-nd` 干跑（untracked 被 `-df` 删掉**救不回**）。
- ⛔ **不代用户 `git add`/`git commit`**（分别授权）。提交前核对 `git diff --cached`：用户中途 `git add` 存过快照时，会**静默提交一个已废弃但能编译的设计**，修法 `git add -A`。
- ⛔ **别对仓库文件跑 `dart format`**；补救 `git show HEAD:<f>`。

## 架构
`core/` 纯工具 · `domain/` 实体+服务+适配器抽象（**不 import Flutter/drift**）· `data/` 夸克/drift/刮削/凭证 · `ui/` Riverpod 组合根 + go_router + 页面。跨层信号放叶子文件。

## 电视分支（§）
`isTvLayout`：android + 逻辑宽≥960（⛔ 判据读 view 宽，页面实得 624，**壳外页实得 960**）。⛔ **页头 `actions` 必须 `Wrap`**；⛔ TV 另一套缓冲（`cache=yes` + 硬解参数，见下节）；⛔ **过扫描内边距只有 `app_shell` 一处**，壳外页（`/work` `/diagnostics` `/auth/qr`）与**播放器覆盖层**自己加；⛔ 播放器遥控器 **↓ 绝不接管**；⛔ **侧栏方向键靠壳层兜底**（候选**只搜侧栏子树**）。→ `§电视（Android TV）分支`。

## Android TV 4K 丢帧（10-04，§，报告见 `docs/AndroidTV-4K-丢帧-夸克对标.md`）
- 根因**不是解码、也不是网络**：真机 `解码丢帧=0 / 显示丢帧 21s 涨 44`，[中继] 零告警。瓶颈是 `mediacodec-copy` 的「拷回 CPU + 上传纹理」。
- ⛔ `hwdec` 必须写成 **`mediacodec,auto-safe`**（逗号=带回退；⛔ 光写 `mediacodec` 失败只剩软解）。
- 判据：起播后读 `hwdec-current`，带 `copy` = 拷贝档（`isCopyHwdec`，⛔ **空串不算**）。
- ⛔ `VideoControllerConfiguration.hwdec` 与 `PlayerBufferConfig.apply` **必须同值**，且**都排在 media_kit `create()` 之前** → Surface 就绪后要再写一次才生效。
- 对标（逆向夸克 TV APK）：夸克用 Apollo(ExoPlayer 分支)/ijkplayer，**MediaCodec 直出 SurfaceView，零拷贝**；云影 mpv 出在 **Flutter 纹理**上，多一层合成。
- ⛔⛔ **10-04 试过「4K 切 fvp」并已全部回退，别再走一遍**（`§HOWTO` 有完整证据，报告见 `docs/AndroidTV-4K-丢帧-夸克对标.md §4.5`）。两轮真机都失败：① 只加 `VideoViewType.platformView` → 用户报「更卡、音画不同步」；② 再加 `tunnel: true`（零拷贝）→ 用户报「**4K 看不到画面，只有声音**」。判据已从路由里删掉（`needsAlternateForResolution` / `highResolutionEngine` 全没了），`main.dart` 的注册范围收回 `['macos']`。
  - 崩溃证据（`logcat -b crash`）：`libmdk.so` 的 `strlen→vfprintf→vsnprintf`（mdk 工作线程）；以及反复出现的 `SurfaceTextureWrapper.release`（FinalizerDaemon）—— 后者是 Flutter 引擎在 `SurfaceProducer` 释放后**二次释放**，**换内核就触发、与 viewType 无关**。
  - ⛔ **mpv 在 Android 上做不到零拷贝，是结构性的**：`media_kit_video-1.3.1/android/.../VideoOutput.java` **写死** `textureRegistry.createSurfaceProducer()`，永远是 Flutter 纹理，没有 platformView 选项。调 mpv 参数没用。
  - ⚠️ **下次要查的第一个假设（未证实）**：fvp 的 tunnel 分支**显式跳过** `maxWidth/maxHeight` 钳制 → `FvpVideoView.setFixedSize` 拿到视频原生 3840×2160，而 Android 显示层只有 1920×1080。先试「platformView + **不开** tunnel + `maxWidth:1920,maxHeight:1080`」。
  - 📌 **面板事实**：`ro.boot.mi.panel_resolution=3840x2160`（65 寸 4K），但 Android 显示层**只有 1920×1080**（`dumpsys display`：`real 1920 x 1080`，唯一 mode 1920×1080@60）。⇒ 应用内渲染最高 1080p，由电视倍线到 4K；**只有 SurfaceView 才可能真 4K 扫描输出**。
  - 4K 现在的取舍只有两条：用 **`super`(810p) 转码档**（同机实测只丢 0~7 帧、流畅、降画质），或接受原画卡顿。

## 资源采样：CPU / 内存 / 磁盘（10-04，§）
`core/diagnostics/resource_probe.dart`：`ResourceProbe`（引擎 `open()` 起、`stop()`/`dispose()` 停，两个引擎各持一个）+ 一整套纯解析函数。**fvp 那条路没有视频探针**（mpv 属性在 mdk 上无对等物），所以这是它唯一的周期性证据。
- ⛔ **周期 10 秒**，**故意不与**视频探针的 21 秒相等：用户报的正是「每 21 秒掉一批帧」，周期相等会**拍频锁定**、把规律整个掩盖（10 与 21 互质）。
- ⛔ **读不到一律留空、整段从日志行消失**，不许退化成 0 ——「未知」写成「空闲」比不写还糟。
- ⛔ 进程 CPU 是**单核口径**（4 核盒子要 400% 才叫满载），日志必须写明「折合 N 核」，否则 48% 被误读成「很闲」。
- ⛔ 系统 CPU 的「忙」**不含 iowait**（iowait 是「在等磁盘」，算进去会让磁盘慢伪装成 CPU 忙）；⛔ `/proc/stat` 只认汇总行 `cpu `，**别用 `cpu0`**。
- ⛔ **`/proc/loadavg` 在目标电视上是 `Permission denied`**（实测连 `ls -l` 都拒），**`/proc/pressure/*` 在 Android 9 上不存在**。替代读数是 `/proc/stat` 里的 `procs_running` / `procs_blocked`（`parseProcStatProcs`，**与系统 CPU 同一个文件、不额外读盘**）。日志里写 `可运行进程=N（4 核，超订 x.xx×）` —— ⛔ **核数必须一起写**，否则 14 在 4 核是 3.5 倍超订、在 16 核是空闲。`阻塞IO进程` 只在 > 0 时写（常态是 0，每拍都写会掩盖异常）。
- ⛔ `/proc/self/stat` 的字段**必须按最后一个 `)` 切**：comm（进程名）允许含空格与括号，按空白 split 会让后面字段整体错位，**且不报错**。
- ⛔ `df` 用正则**从左锚定**、不按列 split（挂载点可含空格）；⛔ 用异步 `Process.run` 而非 `runSync`（别让诊断自己变成卡顿源）。
- macOS 无 `/proc`：内存退回 `ProcessInfo.currentRss`，CPU/负载留空 —— 属**正常**，不是 bug。

## TV 播放器 OSD：贴底 XY 菜单（§）
**照夸克做**：`PlayerTvSheet` 贴底横排，选中行下面铺 chip 条；`↑↓` 换行（循环）、`←→` 挪光标（不循环、**跳过灰掉的**）、**`OK` 才生效**；`←→` 只在**没有 chip 条**的行回调 `onAdjust`。⛔ **菜单开着时不画控制栏**；⛔ 字幕要**抬高**（`_subtitleBottomPadding`）；⛔ `kPlayerTvSheetHeight` 末尾 `+0.8` 是描边算成内边距，删了就溢出。→ `§夸克 TV 播放器的 OSD 实测几何`。

## 侧栏一级导航（10-03）
五项：媒体库 `/library` · **文件夹 `/folders`** · 扫描 · 下载 · 设置；`app_shell._items` 与 `app_router.branches` **必须同序**（判据是下标）。⛔ 文件夹读**网盘实时目录**、媒体库读**本地索引**，两者**并列**；**搜索词各一份**。

## 文件夹模式与局部发现（10-01）
本地索引在这页只做**「已入库」叠加层**。与全盘扫描共用三份唯一实现：`media_entry_classifier.dart`（镜像判定必须在视频判定**之前**）、`work_builder.dart`、`request_throttle.dart`。三条硬约束（做错不报错、只悄悄坏数据）：**绝不清理陈旧记录**、**绝不写续扫游标**、**深度从本次目标算第 0 层**。发现让着扫描（`DiscoveryController.canStart`）。

## 目录视图：三组条目 + 排序 + 直接播 + 多选删除（§）
三组**目录 → 视频 → 其他文件**（组间顺序是**结构**，不随排序变）。⛔ 分组只管排布，**入库判据仍只有 `classifyEntry` 一处**。⛔ 下载取链**复用 `adapter.resolveStream`**（别打 `/file/download`，>50MiB 直接 23018）。⛔ `FolderSortMode`/`ItemSortMode` **各一份设置键**、都在**渲染时**排，**只改显示、不改 `primary`**。视频行**整行可点=播**（未入库走 `playDriveEntry`，**不写库**）。⛔ 多选：`folderSelectionProvider` 键=fid、**换目录清空**、**全选只勾当前可见**。→ `§从 MEMORY.md 下沉`。

## 下载记录与断点续传（v16，§）
表 `download_tasks`（主键 `provider:fileId`）。⛔ `.part` 是断点**唯一真源**；服务端**忽略 Range 回 200 必须从 0 重写**；`parse` 读不懂退 **paused**（退 queued 会一开应用自动开下）。⛔ `downloadQueueProvider` **不能 autoDispose**、`settingsProvider` 用 `listen` 不用 `watch`。角标只数**排队 + 下载中**。多连接 8×2 MiB、writer 顺序落盘。

## Android 产物名与版本号（10-03）
⛔ 产物名由 Flutter 工具链**定死**，改 AGP `outputFileName` 无效；做法：给 `assemble<Mode>` 挂 **finalizer**（⛔ 别 doLast）**复制**（⛔ 不能改名）成 `cloudcine-<versionName>-b<versionCode>-android.apk`。⛔ 报错只剩一个版本号 = **JBR 25 崩了 Kotlin**，指 JDK 21。

## macOS 签名与 entitlements（§）
⛔ 不许写 `keychain-access-groups`（→ **启动即 SIGKILL**）；`app-sandbox` 必须 **`false`**；两份都要 `network.client/server`·`files.user-selected.read-write`；`DebugProfile` 另加 `get-task-allow`。Podfile 与 `RegisterGeneratedPlugins` 的补丁别删。

## 凭证存储（§335）
macOS 走 `EncryptedFileSecretBackend`（⛔ 别再试钥匙串，其余平台 `flutter_secure_storage`）；密钥由 `IOPlatformUUID` 派生（**别掺易变环境值**）。

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

## 播放器（两份实现，别只改一个）
macOS 独立窗口 `player_window_app.dart` + 内置页 `player_page.dart`。**键位表、菜单、偏好还原、换流提示、hover 唤醒都要改两处**；⛔ 独立窗口要 `mouseTrackingMode=.always` + `onEnter`；菜单统一走 `anchored_menu.dart`。
缓冲条共用 `buffered_slider.dart`（**0..1 比例**，⛔ `demuxer-cache-time` 是**绝对时间戳**）。音轨过 `TrackLabels.realTracks`；搜索走 `subtitle_query.dart`（⛔ 别拿 `displayTitle`）；缩略图走 `fetchThumbnail`。
**音效 ≠ 音轨**：⛔ 无可用 Avfilter、**`af set` 返回值不能当依据**；⛔ macOS `audio-spdif` 直通必卡死。
**逐影片偏好**表 `playback_prefs`（v14，同 `groupKey` 非空最新、写整条覆盖；音量/倍速仍全局）。**进度两列** `resumePositionMs`（起播，看完清）vs `maxPositionMs`（显示，v15，只增不减）⛔ 别合并。
**DV P5**：⛔ macOS libmpv **架构上做不到**（`gpu-next` 零命中）→ 调 mpv 参数无用。唯一出路 **fvp/libmdk**：**只 DV 片走 fvp**、TV 不动、音效置灰。契约 `PlaybackEngine` + 两份实现在 `playback_engine.dart`、`data/playback/`；选引擎走 `playback_engine_router.dart`（**开播前探头部字节**）；`main.dart` 的 `fvp.registerWith` **必须先于分窗**；画面走 `playback_surface.dart`。⚠️ `registerWith` 的 platforms 与「DV 只在 macOS」两处判据**必须一致**。

## 媒体库三轴（不能互推/合并，§）
`MediaKind`（结构，只看文件名 `SxxExx`）· `MediaCategory`（语义，落库 `media_works.category`，空串≠other）·「最近播放」（视图，`LibraryFilter.playedOnly`，与 `category` 互斥、与 `query` 叠加）。`MediaCategoryGuesser.guess` 序：TMDB genres→目录路径→片名+文件名→结构兜底。
**交互**：`PlayTarget.resolve` 三档；`playItem()` 唯一起播入口。⛔ 路径归一化只在 `core/utils/drive_paths.dart`。→ `§媒体库三轴的「交互」细节`。

## 季 / 部 / 跨目录归一（§）
`MediaItem`+`part/partLabel`（v9）；`MediaWork`+`seasonCount`（v10）+`mergedInto`（v11）。层级**不落库**（现算）：**季在外、部在内**，某层**少于 2 个选项不画**。`seasonCount` 是 `COUNT(DISTINCT)` **不能相加**。
- **目录名当系列名**：判定单元是**目录不是文件**（`DirectoryTitle`），**四处调用点都要传 `dirPath`**。
- 自动归一：只认 `onlineId` 相同 + `source==online` + kind 相同；**本地片名相似度绝不参与**。`autoMergeByOnlineId` 默认开。
- 手动归一「合并到…」（`MergeWorkDialog`，**无刮削门槛**）：留下**选中的那一部**；撤销=目标页「拆开」。
- ⛔ **归一 = 打标记**：不删行、不改 `group_key`；滤 `merged_into IS NULL`、`itemsForWork` 取并集。**不许链式**。⚠️ `mergeWorkForUpsert` 里**无条件取旧值**；搜索穿透折叠内层表**必须起别名**。⛔ `_unionStats` 别改回 JOIN 里的 `OR`。→ `§从 MEMORY.md 下沉`。

## 筛选面板（§）
⛔ **已刮削判据 = `source==online`**，不是 `isScraped`；算进 `hasExtra`/`clearExtra` 且**进 `_facetScope`**。⛔ `==`/`hashCode` 按**集合内容**比（`setEquals`+`Object.hashAllUnordered`）。

## 封面与刮削（§）
⛔ `posterFaceX` 与 `posterUrl` **必须成对**。熔断只计**网络层**失败。TMDB/豆瓣响应形状**≠夸克信封**。**TMDB `/search/*` 必须过 `ScrapeMatch` 闸门**。⛔ **手动刮削通道**三条交互不许改；**「自定义」** `customizeWork` **整行写、不过 merge**。**候选链** `ScrapeQuery.fallbacks` = 文件名 → 目录名逐级向上、串行命中即停，⛔ 本地兜底只用主查询、⛔ 两个调用点都要传 `dirPath`。⚠️ 待办 `DirectoryTitle._clean` 清年份/画质标记（⛔ 别用 `_parseDotted`）。

## 取链：转码档现在是 HLS（10-04，§）
⛔ 夸克把 `video_list[].video_info.url` 从签名直链换成了 `media.m3u8`。鉴权靠 `play/info` 下发的 **`Video-Auth`** cookie（必须进 `knownCookieNames`，否则分片 **404**）。⛔ **HLS 必须走本地中继**：本机 `http_proxy` 会让 ffmpeg 选**未列白名单**的 `httpproxy` → `avformat_open_input() failed`。⛔ 该故障**护栏会放行** → 诊断触发必须**独立于** `isRealEnd`。⛔ **TV 的 mpv 只开 `error` 级**（内置页）→ `Failed to open 127.0.0.1/sN` 只靠中继日志还原。

## 测试取向（§）
纯函数优先；断言写「为什么重要」。⛔ **每个需求只跑相关单测，不回归全量**（用户 10-04 定的）。修并发/竞态 bug **先加测试确认红**再加修复。⚠️ 用户常**边改边跑**，判据=红的在不在我改的文件里。其余见 `§测试取向`。
