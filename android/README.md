# 云影 Android 端

云影在 **Android / Android TV** 上的**正式实现** —— 原生 Kotlin，全程不含 Flutter。

包名 `com.cloudcine.tv`。

> 仓库根的 Flutter 工程（`lib/` `macos/` `windows/` `pubspec.yaml`）是**PC 端**
> （macOS / Windows）。两个工程互不引用、互不构建对方，可以并存安装。

---

## 一、为什么 Android 不用 Flutter

这不是口味问题，是 2026-10-06 在一台小米电视（Android 9，4 核 / 2.5 GB）上量出来的：

| 结论 | 读数 |
|---|---|
| 瓶颈**不在解码** | 真机 `解码丢帧=0`、`显示丢帧` 却在 21 秒里涨 44 |
| 瓶颈**不在网络总量** | 8 连接聚合稳态 8.03 MiB/s，而 4K 原画只需 3.67 MiB/s |
| 瓶颈**在数据通路** | 夸克对**单条连接**限速 ≈1 MiB/s；Flutter 侧的多连接中继跑在 **Dart 主 isolate**（= Android 主线程） |
| 主线程被占的代价 | 「按 MENU → 菜单上屏」Flutter 实测 **524 ms**，原生同口径 **0.3~8.3 ms** |

所以 Android 端必须原生：**8 连接并行取流 + 磁盘旁路预取 + 原生 View OSD**。
证据见 `docs/AndroidTV-4K-丢帧-夸克对标.md` 与 `docs/解决4k片源不卡顿解析方案.md`。

## 二、它长什么样

```
MainActivity      启动页：只看登录态，转去登录页或媒体库
  └ LoginActivity   扫码登录：二维码画在电视上，手机扫
      └ LibraryActivity 媒体库海报墙（首页）：作品 → 简介页 → 起播
          ├ BrowseActivity 文件列表（网盘实时目录）：找一个还没入库的文件
          │                 菜单里有「发现本目录 / 只发现这一层 / 加入媒体库」
          ├ ScrapeActivity 手动刮削（豆瓣 / TMDB 双源）：搜 → 挑一条 → 更新
          ├ ScrapeSettingsActivity 刮削设置（TMDB Key / 两个反代地址 / 豆瓣 Cookie）
          └ PlayerActivity 播放页：ExoPlayer + SurfaceView + 原生 OSD
```

`pan/` 包是网盘客户端：`PanHttp`（`HttpURLConnection`）、`PanApi`
（列目录 / 取链）、`QrLogin`（CAS 扫码）、`PanModels`、`CredStore`（凭证）、
`Bg`（后台线程池）。

`library/` 包是本地索引：`LibrarySchema`（7 条 DDL，跨端唯一真源）、
`LibraryDb`、`LibraryScanner`（全盘扫描 + 局部**发现**）、`LibraryBackupService`
（备份 / 同步）、`PlayTarget`、`PosterNaming` / `PosterStore` / `PosterFetcher`，
以及刮削那一组 `ScrapeModels` / `ScrapeHttp` / `DoubanScraper` / `TmdbScraper` /
`ScraperPipeline`。

### 启动时的那句「网盘上有更新的备份」

每次**启动 App** 会在后台问一次「网盘上有没有比本机更新的媒体库备份」，
有就弹一句提示，让用户决定要不要同步（`LibraryActivity.probeRemoteBackupAtStartup`）。

| 约束 | 为什么 |
|---|---|
| 只在「远程赢」时弹（`StartupSync.shouldPrompt`） | 本地更新是常态（看一集就变了），每次都问「要不要上传」＝每次都烦 |
| 探测**只读**，不传不覆盖 | 真正动手要用户点「立即同步」，那才走 `sync()` 并**重新判一次方向** |
| 失败静默 | 没网 / 凭证过期时启动路径上弹错误框，比「这次没同步」更烦，用户也没法处理 |
| 界面正忙就不弹 | 探测在后台跑，回来时用户可能已经开了菜单或正在扫描；抢着弹会打断他，还会搅乱 overlay 状态 |
| 一个进程一次（`startupProbed`） | 每个页面是独立 Activity，从「文件列表」返回会**重建**媒体库页 —— 实例字段会导致来回切一次弹一次 |

探测不整包下载：备份包的清单在最前面（`[magic][清单长度][清单][库][海报]`），
只读头部 64 KiB（`PanApi.fileHeadBytes` → `PanHttp.getBytesHead`，带 `Range`），
读不出来才退回整包。它**也不创建**「云影备份」目录（走 `PanApi.findFolder`）——
没备份过的用户不该每次开电视都被塞一个空目录。

### 文件列表里的「发现」与详情页的「手动刮削」

**「发现」= 局部扫描**，解决的是「我只想把这几个目录收进来」。它和全盘扫描
共用同一套入库链路，但有**三条硬区别**（`LibraryScanner.discover`）：

| | 全盘 `scan` | 发现 `discover` |
|---|---|---|
| 清理陈旧记录 | 调 `pruneMissingItems` | ⛔ **绝不调** |
| 写续扫游标 | 写 `scan_cursors` | ⛔ **绝不写** |
| 深度 | 按设置 | `recursive=false` 只扫一层 |

