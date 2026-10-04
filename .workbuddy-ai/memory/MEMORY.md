# 云影（cloudcine）项目长期约定

Flutter 3.29 / Dart 3.7 的 macOS / Android TV 网盘媒体库播放器，对接夸克。
- 本机通用事实（gvm/`NO_PROXY`/沙箱/`ps`→`pgrep`/同文件两条 Edit/Android 构建）见 `~/.workbuddy-ai/MEMORY.md`。
- **理由、实测证据、标识符细节都在 `HOWTO.md`**（`§` 指其章节）；逐日经过在 `YYYY-MM-DD.md`。
- ⚠️ **本文件贴 8000 字符注入上限**：加内容前先 `wc -m`；**能下沉到 `HOWTO.md` 的就下沉**，这里只留红线与指针。

## 版本控制
- **攒够一小轮就 commit**；`git clean` 先 `-nd` 干跑（untracked 被 `-df` 删掉**救不回**）。
- ⛔ **不代用户 `git add`/`git commit`**（分别授权）。提交前核对 `git diff --cached`：用户中途 `git add` 存过快照时，会**静默提交一个已废弃但能编译的设计**，修法 `git add -A`。
- ⛔ **别对仓库文件跑 `dart format`**；补救 `git show HEAD:<f>`。

## 架构
`core/` 纯工具 · `domain/` 实体+服务+适配器抽象（**不 import Flutter/drift**）· `data/` 夸克/drift/刮削/凭证 · `ui/` Riverpod 组合根 + go_router + 页面。跨层信号放叶子文件。

## 电视分支（§）
TV 走独立布局分支（`isTvLayout`：android，逻辑宽≥960；⛔ 判据读 view 宽，页面实得 624，**壳外页实得 960**）。⛔ **页头 `actions` 必须 `Wrap`**（`Row` 实测溢出，Release 静默裁掉）；⛔ TV 另一套缓冲（**`cache=yes`** + **`hwdec=auto-safe`**）；⛔ **过扫描内边距全项目只有 `app_shell` 一处**，壳外页（`/work` `/diagnostics` `/auth/qr`）与**播放器覆盖层**要自己加；⛔ 播放器遥控器 **↓ 绝不接管**（没菜单键的盒子唯一进面板的路）；⛔ **侧栏方向键靠壳层兜底**（⛔ 候选**只搜侧栏子树**）；⛔ 侧栏 540 下余量仅 **23px**。见 `HOWTO.md §电视（Android TV）分支`。

## 侧栏一级导航（10-03）
五项：媒体库 `/library` · **文件夹 `/folders`** · 扫描 · 下载 · 设置；`app_shell` 的 `_items` 与 `app_router` 的 `branches` **必须同序**（判据是下标）。⛔ 文件夹与媒体库**并列**：前者读**网盘实时目录**（`driveListingProvider`），后者读**本地索引**；**搜索词各一份**（SQL vs 当前层）。

## 文件夹模式与局部发现（10-01）
- 本地索引在这一页只做**「已入库」叠加层**（`folderTreeProvider`/`indexedFileIdsProvider`）。
- 局部发现与全盘扫描共用三份唯一实现：`media_entry_classifier.dart`（镜像判定必须在视频判定**之前**）、`work_builder.dart`、`request_throttle.dart`。
- 三条硬约束（做错不报错、只悄悄坏数据）：**绝不清理陈旧记录**、**绝不写续扫游标**、**深度从本次目标算第 0 层**。发现让着扫描（`DiscoveryController.canStart`）。

