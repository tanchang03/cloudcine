# 云影（cloudcine）项目长期约定

Flutter 3.29.0 / Dart 3.7.0 的 macOS 网盘媒体库播放器，对接夸克网盘。参考项目：`/Users/tandy/workbuddy-ai/夸克音乐播放器`（授权与取流复刻自它）。

- 本机环境通用事实（gvm/代理/沙箱/`ps` 不可用改 `pgrep`/同文件不能同消息发两个 Edit）见 `~/.workbuddy-ai/MEMORY.md`。
- **每条规则的来龙去脉、实测证据、踩坑复盘都在 `HOWTO.md`**；改下面任何一条前先读那一节。

## 目录与依赖方向
`core/` 纯工具 · `domain/` 实体+服务+适配器抽象（**不 import Flutter/drift**）· `data/` 夸克适配器/HTTP/drift/刮削器/凭证 · `ui/` Riverpod 组合根（`providers/`）、go_router、页面。
组合根 `providers/app_providers.dart` 被依赖；跨层信号（播放→刷新媒体库）放叶子文件 `library_refresh_providers.dart`，**别让组合根 invalidate feature provider（成环）**。

## 不可动摇的设计约束
1. 本地解析永远可用，在线刮削是增强；`LocalFilenameScraper` 排 `ScraperPipeline` 最后。
2. 原画只认 `/file/audioplay` 的 `audio_url`（名字骗人，给的是原文件）；`play/info` 的 `audio_list` 是纯音频流，当原画会**有声音没画面不报错**，`QuarkPlayRoutes.audioOnlyKeys` 别删。兜底：`v2/play`(**必须 POST**) → `download`(≤50MiB)。
3. `Capabilities.maxSingleFileBytes` 刻意不声明（50MiB 只是 download 限制）。
4. `ScanPolicy.audioOnly` 默认 `true`；视频库必须显式 `audioOnly:false`，否则扫完一条不剩且不报错。
5. 直链必须带 Cookie（缺则 412）；`__puus` 每响应轮换回填。`PosterCache.headersFor(url)` 每次下载现取。
6. 字幕自取字节（`SubtitleTrack.uri/.data` 无请求头），用 `decodeTextBytes`（先 UTF-8 后 GBK）。
7. 扫描期不下载字幕正文，只写引用（夸克 QPS 限制）。
8. 落库接 `PlaybackController.onPositionTick` 回调（组合根），不暴露 `Player`。
9. `ScanPhase` 只有 `walking/scraping/finishing`，用 `ScanPhase?` 表「空闲」。
10. 起播位置只走 `Media(start:)` 且每次显式给（不续播给 `Duration.zero`），共享入口 `PlaybackMedia.build`；`seek` 只用于播放中跳转。
11. 刮削默认不跟扫描跑（`autoScrapeOnScan` 默认 `false`）；`ScanController.start()` 不接受 `scrape` 参数（自己读设置）。
12. 刮削优先级靠列表顺序；`ScraperPipeline` 最后一个当兜底、前面竞速。

**键盘快捷键**：两个播放器各一份键位表（`player_page.dart`/`player_window_app.dart`，macOS 点播放走**后者**）——只改一个=用户看到「功能没做」。空格播放暂停·←/→跳10秒·F全屏·Esc退全屏。硬规则（`Focus(autofocus)`、控制栏整块 `ExcludeFocus`、诊断页换只含 Esc 的表、跳转过 `clampSeekTarget`）见 HOWTO。
**缓冲配置**：`PlayerBufferConfig`（`core/utils/player_buffer_config.dart`）是两个播放器共用的缓冲配置真源。`bufferSize`=1GB（`PlayerConfiguration.bufferSize` → `demuxer-max-bytes`/`demuxer-max-back-bytes`）+ `readaheadSecs`=9999（`NativePlayer.setProperty('demuxer-readahead-secs')`，≈2.7小时=一直往前缓存到片尾）。改缓冲参数改这一个文件，别在两个 Player 构造里各搞各的。media_kit 默认 32MB/1秒对高码率原画远远不够（40Mbps 只有 6.4 秒缓存）。配合 media_kit 硬编码 `cache-on-disk=yes`，超额落盘。

## TMDB
响应形状≠夸克信封（`{code,message,data}`）：`/3/search/{movie,tv}` 顶层 `{page,results}`、`/3/genre/.../list` 顶层 `{genres}`。用夸克信封读会静默得 `[]`/`null`=永远搜不到。`TmdbScraper` 用 `_resultsOf`/`['genres']`，别改回 `dataListItems/dataMap`。回归 `test/data/tmdb_scraper_test.dart`。`year`/`first_air_date_year` 是硬过滤，无结果时去掉年份再搜。
**熔断（境内必须）**：`api.themoviedb.org` DNS 污染（`www.` 却 200）；只把**网络层失败**计入，连 3 次即 `_unreachable`，拿到任何 HTTP 响应都清零（否则 Key 填错表现成连不上）。熔断单向。