「只增不减」是这个功能的**定义**：用户在文件列表里点的是「把这几个收进来」，
不是「用这个目录重建我的库」。任何一处顺手 prune 都会让他丢掉别的目录里的
条目，而且不报错。

入口在文件列表的 MENU 里，按光标落在哪一行给出不同选项：

| 光标位置 | 菜单项 |
|---|---|
| 目录 | `发现本目录「X」（含子目录）` / `只发现「X」这一层` |
| 视频文件 | `把「X」加入媒体库`（只收这一个，不拖兄弟） |
| 任意 | `发现「X」（含子目录）`（X = 当前所在目录） |

⛔ 非视频 / 光盘镜像**不收**：判据是 `!isVideoFile(name) || isDiscImage(name)`，
两个条件缺一不可 —— `.iso` 在视频白名单里（映射到 `other` 容器），只能靠
`isDiscImage` 拦下来。

**「手动刮削」** 解决的是「自动刮削失败了」。失败大多是**片名解析不准**（文件名
里插了 `z`、只剩分辨率信息、或数据源里根本没收录），这时唯一的出路是用户自己
敲一个词再搜、从候选里挑一条。

- 详情页（`LibraryActivity` 的 `Level.ITEMS`）菜单 → `手动刮削「X」`；
  刮完自动刷新这一页（重读 `media_works` 那一行 + 重建海报索引）。
- 双源与 PC 端一致：**TMDB 优先、豆瓣兜底**，两者候选**拼接**给用户挑
  （手动刮削是用户自己判断，不是「取第一个成功的」）。豆瓣不要求配 Cookie
  也能用（匿名额度实测约 10 个搜索词，耗尽后熔断一段时间并提示去设置里贴
  Cookie）。
- 输入框预填的是**文件名解析出来的词**，不是库里已存的标题 —— 库里那个标题
  很可能就是上一次刮错的结果，用户得先意识到「框里是错的」才会去改。
- ⛔ 屏幕上的 OK 键**全部自管**（`dispatchKeyEvent`），候选列表上 DOWN 与 UP
  **都要吞**（只吞 DOWN 会让一次按键刮两遍）；单行 `EditText` 会自己吃掉 ↑↓，
  也必须接管。

**刮削凭证随备份恢复。** 这是**不需要任何新的备份代码**的：备份包（`.ccbak`）
里装的是整个 `cloudcine.sqlite` 文件的原始字节，`settings` 表随之一起走。所以
只要把值写进 `settings` 表（**不是** `AppPrefs` / SharedPreferences —— 那个在
备份包里根本不存在）就自动跨端走：

```
tmdb_api_key · tmdb_api_base · tmdb_image_base · douban_cookie
```

键名与 PC 端 `SettingKeys` **逐字一致**（`ScrapeSettingsKeysTest` 钉死）。
差一个字母的表现是「在电脑上能刮，电视上刮不到」，两边都不报错。

⚠️ 顺带修掉 PC 端一个真 bug：`SettingsStore` 有一层进程内缓存，而恢复备份是
**换掉整个数据库文件** ⇒ 缓存对「文件被换了」一无所知。触发路径很容易撞 ——
在新机器上先打开设置页（缓存记下「TMDB Key 为空」）→ 从网盘恢复电脑上的备份
→ 设置页还是空的、刮削继续走匿名额度，**要重启应用才对**。修法是清
`SettingsStore` 缓存 + `invalidate(settingsProvider)`，两条缺一不可。

### 作品简介页（点卡片先去这里）

⛔ **OK 点作品卡片 = 进简介页，不是直接播放**（2026-10-07 起）。直接播等于替
用户做了三个决定 —— 播哪一条（`PlayTarget`）、播哪一版、要不要先刮削；而用户
点卡片时想做的经常是「看看这部是什么」「换一集」「刮一下海报」。简介页把这三件
事都摆成胶囊，播放只是其中最显眼的一颗。

版式对标 PC 端 `work_detail_page.dart` 的 `_InfoColumn`：

```
[logo] 媒体库 / 片名                       剧集 · 12 个文件
┌────┐  片名                                  ← 简介页头部（detailHead）
│海报│  原名 / Original Title
│96× │  2024 · 2 季 · 12 集 · 剧集 · ★ 8.7 · 已刮削 · 剧情/犯罪
└────┘  简介正文（最多三行，超出省略）
[▶ 续播] [手动刮削] [刮削设置] [选集（12）]      ← 动作胶囊（actionsScroll）
[修改时间倒序] [剧集顺序] [标题]                ← 排序胶囊（itemsSortScroll）
黑亚当.2022.S01E01.1080p.WEB-DL   S01E01  3 天前   ← 剧集列表（ListView）
   1080p · 1.2 GB · 看到 12:34 / 45:00
黑亚当.2022.S01E02.1080p.WEB-DL   S01E02  3 天前
   1080p · 1.2 GB
```

