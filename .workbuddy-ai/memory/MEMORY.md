# 云影（cloudcine）项目长期约定

Flutter 3.29 / Dart 3.7 的 macOS / Android TV 网盘媒体库播放器，对接夸克。
- 本机通用事实（gvm/代理/沙箱/`ps` 改 `pgrep`/同文件不能同消息发两个 Edit）见 `~/.workbuddy-ai/MEMORY.md`。
- **理由与实测证据在 `HOWTO.md`**（`§` 指其章节）；逐日经过在 `YYYY-MM-DD.md`。
- ⚠️ **本文件贴注入上限（8000 字符）**：加内容前先 `wc -m` 并**等量删旧**；细节能指向 `§` 的**不进本文件**。

## 版本控制
- **攒够一小轮就 commit**；`git clean` 前先 `-nd` 干跑 —— untracked 被 `-df` 删掉**永久救不回**。
- ⛔ **不要代用户 `git add` / `git commit`** —— 暂存与提交需**分别**授权。
- ⚠️ 提交前核对**索引 vs 工作区**：用户会中途自己 `git add` 存快照，之后我们继续改，索引停在旧状态，而 `git commit` 提交的是索引 → 静默提交一个已废弃但能编译的设计。`git diff` 看不出，要 `git diff --cached`；修法 `git add -A`。
- ⛔ **别对仓库文件跑 `dart format`**（5 处→60+ hunk）；补救：`git show HEAD:<f>` 取回原版。

## 架构
`core/` 纯工具 · `domain/` 实体+服务+适配器抽象（**不 import Flutter/drift**）· `data/` 夸克/HTTP/drift/刮削/凭证 · `ui/` Riverpod 组合根 + go_router + 页面。跨层信号放叶子文件，**别让组合根 invalidate feature provider**。

## 文件夹模式与局部发现（2026-10-01）
- 文件夹视图的数据源是**网盘实时目录**（`driveListingProvider` 按 `DriveCrumb` 逐层列），**不是**已扫描的媒体库；本地索引退居「已入库」叠加。
- 局部发现与全盘扫描共用三份唯一实现：`media_entry_classifier.dart`（镜像判定必须在视频判定**之前**）、`work_builder.dart`、`request_throttle.dart`。
- 三条硬约束（做错不报错，只表现为数据悄悄坏掉）：**绝不清理陈旧记录**、**绝不写续扫游标**、**深度从本次目标算第 0 层**。
- 两条入口共用 QPS：发现让着扫描（`DiscoveryController.canStart` 看 `scanController.running`），`MediaDiscoveryService._active` 防重入。

## macOS 签名与 entitlements（§254 §275）
- ⛔ 两份 entitlements 都不许写 `keychain-access-groups`：受限能力项，ad-hoc 下 taskgated 判签名无效 → **启动即 SIGKILL**（崩溃报告无栈）。
- `app-sandbox` 必须 **`false`**。两份都要 `network.client`·`network.server`·`files.user-selected.read-only`；`DebugProfile` 另加 `get-task-allow`（缺了 `flutter run` 卡住、无窗口）。
- 部署目标 10.15；Podfile `post_install` 逐 target 覆盖；两段补丁别删：`cloudcine_fix_media_kit_symlinks`、`FileUtils.rm_rf`。⚠️ `pod install` 前设 `LANG/LC_ALL=en_US.UTF-8`（路径含中文）。`MainFlutterWindow.swift` 的 `setOnWindowCreatedCallback { RegisterGeneratedPlugins }` 别删，否则子窗口插件全 `MissingPluginException`。

