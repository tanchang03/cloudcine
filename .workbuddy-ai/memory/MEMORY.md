# 云影（cloudcine）长期约定

**两个互不引用的工程**：`android/` = ★ Android / Android TV 正式实现（原生 Kotlin，`com.cloudcine.tv`）；`lib/ macos/ windows/ pubspec.yaml` = Flutter PC 端。
- 细节下沉：**理由/证据 → `HOWTO.md`**；逐日 → `YYYY-MM-DD.md`；产品文档 → `android/README.md`。**本文件只留红线 + 标识符**；⚠️ 超 1.2 万字节即被截断 ⇒ 加新条目**先删旧的**。
- 本机通用事实（gvm / `NO_PROXY` / 沙箱 / `git push`）见 `~/.workbuddy-ai/MEMORY.md`。

## 仓库结构 / 版本控制 / CI
- Android = 原生 Kotlin 独立工程；Flutter 只 PC 端。⛔ 旧「Flutter 跑在 Android 上」的结论**全部失效**（fvp / media_kit 零拷贝 / FlutterView / `hwdec` / `platformView` / `tunnel:true` / DV P5）→ §PC-1。
- ⛔ 根 `tool/adb_tv.sh` 已死 ⇒ 用 `android/tool/adb_tv.sh`。⛔ `applicationId` / `versionCode` 别改（换包名 = 丢磁盘缓存）。
- ★★ **CI**：`packages/video_player_android` 是 path 依赖 ⇒ 其 `dev_dependencies` 不安装 ⇒ `pigeons/`·`test/` 的 `pigeon`/`mockito` 解析不到 ⇒ 根 `analysis_options.yaml` 必须 `analyzer.exclude: packages/video_player_android/**`。
- ★★ `flutter analyze` **有任何 issue（含 info）就 exit 1** ⇒ 先找 info 级 lint；刻意保留的弃用 API 用 `// ignore: <rule>`。
- 攒够一小轮就 commit；`git clean` 先 `-nd` 干跑。⛔ 不代用户 `git add`/`commit`；提交前核对 `git diff --cached`。⛔ 别对仓库文件跑 `dart format`。

## ★★ 媒体库数据结构 = 跨端同步的唯一契约（→ HOWTO「`cloudcine.sqlite`」/「`.ccbak`」）
- `cloudcine.sqlite`（PC `getApplicationSupportDirectory()/`，`schemaVersion = 17`）7 表：`media_items`(PK `id`)·`media_works`(PK `key`)·`subtitle_refs`·`scan_cursors`·`settings`·`playback_prefs`·`download_tasks`（权威 `lib/data/db/tables.dart`）。⛔ 主键全是**文本**；⛔ `category` 默认**空串**。
- ⚠️ 播放进度三列（`resume_position_ms`·`max_position_ms`·`last_played_at`）**已降级为物化投影**；真源 = `playback_progress.json`（**不进 `.ccbak`**）⇒ 清理/恢复媒体库**不再丢进度**。★★ 契约 `{v:1,items:{<id>:{r,m,p,u}}}`（ms·ms·秒·秒）；**逐条 LWW，但 `m`·`p` 取并集**。⛔ 写前必先 `load()`；`.tmp`+`rename`；⛔ **下载失败绝不上传**；★ `libraryModifiedAt` **已摘掉 `last_played_at`**。触发：启动+退出播放器+30 分钟；恢复/重扫后 `backfill()`。⛔ `ProgressStore` 进程单例；`LibraryDb(...)` 必传 `progress =`（`ProgressWiringTest` 守）→ 契约/类文档见 `library/PlaybackProgress.kt`
- `.ccbak` = 全大端 `['CCBK'][manifestLen][manifest][dbLen][db][posters]`，⛔ **不是 ZIP**；目录 `云影备份`；文件名**必须带时间戳**；恢复 = **换掉整个 db**。★★ 同步判据 **`libraryModifiedAt`**（**不是** `createdAt`）；本地空库让远程赢、远程空备份不覆盖本地；冲突 = 不同设备且差 < 60s。⛔ 不备份网盘凭证。

## ★★ 追剧 / 更新提醒（→ HOWTO **§9**）
- 4 列在 `media_works`：`followed`/`follow_started_at`/`follow_checked_at`/`new_item_count`（schema **17**，无回填）。判据全靠 `first_seen_at` 做差（⛔ 不用 `modified_at`）。NEW = 追剧后新增 ∧ **`max_position_ms`·`last_played_at` 两条都空**。
- ★★ **「点过就不再是 NEW」两端同口径（→ §9.10/9.11）**：`last_played_at` 在**点击那一刻**写（`markPlayed`），⛔ **不等**进度落库、写完**必须重读该页**；⛔ 起播**不写** `max_position_ms`。PC 只下调计数、跟 `mergedInto`；Android 走 `onActivityResult(REQ_PLAYER)`。
- ⛔⛔ 自动检查**绝不写 `media_works.updated_at`**（污染同步 LWW）；节流零点 `settings.follow_last_check_at`（Unix **秒字符串**）。⛔ 目录失败不推进水位线（水位线取「发现跑完之后」、按**目录**回写）。⛔⛔ `FollowAutoCheck.off` 的 `throttleWindow == null` = 不节流 ⇒ 必须 `_run` 里**显式**挡掉。⛔ 手动入口 `force: true`；⛔ 扫描/刮削在跑时禁用。
- PC：`AppShell._FollowLaunchCheck`（延迟 20s + `every_6h`），⛔ 两个 `Timer` 必须 `dispose` cancel；「检查更新」在**分类栏右端**；角标 = `new_item_count > 0` 的作品数；⛔ 不加侧栏一级入口。⛔ 恢复备份后 `_refreshLibraryViews` invalidate 六个。
- ⚠️⚠️ **已知缺口（2026-10-07，未修）**：检查更新的**增量统计与它触发的发现是两套口径** ⇒ 发现把新集归到**新作品**上时增量恒 0、报「没有更新」（细节 → §9.12）。另：`导入 .ccbak` **整库替换**。