## macOS 五条别回退
1. entitlements 必须含 `com.apple.security.network.client`（Debug/Release 都要），否则发不出请求且报错不指向权限。
2. **两份 entitlements 都要含 `com.apple.security.files.user-selected.read-only`**（播放器「加载本地字幕文件」要读用户选中的文件）。没有它时 `NSOpenPanel` 照样弹、照样返回路径，只有紧接着的读取失败，报的还不是权限错。
3. 部署目标 10.15；Podfile `post_install` 逐个 target 覆盖 `MACOSX_DEPLOYMENT_TARGET`。
4. Podfile 两段补丁别删：`cloudcine_fix_media_kit_symlinks`（纯 Ruby）补 mpv 符号链接；`FileUtils.rm_rf` 绕开 safe-delete。`pod install` 正常 1~2 秒。
5. **两份 entitlements 都要含 `keychain-access-groups`**（值 `$(AppIdentifierPrefix)com.cloudcine.cloudcine`），且 `SecureCredentialStore` 的 `useDataProtectionKeyChain` 必须 `true`。少了 entitlement 会报 `-34018`；`useDataProtectionKeyChain=false`（旧版 login.keychain）沙箱+ad-hoc 签名下每次启动弹「访问钥匙串」密码框且「始终允许」记不住。
6. **`DebugProfile.entitlements` 必须含 `com.apple.security.get-task-allow`**（Release 不含）。macOS 的 `taskgated` 守护进程收到 `task_for_pid` 请求时查这个权限——没有它，`flutter run` 构建成功但永远连不上 Dart VM Service，表现是「一直卡住、没有窗口弹出」。之前缺失过，补回后正常。残留进程也会干扰新启动（`pgrep cloudcine` 清）。
⚠️ **`pod install` 在本机必须先设 locale**：路径含中文，直接跑必炸 `Unicode Normalization not appropriate for ASCII-8BIT`。用 `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pod install`（`flutter run` 自己会处理，所以平时不暴露）。
⚠️ 子窗口（独立播放窗口）能用任何插件，靠的是 `MainFlutterWindow.swift` 里的 `setOnWindowCreatedCallback { RegisterGeneratedPlugins(registry: $0) }`。删了它，media_kit 与 file_selector 在播放窗口全部 `MissingPluginException`。

## 播放器：字幕与音轨（两个播放器各一份菜单，别只改一个）
macOS 点播放走**独立窗口** `player_window_app.dart`，内置播放页 `player_page.dart` 是另一份。
音轨数据源 `player.stream.tracks`（**持续听**，容器没解析完时是空的），必须过 `TrackLabels.realTracks` 剔掉 media_kit 的 `auto`/`no` 合成轨。**选中态一律以 `player.stream.track` 回报为准，不在点击时乐观更新**。
字幕四路：`embedded` 切轨；`cloud`/`online`/`local` **先取正文再 `SubtitleTrack.data`**。来源用枚举穷举（`_SubtitleKind`），漏一种=「点了没反应」。
**打勾口径**：有外挂字幕挂着时内嵌轨一律不打勾（mpv 认不出后挂的外挂字幕是哪一条）。
**编码一律走 `decodeTextBytes`**（先严格 UTF-8 失败再 GBK）—— 中文外挂字幕大量 GBK，`readAsString()` 得到满屏乱码且不报错。
搜索条件走 `domain/services/subtitle_query.dart`：**绝不能拿 `displayTitle` 去搜**（带 `S01E01` → 结果归零且不报错）；片名进 query、季集号进独立参数、剧集不按年份过滤。协议层传 `itemId`（+`fallbackQuery`），由主窗口查库补全。
**跨引擎通道的错误只认 `PlatformException`**：别的异常到对面会退化成 `code='error'` + 整段 `toString`（用户看到一坨内部类型名）。主窗口抛 `code='opensubtitles/<failure>'` + 中文 `message`。
在线字幕走 OpenSubtitles（`data/remote/subtitle/opensubtitles_client.dart`），Api-Key 在设置页「在线字幕」一节。**搜索不占额度、下载才占**，所以搜索结果缓存在窗口里（换片才清），不要每次开菜单都重搜。