## 目录视图：三组条目 + 排序 + 直接播 + 多选删除（10-03，§）
一层列**全部条目**，三组**目录 → 视频 → 其他文件**（组间顺序是**结构**，不随排序变）。⛔ 分组只管「怎么排、行上给什么动作」，**入库判据仍只有 `classifyEntry` 一处**。
- 下载取链**复用 `adapter.resolveStream`**（⛔ 别打 `/file/download`，>50MiB 直接 23018）；`autoUncompress=false` + `Accept-Encoding: identity` + `findProxy=DIRECT`。
- 排序：`FolderSortMode`（文件夹页）与 `ItemSortMode`（详情页，**默认**修改时间倒序）**各一份设置键**，都在**渲染时**排（⛔ 前者别进 `driveListingProvider`）。⛔ **排序只改显示、不改 `primary`**。
- 视频行**整行可点=播**（下载是右侧独立按钮）：未入库走 `playDriveEntry`（**不写库**，与发现共用 `parseTransientMedia`）。`local_stream_relay.dart` **只服务原画**（HLS 排除）。
- **多选删除**：`folderSelectionProvider`（键=fid）；⛔ **换目录清空**、**全选只勾当前可见**（`displayEntries` 是列表与全选**唯一**共用定义）。`DriveCleanupController`：分块 100、凭证失效/断网**中止后续批次**并把没发出去的算失败（`rateLimited` 不中止）、删成功的**连同索引**清；⛔ **失败的批次不清索引**。

## 下载记录与断点续传（v16，§）
表 `download_tasks`（主键 `provider:fileId`）。⛔ 最易犯三条：`.part` 是断点**唯一真源**；服务端**忽略 Range 回 200 必须从 0 重写**；`parse` 读不懂退 **paused**（退 queued 会一开应用自动开下）。⛔ `downloadQueueProvider` **不能 autoDispose**、`settingsProvider` 用 `listen` 不用 `watch`。角标只数**排队 + 下载中**。**多连接分块**：8×2 MiB、writer 顺序落盘保 `.part` 连续前缀；>8MiB+`supportsRange` 才触发，回 200→降级单连接。

## Android 产物名与版本号（10-03）
⛔ `flutter build apk` 的产物名由 Flutter 工具链**定死**，**改 AGP `outputFileName` 无效**（只多一个副本；`flutter install` 仍按精确名 `app-<mode>.apk` 找）。做法：`build.gradle.kts` 给 `assemble<Mode>` 挂 **finalizer**（⛔ 别用 doLast），**复制**（⛔ 不能改名）成 `cloudcine-<versionName>-b<versionCode>-android.apk`。机制见 `HOWTO.md §产物名与版本号`。

## macOS 签名与 entitlements（§）
⛔ 不许写 `keychain-access-groups`（→ **启动即 SIGKILL**）；`app-sandbox` 必须 **`false`**；两份都要 `network.client/server`·`files.user-selected.read-write`；`DebugProfile` 另加 `get-task-allow`（缺了 `flutter run` 卡住）。Podfile 与 `RegisterGeneratedPlugins` 的补丁别删。

## 凭证存储：macOS **不用钥匙串**（§335）
其余平台走 `flutter_secure_storage`；**macOS 走 `EncryptedFileSecretBackend`**。⛔ 别再试钥匙串（ACL 只认创建条目的那份签名，ad-hoc 重建即变 → 每次启动弹密码框）。⚠️ 密钥由 `IOPlatformUUID` 派生（**别掺易变环境值**）。

## 不可动摇的设计约束
1. 本地解析永远可用，在线刮削是增强；`LocalFilenameScraper` 排 `ScraperPipeline` 末位。
2. 原画只认 `/file/audioplay` 的 `audio_url`；`play/info` 的 `audio_list` 是纯音频流，当原画会**有声音没画面不报错**（`audioOnlyKeys` 别删）。
3. `ScanPolicy.audioOnly` 默认 `true`；视频库必须显式 `false`，否则扫完一条不剩且不报错。
4. 直链必须带 Cookie（缺则 412）；`__puus` 每响应轮换回填。`PosterCache.headersFor(url)` 每次现取。
5. 字幕字节一律走 `decodeTextBytes`（先 UTF-8 后 GBK）；扫描期只写引用、不下载正文。
6. 起播位置只走 `Media(start:)` 且每次显式给（不续播给 `Duration.zero`），入口 `PlaybackMedia.build`；`seek` 只在播放中跳转。
7. 刮削默认不跟扫描跑（`autoScrapeOnScan` 默认 `false`）；`ScraperPipeline` 最后一个兜底、前面竞速。
8. 落库接 `PlaybackController.onPositionTick` 回调（组合根），不暴露 `Player`。
9. 夸克上传收尾**两步**、备份同步比 `libraryModifiedAt`，各有空守卫；`includeSettings`/`restoreSettings` 是**空开关**。
10. **TV 上 `SelectableText` 是焦点陷阱** → 用 `widgets/tv_text.dart` 的 `TvSelectableText`。