## 凭证存储：macOS **不用钥匙串**（§335）
`SecureCredentialStore` 按平台挑后端：其余平台走 `flutter_secure_storage`；**macOS 走 `EncryptedFileSecretBackend`**（`credentials.enc`，`secret_cipher.dart`）。
- ⛔ **别再试钥匙串**：ACL 只认「创建条目的那份签名」，ad-hoc（重建即变）→ 每次启动弹密码框（§335）。
- ⚠️ 密钥由 `IOPlatformUUID` 派生 → **同机同用户任何程序都能解开**；**别掺易变环境值**（`localHostname` 跟电脑名走，改名即解不开→静默掉登录）。⚠️ 依赖 `appSupportDirProvider`（`main()` override），漏了抛 `UnimplementedError`。

## 不可动摇的设计约束
1. 本地解析永远可用，在线刮削是增强；`LocalFilenameScraper` 排 `ScraperPipeline` 末位。
2. 原画只认 `/file/audioplay` 的 `audio_url`；`play/info` 的 `audio_list` 是纯音频流，当原画会**有声音没画面不报错**，`QuarkPlayRoutes.audioOnlyKeys` 别删。兜底：`v2/play`(**POST**) → `download`(≤50MiB)。
3. `ScanPolicy.audioOnly` 默认 `true`；视频库必须显式 `false`，否则扫完一条不剩且不报错。
4. 直链必须带 Cookie（缺则 412）；`__puus` 每响应轮换回填。`PosterCache.headersFor(url)` 每次现取。
5. 字幕自取字节一律走 `decodeTextBytes`（先 UTF-8 后 GBK）。扫描期不下载字幕正文，只写引用。
6. 起播位置只走 `Media(start:)` 且每次显式给（不续播给 `Duration.zero`），共享入口 `PlaybackMedia.build`；`seek` 只用于播放中跳转。
7. 刮削默认不跟扫描跑（`autoScrapeOnScan` 默认 `false`）；优先级靠列表顺序，`ScraperPipeline` 最后一个当兜底、前面竞速。
8. 落库接 `PlaybackController.onPositionTick` 回调（组合根），不暴露 `Player`。
9. 夸克上传收尾**两步**、备份同步比 `libraryModifiedAt`，各有空守卫；`includeSettings`/`restoreSettings` 是**空开关**（§）。
10. Android TV 构建：`flutter build apk --release` 已通（须无沙箱**且前台**，其余见 §「Android 构建」）。
11. **TV 上 `SelectableText` 是焦点陷阱**（D-pad 进去出不来）→ 用 `widgets/tv_text.dart` 的 `TvSelectableText`（§）。
**缓冲**：`PlayerBufferConfig` 是两播放器共用真源，只改这个文件。

## 播放器（两个播放器各一份，别只改一个）
macOS 点播放走**独立窗口** `player_window_app.dart`，内置播放页 `player_page.dart` 是另一份。**键位表、三个菜单都要改两处**，只改一个=用户看到「功能没做」。数字键表与长按加速**共用**（`player_keys.dart`、`seek_acceleration.dart`），但⚠️「一串结束了没有」两边机制不同：`Focus.onKeyEvent` 有 key-up、`CallbackShortcuts` 只能靠 700ms 超时。
**菜单统一走 `ui/widgets/anchored_menu.dart`**（贴按钮正上方划出）；别退回 `AlertDialog`（屏幕正中）或 `CompositedTransformFollower`（飘左上角）。摆位是纯函数 `anchoredMenuOffset`，有单测。
**进度条**：两播放器共用 `ui/widgets/buffered_slider.dart`（**0..1 比例**）。算法只在 `core/utils/player_buffer_progress.dart`：`demuxer-cache-time` 是播放头**前面**的秒数 → 缓冲位置 = 播放头 + 它；时长未知返回 **null** 不画。
音轨源 `player.stream.tracks` 必须过 `TrackLabels.realTracks` 剔掉 media_kit 的 `auto`/`no` 合成轨；**选中态以 `player.stream.track` 回报为准**。字幕四路枚举穷举，漏一种=「点了没反应」。搜索走 `subtitle_query.dart`：**绝不能拿 `displayTitle` 去搜**。**跨引擎错误只认 `PlatformException`**。
## 媒体库三轴（不能互相推导/合并）
- `MediaKind`（结构）：只看文件名 `SxxExx`。
- `MediaCategory`（语义）：落库 `media_works.category`；空串≠other。`MediaCategoryGuesser.guess` 序：TMDB genres→目录路径→片名+文件名→结构兜底；ASCII 关键词必须卡词边界。
- 「最近播放」（视图）：只看播过的，不落库（`LibraryFilter.playedOnly`）；与 `category` 互斥、与 `query` 叠加。
**交互**：`PlayTarget.resolve` ①最近播过且留续播点→那集 ②播过但续播点清→仍是那集 ③全新→第一集；排掉 `isSampleOrExtra`。`playItem()` 是唯一起播入口。`mergeWorkForUpsert`：`category` 取新值但**先按 `effectiveGenres` 折算**；手动标记的行整列不动；`posterUrl` 永不为空；`source=manual` 只被**显式**刮削覆盖（`overrideManual`；那时**分类与锁都取 incoming**，不认旧锁，§「手动重刮改了类型却没生效」）。
**路径**：归一化只在 `core/utils/drive_paths.dart`（`/电影` 与 `/电影/` 变两键→静默筛不到）；`dirPath` 带尾斜杠、目录树内部不带（`drivePathJoin`）。目录视图不排序；搜索只筛当前层。

