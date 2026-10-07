# 云影（cloudcine）长期约定

**两个互不引用的工程**：`android/` = ★ Android / Android TV 正式实现（原生 Kotlin，`com.cloudcine.tv`）；`lib/ macos/ windows/ pubspec.yaml` = Flutter PC 端。
- 细节下沉：**理由/实测证据 → `HOWTO.md`**（PC 端 §PC-1~8、**PC 红线索引**、**Android 端 §AND-1**）；逐日经过 → `YYYY-MM-DD.md`；产品文档 → `android/README.md`。本文件只留**红线 + 标识符**。
- ⚠️ **超约 1.2 万字节即被注入截断** ⇒ 加新条目**先删旧的**，目标 ≤ 11000 字节；**新细节写进 HOWTO**。
- 本机通用事实（gvm / `NO_PROXY` / 沙箱 / `ps`→`pgrep` / `git push` 要 `HOME` / **同文件两条 Edit 互相覆盖**）见 `~/.workbuddy-ai/MEMORY.md`。

## 仓库结构 / 版本控制
- Android = 原生 Kotlin 独立工程；Flutter 只 PC 端。Flutter 的 Android 宿主已整体移出（备份 `~/.workbuddy-ai/backups/cloudcine-flutter-android-20261006-173700/`）；`git mv prototype/cloudcine android`。
- ⛔ 旧记忆里一切「Flutter 在 Android 上」的结论**全部失效**（fvp/ExoPlayer 路由、media_kit 零拷贝、TvOsdView 挂 FlutterView、Dart 主 isolate 中继、`hwdec`、`platformView`、`tunnel:true`、DV P5）→ HOWTO §PC-1。
- ⛔ 根 `tool/adb_tv.sh` **已死** ⇒ 用 `android/tool/adb_tv.sh`。⛔ `packages/video_player_android` 仍在仓库根（pubspec path 依赖）。⛔ `applicationId` / `versionCode=1` 别改（换包名 = 丢磁盘缓存）。
- 攒够一小轮就 commit；`git clean` 先 `-nd` 干跑。⛔ 不代用户 `git add`/`commit`；提交前核对 `git diff --cached`（中途 `git add` 过快照会**静默提交已废弃但能编译的设计**，修法 `git add -A`）。⛔ 别对仓库文件跑 `dart format`。

## ★★ 媒体库数据结构 = 跨端同步的唯一契约（细节 → HOWTO §1/§2/§AND-1）
- `cloudcine.sqlite`（PC 路径 `getApplicationSupportDirectory()/`）：drift `schemaVersion = 16` → SQLite `user_version`；7 表 `media_items`(PK `id`)·`media_works`(PK `key`)·`subtitle_refs`·`scan_cursors`·`settings`·`playback_prefs`·`download_tasks`（列名 = Dart 字段 snake_case，权威 `lib/data/db/tables.dart`）。
- ⛔ 主键全是**文本**（`provider:fileId`）；⛔ `media_works.category` 默认**空串**（= 没判定过）；⛔ `resolution`/`container`/`status` 存**枚举名**，`flags`/`genres` 是 **JSON 数组字符串**（默认 `'[]'`），布尔 0/1，时间列 **Unix 秒**；迁移见 `app_database.dart onUpgrade`（**有回填的只有 v6/v7/v10/v15**）。
- 备份包 `.ccbak`：全大端 `['CCBK'][manifestLen][manifest][dbLen][db][posters]`，⛔ **不是 ZIP**；默认目录 `云影备份`；文件名**必须带时间戳**。恢复 = `db.replaceWithRawBytes(整库字节)` ⇒ **`settings` 表随之走**。
- ★★ 同步判据是 **`libraryModifiedAt`**（**不是** `createdAt`）；空库 `effectiveModifiedAt` 退化成 `createdAt`（**不是 0**）；库变更口径 = `MAX(media_works.updated_at)` ∪ `MAX(media_items.first_seen_at)` ∪ `MAX(media_items.last_played_at)`；本地空库让远程赢、远程空备份绝不覆盖本地；冲突 = 不同设备且差 < 60s。⛔ 不备份网盘凭证；⛔ `includeSettings`/`restoreSettings` 是**空开关**。

