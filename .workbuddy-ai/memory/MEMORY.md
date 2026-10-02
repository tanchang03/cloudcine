# 云影（cloudcine）项目长期约定

Flutter 3.29.0 / Dart 3.7.0 的 macOS 网盘媒体库播放器，对接夸克网盘；授权/取流/签名复刻自同目录的 `夸克音乐播放器`。
- 本机通用事实（gvm/代理/沙箱/`ps` 改 `pgrep`/同文件不能同消息发两个 Edit）见 `~/.workbuddy-ai/MEMORY.md`。
- **规则的理由与实测证据在 `HOWTO.md`**（下文 `§` 指其章节）；逐日经过在 `YYYY-MM-DD.md`。
- ⚠️ **本文件已贴注入上限**：加内容前先 `wc -m`（超 8000 就被截断、规则等于白写），必须**等量删旧**；细节能指向 `§` 的一律不进本文件。

## 版本控制
- **攒够一小轮就 commit**；`git clean` 前先 `-nd` 干跑 —— untracked 被 `git clean -df` 删掉 git **永久救不回**（2026-10-01 丢 34 项，靠技能 `git-clean-recovery` 救回）。
- ⛔ **不要代用户 `git add` / `git commit`** —— 暂存与提交需**分别**授权。
- ⚠️ 提交前核对**索引 vs 工作区**：用户会中途自己 `git add` 存快照，之后我们继续改，索引就停在旧状态，而 `git commit` 提交的是索引 → 静默提交一个已废弃但自洽能编译的设计。`git diff` 看不出，要 `git diff --cached`；修法是 `git add -A`（`-a` 不含未跟踪文件）。
- ⛔ **别对仓库文件跑 `dart format`**（仓库不符合 formatter）—— 5 处改动会膨胀成 60+ hunk；补救：`git show HEAD:<f>` 取回原版重放。

## 架构
`core/` 纯工具 · `domain/` 实体+服务+适配器抽象（**不 import Flutter/drift**）· `data/` 夸克适配器/HTTP/drift/刮削/凭证 · `ui/` Riverpod 组合根（`providers/`）+ go_router + 页面。跨层信号放叶子文件（`library_refresh_providers.dart` 的 `libraryWriteSignalProvider`），**别让组合根 invalidate feature provider（成环）**。

## 文件夹模式与局部发现（2026-10-01）
- 文件夹视图的数据源是**网盘实时目录**（`driveListingProvider` 按 `DriveCrumb` 逐层列），**不是**已扫描的媒体库；本地索引退居「已入库」叠加层（`folderTree.fileIds` / `indexedCountAt`）。
- 局部发现 `MediaDiscoveryService` 与全盘扫描共用三份唯一实现，**别再各写一份**：`media_entry_classifier.dart`（条目分类；镜像判定必须在视频判定**之前**）、`work_builder.dart`（`WorkSeedBook` 归组/作品构造）、`request_throttle.dart`（列目录节流）。
- 三条硬约束（做错不报错，只表现为数据悄悄坏掉）：**绝不清理陈旧记录**、**绝不写续扫游标**、**深度从本次目标算第 0 层**。
- 两条入口共用 QPS：发现让着扫描（`DiscoveryController.canStart` 看 `scanController.running`），`MediaDiscoveryService._active` 防重入。

## macOS 签名与 entitlements（§254 §275）
- ⛔ 两份 entitlements 都不许写 `keychain-access-groups`：受限能力项，ad-hoc 签名下 taskgated 判签名无效 → **启动即 SIGKILL**（崩溃报告**无调用栈**、`dyld_path_missing`），Xcode 另报 `requires a provisioning profile`。
- `app-sandbox` 必须 **`false`**。两份都要 `network.client`·`network.server`·`files.user-selected.read-only`；`DebugProfile` 另加 `get-task-allow`（缺了 `flutter run` 卡住、无窗口）。
- 部署目标 10.15；Podfile `post_install` 逐 target 覆盖；两段补丁别删：`cloudcine_fix_media_kit_symlinks`、`FileUtils.rm_rf`。
- ⚠️ `pod install` 前必须设 `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`（路径含中文）。`MainFlutterWindow.swift` 的 `setOnWindowCreatedCallback { RegisterGeneratedPlugins }` 别删，否则子窗口插件全 `MissingPluginException`。

## 凭证存储：macOS **不用钥匙串**（§335）
`SecureCredentialStore` 按平台挑后端：iOS/Android/Windows/Linux 走 `flutter_secure_storage`；**macOS 走 `EncryptedFileSecretBackend`**（应用支持目录 `credentials.enc`，`secret_cipher.dart`）。
- ⛔ **别再试钥匙串**：ACL 只认「创建条目的那份代码签名」，本仓库 ad-hoc（身份=cdhash，重建即变）→ 每次启动弹密码框；三条路全废（§335）。**零弹框只有稳定签名身份（Developer ID）**。
- ⚠️ 代价必须说清：密钥由**本机硬件 UUID**（`IOPlatformUUID`）派生，**同机同用户的任何程序都能解开** —— 「混淆级」，**别宣传成加密保险箱**。
- ⛔ **密钥材料别掺易变环境值**（主机名/用户名/HOME）：`Platform.localHostname` 跟电脑名称走，用户改名 → 解不开 → **静默掉登录**。**能拿到 UUID 就只用它**。
- 换机器 → 解不开 → 表现是「需要重新登录一次」，不是崩溃。⚠️ 依赖 `appSupportDirProvider`（`main()` 里 override 注入），漏了抛 `UnimplementedError`。