⛔ 列表**主标题是文件名**（`EpisodeLabels.fileLabel`，去扩展名），**不是**作品名
（2026-10-07 用户反馈：「文件列表应该重点凸显的是文件名，而不是全部都是媒体名，
否则剧集列表都是媒体名，看起来体验非常不好」）。用 `LibraryItem.displayTitle` 的话
它优先返回作品标题，12 集会印成 12 个「黑亚当」。副标题的进度读**历史最大位置**
（`maxPositionMs`，看完不清），不是续播点（看完会被清成 NULL ⇒ 看不出「看过没有」）。
口径与播放页 OSD 的「选集」共用 `library/EpisodeLabels.kt`，由 `EpisodeLabelsTest` 钉死。

| 胶囊 | 做什么 | 判据 |
|---|---|---|
| `▶ 播放` / `▶ 续播` | `playWork` → `PlayTarget.resolve` 选好的那一条 | 文案看 `resumeFraction > 0`；没有可播文件时置灰 |
| `手动刮削` | `ScrapeActivity`，刮完回来重画头部与胶囊 | 恒可用 |
| `刮削设置` | TMDB Key / 反代 / 豆瓣 Cookie | 恒可用 |
| `选集（N）` | **不是一个动作**，而是把光标交给下面的列表 | N = 作品下的文件数（含花絮） |

⛔ **两行胶囊是两套光标态**（`actionsFocused` / `itemsSortFocused`），刻意不合并：
动作行回答「对这一部作品做什么」，排序行回答「这一页的列表怎么排」。合成一行
的话「播放」会和「修改时间倒序」并排，用户按 ←→ 路过时分不清哪颗是动作。

⛔ **焦点始终留在 `itemsList` 上**，两行胶囊只吃「光标态」。焦点一挪到胶囊上，
底下列表那行的高亮就没了，用户会以为列表被清空了。方向键靠两个标志位在
`dispatchKeyEvent` 里分流。

⛔ 上下层的顺序**照屏幕上的物理位置**：动作行 ↑↓ 到排序行，排序行 ↑↓ 到列表，
列表首行 ↑ 回排序行。只有动作行上再按 ↑（或返回）才退出这一页 —— 排序行上的 ↑
**不再**是「回作品墙」。

⛔ 海报尺寸是 **96×144**，不照抄 PC 的 138×207：电视横屏逻辑高只有 540dp
（1080p / density 2.0），207dp 的海报加上两行胶囊、列表、两行提示会把这页撑爆，
列表只剩一行 —— 而「选集」恰恰是这一页的主要用途。

⛔ 简介页的文案口径（「已刮削」的判据是 `source == 'online'` 而不是「有海报」、
季数门槛 `>= 2`、类型最多 4 个、原名与标题相同时不画）全部封在
`library/WorkDetailFormat.kt` 这个**纯函数**里，由 `WorkDetailFormatTest` 钉死。
放在 Activity 里的话 JVM 单测跑不起来，而这些错**全都不会报错**。

### 播放页的几块关键拼图

| 文件 | 干什么 |
|---|---|
| `ParallelRangeReader` / `ParallelRangeDataSource` | 一条 HTTP Range 请求拆成 8 条连接并行取，绕开单连接限速 |
| `DiskPrefetcher` | **旁路**预取：不走 loader、不受 `SampleQueue` 约束，暂停时照样往磁盘灌 |
| `PrefetchCache` / `DiskCacheEvictor` / `DiskSpace` | 磁盘缓存单例 + 按可用空间自适应的 LRU 上限 |
| `SeekPlan` | 连续快进的累加 / 夹取 / 加速档位（纯函数，可单测） |
| `TvOsdView` | 原生 OSD（挂在 `android.R.id.content` 之上，与 Dart/主线程彻底解耦） |
| `StatsOverlay` / `ResourceProbe` | 调试浮层与 CPU / 内存 / 磁盘采样 |

## 三、构建

```bash
cd android
export JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home
export ANDROID_HOME=/Users/tandy/Library/Android/sdk

./gradlew :app:assembleDebug      # 自测用
./gradlew :app:assembleRelease    # 发版用（会自动带上单测）
```

或者用封装好的助手（顺带能装包 / 看日志）：

```bash
android/tool/adb_tv.sh build            # release + 单测
android/tool/adb_tv.sh build debug      # debug
android/tool/adb_tv.sh install          # 装到电视
android/tool/adb_tv.sh log              # 只看 CloudCine 这个 tag
```

产物：

| 路径 | 说明 |
|---|---|
| `app/build/outputs/apk/debug/app-debug.apk` | debug |
| `app/build/outputs/apk/release/app-release.apk` | release（AGP 认的原名，**不要改名**） |
| `app/build/outputs/apk/branded/cloudcine-<ver>-b<code>-android.apk` | 品牌化副本，与 PC 端交付物命名对齐 |

⛔ `JAVA_HOME` 必须是 **JDK 21**。用 Android Studio 自带的 JBR（25）时 Kotlin 编译会失败。

### 发布签名

取值顺序：`android/keystore.properties` → 环境变量 → **退回 debug 签名**。

```bash
cp keystore.properties.example keystore.properties   # 填进去，别提交
```