## ★★ Android 端红线（细节 → HOWTO §AND-1）
- ⛔⛔ 电视上 **`AbsListView.OnItemClickListener` 按 OK 不触发** ⇒ 在 `dispatchKeyEvent` 自管 OK，**DOWN 与 UP 都要吞**（只吞 DOWN = 一按播两遍）。
- ⛔⛔ **`lateinit` 视图别在赋值用的 `apply` 块里调自己的上色函数**：`saveButton = TextView(this).apply { …; paintSaveButton(false) }` 里那个函数读的就是 `saveButton` ⇒ `UninitializedPropertyAccessException` ⇒ 系统 `Force finishing activity`。**现象是「点进去立刻弹回上一页、零报错」**（2026-10-07 `ScrapeSettingsActivity`）。⇒ **先赋值、再调用**；`navOrder = listOf(…, saveButton)` 同理。
- ⛔⛔ **覆盖层 / 菜单弹出前必须收软键盘**：搜索框持焦点时 IME 抢在 Activity 前吃掉 ↑↓/OK，菜单弹出来**一行都选不动**且下半屏被盖住 ⇒ `showOverlay()` 里先 `hideKeyboard()`。返回键：**键盘在才吞**（`keyboardUp`），否则放行 —— 无条件吞 = 用户被困在页里只能按 HOME。
- ⛔ `applyWorks` 无条件 `requestFocus()` = 一级导航「点不动」；⛔ **光标态与生效态分离**（←→ 只移 `navIndex`，OK 才 `applyTab()`）。
- ★ 取片 `PlayTarget.resolve`（续播点 → 看完仍播那集 → 第一条；先滤花絮）；海报名 `PosterNaming` = `{sanitize(key)}_{FNV-1a32(url) 8位}.jpg` 现算；分类口径 `(category IS NULL OR category='')`；`genres` 用 `LIKE '%"动画"%'`；分面角标不含自身维度。
- ★★ 深色 UI 层次靠**实心面明度**不靠描边（用户两次点名「线框不高级」）：选中态 = 实心圆角块 + 左侧 4dp 竖条（`MenuRow.kt`）；⛔ 导航带不画整体贯通外框。评分角标**对标 PC**：`#FFB454`@92% 圆角 5、`h7/v3`、11sp **粗体**、深色字 `#0B0D12`，贴海报**左下** 6dp。
- ★★ 播放器 OSD：画质 chip **只放短名**（`PanApi.tierLabel`）；分辨率/码率/需带宽走 `Log.i`；chip 有 `maxWidth`(160dp)+`ellipsize`。
- ★★ **启动探测**（`StartupSync`）：只在 `restores` 动作弹；**零点在 `MainActivity.onCreate`**；探测只读 —— 不建备份目录、只读包头 64 KiB（`fileHeadBytes`）、不读库字节（`lightLocalManifest`，避免 `rawBytes()` 关连接）。
- ★★ **「发现」= 局部扫描，只增不减**（`LibraryScanner.discover`，文件列表 MENU）：⛔ 绝不 `pruneMissingItems`、⛔ 绝不写 `scan_cursors`、`recursive=false`；归组**复用已有 `group_key`**。入仓判据 `!isVideoFile(name) || isDiscImage(name)` —— `.iso` **在**视频白名单里，**只能靠 `isDiscImage` 拦**。
- ★★ **作品简介页**（`Level.ITEMS` 头部）：⛔ **OK 点卡片 = 进简介页，不再直接播**（`openWork`；「直接续播」降级成胶囊 + 菜单项）。⛔ 两行胶囊是**两套光标态**；**焦点始终留在 `itemsList`**；只有动作行上的 ↑/返回才回作品墙。⛔ 海报 **96×144**（不照抄 PC 的 138×207）。⛔ `items` 别「先填一遍再清一遍」（`sortItems` 拿空列表 ⇒ 剧集列表永远空、**不报错**）。⛔ 胶囊不可用时**置灰不消失**。文案口径封在 `library/WorkDetailFormat.kt` + 13 例测试。
- ★★ **手动刮削**（`ScrapeActivity` + `library/Scrape*`）：双源**拼接**候选（TMDB 优先 + 豆瓣兜底）。⛔ 豆瓣 6 坑：读 `subjects.items` **和** `smart_box`／按 `target_type` 剔非影视／搜索 `cover_url` 是 120px 横条**不能当海报**／类型读**响应体**（`/movie/{id}` 对剧集 301 到 `/tv`）／**业务码判在状态码之前**（`103` 既见 200 也见 403）／`img*`→`qnmob3-sign` **字面量**替换。熔断**必须会过期**。⛔ 标题拿不到返回 `null`，**绝不拿查询词兜底**。
- ★★ **TMDB 两代 Key 送法不同**（2026-10-07 血案）：**v4 读取令牌**（`eyJ` JWT）必须 `Authorization: Bearer`；**v3 Key**（32 位十六进制）走 `api_key`。把 v4 塞进 `api_key=` 回 **401 `Invalid API key`**，看起来与「Key 填错了」一模一样。判据 `TmdbScraper.isV4Token` 与 PC `tmdb_client.dart` **逐字一致**。实测 `?api_key=<JWT>`→401 / `Bearer <JWT>`→200。
- ★★ **刮削设置页有「测试」按钮**：`TmdbScraper.probe()` 打 `/configuration`（**地址不通 / 401 Key 被拒 / 其它 HTTP** 分开）；`DoubanScraper.probe()` 打真实搜索（**连不上 / 103 / HTTP 错 / 零命中 / 正常**，并报 Cookie 含不含 `dbcl2`）。⛔ 用**输入框当前值**测；⛔ `probe` **不碰熔断**；⛔ `ScrapeProbe.ok` 只有明确验证过才 `true`。
- ★★ **刮削凭证随备份走**：写 `settings` 表（**不是** `AppPrefs` —— 包里没有它），键名与 PC `SettingKeys` 逐字一致：`tmdb_api_key`·`tmdb_api_base`·`tmdb_image_base`·`douban_cookie`（`ScrapeSettingsKeysTest` 钉死）。⛔ **换库后必须清设置缓存**：PC `SettingsStore.invalidate()` + `invalidate(settingsProvider)`。⚠️ 电视上若**从未恢复过**电脑的备份（本地更新 ⇒ `uploadLocalNewer`）凭证就是空的 —— 表现 = TMDB 401 + 豆瓣 103。
- ★ `PosterStore.fileFor` **三级**：①`poster_file` → ②**按当前 `posterUrl` 现算** → ③目录索引。②是「刮削换图后立刻可见」的关键。⛔ 索引**一键一图**（同键多图时索引命中 ≠ 对的那张）。
- `library/`：`LibrarySchema` = 唯一真源（7 条 DDL 与 Dart 逐字一致，`LibrarySchemaTest` 守着）；`LibraryDb` 只补表补列、⛔ **不做 v1→v16 迁移**、补列必须 `col.copy(notNull = false)`、⛔ **不用 WAL**（`journal_mode=DELETE`）；`LibraryItem` 必须带 `dirId`。
- `pan/`：`PanHttp`（`HttpURLConnection`，不引 OkHttp）/`PanApi`/`OssAuth`/`QrLogin`（业务码读 `bizCode`）/`CredStore`/`Bg`。⛔ 速率用 `CountingDataSource` 数字节；⛔ 目录判定只认 `dir` 布尔位（`file_type` `0`=目录、`1`=文件）。
- `TvOsdView` 挂 `android.R.id.content` 之上；⛔ 回调只回传**行下标** ⇒ 按 `Row.id` 分派。⛔ `SeekPlan`：松手才 `seekTo`；兜底窗口 800 ms 必须大于自动重复间隔。
- ⛔ `UI fps` 不可用于比较（`StatsOverlay` 自己重排自己）；⛔ JVM 单测里 `org.json`/`android.util.Base64` 是空壳 ⇒ 用 `MiniJson`/`OssAuth.base64`；⛔ 长串断言先钉长度（`ComparisonCompactor` 只留 20 字符）。
- 工程约定：minSdk 21 / targetSdk 34 / compileSdk 36 / Media3 1.5.1；⛔ 不引 OkHttp / media3-ui / AppCompat / Material / RecyclerView；`Bg` 不支持 lambda 单参重载。
- 构建：Gradle 8.10.2 / AGP 8.7.0 / Kotlin 2.1.0；**`JAVA_HOME` 用 JDK 21**（`/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home`；默认 `jdk-17.0.2.jdk` 是 x86 壳 ⇒ `Bad CPU type in executable`）。