## ★★ Android 端红线（→ HOWTO §AND-1）
- ⛔⛔ 电视上 **`AbsListView.OnItemClickListener` 按 OK 不触发** ⇒ `dispatchKeyEvent` 自管 OK，**DOWN 与 UP 都要吞**（只吞 DOWN = 一按播两遍）。
- ⛔⛔ **`lateinit` 视图别在赋值用的 `apply` 块里调自己的上色函数** ⇒ `UninitializedPropertyAccessException`；**现象 =「点进去立刻弹回上一页、零报错」** ⇒ **先赋值、再调用**。
- ⛔⛔ **覆盖层 / 菜单弹出前必须收软键盘**（IME 抢吃 ↑↓/OK）⇒ `showOverlay()` 先 `hideKeyboard()`；返回键**键盘在才吞**。
- ⛔ `applyWorks` 无条件 `requestFocus()` = 一级导航「点不动」；⛔ **光标态与生效态分离**（←→ 只移 `navIndex`，OK 才 `applyTab()`）。⛔ 深色 UI 靠**实心面明度**不靠描边。
- ★ `PlayTarget.resolve`（续播点 → 看完仍播那集 → 第一条；先滤花絮）；`PosterNaming` = `{sanitize(key)}_{FNV-1a32(url)8位}.jpg` 现算；分类口径 `(category IS NULL OR category='')`；画质 chip **只放短名**。
- ★★ **「发现」= 局部扫描，只增不减**（`LibraryScanner.discover`）：⛔ 绝不 `pruneMissingItems`、绝不写 `scan_cursors`、`recursive=false`；归组**复用已有 `group_key`**。入仓判据 `!isVideoFile(name) || isDiscImage(name)`。
- ★★ **作品简介页**（`Level.ITEMS`，→ §6/§7）：⛔ **OK 点卡片 = 进简介页**（`openWork`），不直接播。⛔ 两行胶囊 = **两套光标态**，**焦点始终留 `itemsList`**；⛔ 胶囊不可用**置灰不消失**；⛔ `items` 别「先填后清」。⛔ **主标题 = 文件名**，进度读 `max_position_ms`。⚠️ PC 拼「剧名-文件名」前缀，电视**刻意不拼**。
- ★★ **归一并集**（「遮天」TV 1 / PC 13）：⛔ `mergeWorksInto` 只给源行打 `merged_into`，**从不改写 `media_items.group_key`** ⇒ 查询 = 「自己名下 ∪ 源名下」（`itemsForWork` 先 `ownerKeyOf`、`listWorks`→`withUnionStats`、`unfinishedCount`）。⛔⛔ **并集不许塞进 `WORK_COLUMNS` 逐行子查询**（`IN (SELECT …)` 7.5s）⇒ 走**页级** `unionStats`。⛔ 简介页「N 集」走 `workForDetail`。⛔ `checkFollow` 完站简介页走 `reloadCurrentItems()`。
- ★★ **刮削**（`library/Scrape*`，→ §5/§8）：双源拼接（TMDB 优先 + 豆瓣兜底）。⛔ **TMDB 两代 Key 送法不同**：v4（`eyJ`）走 `Authorization: Bearer`，v3（32 位 hex）走 `api_key`，送错回 **401**（`TmdbScraper.isV4Token` 与 PC **逐字一致**）。⛔ 「测试」用**输入框当前值**、不碰熔断；⛔ 标题拿不到返 `null`；熔断必须会过期。`AUTO_SCRAPE_ON_SCAN`：PC 关、Android 开。
- ★★ **扫描进度与封面**（→ §8）：⛔ `PUBLISH_EVERY_MS=1000` **必须远大于** `REPORT_EVERY_MS=400` 且在 `applyScanItems` 之后；UI **原地刷新**（别 `loadWorks()`）。⛔ 未刮削封面用 `PanApi.thumbBytes`（带 Cookie；裸链 `401`）。
- ★★ **海报墙**（→ HOWTO **§AND-2**）：`TARGET_CARD_DP` **同时**决定列数与卡高（2:3 ⇒ 高 = 宽 × 1.5）；实测 **100dp → 8 列/完整 2 行**。⛔ 别低于 88dp；⛔ 卡片**上留白 dp(8)→dp(4) 决定第二行能否完整露出**；底部 dp(6) 不能动。
- `library/`：`LibrarySchema` = 唯一真源（7 条 DDL 与 Dart 逐字一致，`LibrarySchemaTest` 守着）；`LibraryDb` 只补表补列、⛔ **不做 v1→v16 迁移**、补列必须 `col.copy(notNull = false)`、⛔ **不用 WAL**；`LibraryItem` 必须带 `dirId`。
- `pan/`：`PanHttp`（`HttpURLConnection`，不引 OkHttp）/`PanApi`/`OssAuth`/`QrLogin`（业务码读 `bizCode`）/`CredStore`/`Bg`。⛔ 速率用 `CountingDataSource` 数字节；⛔ 目录判定只认 `dir` 布尔位（`file_type` `0`=目录、`1`=文件）。
- `TvOsdView` 挂 `android.R.id.content` 之上，回调只回传**行下标** ⇒ 按 `Row.id` 分派。⛔ `SeekPlan`：松手才 `seekTo`，兜底 800 ms > 自动重复间隔。⛔ `UI fps` 不可用于比较；⛔ JVM 单测里 `org.json`/`android.util.Base64` 是空壳 ⇒ 用 `MiniJson`/`OssAuth.base64`。
- 工程约定：minSdk 21 / targetSdk 34 / compileSdk 36 / Media3 1.5.1；⛔ 不引 OkHttp / media3-ui / AppCompat / Material / RecyclerView。Gradle 8.10.2 / AGP 8.7.0 / Kotlin 2.1.0；**`JAVA_HOME` 用 JDK 21**。

