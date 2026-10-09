# 云影（cloudcine）长期约定

**两个互不引用的工程**：`android/` = ★ Android/TV 正式实现（原生 Kotlin，`com.cloudcine.tv`）；`lib/ macos/ windows/ pubspec.yaml` = Flutter PC 端。
- 细节下沉：理由 → `HOWTO.md`；逐日 → `YYYY-MM-DD.md`；产品 → `android/README.md`。**只留红线 + 标识符**；⚠️ 超 1.2 万字节被截断 ⇒ 加新条目**先删旧的**。

## 仓库结构 / 版本控制 / CI
- ⛔ 旧「Flutter 跑 Android」结论全失效 → §PC-1。⛔ 根 `tool/adb_tv.sh` 已死 ⇒ 用 `android/tool/adb_tv.sh`。⛔ `applicationId`/`versionCode` 别改（换包名 = 丢磁盘缓存）。
- ★★ **CI**：`packages/video_player_android` 是 path 依赖 ⇒ 其 `dev_dependencies` 不装 ⇒ 根 `analysis_options.yaml` 必须 `analyzer.exclude: packages/video_player_android/**`。
- ★★ `flutter analyze` **有 issue（含 info）即 exit 1** ⇒ 先找 info 级 lint；弃用 API 用 `// ignore: <rule>`。`git clean` 先 `-nd` 干跑。⛔ 别对仓库文件跑 `dart format`。

## ★★ 媒体库数据结构 = 跨端同步唯一契约（HOWTO）
- `cloudcine.sqlite`（PC `getApplicationSupportDirectory()/`，schema **17**）7 表：`media_items`·`media_works`·`subtitle_refs`·`scan_cursors`·`settings`·`playback_prefs`·`download_tasks`。⛔ 主键全是**文本**；⛔ `category` 默认**空串**。
- ⚠️ 进度三列（`resume_position_ms`·`max_position_ms`·`last_played_at`）**已降级为物化投影**；真源 = `playback_progress.json`（**不进 `.ccbak`**）。★★ 契约 `{v:1,items:{<id>:{r,m,p,u}}}`；**逐条 LWW，`m`·`p` 取并集**。⛔ 写前先 `load()`；`.tmp`+`rename`；⛔ **下载失败绝不上传**；★ `libraryModifiedAt` 摘掉 `last_played_at`。`LibraryDb(...)` 必传 `progress=`（`ProgressWiringTest` 守）。
- `.ccbak` = 全大端自定义容器（⛔ **不是 ZIP**）；目录 `云影备份`；文件名**必须带时间戳**；恢复 = **换掉整个 db**。★★ 同步判据 = `libraryModifiedAt`；本地空库让远程赢、远程空备份不覆盖本地；冲突 = 不同设备且差 < 60s。⛔ 不备份网盘凭证。

## ★★ 追剧 / 更新提醒（§9）
- 4 列在 `media_works`：`followed`/`follow_started_at`/`follow_checked_at`/`new_item_count`（schema **17**，无回填）。判据用 `first_seen_at` 做差（⛔ 不用 `modified_at`）。NEW = 追剧后新增 ∧ **`max_position_ms`·`last_played_at` 两条都空**。
- ★★ **「点过就不再是 NEW」两端同口径**：`last_played_at` 在**点击那一刻**写（`markPlayed`），⛔ **不等**进度落库、写完**必须重读该页**；⛔ 起播**不写** `max_position_ms`。PC 只下调计数、跟 `mergedInto`；Android 走 `onActivityResult(REQ_PLAYER)`。
- ⛔⛔ 自动检查**绝不写 `media_works.updated_at`**（污染同步 LWW）；节流零点 `settings.follow_last_check_at`（Unix **秒字符串**）。⛔ 目录失败不推进水位线（按**目录**回写）。⛔⛔ `FollowAutoCheck.off` 的 `throttleWindow == null` = 不节流 ⇒ 必须 `_run` 里**显式**挡掉。⛔ 手动入口 `force: true`；⛔ 扫描/刮削在跑时禁用。
- PC：`AppShell._FollowLaunchCheck`（延迟 20s + `every_6h`），⛔ 两个 `Timer` 必须 `dispose`；入口位置/角标口径见 §9。⚠️⚠️ **未修缺口**：增量统计与发现两套口径 ⇒ 新集归到新作品时增量恒 0、报「没有更新」（§9.12）。