环境变量版本（CI 用）：`ANDROID_KEYSTORE_PATH` / `ANDROID_KEYSTORE_PASSWORD`
/ `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD`。

⚠️ 没配发布签名时也能出包，但**每个构建的签名都不同** —— 覆盖安装会报
「应用未安装」，且不能上架。这是有意保留的兜底（宁可出个能装的包，也不要
因为缺密钥直接构建失败）。

### 单测：`./gradlew :app:testDebugUnitTest`

JVM 单测跑的是 **AGP 生成的 `mockable-android-*.jar`（空壳）**，不是真 Android 框架。
`app/build.gradle.kts` 里开了 `unitTests.isReturnDefaultValues = true`，于是空壳方法
**静默返回默认值**而不是抛异常 —— 这是过去「全量单测永远不返回」的根因。

**已踩过的坑（都是这一条引起的）：**

| 现象 | 真因 | 修法 |
|---|---|---|
| 单测挂死、退出码 137 | `TextUtils.isEmpty` 恒 `false` ⇒ Media3 `WebvttParser` 的 `while (!TextUtils.isEmpty(readLine()))` 变 `while(true)` | `src/test/java/android/text/TextUtils.java` 替身（同名类在测试源集里**优先命中**） |
| `Cue.<init>` NPE | 空壳造出的 `text == null`，而 `Cue` 要求「`text == null` 时 `bitmap != null`」 | 不测真解析器 |
| `ASS` 用例拿到空数组 | `SubripParser.buildCue` 入参是 `android.text.Spanned`，一路依赖 `SpannableStringBuilder` / `Span` / `Bundle` / `Paint` 整套框架类 | 注入假工厂 |

**结论：Media3 字幕解析器在 JVM 上根本跑不了，别去修它。**

* 我们自己的逻辑（编码嗅探 / 排序 / 二分 / `endOf` 兜底 / 文件名归一）用
  `ExternalSubtitle.parse(name, raw, factory = FakeFactory(...))` 注入假工厂来测。
  生产调用点只有一个（`PlayerActivity`），走默认参数，不受影响。
* 真解析器只由**真机回归**验（放字幕 → 看有没有出来）。
* 兜底：`tasks.withType<Test> { timeout.set(Duration.ofMinutes(5)) }` —— 再有死循环
  5 分钟必挂，不会把 Gradle daemon 拖死。

**排查手法（下次卡住照这个来）：**

```bash
pgrep -fl 'Gradle Test Executor'          # 找到 Test Executor 的 pid
jstack <pid> | grep -A 30 '"Test worker"'
```

看 `Test worker` 那行：`RUNNABLE` 且 **`cpu ≈ elapsed`** ⇒ 死循环（不是等 IO、不是内存不足）。
`exit 137` 是**结果**不是原因 —— 死循环烧满一个核，Gradle daemon 被系统杀掉。

⚠️ 测试源集里**没有** `android.util.Base64` / `org.json` 的真实现 ⇒ 用
`MiniJson` / `OssAuth.base64`（见坑清单）。

### 关于 `--offline`

**首次构建必须联网**，这几条不在本机 Gradle 缓存里：

* `androidx.annotation:annotation-jvm:1.6.0`（新版的 KMP 命名）
* `androidx.lifecycle:lifecycle-runtime:2.3.1`
* `com.google.zxing:core:3.5.3`（二维码）
* `junit:junit:4.13.2` + `hamcrest-core`（单测）

拉过一次之后就可以 `--offline` 了。

AGP 8.7.0 / Kotlin 2.1.0 / Gradle 8.10.2 / Media3 **1.5.1**。
⛔ 不要引 `androidx.media3:media3-ui`：`PlayerView` 自带一套控制栏，会和
`PlayerControlsView` 打架。⛔ 也不要引 AppCompat / Material / RecyclerView。

## 四、遥控器操作