## 目录名作为系列名（§）
判定单元是**目录不是文件**：`parse` 带 `dirPath`，`DirectoryTitle.seriesTitleOf` 上溯到第一个非容器名；目录名可信且文件非**独立发行物**时整目录归一部剧集，**四处调用点都要传 `dirPath`**。

## 季 / 部 / 跨目录归一（§）
`MediaItem` + **`part/partLabel`**（v9）；`MediaWork` + **`seasonCount`**（v10）+ **`mergedInto`**（v11）。层级**不落库**（`work_levels.dart` 现算）：**季在外、部在内**，某层**少于 2 个选项不画**。
- 自动归一在 `work_merge_planner.dart`（纯函数）：**只认 `onlineId` 相同 + `source==online` + kind 相同**，`manual` 不参与；目标=itemCount 最大→firstSeenAt 最早→key 升序。**本地片名相似度绝不参与**；手动闸门 `manualBlocker` 同处；`siblingOf` 复用 `planFor`。
- **手动归一**「合并到…」（`MergeWorkDialog`，**无刮削门槛**）：留下**选中的那一部**；不能合→按钮灰+原因（自己 / 目标已别名 / **源自己还折着别人**）；撤销=目标页「拆开」。
- ⚠️ 卡片三个计数是**并集**：`listWorks` 读时现算、**不写回**、**只碰真有源的行**；`seasonCount` 是 `COUNT(DISTINCT)`**不能相加**；`allWorks`/`workByKey` 仍存值。
- ⛔ `_unionStats` SQL **别改回 JOIN 里的 `OR`**（用不上索引 → 336ms；必须两段 `UNION ALL` 等值连接 = 3ms）；第一段的 `EXISTS` **别删**（删了 6.4s，且会覆盖无关作品）。`listWorks` 唯一热路径（§）。
- ⛔ **归一 = 打标记，不删行、不改 `group_key`**：列表/角标滤 `merged_into IS NULL`、`itemsForWork` 取并集、撤销=清标记。**不许链式**。⚠️ `mergeWorkForUpsert` 里它**无条件取旧值**（照抄=重扫拆开）；`copyWith` **清不掉**它；搜索穿透折叠时内层表**必须起别名**。
- 设置 `autoMergeByOnlineId` **默认开**（判据 `!= 'false'`，与 `autoScrapeOnScan` 相反）。

