# 云影（cloudcine）长期约定

**两个互不引用的工程**：`android/` = ★ Android/TV 正式实现（Kotlin，`com.cloudcine.tv`）；`lib/ macos/ windows/ pubspec.yaml` = Flutter PC 端。
- 细节下沉：理由 → `HOWTO.md`；逐日 → `YYYY-MM-DD.md`。**只留红线 + 标识符**；⚠️ 超 1.2 万字节截断 ⇒ 加新条目**先删旧的**。

## 仓库 / CI / 打包
- ⛔⛔ Android 产物**只**走 `cd android && ./gradlew :app:assembleRelease`（JDK 21）：根 `flutter build apk` 必报 `deleted Android v1 embedding`。⛔ `applicationId`/`versionCode` 别改（换包名 = 丢磁盘缓存）。
- ★★ `packages/video_player_android` 是 path 依赖 ⇒ 根 `analysis_options.yaml` 要 `analyzer.exclude` 它。`flutter analyze` **有 issue 即 exit 1**；弃用 API 用 `// ignore: <rule>`。
- ★★ **发版**：tag 必须 `v*`；版本号**只改 `pubspec.yaml` 的 `version:`** 再跑 `dart tool/version.dart`（`versionCode = x*10000+y*100+z`）。守卫 `version-guard` + `version_consistency_test.dart`。
- ⛔⛔ macOS Release 签名**不许带 `get-task-allow`** ⇒ Runner **Release** 须 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`。⛔ 部署目标 **12.0**（Xcode 27 拒收更低）。

## ★★ 媒体库数据结构 = 跨端同步唯一契约
- `cloudcine.sqlite`（schema **18**）**8 表**：`media_items`·`media_works`·`subtitle_refs`·`scan_cursors`·`settings`·`playback_prefs`·`download_tasks`·`skip_samples`。⛔ 主键全**文本**；⛔ `category` 默认**空串**。
- ★★ 两端 `schemaVersion` **必须相等**（PC `AppDatabase.currentSchemaVersion` ≡ Android `LibrarySchema.VERSION`）；备份拒收更高版本 ⇒ 加表加列**两端一起升**。
- ★★ **旧备份恢复后必须补列**：PC `beforeOpen` → `_ensureSchemaComplete` 幂等补表补列、**不信 `user_version`**；Android `LibraryDb.ensureSchema` 同口径。⛔ `Migrator.addColumn` **不查存在性** ⇒ 先 `PRAGMA table_info`。守卫 `db_schema_backfill_test.dart`。→ HOWTO §13.8
- ⚠️ 进度三列（`resume_position_ms`·`max_position_ms`·`last_played_at`）= **物化投影**；真源 `playback_progress.json`（**不进 `.ccbak`**）。★★ 契约 `{v:1,items:{<id>:{r,m,p,u}}}`，**逐条 LWW、`m`·`p` 取并集**。⛔ 写前先 `load()`；`.tmp`+`rename`；⛔ **下载失败绝不上传**；★ `libraryModifiedAt` 摘掉 `last_played_at`。`LibraryDb(...)` 必传 `progress=`（`ProgressWiringTest`）。
- `.ccbak` = 全大端自定义容器（⛔ **不是 ZIP**），装**整个 SQLite 原始字节**；目录 `云影备份`；文件名**必带时间戳**；恢复 = **换掉整个 db**（`closeDatabase()`→`writeAsBytes`→`openDatabase()`）。★★ 同步判据 `libraryModifiedAt`；本地空库让远程赢、远程空备份不覆盖本地；冲突 = 不同设备且差 < 60s。⛔ 不备份网盘凭证。
- ★★ **批量移除可勾「一并删网盘」**（⛔ 默认不勾）：⛔ 先删网盘再删索引；⛔ 只读网盘跳过。

## ★★ 片头 / 片尾自动学习（schema 18）→ HOWTO §13
- 规则 `skip_learning.dart` ↔ `library/SkipLearning.kt`（阈值与 `SkipKind.dbName` 逐字同源）；片头 `intro_*.dart` ↔ `library/IntroSkip.kt`。
- 列：`media_works.learned_intro_start_ms`/`learned_intro_end_ms`/`learned_outro_offset_ms`/`learned_samples`/`learned_at`；表 `skip_samples`（主键 `itemId#kind#毫秒`）。⛔ 手标与学习**两条独立支路**；Android `WORK_COLUMNS` 必读手标两列。
- 取值链：PC **章节 > 手标 > 学习**；Android **手标 > 学习**。片尾存**距末尾偏移**、⛔ **没有终点列**。
- ⛔⛔ **自我实现防护**：自动跳引起的 seek / 换集**绝不记样本** —— PC `_seek(..., user: false)` / `_openEpisode(reportSwitch: false)`；Android `seekToPosition(..., user = false)` / `switchEpisode(..., fromOutro = true)`（标记**由 `onNewIntent` 消费**、须在 `startActivity` **之前**挂）。→ §13.4
- 片尾唯一信号 = **切下一集 / 退出播放**；片头才要 `stableWatch`(15s)，⛔ `notePosition` **只产片头**。片尾默认**只提示不跳**，开 `auto_play_next` 才跳（⛔ 误跳 = 丢结局）。★★「当场学会」须同步进状态机（`applyLearnedOutro` 归零 `_outroReached`）。
- 设置键（逐字一致，判据**都是 `!= "false"`**）：`skip_intro` / `auto_play_next`。⛔ `saveLearnedSkip(empty)` **直接 return**；非空**三列整体写**；⛔ **绝不写 `updated_at`**；⛔ 学习数据**不参与 `libraryModifiedAt()`**，但 `skip_samples` **随备份走**。