| 页 | 键 | 行为 |
|---|---|---|
| 登录 | — | 手机扫码即可，电视上不用按键 |
| 列表 | ↑↓ | 选择 |
| 列表 | OK | 目录→进入；视频→起播 |
| 列表 | 返回 | 上一层（根目录时退出） |
| 列表 | 菜单 | **发现 / 加入媒体库**（按光标落在目录还是文件给不同项）、媒体库、重新登录 |
| 媒体库 | ↑↓←→ | 选海报 / 切分类（←→ 只移光标，OK 才生效） |
| 媒体库 | OK | 作品→**简介页**；剧集→起播 |
| 媒体库 | 菜单 | 简介页 / 播放 / **手动刮削** / 排序 / 筛选 / 扫描 / 同步 / 备份 / **刮削设置** |
| 简介页 | ←→ | 在**动作胶囊**（播放 / 手动刮削 / 刮削设置 / 选集）与**排序胶囊**之间移光标（⛔ 只移光标，OK 才生效） |
| 简介页 | ↑↓ | 换层：动作行 ↔ 排序行 ↔ 剧集列表（列表首行 ↑ 回排序行） |
| 简介页 | OK | 动作行→执行（播放 / 进刮削 / 进设置 / 跳选集）；排序行→应用排序；列表→起播这一集 |
| 简介页 | 返回 | 回作品墙（动作行上的 ↑ 同义） |
| 刮削 | ↑↓ | 搜索框 ↔ 胶囊行 ↔ 候选列表 |
| 刮削 | OK | 搜索框→编辑；胶囊→搜索 / 弹子菜单；候选→**用这一条更新** |
| 刮削 | 菜单 | 换搜索源 / 媒体类型 / 重新搜索 / 清空搜索词 |
| 刮削设置 | ↑↓ | 在四个输入框与「保存」之间移动（⛔ 单行输入框会吃掉 ↑↓，所以自己接管） |
| 刮削设置 | OK | 输入框→弹软键盘；保存→落库 |
| 播放 | 菜单 / ↑ | 打开 OSD |
| 播放 | ↑↓ | 切行（画质 / 连接数 / 音轨 / 音效 / 字幕 / 倍速 / 调试） |
| 播放 | ←→ | 在选项里挪（撞到两端就停，跳过灰掉的） |
| 播放 | OK | 应用。**画质 / 音效**会收菜单（两者都要重建播放链路）；音轨/字幕/倍速/调试**留在菜单里** |
| 播放 | ←→（OSD 关着时） | 快退 / 快进。**按住会加速**（见下） |
| 播放 | 返回（OSD 开着） | 关 OSD |
| 播放 | 返回（控制栏亮着） | 收控制栏，回到全屏播放 |
| 播放 | 返回（已全屏） | 弹「要退出播放吗？」确认框 |
| 播放 | OK（OSD 关着时） | 播放 / 暂停 |

### 快进的三个约定（`SeekPlan`）

1. **拖动过程中不动播放进度** —— 按键只累加目标位置并立刻把进度条挪过去，
   **松手（`ACTION_UP`）后才真正 `seekTo`**。否则遥控器的自动重复（约 20 次/秒）
   会变成 seek 风暴：每次 `seekTo` 都要重建数据源、一次性分配 16 MiB，
   实测 2 秒内 28 次 seek 直接把 Java 堆打满 → `OutOfMemoryError`。
2. **前 2 秒不加速**，之后 `×2 / ×4 / ×8 / ×12` 逐级上升，2 小时的片子约 9 秒到底。
3. 兜底窗口 800 ms **必须大于遥控器的自动重复间隔**（有些遥控器 ~500 ms），
   否则按住时每按一下就提交一次。

### 「画质」那一行只显示短名

菜单里画质 chip 的文案 = `PanApi.tierLabel()` 给的档位短名，只有
`原画 / 4K / 2K / 超清 / 高清 / 标清 / 流畅` 这几个词。

⛔ **不要往 chip 里拼分辨率 / 码率 / 需带宽**（曾经拼过，形如
`4K  3840×1606 · 5.2 Mbps · 需 0.63 MB/s`）：一个 chip 就吃掉大半行，
后面几档全被挤出右侧面板 —— 用户的反馈原话是「选项过于冗长，超出设置面板，
只需要 4K 原画 超清等名称即可」。

想看那些数字时**读日志**：每次重绑菜单都会打一行

```
画质档位：原画(ORIGIN) 3840×1606 · 5.2 Mbps · 需 3.00 MB/s | 4K(4k) …
```

这行是排查「4K 卡顿」的第一步（原画 3.00 MB/s vs `4k` 0.63 MB/s，差 5 倍）。
选哪一档本来也不用用户心算 —— 起播时 `chooseQuality()` 已按实测带宽挑好。

`TvOsdView` 里每个 chip 还有 `maxWidth = MAX_CHIP_W`（160dp）+ 省略号兜底：
服务端偶尔给出映射表外的档位 id，`tierLabel` 会原样回退，长串会撑破整行。

## 五、左上角浮层怎么读

**默认关闭**（全局参数，存 `cloudcine_prefs`，跨片跨重启都记得）：
播放页 → 菜单 → 调试 → 开启。

每秒把同一行 `Log.i(TAG, "[统计] …")` 打出去，按键时打 `[按键] → 下一帧 x.x ms`。
tag 是 `CloudCine`：

```bash
android/tool/adb_tv.sh log          # 等价于 adb logcat -s CloudCine
```

⛔ **这不是调试残留，是必需通道**：有硬件视频层时 `screencap` 拿不到画面
（视频层不进 framebuffer 快照），播放中 `uiautomator dump` 也拿不到 UI
（永不 idle），logcat 是唯一的出口。

| 行 | 含义 |
|---|---|
| 片源 | 实际解码出的宽高 / 帧率 / 编码 |
| 解码器 | `c2.xxx` / `OMX.MS.*` = 硬件，`OMX.google` / `sw` = 软件。**这是关键证据** |
| 渲染 / 丢帧 / 已解码 | 来自 `VideoDecoderCounters`，与 PC 端 `[解码]` 同一口径 |
| 进程CPU | **单核口径**，括号里写明折合 N 核（4 核盒子要 400% 才叫满载） |
| 系统可用内存 | 用来对照「2.5 GB 机器 + 150 MB 进程」的内存压力 |
| 磁盘 本片 / 目录 | 本片在盘上覆盖了多少（几段、最远到哪）／整个缓存目录的占用与上限 |
| 预取 第 N 块 · 领先 | 旁路预取下到第几块、领先播放头多少字节 |
| UI fps / 最大帧间隔 | ⛔ **`UI fps` 是自续帧回调数出来的，恒≈刷新率，不是性能**（见下） |
| **按键→下一帧** | 从按键被吃掉到下一帧开始。**这才是「跟手」的直接读数** |