## 播放器（两份实现，别只改一个）
macOS 点播放走**独立窗口** `player_window_app.dart`，内置页 `player_page.dart` 是另一份。**键位表、菜单、偏好还原、换流提示、hover 唤醒都要改两处**；⛔ 独立窗口要 `mouseTrackingMode=.always` + `onEnter`；菜单统一走 `anchored_menu.dart`。
缓冲条共用 `buffered_slider.dart`（**0..1 比例**，⛔ `demuxer-cache-time` 是**绝对时间戳**、时长未知返 null）。音轨过 `TrackLabels.realTracks`、选中态认 `player.stream.track`；搜索走 `subtitle_query.dart`（⛔ 别拿 `displayTitle`）；缩略图走 `fetchThumbnail`→主窗口 `PosterCache`。
**音效 ≠ 音轨**：⛔ 无可用 Avfilter、**`af set` 返回值不能当依据**；⛔ **macOS `audio-spdif` 直通必卡死→别下发**。
**逐影片偏好**表 `playback_prefs`（**v14**，同 `groupKey` 非空最新、写整条覆盖；音量/倍速仍全局）。**进度两列** `resumePositionMs`（起播，看完清）vs `maxPositionMs`（显示，**v15**，只增不减）⛔ 别合并。
**DV P5**：macOS libmpv 做不到；mdk 内核 PoC 已验。**按需路由**：只 DV 片走 fvp，TV 不动，音效置灰。内核已抽象成 `PlaybackEngine`，两份实现在 `lib/data/playback/`。
→ 标识符索引、引擎契约的坑见 `HOWTO.md §标识符索引：播放器与刮削`、`§引擎契约的标识符与两条硬约束`。

## 媒体库三轴（不能互推/合并，§）
- `MediaKind`（结构）：只看文件名 `SxxExx`。
- `MediaCategory`（语义）：落库 `media_works.category`；空串≠other。`MediaCategoryGuesser.guess` 序：TMDB genres→目录路径→片名+文件名→结构兜底；ASCII 关键词卡词边界。
- 「最近播放」（视图）：只看播过的、不落库（`LibraryFilter.playedOnly`）；与 `category` 互斥、与 `query` 叠加。
**交互**：`PlayTarget.resolve` ①最近播过且留续播点→那集 ②播过但续播点清→仍是那集 ③全新→第一集；排掉 `isSampleOrExtra`。`playItem()` 唯一起播入口。`mergeWorkForUpsert`：`category` 取新值但**先按 `effectiveGenres` 折算**；手动标记的行整列不动；`posterUrl` 永不为空；`source=manual` 只被**显式**刮削覆盖。**路径**归一化只在 `core/utils/drive_paths.dart`（`/电影` 与 `/电影/` 变两键→静默筛不到）；`dirPath` 带尾斜杠、内部不带。