## ★★ 真机调试（电视 = `MiTV-MFTP0`，Android 28，1920×1080，`192.168.5.169:5555`）
- 装机/日志/按键/截图走 `android/tool/adb_tv.sh`。⛔ `find_apk` **按 mtime 取最新**（`branded/` 会躺旧包 ⇒ 白查一整轮）。
- ⛔ **别用 `logcat -d | … | tail -N`**：系统噪声（`AppMonitor`/`BleRemoteService`/`MTK_KL`）几千行，`tail` 会把 `FATAL EXCEPTION` 截掉 ⇒ **先存本地文件再 grep**。顺序：`dumpsys activity activities | grep mResumedActivity` → 全量 logcat → 找 `FATAL EXCEPTION` / `Force finishing activity`。
- ★ `exported=true` 且吃 extras 的页**直启比走 UI 快**：`am start -n com.cloudcine.tv/.ScrapeActivity --es scrape_work_key <k> --es scrape_work_title <t>`。⛔ 软键盘会吃掉 `input keyevent 20/23`（DOWN/OK）⇒ 复现前先 `key back`。

## ★★ 4K 卡顿的真因：播错了档位（`tool/quark_probe.py` 实测）
`黑亚当 2160p`（21.9 GiB）所需带宽：原画 **3.00 MB/s** · `4k` **0.63** · `super` 0.14 · `high` 0.09。夸克默认档是 `super`，云影默认播**原画** ⇒ 单连接喂不动 ⇒ 8 连接中继 ⇒ 主线程饿死。**不是解码 / 渲染面 / OSD 画法**。⇒ 治本：默认播转码档（≥`4k`，Android `probeThroughput` → `chooseQuality`，留 30% 余量）。
- **直链 Cookie**（★ 极易踩）：带 `__puus`（新旧都行）→ **206**；有 `__pus` 但缺 `__puus` → **412**；完全不带 → **206** ⇒「**要么不带，要么带全**」。`__puus` 在**每个**响应里轮换下发（PC `quark_adapter.dart:1285` / Android `PanApi.absorbCookies`）。
- ⛔ `batch/file/play/info` **必须带 `pr=ucpro&fr=pc`**（漏了回 `401 code=31001`）。⛔ `useCaches = false` 不能省；⛔ 解析 `video_list` **必须跳过 `audio_list`**（否则有声音、进度条在走、**没画面、不报错**）。
- ⛔ 上传收尾是**两步**：OSS `CompleteMultipartUpload`（带 `x-oss-callback`）→ `file/upload/finish`（body 只有 `task_id`+`obj_key`）。签名全在 `pan/OssAuth.kt`。