⛔⛔ **`UI fps` 不可用于比较**：`StatsOverlay.doFrame` 里
`choreographer.postFrameCallback(this)` **自己重新排自己**，于是每个 vsync
都被叫到，`uiFps` 恒≈刷新率（实测 100~101，**还没出第一帧时就已经报 90+**）。
唯一可比的是 **「按键→下一帧」** 和 SurfaceFlinger `--latency`。

## 六、音轨 / 音效 / 字幕

### 音轨 ≠ 音效（菜单里是**两行**，别合并）

| 行 | 是什么 | 数据来源 | 选项长什么样 |
|---|---|---|---|
| **音轨** | 片源里**封着的流** | `Player.Listener.onTracksChanged` | `韩语 · 立体声 · 杜比+` |
| **音效** | **播放端对输出的处理** | `AppPrefs.audioEffect` | `跟随片源` / `强制立体声` |

⛔ 2026-10-06 之前「音轨」那一行的标签写的是**「音效」**，于是菜单里出现
「音效 → 韩语 · 立体声 · 杜比+」这种自相矛盾的组合，用户的反馈是
「音效感觉像是音轨，找不到音轨在哪」。PC 端的 `player_audio_effect.dart`
里早就写着这条后果（「用户会以为『音效』里那一列就是能选的音轨」）——
两端是同一个坑，所以标签不许再写错。

⛔ 「立体声 / 杜比」**不是音效**，是**音轨自带的属性**（发布组压制时定的）。
真正能切的「音效」只有 `AudioEffect` 里那两档，实现见 `AudioEffect.kt`。

### 音轨 / 字幕

「音轨」「字幕」两行**直接来自 `Player.Listener.onTracksChanged`**，
不轮询、不缓存。判定有没有切成功的唯一办法是看日志：

* `轨道变化：` —— 每次轨道表变化打一份，条目后面带 `← 选中` 的那个才是当前生效的；
* `菜单内容：` —— 每次重绑菜单打一份，`[方括号]` 里的是光标所在项。

⛔ 换画质档会换掉整个 media source，字幕/音轨随之重来 —— `playQuality()` 里
`resetTrackOverrides()` 会把逐文件的轨道选择清掉（**不动**跨片的语言偏好）。

### 音效为什么切换时会黑一下

⛔ 音效是靠给 `AudioSink` 装一个 `ChannelMixingAudioProcessor` 实现的，而它的
**输出声道数在 `onConfigure()` 里就定死了**；`AudioSink` 又只在**建播放器时**
由 `DefaultRenderersFactory.buildAudioSink()` 造出来，media3 1.5.1 没有运行期
换它的接口 ⇒ **改音效只能重建播放器**（`applyAudioEffect()`）。

代价与「换档」同级：黑一下、从当前位置重新缓冲。位置、播放态、倍速，以及
**用户选过的音轨与字幕**（按标签，`restorePendingTracks()`）都会带过去。

⛔ 别为了「不黑一下」去改成 `setMediaItem()`：那**不一定**会重新配置 AudioSink
（解码器可能被复用，`onOutputFormatChanged` 就不回调），表现是「切了没反应」。
⛔ 也别去打开浮点输出（`enableFloatOutput`）：`ChannelMixingAudioProcessor`
只吃 16 bit 整数 PCM，浮点会让它当场抛异常 —— **整部片没声音**。

⚠️ **已知限制**：片源是 AC-3 / DTS 且设备走了直通（HDMI 功放）时，码流不过
解码器，「强制立体声」不起作用。不强行砍 `AudioCapabilities` 来逼解码 ——
那会让**没有 AC-3 解码器**的机器从「有声音」直接变成「没声音」。

## 七、量真帧率（别信浮层）

```bash
L="SurfaceView - com.cloudcine.tv/com.cloudcine.tv.PlayerActivity#0"
adb shell dumpsys SurfaceFlinger --list | grep cloudcine      # 找层名
adb shell "dumpsys SurfaceFlinger --latency '$L'"              # 首行=刷新周期ns，其后 128 帧三列时间戳
```

有效帧跨度反推 fps。实测：**25.2 fps、帧间隔中位 40.3ms、>100ms 卡顿 0 次**。

## 八、磁盘缓存

播放页的磁盘缓存**跨会话可复用**，这是「同一部片第二次打开不用重新缓冲」的前提。

⛔ 缓存键**不是 URL**。夸克直链是每次起播现取的带签名临时地址，按 URL 做键
等于「每次会话都是新片」。键的构成是 `quark:<fid>:<画质档 id>`：