## 媒体库三轴（不能互相推导/合并）
- `MediaKind`（结构）：电影/剧集/未知，只看文件名 `SxxExx`。
- `MediaCategory`（语义）：电影/剧集/动漫/综艺/纪录片/其他，落库 `media_works.category`。空串≠other（空串=还没判定，`backfillWorkCategories` 只回填空串行）。`MediaCategoryGuesser.guess` 顺序：TMDB genres→目录路径→片名+文件名→结构兜底；ASCII 关键词必须卡词边界（`ova` 会命中 `Nova.2023`）。
- 「最近播放」（视图）：只看播过的，不落库。是 `LibraryFilter.playedOnly` 视图位（不是枚举取值）；与 `category` 互斥、与 `query` 叠加；筛 `last_played_at IS NOT NULL`；角标走 `countPlayedWorks()`。点这栏顺带切 `recentPlayed`、离开不切回。空态单独给。刷新：`PlaybackLibraryLink` 版本号被 `workListProvider`/`playedCountProvider` watch，只在换条时推进。

**分辨率归档**：长边+短边各算一遍取较高档；第二轴用短边不用「高」。优先级：实测尺寸→文件名宽高→文件名档位。

**交互/合并**：`PlayTarget.resolve`：①最近播过且留续播点→那一集（多条取 `lastPlayedAt` 最新）②播过但续播点清→仍是那一集不猜下一集③全新→第一集；排掉 `isSampleOrExtra`。`playItem()` 是唯一起播入口；海报墙点击直接起播，简介走卡片常驻「简介」按钮。`resolvePlayTarget` 不做 Provider。`mergeWorkForUpsert`：`category` 永远取新值；`posterUrl` 永不为空，`keepPosterFile` 额外加 `incoming.posterUrl==null`。

**目录视图**：媒体库页头「海报墙/文件夹」切换。`FolderTree` 离线从 `dirPath` 拼出；路径归一化只在 `core/utils/drive_paths.dart`（`/电影` 与 `/电影/` 变两键→静默筛不到）。`currentFolderProvider` 只存路径字符串不存节点。`folderTreeProvider` 一次 `listItems()` 拉全量。目录视图不排序；搜索匹配文件名+完整路径。回归：`test/core/drive_paths_test.dart`·`folder_tree_test.dart`·`media_repository_list_items_test.dart`。

## 封面
地址不缺（`thumbnail`/`big_thumbnail`/`preview_url`），缺字段别自己拼 URL（401/404）。夸克缩略图是剧中帧不是海报，别再投入。`PosterImage`=模糊放大 cover 底图+压暗层+`contain` 完整画面，格子 `AppTheme.posterAspect`(2:3)，不按来源分支。`PosterCache` 磁盘命中看 `File(target).existsSync()`（旧逻辑只看列→每次重下）。
**人物锚点**：`cover_face_boundary` 决定 16:9 剧中帧裁哪段（`core/utils/face_anchor.dart`，链路 `toEntry→DriveEntry.faceAnchorX→MediaItem.faceAnchorX→MediaWork.posterFaceX`）。`posterFaceX` 与 `posterUrl` 必须成对（TMDB 海报的 `null` 是结论）；`keptWidth` 必须 `LayoutBuilder` 现算（约 0.8→保留 45%）；有锚点→`cover`+`Alignment(t,0)`，无→模糊底图+`contain`。

## 刮削源
无「国内版 TMDB」：`api.themoviedb.org` DNS 污染、`image.tmdb.org` SNI 阻断、`www.` 却 200→封锁按主机名，只有反代能解。
`[TmdbScraper, DoubanScraper, LocalFilenameScraper]` 顺序即优先级、最后兜底。流水线实例必须长期存活（`scraperPipelineProvider`），直接 watch `settingsProvider` 会让调音量清零熔断。扫描期默认不刮。`WorkScraper`：分类不跟着变、海报换则 `posterFaceX` 归零且 `posterFile` 清、必须看 `meta.source==online`。查询走 `ScrapeQuery.fromParsed`。
**豆瓣(rexxar)坑**：①剧集 301 跳 `/tv/{id}`→类型读响应体 `type`；②正主常在 `smart_box` 不在 `subjects.items`→两处都读，`type=movie` 不是过滤器；③候选不取第一条（标题契合度为主、年份差≥2 年重罚），海报只取详情（`cover_url` 是横条），`img*.doubanio.com` 缺 `Referer` 一律 418；④额度极小（~10 词，同词走缓存），耗尽报 `{"code":103}`，HTTP 状态码不稳→必须先解析业务码。

## 测试取向
纯函数优先；断言写「为什么这条规则重要」（夸克信封/熔断/视图vs分类都是改错不报错）。
⚠️ 跑测试必须带 `NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost`，否则 `Unable to connect to flutter_tester process`。
⚠️ 改 `tables.dart` 列后先跑 `flutter pub run build_runner build`。
⚠️ 看不懂的编译错误先重跑一次（常有并发编辑），别动手「修」。
`AppSettings.fromValues(Map)` 是默认值唯一真源。