## ★★ 真机调试（电视 = `MiTV-MFTP0`，Android 28，1920×1080 / density 320，`192.168.5.169:5555`）
- 装机/日志/按键/截图走 `android/tool/adb_tv.sh`；⛔ `find_apk` **按 mtime 取最新**。⛔ **别用 `logcat -d | tail -N`**（噪声会截掉 `FATAL EXCEPTION`）⇒ **先存文件再 grep**。
- ★ **量版式别靠目测**：`uiautomator dump` 拿控件 `bounds`（静态页可用；⚠️ 播放页 dump 不出）。`am start` 直启 + `screencap` 是最快回路。⛔ 软键盘会吃掉 `input keyevent 20/23` ⇒ 先 `key back`。

## ★★ 4K 卡顿的真因：播错了档位（→ HOWTO 同名节）
夸克默认档 `super`、云影默认播**原画** ⇒ 单连接喂不动 ⇒ 8 连接中继 ⇒ 主线程饿死。**不是解码 / 渲染面 / OSD** ⇒ 默认播转码档（≥`4k`，`probeThroughput` → `chooseQuality`）。
- ⛔ 直链 Cookie **「要么不带，要么带全」**（带 `__puus` → 206；有 `__pus` 缺 `__puus` → **412**）；⛔ `play/info` 必带 `pr=ucpro&fr=pc`；⛔ 解析 `video_list` **必须跳过 `audio_list`**（否则有声有进度、**没画面、不报错**）。

## Flutter PC 端红线（索引 → HOWTO 同名节：引擎/硬解·中继 416·媒体库三轴·播放器·侧栏·下载·TV 布局·OSD·**追剧 §9**）
- 最常踩的三条：⛔ `chunkSize` 别放大（2→8 MiB ⇒ 零成功播放）；⛔ `app_shell._items` 与 `app_router.branches` **必须同序**（判据是**下标**）；⛔ 恢复备份后要清设置缓存（`SettingsStore._cache` + `SettingsController`）。
- ★ 行标题口径 `MediaItem.rowLabel(RowLabelStyle, {workTitle})`：**提不出集号时退回「剧名-文件名」，绝不退回片名**。

## 运维 / 打包 / 测试
- 采样 / 取证 / 打包判据 → `HOWTO.md` §8；**发版流程 → §10**。⛔ 本机**出不了 Flutter release 包**。
- ⛔⛔ **macOS Release 签名不许带 `get-task-allow`**（Xcode **构建期注入**）⇒ Runner **Release** 配置须 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`（⛔ 只关 Release，Debug/Profile 保留否则 `flutter run` 连不上 VM Service；判据只有 `codesign -d --entitlements -`）→ §8。
- ★★ **发版**：tag 必须 `v*` 才触发 `release.yml`。⛔⛔ **版本号两个源头必须同改**：`pubspec.yaml` 的 `version` 与 `android/app/build.gradle.kts` 的 `versionName`。⛔ `versionCode` 单调递增、`applicationId` 不许动。
- 测试：纯函数优先、断言写「为什么重要」；⛔ **每个需求只跑相关单测，不回归全量**；修 bug **先加测试确认红**。Android 用 `:app:testDebugUnitTest --tests 'com.cloudcine.tv.library.*'`（JDK 21）。⛔ 断言**终态**而终态前夹真文件 IO ⇒ 用轮询（`_settleUntil`），别用固定拍数。
