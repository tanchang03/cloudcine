# 夸克方案验证原型（Android）

**目的**：回答一个问题 —— 把**授权 / 文件列表 / 播放**这一整条链路都交给
**原生实现**（`ExoPlayer` + MediaCodec 直出的 `SurfaceView` + 原生 View OSD，
全程不含 Flutter），这台电视（小米 MiTV，Android 9，4 核 / 2.5 GB）上还剩多少余量？

这是一个**不含 Flutter** 的独立工程。只要 Flutter 引擎还在同一个进程里跑，
「每秒 10 次整页 rebuild」这个变量就撇不干净 —— 而它正是要验证的对照组。

---

## 一、它长什么样

```
MainActivity      启动页：只看登录态，转去登录页或文件列表
  └ LoginActivity   扫码登录：二维码画在电视上，手机夸克 App 扫
      └ BrowseActivity  文件列表：遥控器 ↑↓ 选择、OK 进目录/起播、返回 上一层
          └ PlayerActivity 播放页：ExoPlayer + SurfaceView + 原生 OSD
```

`quark/` 包是夸克客户端：`QuarkHttp`（`HttpURLConnection`）、`QuarkApi`
（列目录 / 取链）、`QuarkQrLogin`（CAS 扫码）、`QuarkModels`、`Bg`（后台线程池）。

## 二、构建

```bash
cd prototype/kuake
export JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home
export ANDROID_HOME=/Users/tandy/Library/Android/sdk
./gradlew assembleDebug
adb install -r -d app/build/outputs/apk/debug/app-debug.apk
```

产物 `app/build/outputs/apk/debug/app-debug.apk`（用本机 `~/.android/debug.keystore`
的 debug 证书签的）。

### 关于 `--offline`

**首次构建必须联网**：这几条不在本机 Gradle 缓存里 ——

* `androidx.annotation:annotation-jvm:1.6.0`（新版的 KMP 命名）
* `androidx.lifecycle:lifecycle-runtime:2.3.1`
* `com.google.zxing:core:3.5.3`（二维码）

拉过一次之后就可以 `./gradlew assembleDebug --offline` 了。

AGP 8.7.0 / Kotlin 2.1.0 / Gradle 8.10.2 / Media3 **1.5.1** 都与云影
`android/` 同版。⛔ 不要引 `androidx.media3:media3-ui`（缓存里没有，而且
`PlayerView` 自带控制栏，会把「原生 OSD 到底贵不贵」这个变量搅浑）；
⛔ 也不要引 AppCompat / Material / RecyclerView。

## 三、遥控器操作

| 页 | 键 | 行为 |
|---|---|---|
| 登录 | — | 手机扫码即可，电视上不用按键 |
| 列表 | ↑↓ | 选择 |
| 列表 | OK | 目录→进入；视频→起播 |
| 列表 | 返回 | 上一层（根目录时退出） |
| 列表 | 菜单 | 退出登录（清凭证回登录页） |
| 播放 | 菜单 / ↑ | 打开 OSD |
| 播放 | ↑↓ | 切行（画质 / 倍速） |
| 播放 | ←→ | 在选项里挪 |
| 播放 | OK | 应用 |
| 播放 | 返回 / 菜单（OSD 开着时） | 关 OSD |
| 播放 | OK（OSD 关着时） | 播放 / 暂停 |
| 播放 | ←→（OSD 关着时） | 快退 / 快进 10 秒 |

## 四、⚠️ 画质菜单里的那行数字才是重点

「画质」每一档后面写着**真实分辨率、码率和「需要多少 MB/s」**。同一部片子：

| 档位 | 分辨率 | 需要带宽 |
|---|---|---|
| 原画 | 3840×1606 | **3.00 MB/s** |
| `4k` | 3840×1606 | **0.63 MB/s** |
| `super` | 1440×602 | 0.14 MB/s |

**差 5 倍。**夸克自己的 `default_resolution` 是 `super`，本原型也默认跟着它走。
云影默认播**原画** —— 要 3 MB/s，单连接喂不动，只能靠 8 连接中继去凑，
而那个中继跑在 Dart 主 isolate 上。**这才是「夸克流畅、云影卡」的主因**，
不是解码、不是渲染面、也不是 OSD 的画法。

## 五、左上角浮层怎么读

每秒把同一行 `Log.i(TAG, "[统计] …")` 打出去，按键时打 `[按键] → 下一帧 x.x ms`。
tag 是 `KuakeProto`：

```bash
adb logcat -s KuakeProto
```

⛔ **这不是调试残留，是必需通道**：有硬件视频层时 `screencap` 拿不到画面
（视频层不进 framebuffer 快照），logcat 是唯一的出口。

