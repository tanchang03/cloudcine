# 云影（cloudcine）长期约定

**两个互不引用的工程**：`android/` = ★ Android / Android TV 正式实现（原生 Kotlin，`com.cloudcine.tv`）；`lib/ macos/ windows/ pubspec.yaml` = Flutter PC 端。
- 细节下沉：**理由/证据 → `HOWTO.md`**（PC §PC-1~8、Android §AND-1/§AND-2、运维/打包 §8）；逐日 → `YYYY-MM-DD.md`；产品文档 → `android/README.md`。**本文件只留红线 + 标识符**。
- ⚠️ **超约 1.2 万字节即被截断** ⇒ 加新条目**先删旧的**。
- 本机通用事实（gvm / `NO_PROXY` / 沙箱 / `ps`→`pgrep` / `git push` 要 `HOME`）见 `~/.workbuddy-ai/MEMORY.md`。

## 仓库结构 / 版本控制 / CI
- Android = 原生 Kotlin 独立工程；Flutter 只 PC 端。⛔ 旧「Flutter 跑在 Android 上」的结论**全部失效**（fvp/ExoPlayer、media_kit 零拷贝、TvOsdView 挂 FlutterView、`hwdec`、`platformView`、`tunnel:true`、DV P5）→ HOWTO §PC-1。
- ⛔ 根 `tool/adb_tv.sh` **已死** ⇒ 用 `android/tool/adb_tv.sh`。⛔ `applicationId` / `versionCode=1` 别改（换包名 = 丢磁盘缓存）。
- ★★ **CI**：`packages/video_player_android` 是 `dependency_overrides` 的 **path 依赖**；⛔⛔ **path 依赖的 dev_dependencies 不会被安装** ⇒ 它 `pigeons/`、`test/` 里的 `pigeon`/`mockito` 解析不到 ⇒ 根 `analysis_options.yaml` 必须 `analyzer.exclude: packages/video_player_android/**`，否则 `flutter analyze` 报 **128 条 `uri_does_not_exist`**。
- ★★ `flutter analyze` **有任何 issue（含 info）就 exit 1** ⇒ 先找 info 级 lint；刻意保留的弃用 API 用 `// ignore: <rule>`（`player_page.dart` 的 `WillPopScope`）。
- 攒够一小轮就 commit；`git clean` 先 `-nd` 干跑。⛔ 不代用户 `git add`/`commit`；提交前核对 `git diff --cached`。⛔ 别对仓库文件跑 `dart format`。

## ★★ 媒体库数据结构 = 跨端同步的唯一契约（→ HOWTO「`cloudcine.sqlite`」/「`.ccbak`」）
- `cloudcine.sqlite`（PC `getApplicationSupportDirectory()/`，`schemaVersion = 17`）7 表：`media_items`(PK `id`)·`media_works`(PK `key`)·`subtitle_refs`·`scan_cursors`·`settings`·`playback_prefs`·`download_tasks`（权威 `lib/data/db/tables.dart`）。⛔ 主键全是**文本**；⛔ `category` 默认**空串**。
- `.ccbak` = 全大端 `['CCBK'][manifestLen][manifest][dbLen][db][posters]`，⛔ **不是 ZIP**；目录 `云影备份`；文件名**必须带时间戳**；恢复 = 换掉整个 db。★★ 同步判据 **`libraryModifiedAt`**（**不是** `createdAt`）；本地空库让远程赢、远程空备份绝不覆盖本地；冲突 = 不同设备且差 < 60s。⛔ 不备份网盘凭证。

## ★★ 追剧 / 更新提醒（→ HOWTO **§9**）
- 4 列在 `media_works`：`followed`/`follow_started_at`/`follow_checked_at`/`new_item_count`（schema **17**，无回填）。判据全靠 `first_seen_at` 做差，⛔ **不用 `modified_at`**。NEW 行 = 追剧后新增 ∧ **`max_position_ms` 与 `last_played_at` 两条都空**。
- ★★ **「点过就不再是 NEW」两端同口径（→ §9.10/§9.11）**：`last_played_at` 在**点击那一刻**写（`markPlayed`），**不等**进度落库；⛔ 写完**必须重读该页**。PC `play_action._markOpened` + `syncFollowReadCount`（**只下调**、跟 `mergedInto` 走）；Android `LibraryActivity.play()` + `onActivityResult(REQ_PLAYER)` → `reloadCurrentItems()`。⛔ 起播**不写** `max_position_ms`。
- ⛔⛔ 自动检查**绝不写 `media_works.updated_at`**（污染同步 LWW）；节流零点 `settings.follow_last_check_at`（Unix **秒字符串**）。⛔ 目录失败不推进水位线；水位线取「发现跑完之后」；按**目录**回写。⛔⛔ `FollowAutoCheck.off` 的 `throttleWindow == null` = 不节流 ⇒ 必须在 `_run` 里**显式**挡掉。⛔ 手动入口 `force: true`；⛔ 扫描/刮削在跑时禁用。
- PC：`AppShell._FollowLaunchCheck`（延迟 20s + `every_6h`），⛔ 两个 `Timer` 必须 `dispose` cancel；「检查更新」在**分类栏右端**（⛔ 桌面页头 8 控件已满）；角标 = `new_item_count > 0` 的作品数；⛔ 不加侧栏一级入口。⛔ 恢复备份后 `_refreshLibraryViews` invalidate 六个。