## 季 / 部 / 跨目录归一（§）
`MediaItem` + **`part/partLabel`**（v9）；`MediaWork` + **`seasonCount`**（v10）+ **`mergedInto`**（v11）。层级**不落库**（现算）：**季在外、部在内**，某层**少于 2 个选项不画**。卡片三个计数是**并集**，`seasonCount` 是 `COUNT(DISTINCT)` **不能相加**。
- **目录名当系列名**：判定单元是**目录不是文件**（`DirectoryTitle`），**四处调用点都要传 `dirPath`**（§）。
- 自动归一 `work_merge_planner.dart`：**只认 `onlineId` 相同 + `source==online` + kind 相同**，`manual` 不参与；目标=itemCount 最大→firstSeenAt 最早→key 升序。**本地片名相似度绝不参与**。`autoMergeByOnlineId` **默认开**（`!= 'false'`）。
- **手动归一**「合并到…」（`MergeWorkDialog`，**无刮削门槛**）：留下**选中的那一部**；不能合→按钮灰+原因（自己 / 目标已别名 / **源自己还折着别人**）；撤销=目标页「拆开」。
- ⛔ **归一 = 打标记**：不删行、不改 `group_key`；列表/角标滤 `merged_into IS NULL`、`itemsForWork` 取并集、撤销=清标记。**不许链式**。⚠️ `mergeWorkForUpsert` 里**无条件取旧值**（照抄=重扫拆开）；搜索穿透折叠内层表**必须起别名**。⛔ `_unionStats` 别改回 JOIN 里的 `OR`（§ 有实测数字）。

## 筛选面板（§）
⛔ **已刮削判据 = `source==online`**，不是 `isScraped`（含 `manual`，而「自定义」恰恰清掉了在线信息）；算进 `hasExtra`/`clearExtra` 且**进 `_facetScope`**。⛔ `==`/`hashCode` 必须按**集合内容**比（`setEquals`+`Object.hashAllUnordered`）——Set 默认引用相等会让 Riverpod 误判「没变」。

## 封面与刮削（§）
`posterFaceX` 与 `posterUrl` **必须成对**；`keptWidth` 用 `LayoutBuilder` 现算。熔断只计**网络层**失败；TMDB/豆瓣响应形状**≠夸克信封**（照夸克信封读**静默得空**）；**TMDB `/search/*` 必须过 `ScrapeMatch` 闸门**。**手动刮削通道**三条交互与「不过闸门」不许改。**「自定义」** `customizeWork` **整行写、不过 merge**。**候选链** `ScrapeQuery.fallbacks` = 文件名 → 目录名逐级向上，串行命中即停，⛔ **本地兜底只用主查询**、⛔ 两个调用点都要传 `dirPath`。**两条解析层守卫**只影响「目录名能否顶掉文件名」。⚠️ 待办 `DirectoryTitle._clean` 清年份/画质标记（⛔ 别用 `_parseDotted`）。→ 守卫与闸门细节见 `HOWTO.md §封面与刮削`。

## 取链：转码档现在是 HLS（10-04，§）
⛔ 夸克把 `play/info` 的 `video_list[].video_info.url` 从**签名直链**换成了 `media.m3u8`（10-03 还是直链）。**不是我们改的**：`_firstUrl` 只照抄服务端给的 `url`。
- 转码档鉴权靠 `play/info` 下发的 **`Video-Auth`** cookie（原画走 `audioplay` 签名直链，不下发它）→ 必须在 `knownCookieNames` 里，否则取分片 **404**：**只有声音没画面、几秒 EOF**。
- ⛔ 该故障**护栏会放行**（位置 3~7s + 报过视频尺寸）→ 诊断触发必须**独立于** `isRealEnd`，否则证据永远拿不到。

## 测试取向（§）
纯函数优先；断言写「为什么重要」。⛔ **每个需求只跑相关单测，不回归全量**（用户 10-04 定的）。
- ⚠️ **修并发/竞态 bug：先加测试跑一遍确认确实红，再加修复**。
- ⚠️ 用户常**边改边跑**，全量冒 1~2 红例是常态。**判据=红的在不在我改的文件里**（文件名+mtime），正在改的**别碰**。
- 其余（注入时钟、`debugDefaultTargetPlatformOverride`、`find.byType(FilledButton)` 的坑、`build_runner`）见 `HOWTO.md §测试取向`。