## ★★ Android 端红线
- ⛔⛔ 电视上 **`AbsListView.OnItemClickListener` 按 OK 不触发** ⇒ `dispatchKeyEvent` 自管 OK，**DOWN 与 UP 都要吞**。
- ⛔⛔ `lateinit` 视图别在赋值用的 `apply` 块里调自己的上色函数（现象＝「点进去立刻弹回上一页、零报错」）⇒ **先赋值、再调用**。
- ⛔⛔ **覆盖层 / 菜单弹出前必须收软键盘**（IME 抢吃 ↑↓/OK）⇒ `showOverlay()` 先 `hideKeyboard()`；返回键键盘在才吞。
- ⛔ `applyWorks` 无条件 `requestFocus()` = 一级导航「点不动」；⛔ **光标态与生效态分离**（←→ 只移 `navIndex`，OK 才 `applyTab()`）。
- ★ `PlayTarget.resolve`（续播点→看完仍播那集→第一条；先滤花絮）；`PosterNaming` = `{sanitize(key)}_{FNV-1a32(url)8位}.jpg`；分类口径 `(category IS NULL OR category='')`。
- ★★ **「发现」= 局部扫描，只增不减**（`LibraryScanner.discover`）：⛔ 绝不 `pruneMissingItems`、绝不写 `scan_cursors`、`recursive=false`；归组复用已有 `group_key`。
- ★★ **作品简介页**（`Level.ITEMS`）：⛔ **OK 点卡片 = 进简介页**（`openWork`），不直接播。⛔ 两行胶囊 = **两套光标态**，**焦点始终留 `itemsList`**；⛔ 胶囊不可用**置灰不消失**。⛔ **主标题 = 文件名**，进度读 `max_position_ms`。⚠️ PC 拼「剧名-文件名」前缀，电视不拼。
- ★★ **归一并集**：⛔ `mergeWorksInto` 只给源行打 `merged_into`，**从不改写 `media_items.group_key`** ⇒ 查询 = 「自己名下 ∪ 源名下」（`itemsForWork`→`ownerKeyOf`、`listWorks`→`withUnionStats`、`unfinishedCount`）。⛔⛔ **并集不许塞进 `WORK_COLUMNS` 逐行子查询**（7.5s）⇒ 走**页级** `unionStats`。`checkFollow` 完站简介页走 `reloadCurrentItems()`。
- ★★ **刮削**（§5/§8）：TMDB 优先 + 豆瓣兜底。⛔ **TMDB 两代 Key 送法不同**：v4（`eyJ`）走 `Bearer`，v3（hex）走 `api_key`，送错 **401**。`AUTO_SCRAPE_ON_SCAN`：PC 关、Android 开。
- ★★ **扫描进度**（§8）：⛔ `PUBLISH_EVERY_MS=1000` **≫** `REPORT_EVERY_MS=400` 且在 `applyScanItems` 之后；UI 原地刷新。⛔ 未刮削封面用 `PanApi.thumbBytes`（带 Cookie；裸链 `401`）。
- ★★ **海报墙**（§AND-2）：`TARGET_CARD_DP` **同时**决定列数与卡高（**100dp → 8 列/2 行**）。⛔ 别低于 88dp；⛔ 卡片上留白 dp(8)→dp(4) 决定第二行能否完整露出；底部 dp(6) 不能动。
- `library/`：`LibrarySchema` = 唯一真源；`LibraryDb` 只补表补列、⛔ **不做旧版迁移**、补列须 `col.copy(notNull = false)`、⛔ **不用 WAL**；`LibraryItem` 带 `dirId`。`pan/`：`PanHttp`/`PanApi`/`OssAuth`/`QrLogin`/`CredStore`/`Bg`；⛔ 目录只认 `dir` 位（`0`=目录、`1`=文件）。
- `TvOsdView` 挂 `android.R.id.content` 之上，回调只回传**行下标** ⇒ 按 `Row.id` 分派。⛔ `SeekPlan` 松手才 `seekTo`，兜底 800 ms > 自动重复间隔。⛔ JVM 单测 `org.json`/`Base64` 是空壳 ⇒ 用 `MiniJson`/`OssAuth.base64`。
- 工程约定：minSdk 21/targetSdk 34/compileSdk 36/Media3 1.5.1；⛔ 不引 OkHttp/media3-ui/AppCompat/Material/RecyclerView。Gradle 8.10.2/AGP 8.7.0/Kotlin 2.1.0；**`JAVA_HOME` 用 JDK 21**。

## ★★ 真机调试 / 4K 卡顿
电视 `MiTV-MFTP0`（Android 28，`192.168.5.169:5555`）：走 `android/tool/adb_tv.sh`。⛔ 别 `logcat -d | tail -N` ⇒ 先存文件再 grep；⛔ 软键盘吃 `keyevent 20/23` ⇒ 先 `key back`。
4K 卡顿真因 = 默认播原画 ⇒ 默认播转码档（≥`4k`）。⛔ 夸克直链 Cookie 要么不带要么带全（缺 `__puus`→**412**）；⛔ `play/info` 必带 `pr=ucpro&fr=pc`；⛔ `video_list` 跳过 `audio_list`。