## 不可动摇的设计约束
1. 本地解析永远可用，在线刮削是增强；`LocalFilenameScraper` 排 `ScraperPipeline` 最后。
2. 原画只认 `/file/audioplay` 的 `audio_url`（名字骗人，给的是原文件）；`play/info` 的 `audio_list` 是纯音频流，当原画会**有声音没画面不报错**，`QuarkPlayRoutes.audioOnlyKeys` 别删。兜底：`v2/play`(**必须 POST**) → `download`(≤50MiB)。
3. `ScanPolicy.audioOnly` 默认 `true`；视频库必须显式 `false`，否则扫完一条不剩且不报错。
4. 直链必须带 Cookie（缺则 412）；`__puus` 每响应轮换回填。`PosterCache.headersFor(url)` 每次现取。
5. 字幕自取字节一律走 `decodeTextBytes`（先 UTF-8 后 GBK）。扫描期不下载字幕正文，只写引用（夸克 QPS 限制）。
6. 起播位置只走 `Media(start:)` 且每次显式给（不续播给 `Duration.zero`），共享入口 `PlaybackMedia.build`；`seek` 只用于播放中跳转。
7. 刮削默认不跟扫描跑（`autoScrapeOnScan` 默认 `false`）；优先级靠列表顺序，`ScraperPipeline` 最后一个当兜底、前面竞速。
8. 落库接 `PlaybackController.onPositionTick` 回调（组合根），不暴露 `Player`。
9. 夸克上传收尾**两步**，缺一即 `43001`；备份同步比**库内容时间**（`libraryModifiedAt`）不比文件创建时间，空库/空包各有守卫（§「夸克上传」/「备份同步」）。
**缓冲**：`PlayerBufferConfig`（`core/utils/player_buffer_config.dart`）是两播放器共用真源（1GB + `readaheadSecs`=9999 + `disableStreamCache`）。只改这一个文件。

## 播放器（两个播放器各一份，别只改一个）
macOS 点播放走**独立窗口** `player_window_app.dart`，内置播放页 `player_page.dart` 是另一份。**键位表、字幕菜单、音轨菜单都要改两处**（键位见 §416），只改一个=用户看到「功能没做」。
**进度条**：两个播放器共用 `ui/widgets/buffered_slider.dart`（三层轨道），都是 **0..1 比例**。算法只在 `core/utils/player_buffer_progress.dart`：`demuxer-cache-time` 是播放头**前面**的秒数 → 缓冲位置 = 播放头 + 它（直接除总时长 = 1% 死线）；时长未知返回 **null** 不画。
音轨数据源 `player.stream.tracks`（**持续听**）必须过 `TrackLabels.realTracks` 剔掉 media_kit 的 `auto`/`no` 合成轨；**选中态一律以 `player.stream.track` 回报为准，不做乐观更新**。字幕四路（embedded/cloud/online/local）枚举穷举，漏一种=「点了没反应」；外挂字幕挂着时内嵌轨一律不打勾。搜索走 `subtitle_query.dart`：**绝不能拿 `displayTitle` 去搜**（带 `S01E01` → 归零且不报错）。**跨引擎错误只认 `PlatformException`**。在线字幕（OpenSubtitles）**搜索不占额度、下载才占**。

## 媒体库三轴（不能互相推导/合并）
- `MediaKind`（结构）：只看文件名 `SxxExx`。
- `MediaCategory`（语义）：落库 `media_works.category`；空串≠other（空串=还没判定）。`MediaCategoryGuesser.guess` 顺序：TMDB genres→目录路径→片名+文件名→结构兜底；ASCII 关键词必须卡词边界（`ova` 会命中 `Nova.2023`）。
- 「最近播放」（视图）：只看播过的，不落库。是 `LibraryFilter.playedOnly`；与 `category` 互斥、与 `query` 叠加。
**交互**：`PlayTarget.resolve` ①最近播过且留续播点→那集 ②播过但续播点清→仍是那集不猜下一集 ③全新→第一集；排掉 `isSampleOrExtra`。`playItem()` 是唯一起播入口。`mergeWorkForUpsert`：`category` 永远取新值，但**要先按 `effectiveGenres` 折算一次**（否则重扫会把刮削修好的分类冲回去）；`posterUrl` 永不为空。
**路径**：归一化只在 `core/utils/drive_paths.dart`（`/电影` 与 `/电影/` 变两键→静默筛不到）；`MediaItem.dirPath` 带尾斜杠、目录树内部不带（`drivePathJoin`）。目录视图不排序；搜索只筛当前层。