## ★★ 追剧 / 更新提醒（§9）
- 4 列在 `media_works`：`followed`/`follow_started_at`/`follow_checked_at`/`new_item_count`。判据用 `first_seen_at` 做差（⛔ 不用 `modified_at`）。NEW = 追剧后新增 ∧ **`max_position_ms`·`last_played_at` 都空**。
- ★★ **「点过就不再是 NEW」两端同口径**：`last_played_at` 在**点击那一刻**写（`markPlayed`），⛔ **不等**进度落库、写完**必须重读该页**；⛔ 起播不写 `max_position_ms`。
- ⛔⛔ 自动检查**绝不写 `media_works.updated_at`**；节流零点 `settings.follow_last_check_at`（Unix **秒字符串**）。⛔ 目录失败不推进水位线。⛔⛔ `FollowAutoCheck.off` 的 `throttleWindow == null` = 不节流 ⇒ 必须 `_run` 里**显式**挡。⛔ 手动入口 `force: true`。PC `AppShell._FollowLaunchCheck`（20s + `every_6h`），⛔ `Timer` 必须 `dispose`。

## ★★ Android 端红线
- ⛔⛔ 电视上 **`OnItemClickListener` 按 OK 不触发** ⇒ `dispatchKeyEvent` 自管 OK，**DOWN 与 UP 都要吞**。
- ⛔⛔ `lateinit` 视图别在赋值用的 `apply` 块里调自己的上色函数（现象＝「点进去立刻弹回上一页、零报错」）⇒ **先赋值、再调用**。
- ⛔⛔ **覆盖层 / 菜单弹出前必须收软键盘**（IME 抢吃 ↑↓/OK）⇒ `showOverlay()` 先 `hideKeyboard()`。
- ⛔ `applyWorks` 无条件 `requestFocus()` = 一级导航「点不动」；⛔ **光标态与生效态分离**（←→ 只移 `navIndex`，OK 才 `applyTab()`）。
- ★★ **「发现」= 局部扫描，只增不减**（`LibraryScanner.discover`）：⛔ 绝不 `pruneMissingItems`、绝不写 `scan_cursors`、`recursive=false`；归组复用已有 `group_key`。
- ★★ **作品简介页**（`Level.ITEMS`）：⛔ **OK 点卡片 = 进简介页**（`openWork`）。⛔ 三层阶梯、**焦点始终留 `itemsList`**（胶囊只吃光标态）⇒ 同时**只有一层发光**（`WorkDetailFormat.itemRowHighlighted`）。⛔⛔ **方向键不做破坏性跳转**：最上层 ↑ = **无事**，退出只认返回键。⛔ 胶囊不可用**置灰不消失**。
- ★★ **归一并集**：⛔ `mergeWorksInto` 只打 `merged_into`、**从不改写 `group_key`** ⇒ 查询 = 「自己名下 ∪ 源名下」（`itemsForWork`/`ownerKeyOf`、`listWorks`/`withUnionStats`）。⛔⛔ **并集不许塞进 `WORK_COLUMNS` 逐行子查询**（7.5s）⇒ 走**页级** `unionStats`。
- ★★ **刮削**：TMDB 优先 + 豆瓣兜底。⛔ **TMDB 两代 Key 送法不同**：v4（`eyJ`）走 `Bearer`，v3（hex）走 `api_key`，送错 **401**。`AUTO_SCRAPE_ON_SCAN`：PC 关、Android 开。⛔ 未刮削封面用 `PanApi.thumbBytes`（带 Cookie；裸链 `401`）。
- ★★ **seek 唯一落点** = `PlayerActivity.seekToPosition(targetMs, source, user)`。⛔ 触摸拖拽与遥控器快进都必须走它；⛔ `bufferedPosition` 必须在 `seekTo` **之前**读。
- `library/`：`LibrarySchema` = 唯一真源；`LibraryDb` 只补表补列、⛔ **不做旧版迁移**、⛔ **不用 WAL**。`pan/`：⛔ 目录只认 `dir` 位（`0`=目录/`1`=文件）。⛔ JVM 单测 `org.json`/`Base64` 是空壳 ⇒ 用 `MiniJson`/`OssAuth.base64`。
- 工程约定：minSdk 21/targetSdk 34/compileSdk 36/Media3 1.5.1；⛔ 不引 OkHttp/media3-ui/AppCompat/Material/RecyclerView。Gradle 8.10.2/AGP 8.7.0/Kotlin 2.1.0；**`JAVA_HOME` 用 JDK 21**。