## Flutter PC 端红线
- 最常踩三条：⛔ `chunkSize` 别放大（2→8 MiB⇒零成功播放）；⛔ `app_shell._items` 与 `app_router.branches` **必须同序**（判据是**下标**）；⛔ 恢复备份后清设置缓存（`SettingsStore._cache`+`SettingsController`）。
- ★★ 页面级 UI 测试（裸铺 `LibraryPage` 等）**必须**注入 `appSupportDirProvider`（真临时目录）：页面读 `scanDriveProvider` 会连锁到 `credentialStoreProvider` ⇒ 缺了报 `UnimplementedError`（CI 红）。⛔ 别照抄设置页用例连 `posterCacheDirProvider` 一起注入 —— 媒体库页不读它（已实测）。

## ★★ 百度网盘（细节 → `2026-10-08/09.md`）
- 代码：`lib/data/remote/baidu/*` + `lib/data/auth/baidu_qr{_login,_driver}.dart`。⛔ 开放平台不可用（xpan 恒 `9019`）⇒ **BDUSS 扫码**。
- ★★ **直链两跳**：`d.pcs.baidu.com` **302** → `*.baidupcs.com`。⛔⛔ Dart 自动重定向丢 UA ⇒ **消费票据一律走 `applyTicketHeaders`**（手工贴头也须 `applyTicketUserAgent`）。
- ★★ **两通道吞吐差 30 倍**（10-09 实测）：`origin=dlna` 带 `vuk`、**只服务媒体**（视频/音频 1~2.9 MB/s；文档 `403 31329`）；不带 `origin` 覆盖全但**按账号**限速 ~80 KB/s ⇒ 取链**先带 dlna**，按 `info[].category`（1=视频·2=音频，`canUseDlna`）分流，非媒体**重取一次去 origin**。⛔ 普通通道**必须单连接**；⛔ **连接数不是提速杠杆**（1 vs 4 互有胜负；跑 ~10 MiB 后账号额度耗尽，1/4/8 一起归零）⇒ `maxConnections`+`connectionsFor()`（`withQuality`/`_mergeOriginalAndLadder` 都要带）。⛔ 无 `vuk` 直链**第一跳必带 `Cookie`**；⛔ `stallTimeout`(`_stallGuarded`) 兜「响应头到了包体不来」。
- ⛔⛔ 与夸克**三处结构性差异**：目录标识是**路径**（`dir=/电影`，`rootId='/'`）· 列表在**顶层 `list`** · 目录位 **`isdir:1`**。⛔ 原画哨兵**必须**用 `kOriginalQualityId`。
- ★★ **扫码链 4 步**：`getqrcode` → `unicast` → 换票 → 落地网盘域。⛔ 换票主线 `GET /v2/api/bdusslogin`、**不带 `loginVersion`**（`qrbdusslogin`=风控分支、`v5`=小程序分支）；④ 回 **302** ⇒ ⛔ 禁自动重定向、**但必须手动逐跳跟到 `pan.baidu.com`**（否则 `uinfo` 恒 `-6`）。
- ★★ **`bdstoken` 必带**（每条 `/api/*` 都带，**读也要**；缺了回 `-6` ⇒ 适配器「补令牌重试一次」自愈）。第 5 步换 **netdisk STOKEN**。⛔ 必带 `Origin`·`Referer`·浏览器 UA；⛔ 4 步**同一批 Cookie**。⚠️ `-6` **一码多义** ⇒ 打原始响应体。
- ★★ **多网盘并存（无「当前网盘」概念）**：`AuthState` = `Map<DriveProvider,CloudAccount>`。`CloudDriveAdapter` = 唯一架构边界（新网盘 = 实现 adapter + 加枚举值，必须 `extends` 继承四个抛 `unsupported` 的写默认）。⛔ 用到网盘处都收**显式** `DriveProvider`。
  - 视图选择（内存态、不持久化）：`browseDriveChoiceProvider`→`browseProvider`、`scanDriveChoiceProvider`→`scanDriveProvider`，默认首个已连网盘（无则 quark）。
  - 其他：`connectedDrivesProvider`（已登录）/`selectableDrivesProvider`（注册了 `AuthMode.qrCode` 的）/`accountForProviderProvider`/`backupDriveProvider`（首个 `canWrite` 的已连盘）。⛔ `QrLoginDriver` 由**工厂**产出（⛔ 不能用 `family` ⇒ 缓存实例 = 旧 sign）。

## 运维 / 打包 / 测试
- 采样/取证 → `HOWTO.md` §8；发版 → §10。
- ⛔⛔ **macOS Release 签名不许带 `get-task-allow`** ⇒ Runner **Release** 须 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`（⛔ 只关 Release；判据 `codesign -d --entitlements -`）。
- ★★ **发版**：tag 必须 `v*` 触发 `release.yml`。⛔⛔ **版本号两处同改**：`pubspec.yaml` 的 `version` 与 `android/app/build.gradle.kts` 的 `versionName`。
- 测试：纯函数优先、断言写「为什么」；⛔ **每个需求只跑相关单测，不回归全量**；修 bug **先加测试确认红**。Android 用 `:app:testDebugUnitTest --tests 'com.cloudcine.tv.library.*'`。⛔ 断言**终态**；终态前夹真 IO ⇒ 轮询（`_settleUntil`）。