## 筛选面板（年代 / 类型，§「筛选面板」）
`library_filter_panel.dart`，`MenuAnchor` 浮层；里面放普通 `InkWell`（不是 `MenuItemButton`）→ **点 chip 不关面板**；面板内 `SingleChildScrollView` 必须 `primary: false`（否则抢 `PrimaryScrollController` → **一打开就抛异常**）。
- `LibraryFilter.decades`（**年代起始年**，2020=2020–2029）/ `.genres`；空集合=这一维不限；多选之间「或」；`clearExtra()` **只清这两组**，`clear()` 才全复位。
- `==`/`hashCode` 必须按**集合内容**比（`setEquals` + `Object.hashAllUnordered`）—— Set 默认引用相等，会让 Riverpod 误判「没变」。
- **角标口径 = 「把年代/类型清空后列表的条数」**（保证每个选项点下去至少有一条）：计数跟着 `category`/`playedOnly`/`query` 收窄、**不跟** decades/genres；三个查询共用 `_workConditions`，替身计数**委托 `listWorks`**。刷新点别漏：`scan_providers` 扫完、`_refreshAfter`。
- ⚠️ 三条一致性陷阱（各有测试钉住）：①计数 provider 必须 `await categoryBackfillProvider`（老库那列是空串）；②`_refreshAfter` 里「分类变了」要**额外**作废这两组角标，只按 `year`/`genres` 判会漏；③**已选条件在切换分类后可能不在 `counts` 里**（`setCategory` 不碰 decades/genres）→ 必须照样画出来标「无结果」，否则用户**取消不掉**它。
- 空态按钮必须与提示语**指向同一件事**（`libraryEmptyHint()`，纯函数可单测）：要清掉**全部在用**的条件 —— 一律 `clear()` 会把分类栏选的位置一起丢掉。

## 封面与刮削
夸克缩略图是剧中帧不是海报；缺字段别自己拼 URL（401/404）。`PosterCache` 磁盘命中看 `File(target).existsSync()`。`posterFaceX` 与 `posterUrl` **必须成对**；`keptWidth` 必须 `LayoutBuilder` 现算。
无「国内版 TMDB」（`api.themoviedb.org` DNS 污染、`image.tmdb.org` SNI 阻断，只有反代能解）；TMDB/豆瓣响应形状**≠夸克信封**（照夸克信封读会**静默得空**）；熔断只计**网络层**失败，连 3 次即断、任何 HTTP 响应即清零。
**TMDB `/search/*` 是模糊搜索，绝不能取 `results.first`**：必须过 `scrape_match.dart` 的 `ScrapeMatch` 闸门（§601）；全没过闸门时必须 `diag.info` 留痕。
**手动刮削通道**（详情页「手动」按钮，§661）：片名被插字符或只剩分辨率时**自动算法救不回来**。三条交互不许改：①预填**文件名解析出的词**；②打开时**不自带搜索**；③点候选只是**选中**，再点「用这一条更新」才生效。手动通道**不过闸门**。⚠️ `implements MetadataScraper` **不继承默认实现**（§769）。
**刮削文案按「通道」分**：`WorkScrapeOutcome.message` 取 `(status, channel)`，`channel` 必填；`notFound` auto=「自己敲片名」、manual=「换候选」；`ScrapeChannel.auto` = 详情页「刮削」按钮（§661）。
豆瓣（§477）：剧集 301 跳 `/tv/{id}`；正主常在 `smart_box`；候选不取第一条；海报 `img*`→`qnmob3-sign`（Referer 仍需）；`code:103` 时**熔断必须是会过期的冷却**（60s→30min）；`cookieHasLoginToken` 判 `dbcl2`；**`title` 只能来自响应体**。

## 测试取向
纯函数优先；断言写「为什么这条规则重要」。**基线：`flutter test` 1080 例全过**（2026-10-02）。
- ⚠️ **修并发/竞态 bug：先只加测试跑一遍确认它确实红，再加修复**。
- ⚠️ 用户常**边改边跑**，全量冒 1~2 个红例是常态。**判据是「红的在不在我改的文件里」**：`tr '\r' '\n' < log | grep "\[E\]"` 拿文件名再看 mtime，用户正在改的**不要碰**（别把自己**新建**的误当成用户在改的 —— 看 `git status` 是 `??` 还是 `A`）。
- ⚠️ **测相似度/打分别猜数值，先写 5 行脚本跑**；断言写 `lessThan(ScrapeMatch.weakSimilarity)` 这类**档位边界**，别写死 `0`/`0.79`。
- ⚠️ 时间相关逻辑（冷却/退避/重试）**必须注入时钟**；测「按平台挑后端」必须设 `debugDefaultTargetPlatformOverride`（`flutter test` 下默认**一律 `android`**），用完 `addTearDown` 清回 `null`。
- ⚠️ 必须带 `NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost`，否则连不上 flutter_tester。
- ⚠️ 涉及播放缓冲时不能用 `pumpAndSettle`（转圈永不停止）→ 显式 pump 几拍；纯浮层/对话框可以。
- ⚠️ 改 `tables.dart` 列后先跑 `build_runner build`；看不懂的编译错误先重跑一次（常有并发编辑），别动手「修」。`AppSettings.fromValues(Map)` 是默认值唯一真源。