* `fid` —— 来源文件 id（`EXTRA_FID`）；
* **画质档 id 不能省** —— 原画与各转码档是**完全不同的字节流**，只按 `fid`
  做键会把原画的字节喂给转码档的解析器，**解码出乱码而且不报错**。

实测：强杀重开后播同一部片，起播第一秒就读到 `磁盘 本片 1.54 GiB · 17 段`，
而本次预取器才写完 1 块（128 MiB）—— 多出来的全部来自上一个会话。

⚠️ 缓存上限按**可用空间**自适应（给系统留 2048 MiB 后取一半），所以别的 App
占盘时它会自动收缩，LRU 会淘汰旧片。这是有意的让路行为，不是 bug。

## 九、对照路径：直接给 URL（不经过登录/列表）

`PlayerActivity` 保留 `--es url` 这条入口，用来跑「PC 端中继 vs 直连」对比：

```bash
adb shell am start -n com.cloudcine.tv/.PlayerActivity \
  --es url "http://127.0.0.1:44151/s2"
```

可选参数：

| 参数 | 默认 | 用途 |
|---|---|---|
| `--es headers "Cookie: …\nUser-Agent: …"` | 空 | 直连 CDN 时才需要 |
| `--ei connectMs 30000` | 8000 | 验证「是不是超时卡掉了 ExoPlayer」 |
| `--ei readMs 30000` | 8000 | 同上 |

同理 `--es fid <fid>` 可以跳过列表页直接起播某一部片（测缓存键时很有用）。

## 十、踩过的坑（改代码前先看这里）

- ⛔ **XML 注释里不能出现 `--`**（写 `am start --es url` 会让 manifest 直接解析失败）。
- ⛔ **CAS 端点的业务码字段是 `status`，不是 `code`**（`{"status":50004001}`）。
  只读 `code` 会一律得到 `-1`，于是「还没扫码」这个**正常态**被当成异常。
  `PanResponse.bizCode` 兼容两套信封。
- ⛔ `batch/file/play/info` **必须带 `pr=ucpro&fr=pc`**，漏了回
  `HTTP 401 code=31001 require login [guest]`（看起来像没登录，其实是缺参数）。
- ⛔ **CDN 直链的 Cookie 规则是「要么不带，要么带全」**：
  带 `__puus`（新旧都行）→ 206；有 `__pus` 但**缺** `__puus` → **412**；
  完全不带 → 206。所以 `PlayerActivity.headersForCdn()` 在凭证里没有 `__puus` 时
  **主动不带 Cookie**。`PanApi.absorbCookies` 负责把每个响应里轮换的 `__puus` 回填。
- ⛔ `HttpURLConnection.useCaches = false` 不能省：每次返回的播放地址都带签名，
  命中缓存会拿到过期地址 —— 表现是「列目录正常、一播就 403」。
- ⛔ 解析 `video_list` 时**必须跳过 `audio_list`**：那条是纯音频流，没有分辨率字段，
  很容易被当成「原画」—— 而原画永远排最前，于是默认播一条**没有视频轨**的流：
  有声音、进度条在走、**没有画面、不报任何错**。
- ⛔ 目录判定**只认 `dir` 布尔位**，`file_type` 仅兜底（`0`=目录、`1`=文件，与直觉相反）。
- ⛔ `ListView` 用 `divider = null` 时**看不出选中项**，得自己给行加高亮背景，
  否则遥控器上「按了没反应」。
- ⛔ 原生 OSD 只回传**行下标**，而行数不固定（没有画质行、没有字幕行都会少一行）。
  回调一律按 `TvOsdView.Row.id` 分派，别 `when (row) { 0 -> … }`。
- ⛔ 速率**不能**取 `AnalyticsListener.onBandwidthEstimate`：那个回调一次传输
  结束才发一次，渐进式 MP4 一次 load 好几秒 ⇒ 界面上只剩「缓冲中」。改用
  `CountingDataSource` 在 `DataSource.read()` 上数字节。
- ⛔ **播放器不许写磁盘缓存**（`setCacheWriteDataSinkFactory(null)`）：两个写者
  撞上同一个 span 时 `SimpleCache.startFile` 抛的是 `IllegalStateException`，
  而 `CacheDataSource` 只吞 `IOException` ⇒ 直接崩。写入方只留 `DiskPrefetcher` 一个。
- ⛔ 预取器**绝不能在预取线程里读 `player.currentPosition`**
  （`IllegalStateException: Player is accessed on the wrong thread`，
  未捕获异常会带走整个进程，用户看到的是「无法打开影片」）。只能读主线程刷新的快照。
- ⛔ `bufferedPosition` **必须在 `seekTo` 之前读**：之后会被夹到 ≥ target，
  于是「命中内存缓冲」恒为真，磁盘缓存那支变成死代码。
- ⛔ **刮削凭证要写 `settings` 表，不能写 `AppPrefs`**：备份包里装的是整个
  `cloudcine.sqlite` 的字节，`AppPrefs`（SharedPreferences）在包里**根本不存在**。
  写错地方的后果是「token / cookie 不随备份走」，而界面一切正常。
- ⛔ **「发现」绝不能顺手 prune / 写续扫游标**：它是「只增不减」的局部扫描。
  泄漏一处就会让用户丢掉别的目录里的条目，且不报错。