| 行 | 含义 |
|---|---|
| 片源 | 实际解码出的宽高 / 帧率 / 编码 |
| 解码器 | `c2.xxx` / `OMX.MS.*` = 硬件，`OMX.google` / `sw` = 软件。**这是关键证据** |
| 渲染 / 丢帧 / 已解码 | 来自 `VideoDecoderCounters`，与云影 `[解码]` 同一口径 |
| 进程CPU | **单核口径**，括号里写明折合 N 核（4 核盒子要 400% 才叫满载） |
| 系统可用内存 | 用来对照「2.5 GB 机器 + 145 MB 进程」的内存压力 |
| UI fps / 最大帧间隔 | ⛔ **`UI fps` 是自续帧回调数出来的，恒≈刷新率，不是性能**（见下） |
| **按键→下一帧** | 从按键被吃掉到下一帧开始。**这才是「跟手」的直接读数** |

⛔⛔ **`UI fps` 不可用于比较**：`StatsOverlay.doFrame` 里
`choreographer.postFrameCallback(this)` **自己重新排自己**，于是每个 vsync
都被叫到，`uiFps` 恒≈刷新率（实测 100~101，**还没出第一帧时就已经报 90+**）。
云影的 `FPS` 同理（那边数的是「引擎实际出帧」，视频在独立图层自渲染时
Flutter 没东西要画，报 2~17）。**两边都不能当流畅度看。**
唯一可比的是 **「按键→下一帧」** 和 **SurfaceFlinger `--latency`**。

## 六、量真帧率（别信浮层）

```bash
L="SurfaceView - com.cloudcine.kuake/com.cloudcine.kuake.PlayerActivity#0"
adb shell dumpsys SurfaceFlinger --list | grep kuake      # 找层名
adb shell "dumpsys SurfaceFlinger --latency '$L'"          # 首行=刷新周期ns，其后 128 帧三列时间戳
```

有效帧跨度反推 fps。实测原型：**25.2 fps、帧间隔中位 40.3ms、>100ms 卡顿 0 次**。

## 七、对照路径：直接给 URL（不经过登录/列表）

`PlayerActivity` 仍保留 `--es url` 这条老入口，用来跑「云影中继 vs 直连」：

```bash
adb shell am start -n com.cloudcine.kuake/.PlayerActivity \
  --es url "http://127.0.0.1:44151/s2"
```

可选参数：

| 参数 | 默认 | 用途 |
|---|---|---|
| `--es headers "Cookie: …\nUser-Agent: …"` | 空 | 直连夸克时才需要 |
| `--ei connectMs 30000` | 8000 | 验证「是不是超时卡掉了 ExoPlayer」 |
| `--ei readMs 30000` | 8000 | 同上 |

（用云影中继时要**先按返回键退出云影播放页**，别让两边同时解同一路 4K；
且 LMK 会在 2~3 分钟内杀掉后台的云影、中继随之消亡。）

## 八、踩过的坑（改代码前先看这里）

- ⛔ **XML 注释里不能出现 `--`**（写 `am start --es url` 会让 manifest 直接解析失败）。
- ⛔ **CAS 端点的业务码字段是 `status`，不是 `code`**（`{"status":50004001}`）。
  只读 `code` 会一律得到 `-1`，于是「还没扫码」这个**正常态**被当成异常。
  `QuarkResponse.bizCode` 兼容两套信封。
- ⛔ `batch/file/play/info` **必须带 `pr=ucpro&fr=pc`**，漏了回
  `HTTP 401 code=31001 require login [guest]`（看起来像没登录，其实是缺参数）。
- ⛔ **CDN 直链的 Cookie 规则是「要么不带，要么带全」**：
  带 `__puus`（新旧都行）→ 206；有 `__pus` 但**缺** `__puus` → **412**；
  完全不带 → 206。所以 `PlayerActivity.headersForCdn()` 在凭证里没有 `__puus` 时
  **主动不带 Cookie**。`QuarkApi.absorbCookies` 负责把每个响应里轮换的 `__puus` 回填。
- ⛔ `HttpURLConnection.useCaches = false` 不能省：夸克每次返回的播放地址都带签名，
  命中缓存会拿到过期地址 —— 表现是「列目录正常、一播就 403」。
- ⛔ 解析 `video_list` 时**必须跳过 `audio_list`**：那条是纯音频流，没有分辨率字段，
  很容易被当成「原画」—— 而原画永远排最前，于是默认播一条**没有视频轨**的流：
  有声音、进度条在走、**没有画面、不报任何错**。
- ⛔ 目录判定**只认 `dir` 布尔位**，`file_type` 仅兜底（`0`=目录、`1`=文件，与直觉相反）。
- ⛔ `ListView` 用 `divider = null` 时**看不出选中项**，得自己给行加高亮背景，
  否则遥控器上「按了没反应」。

## 九、Mac 侧 API 探针

`tool/quark_probe.py`（在仓库根目录）可以在电脑上先把夸克的真实响应形状拿下来 ——
真机迭代一轮要几分钟，这里改一行跑一次是秒级。

```bash
python tool/quark_probe.py login          # 出二维码（PNG + 终端字符画），扫码
python tool/quark_probe.py list [fid]     # 列目录
python tool/quark_probe.py play <fid>     # play/info + audioplay + 实测单连接带宽
```

Cookie 落在 `.quark_probe/cookie.json`。⛔ **该目录含真实凭据，已在
`.gitignore` 里，不要提交。**