## Flutter PC 端红线
- ★ **索引已整体下沉到 `HOWTO.md`**（搜 `## Flutter PC 端红线`，约 5454 行）：引擎/硬解、中继 416、媒体库三轴、播放器、侧栏、目录视图、下载 v16、文件夹模式、TV 布局、OSD 卡顿。此处不重复，避免挤掉 Android 条目。
- 最常踩的三条：⛔ `chunkSize` 别放大（2→8 MiB ⇒ 零成功播放）；⛔ `app_shell._items` 与 `app_router.branches` **必须同序**（判据是**下标**）；⛔ 恢复备份后要清设置缓存（`SettingsStore._cache` + `SettingsController`）。

## 运维 / 打包 / 测试
- 采样：⛔ 周期 **10 秒**（不与探针 21 秒相等 ⇒ **拍频锁定**）；**读不到一律留空**；⛔ 进程 CPU 是**单核口径**；`/proc/loadavg` 在电视上 `Permission denied` ⇒ 用 `procs_running`/`procs_blocked`。★ 真帧率用 SurfaceFlinger 量。
- 打包：⛔ MSI 条件不能写 `VersionNT >= 1000`（钳在 603）⇒ 用 `WindowsBuild >= 10240` + `Installed OR`（**不支持括号**）；⛔ macOS 不许写 `keychain-access-groups`、`app-sandbox` 必须 **`false`**；⚠️ 本机**出不了 Flutter release 包**。
- 测试：纯函数优先、断言写「为什么重要」；⛔ **每个需求只跑相关单测，不回归全量**；修 bug **先加测试确认红**（去掉修复要能让它 FAIL）。Android 跑 `./gradlew :app:testDebugUnitTest`（JDK 21）。