## ★★ Android 端红线（→ HOWTO §AND-1）
- ⛔⛔ 电视上 **`AbsListView.OnItemClickListener` 按 OK 不触发** ⇒ `dispatchKeyEvent` 自管 OK，**DOWN 与 UP 都要吞**（只吞 DOWN = 一按播两遍）。
- ⛔⛔ **`lateinit` 视图别在赋值用的 `apply` 块里调自己的上色函数** ⇒ `UninitializedPropertyAccessException`；**现象 =「点进去立刻弹回上一页、零报错」** ⇒ **先赋值、再调用**。
- ⛔⛔ **覆盖层 / 菜单弹出前必须收软键盘**（IME 抢吃 ↑↓/OK ⇒ 菜单一行都选不动）⇒ `showOverlay()` 先 `hideKeyboard()`；返回键**键盘在才吞**。
- ⛔ `applyWorks` 无条件 `requestFocus()` = 一级导航「点不动」；⛔ **光标态与生效态分离**（←→ 只移 `navIndex`，OK 才 `applyTab()`）。⛔ 深色 UI 靠**实心面明度**不靠描边（`MenuRow.kt`：实心圆角块 + 左 4dp 竖条）。
- ★ `PlayTarget.resolve`（续播点 → 看完仍播那集 → 第一条；先滤花絮）；`PosterNaming` = `{sanitize(key)}_{FNV-1a32(url) 8位}.jpg` 现算；分类口径 `(category IS NULL OR category='')`；画质 chip **只放短名**。
- ★★ **「发现」= 局部扫描，只增不减**（`LibraryScanner.discover`）：⛔ 绝不 `pruneMissingItems`、绝不写 `scan_cursors`、`recursive=false`；归组**复用已有 `group_key`**。入仓判据 `!isVideoFile(name) || isDiscImage(name)`（`.iso` 在视频白名单里，只能靠 `isDiscImage` 拦）。
- ★★ **作品简介页**（`Level.ITEMS`，→ §6/§7）：⛔ **OK 点卡片 = 进简介页**（`openWork`），不直接播。⛔ 两行胶囊 = **两套光标态**，**焦点始终留 `itemsList`**；⛔ 胶囊不可用**置灰不消失**；⛔ `items` 别「先填后清」（`sortItems` 拿空列表 ⇒ 列表永远空、**不报错**）。⛔ **主标题 = 文件名**（`EpisodeLabels.fileLabel`），进度读 `max_position_ms`。⚠️ PC 拼「剧名-文件名」前缀，电视**刻意不拼**。
- ★★ **归一并集**（「遮天」TV 1 / PC 13）：⛔ `mergeWorksInto` 只给源行打 `merged_into`，**从不改写 `media_items.group_key`** ⇒ 查询 = 「自己名下 ∪ 源名下」（`itemsForWork` 先 `ownerKeyOf`、`listWorks`→`withUnionStats`、`unfinishedCount`）。⛔⛔ **并集不许塞进 `WORK_COLUMNS` 逐行子查询**：等值 21ms vs `IN (SELECT …)` **7.5s** ⇒ 走**页级** `unionStats`（4ms）。⛔ 简介页「N 集」走 `workForDetail`；`workByKey` 保持存值给写路径。⛔ `checkFollow` 完站简介页时走 `reloadCurrentItems()`。
- ★★ **刮削**（`library/Scrape*`，→ §5/§8）：双源**拼接**（TMDB 优先 + 豆瓣兜底）。⛔ **TMDB 两代 Key 送法不同**：v4（`eyJ`）走 `Authorization: Bearer`，v3（32 位 hex）走 `api_key` —— 送错回 **401 `Invalid API key`** ⇒ `TmdbScraper.isV4Token` 与 PC **逐字一致**。⛔ 「测试」用**输入框当前值**、不碰熔断；⛔ 标题拿不到返 `null`；熔断必须会过期。⛔ 自动刮削先过闸门 `ScrapeMatch`（`MAX_YEAR_GAP=2`/`STRONG=0.6`/`WEAK=0.35`）+ `ScrapeQueryBuilder`（`requiresExactTitle` = 电影且无年份）；`AutoScraper` 提前退出：取消 / 全源熔断 / `scraped==0 && 连续未命中 ≥ 12`；`ScrapeSourceBudget` **慢且空**才算失败（`SLOW_MS=8000`）。`AUTO_SCRAPE_ON_SCAN`：PC 关、Android 开。
- ★★ **扫描进度与封面**（→ §8）：⛔ `PUBLISH_EVERY_MS=1000` **必须远大于** `REPORT_EVERY_MS=400` 且在 `applyScanItems` 之后；UI **原地刷新**（别 `loadWorks()`）。⛔ 未刮削封面用 `PanApi.thumbBytes`（带 Cookie；裸链 `401 code=31001`）。
- ★★ **海报墙**（→ HOWTO **§AND-2**）：`TARGET_CARD_DP` **同时**决定列数与卡高（2:3 ⇒ 高 = 宽 × 1.5）；实测 132dp → 6 列/1.3 行，**100dp → 8 列/完整 2 行（6 部 → 16 部）**。⛔ 别低于 88dp；⛔ 卡片**上留白 dp(8)→dp(4) 决定第二行能否完整露出**；底部 dp(6) 不能动（圆角裁切切片名的角）。
- `library/`：`LibrarySchema` = 唯一真源（7 条 DDL 与 Dart 逐字一致，`LibrarySchemaTest` 守着）；`LibraryDb` 只补表补列、⛔ **不做 v1→v16 迁移**、补列必须 `col.copy(notNull = false)`、⛔ **不用 WAL**；`LibraryItem` 必须带 `dirId`。
- `pan/`：`PanHttp`（`HttpURLConnection`，不引 OkHttp）/`PanApi`/`OssAuth`/`QrLogin`（业务码读 `bizCode`）/`CredStore`/`Bg`。⛔ 速率用 `CountingDataSource` 数字节；⛔ 目录判定只认 `dir` 布尔位（`file_type` `0`=目录、`1`=文件）。
- `TvOsdView` 挂 `android.R.id.content` 之上，回调只回传**行下标** ⇒ 按 `Row.id` 分派。⛔ `SeekPlan`：松手才 `seekTo`，兜底 800 ms > 自动重复间隔。⛔ `UI fps` 不可用于比较；⛔ JVM 单测里 `org.json`/`android.util.Base64` 是空壳 ⇒ 用 `MiniJson`/`OssAuth.base64`。
- 工程约定：minSdk 21 / targetSdk 34 / compileSdk 36 / Media3 1.5.1；⛔ 不引 OkHttp / media3-ui / AppCompat / Material / RecyclerView。Gradle 8.10.2 / AGP 8.7.0 / Kotlin 2.1.0；**`JAVA_HOME` 用 JDK 21**。