- ⛔ **改完库再读设置前要清缓存**：`SettingsStore` 有进程内缓存，而恢复备份是
  换掉整个库文件。不清的表现是「恢复完了设置还是空的」，要重启才对。
- ⛔ 候选列表 / 菜单上的 OK 要**吞掉 DOWN 和 UP 两个事件**（只吞 DOWN ⇒ 一次按键
  执行两遍）；单行 `EditText` 会吃掉 ↑↓，想让 ↓ 往下走必须自己接管。
- ⛔ **`items` 这个 `ArrayList` 别「先填一遍再清一遍」**：`openWork` 里曾经写成
  `clear → addAll(list) → clear → addAll(sortItems(items, mode))`，
  第二句 `sortItems` 拿到的是**空列表** ⇒ 剧集列表永远是空的，
  而且**不报任何错**（只是「点进去什么都没有」）。保留容器、只清空重填，
  一次排序。
- ⛔ **简介页两行胶囊只吃「光标态」，焦点必须留在 `itemsList` 上**。
  焦点挪到胶囊上的话，底下列表那行的高亮就没了，用户会以为列表被清空。
  靠 `actionsFocused` / `itemsSortFocused` 两个标志在 `dispatchKeyEvent` 里分流，
  ⛔ 各 `focus*` 函数**必须互相清掉对方的标志位**，漏清一个就是「两行同时发光」。
- ⛔ **简介页的海报解码不能 `notifyDataSetChanged()` 海报墙**（那会连带重绑整个
  `GridView`，而用户正在看详情页）；也不能在解码回来后无条件画上去 ——
  那时用户可能已经退出这一页，`currentWork` 换人了，画上去就是**别人的海报**。
  判据：`currentWork?.key == 解码时那个 key`。
- ⛔⛔ **JVM 单测里跑不了 Media3 的字幕解析器**。`SubripParser.buildCue` 的入参
  类型就是 `android.text.Spanned`，一路依赖 `SpannableStringBuilder` /
  `SpannableString` / `StyleSpan` / `ForegroundColorSpan` / `SparseArray`
  一整套框架类；而单测跑的是 `mockable-android-*.jar`（空壳）。硬跑的结局是
  **死循环或 NPE，而且都不指向真因**。要真跑得上 Robolectric（本工程不引）
  或真机仪器化测试。所以 `ExternalSubtitle.parse` 留了一个可注入的
  `SubtitleParser.Factory` 参数（生产恒用默认值），单测注入假解析器，
  只验**我们自己**那一段：编码 / 排序 / 结束时间兜底 / 二分。
- ⛔⛔ **`isReturnDefaultValues = true` 会让框架空壳「静默返回默认值」**，其中
  最毒的是 `TextUtils.isEmpty` 恒 `false` —— Media3 的
  `WebvttParser.parse` 里有一句
  `while (!TextUtils.isEmpty(readLine())) { ... }`，于是变成
  **`while (true)` 死循环**：`ExternalSubtitleTest` 单条用例烧满一个核，
  整个 `testDebugUnitTest`（以及依赖它的 `assembleRelease`）**永远不返回**，
  最后被系统 SIGKILL。修法是给 `android.text.TextUtils` 补真实现
  （`app/src/test/java/android/text/TextUtils.java`），再加一道 `Test` 任务
  兜底超时（`app/build.gradle.kts`）—— 让下一次踩到是**报错**而不是**挂死**。
  ⚠️ 排查手法：卡住时 `jstack <Gradle Test Executor 的 pid>`，看 `Test worker`
  线程在哪个方法里 `RUNNABLE` 且 `cpu ≈ elapsed` —— 那就是死循环的位置。
- ⛔ **Java 源要显式钉 UTF-8**（`android { compileOptions { encoding = "UTF-8" } }`）：
  本工程注释全是中文，而 Gradle 的 `JavaCompile` 默认用平台编码。
  ⚠️ 但别被它的报错骗了 —— javac 报「非法字符: '`'」（反引号！纯 ASCII）时，
  真正的原因往往是**块注释被提前闭合**：在 javadoc 里手写一个内联块注释，
  它的结束标记会把外层 javadoc 关掉，后面整段中文就变成「代码」了。

## 十一、开发工具

| 位置 | 用途 |
|---|---|
| `android/tool/adb_tv.sh` | 本工程的连设备 / 装包 / 看日志 / 按遥控器键 / 截屏 |
| `../tool/quark_probe.py` | Mac 侧 API 探针：先把服务端真实响应形状拿下来，再照着写 Kotlin |

```bash
python ../tool/quark_probe.py login          # 出二维码（PNG + 终端字符画），扫码
python ../tool/quark_probe.py list [fid]     # 列目录
python ../tool/quark_probe.py play <fid>     # play/info + audioplay + 实测单连接带宽
```

真机迭代一轮要几分钟，这里改一行跑一次是秒级。
Cookie 落在 `../.quark_probe/cookie.json`。⛔ **该目录含真实凭据，已在
`.gitignore` 里，不要提交。**