## Flutter PC 端红线
- 最常踩三条：⛔ `chunkSize` 别放大（2→8 MiB⇒零成功播放）；⛔ `app_shell._items` 与 `app_router.branches` **必须同序**；⛔ 恢复备份后清设置缓存（`SettingsStore._cache`+`SettingsController`）。
- ★★ **macOS 原生全屏会拆掉 Flutter 焦点链** ⇒ `CallbackShortcuts` 整张表**同时**失灵、**不报错**（flutter#166237）⇒ `HardwareKeyboard` 兜底（⛔ `_rootFocus.hasFocus` 挡双触发）+ 原生 `makeFirstResponder`。
- ★★ **PC 独立播放窗口关窗必须报 `PlayerBridgeMethod.playerClosed`**（`_releasePlayer()` 开头，**幂等**）。⛔ 少它 = 进度最多晚 30 分钟上网盘 ⇒ **跨环境最后播放集数不同步**。
- ★★ `WorkDetail.primary` / 详情页 `primary` **走 `PlayTarget.resolve`**（续播点→看完仍播那集→第一条；先滤花絮）；分类口径 `(category IS NULL OR category='')`。⛔ `resumePositions` 与 `maxPositions` 别混：画进度条用后者、算该播哪一集用前者。
- ★★ 页面级 UI 测试**必须**注入 `appSupportDirProvider` ⇒ 缺了报 `UnimplementedError`（CI 红）。
- ★★ **PC 切集 = 点击即切**：`_beginEpisodeSwitch`（暂停旧流 + **不透明**罩「正在切换到 第N集…」）→ `_requestFreshTicket` → `_adoptRequest(keepLastFrame)` → 首帧收罩。⛔ `_clearAwaitingFrame` 在 `_switchOpened` 之前**必须忽略**旧流的 position/duration；⛔ 主窗口推新请求 / 播裸流要走 `_discardEpisodeSwitch`（否则罩子永远收不掉）；⛔ 切集时中继预热只等 **800ms**；连点两集走 `_queuedEpisode` + `_drainQueuedEpisode`。守卫 `player_window_app_test.dart`「切集」组。

## ★★ 网盘（→ HOWTO §百度网盘）
- ★★ **多网盘并存（无「当前网盘」）**：`AuthState` = `Map<DriveProvider,CloudAccount>`；`CloudDriveAdapter` = 唯一架构边界。⛔ 用到网盘处都收**显式** `DriveProvider`。选择器 `browseDriveChoiceProvider`/`scanDriveChoiceProvider`、`backupDriveProvider` = 首个 `canWrite`。⛔ `QrLoginDriver` 由**工厂**产出。
- ★★ **进度存储不认厂家**：键一律 `MediaItem.id` = `provider:fileId` ⇒ 两家共用同一份进度文件、同一套 LWW。守卫 `progress_provider_parity_test.dart`。⛔ 漏传 `provider:` = 静默互相覆盖。⚠️ 进度**上传**仍只落夸克（百度只读）。
- ★★ **进度条分母是时长**（`duration>0` 才画）⇒ 百度 `/api/list` 须带 `needmedia=1` 读 **`media_info.duration`**（秒）。★ 兜底 `saveDurationIfMissing`（只在空时写）。⛔⛔ `_toCompanion` 对 `durationMs == null` 必须 `Value.absent()`。守卫 `db_duration_backfill_test.dart`。
- ⛔ 百度**只读**（`canWrite=false`）；⛔ 直链**两跳**且 Dart 自动重定向丢 UA ⇒ 走 `applyTicketHeaders`；⛔ `bdstoken` 每条 `/api/*` 必带（读也要）；⛔ 目录用**路径**、列表在**顶层 `list`**、目录位 `isdir:1`。

## 测试 / 环境
- 纯函数优先、断言写「为什么」；⛔ **每个需求只跑相关单测，不回归全量**；修 bug **先加测试确认红**。Android 用 `:app:testDebugUnitTest --tests '…'`。⛔ 断言**终态**；终态前夹真 IO ⇒ 轮询（`_settleUntil`）。
- ⛔⛔ 本机 shell 带 `HTTP_PROXY/HTTPS_PROXY=127.0.0.1:5xxxx` ⇒ `flutter test` 必报 `Invalid WebSocket upgrade request`。一律 `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost`。
- ⚠️ Agent 沙箱里 `grep` 对某些文件**静默返回空** ⇒ 一律用 Grep 工具或 Read。
- 真机 `MiTV-MFTP0`（Android 28，`192.168.5.169:5555`）走 `android/tool/adb_tv.sh`；⛔ 别 `logcat -d | tail -N`（先存文件再 grep）；⛔ 软键盘吃 `keyevent 20/23` ⇒ 先 `key back`。⛔ 夸克直链 Cookie 要么不带要么带全（缺 `__puus`→**412**）。