## ★★ 真机调试（电视 = `MiTV-MFTP0`，Android 28，1920×1080 / density 320，`192.168.5.169:5555`）
- 装机/日志/按键/截图走 `android/tool/adb_tv.sh`；⛔ `find_apk` **按 mtime 取最新**。⛔ **别用 `logcat -d | tail -N`**（噪声会截掉 `FATAL EXCEPTION`）⇒ **先存文件再 grep**。
- ★ **量版式别靠目测**：`uiautomator dump` 拿每个控件的 `bounds`（静态页可用；⚠️ 播放页 dump 不出）。`am start` 直启 + `screencap` 是最快回路；吃 extras 的页可直启（`am start -n com.cloudcine.tv/.ScrapeActivity --es scrape_work_key <k> --es scrape_work_title <t>`）。⛔ 软键盘会吃掉 `input keyevent 20/23` ⇒ 先 `key back`。

## ★★ 4K 卡顿的真因：播错了档位（→ HOWTO 同名节）
夸克默认档 `super`、云影默认播**原画** ⇒ 单连接喂不动 ⇒ 8 连接中继 ⇒ 主线程饿死。**不是解码 / 渲染面 / OSD** ⇒ 默认播转码档（≥`4k`，`probeThroughput` → `chooseQuality`）。
- ⛔ 直链 Cookie **「要么不带，要么带全」**：带 `__puus` → **206**；有 `__pus` 缺 `__puus` → **412**；不带 → **206**。`__puus` 每个响应轮换下发（`PanApi.absorbCookies`）。
- ⛔ `batch/file/play/info` **必须带 `pr=ucpro&fr=pc`**（漏了回 `401 code=31001`）；⛔ `useCaches = false` 不能省；⛔ 解析 `video_list` **必须跳过 `audio_list`**（否则有声音、进度条在走、**没画面、不报错**）。

## Flutter PC 端红线
- ★ **索引已下沉到 `HOWTO.md`**（搜 `## Flutter PC 端红线`）：引擎/硬解、中继 416、媒体库三轴、播放器、侧栏、下载 v16、TV 布局、OSD 卡顿、**追剧（§9）**。此处不重复。
- 最常踩的三条：⛔ `chunkSize` 别放大（2→8 MiB ⇒ 零成功播放）；⛔ `app_shell._items` 与 `app_router.branches` **必须同序**（判据是**下标**）；⛔ 恢复备份后要清设置缓存（`SettingsStore._cache` + `SettingsController`）。
- ★ 行标题口径 `MediaItem.rowLabel(RowLabelStyle, {workTitle})`：**提不出集号时退回「剧名-文件名」，绝不退回片名**。

## 运维 / 打包 / 测试
- 采样 / 取证 / 打包判据**已下沉到 `HOWTO.md` §8**。⛔ 本机**出不了 Flutter release 包**。
- 测试：纯函数优先、断言写「为什么重要」；⛔ **每个需求只跑相关单测，不回归全量**；修 bug **先加测试确认红**。Android 跑 `./gradlew :app:testDebugUnitTest --tests 'com.cloudcine.tv.library.*'`（JDK 21）。