## 筛选面板（§）
`library_filter_panel.dart`，`MenuAnchor` 浮层；用普通 `InkWell` → **点 chip 不关面板**；内部 `SingleChildScrollView` 必须 `primary: false`（否则抛异常）。TV 无 Esc → 底有常驻「关闭」+ `PopScope`。
- `LibraryFilter.years`（**具体年份**）/ `.genres`；空集合=这一维不限；多选之间「或」；`clearExtra()` **只清这两组**。
- `==`/`hashCode` 必须按**集合内容**比（`setEquals` + `Object.hashAllUnordered`）—— Set 默认引用相等，会让 Riverpod 误判「没变」。
- **角标口径 = 「清空年份/类型后列表的条数」**：跟着 `category`/`playedOnly`/`query` 收窄、**不跟** years/genres。刷新点别漏（§）。⚠️ 三条陷阱见 §。

## 封面与刮削
`posterFaceX` 与 `posterUrl` **必须成对**；`keptWidth` 必须 `LayoutBuilder` 现算。
无「国内版 TMDB」（DNS 污染+SNI 阻断）；TMDB/豆瓣响应形状**≠夸克信封**（照夸克信封读**静默得空**）；熔断只计**网络层**失败，连 3 次即断、任何 HTTP 响应即清零。
**TMDB `/search/*` 是模糊搜索，绝不能取 `results.first`**：必须过 `scrape_match.dart` 的 `ScrapeMatch` 闸门（§）；全没过闸门时必须 `diag.info` 留痕。
**手动刮削通道**（§「手动刮削」）：片名被插字符或只剩分辨率时**自动算法救不回来**。三条交互不许改：①预填**文件名解析出的词**；②打开时**不自带搜索**；③点候选只是**选中**，再点「用这一条更新」才生效。**不过闸门**。刮完：库里已有同 `onlineId` 的一部→自动归一/否则提示；对话框可手选媒体类型。⚠️ **手动通道的「自动」= 按本次刮削重判**：忽略分类锁、**连语义档也会被 `tv/`/`movie/` 改写**（§）；自动通道仍认锁。⚠️ `implements MetadataScraper` **不继承默认实现**（§）。
**「自定义」**：`customizeWork` **整行写、不过 merge**（merge 的「海报永不为空」会把刚清的补回来）。⚠️ 只清**刮来的** `genres`，`genresManual` 的行连类型带锁一起留；`categoryManual` 只在**改了分类**时才锁。清刮削后封面回落网盘缩略图（含 v13 文件级锚点、加列须同步迁移测试 DROP）：§「自定义清刮削后封面回落」。
**刮削文案按「通道」分**：`WorkScrapeOutcome.message` 取 `(status, channel)`，`channel` 必填（§）。
豆瓣（§477）：熔断要会过期；`title` 只能来自响应体。

## 测试取向
纯函数优先；断言写「为什么重要」。**基线：`flutter test` 1473 例全过**。
- ⚠️ **文档进度表/「仍未做」行会过期，判据按代码核**。
- ⚠️ **修并发/竞态 bug：先加测试跑一遍确认确实红，再加修复**。
- ⚠️ 用户常**边改边跑**，全量冒 1~2 红例是常态。**判据=红的在不在我改的文件里**（文件名+mtime），用户正在改的**别碰**。
- ⚠️ **测相似度/打分别猜数值，先写脚本跑**；断言写 `lessThan(ScrapeMatch.weakSimilarity)` 这类**档位边界**。
- ⚠️ 时间相关逻辑**必须注入时钟**；测「按平台挑后端」必须设 `debugDefaultTargetPlatformOverride`（`flutter test` 下默认**一律 `android`**）；复位只能写在**测试体里**。
- ⚠️ 播放缓冲相关不能用 `pumpAndSettle` → 显式 pump 几拍；纯浮层/对话框可以。
- ⚠️ 改 `tables.dart` 列后先跑 `build_runner build`；看不懂的编译错误先重跑一次，别动手「修」。`AppSettings.fromValues(Map)` 是默认值真源。
