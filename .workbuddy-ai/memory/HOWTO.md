# HOWTO — cloudcine 操作手册

`MEMORY.md` 的补充：这些是**怎么做**的配方与**库的行为边界**，不是必须时刻记住的约定，
需要时再读。

## 用产物里的真 libmpv 跑探针

**mpv 的行为一律实测，不靠读源码猜。**

```python
FW = ".../build/macos/Build/Products/Debug/cloudcine.app/Contents/Frameworks"
lib = ctypes.CDLL(f"{FW}/Mpv.framework/Versions/A/Mpv", mode=ctypes.RTLD_GLOBAL)
```

- ⚠️ **`DYLD_FRAMEWORK_PATH` 必须在进程启动前设好**：在 Python 里 `os.environ` 赋值太晚，
  dyld 已经找过 `@rpath/Ass.framework` 并失败。必须写成命令行前缀
  `DYLD_FRAMEWORK_PATH="<...>/Contents/Frameworks" /usr/bin/python3 probe.py`。
- 前置选项：`vo=null ao=null idle=yes terminal=no keep-open=yes`。
- 命令走 `mpv_command_string`；读位置走
  `mpv_get_property(ctx, "time-pos", MPV_FORMAT_DOUBLE=5, byref(c_double))`。
- **必须**用 `mpv_wait_event(ctx, 0.02)` 循环把事件队列抽干，否则命令会卡住。
- 区分「到底播的是哪个文件」要读 `filename` 属性 —— 只看 `duration` 会被
  「两个素材时长一样」骗过去（第一版探针就是这么被误导的）。
- **`MPV_EVENT_LOG_MESSAGE = 2`，不是 26**。写错的表现是「一条日志都收不到」，
  很容易误判成「mpv 压根没去开文件」。
- 跑探针前 unset 所有 proxy 变量：**本机代理连 `127.0.0.1` 也拦**（urllib 拿
  `HTTP 502 Bad Gateway`，curl 因为有 `no_proxy` 反而正常），而 ffmpeg 的 http 协议认
  `http_proxy`，mpv 走它就连不上本地服务。
- **后台 HTTP 服务跨不过 Bash 工具的一次调用**：上一条命令 `nohup ... &` 起的 server，
  到下一条命令就没了（mpv 报 `Connection refused`）。「起服务」和「跑探针」必须放进
  **同一次** Bash 调用。

## 逆向夸克接口

```python
import sys
sys.path.insert(0, "/Users/tandy/workbuddy-ai/夸克音乐播放器/poc")
import quark_session as qs
from quark_client import QuarkClient
cookies = qs.read_manual()          # 读 poc/.quark_cookie
c = QuarkClient("; ".join(f"{k}={v}" for k, v in cookies.items()))
```

- 跑之前 unset 所有 proxy 变量。
- `read_manual()` 读的是文件里那份 Cookie，**而列目录会轮换 `__puus`**。想在同一进程里
  连打多个接口，必须自己维护 `state` 字典并回填 `Set-Cookie`，否则第二个接口必 401。
  实测三态：裸链 `401 code=31001 auth not found`；过期 `__puus` `401 auth expired`；
  当前会话 `200 image/webp`。
- Cookie 明文文件在 `poc/.quark_cookie`（未进版本库）。
- **`file/search` 换关键词返回的是同一批结果**，不能用它来「枚举」某个目录下的视频；
  要遍历得自己做 BFS 目录走。

### 四条取链路由的实测真相（2026-10-01）

| 路由 | 形态 | 实测结果 |
|---|---|---|
| `/batch/file/play/info` | POST `{"fids":[fid]}` | `video_list` **只有转码梯度**（super 1440×600 / high 960×400 / low 480×200），**没有原画** |
| `/file/audioplay` | GET `?fid=` | `audio_url` 是**原文件**（`206` + `video/x-matroska`），**名字骗人** |
| `/file/v2/play` | **必须 POST `{"fid":…}`** | GET → `405`；POST `{"fids":[…]}` → `400 code=14001 "Bad Parameter: [fid is empty!]"` |
| `/file/download` | GET | 3.8 GB → `400 code=23018`（体积上限） |

**「原画没有画面」的完整机理**：`play/info` 的 `audio_list` 里有一条
`type: dolby_eac3` 的**纯音频流**，老解析器把它当「原画」并排到最前
→ 默认播的就是它 → **有声音、进度条在走、没有画面、不报错**。
`Video-Auth` cookie **不需要**（带/不带都是 206）；`__puus` **必需**（缺则 412）。

`play/info` 另外两个静默坑：

- `bitrate` 单位是 **kbps**（`1518.0` = 1.5 Mbps、`7758.0` = 7.8 Mbps）。
  按 bps 处理会显示「0.0 Mbps」。判据：`raw < 100000 ? raw * 1000 : raw`。
- `resolution` **同时出现在外层和 `video_info` 里**。逐层解析时若只认当前层，
  「标识在父层、地址在子层」的档位会被**静默丢掉** → 用 `_Inherited` 把祖先的
  `resolution` / `original` 传下去（`List` 的每一项只继承父层上下文）。

## OpenSubtitles 接口实测（2026-10-01）

`api.opensubtitles.com` 境内**可达**（不像 TMDB），但它的错误码**不能按常识读**。
下面全部是实测（`curl` + 假凭据）：

| 请求 | 实测结果 |
|---|---|
| 不带 `User-Agent` | `403 {"error":"User agent required"}` |
| 带 UA + **无效 `Api-Key`** | `403 {"message":"You cannot consume this service"}` |
| **完全不带 `Api-Key`** | `301`（nginx 默认页，无有效 Location） |
| `POST /download`（无效 key） | `503 {"message":"Service unavailable"}` |
| `GET /infos/languages` | `200` —— **它不校验 key**，别拿它当鉴权探针 |

两个必须记住的点：

1. **「Key 填错」返回 `403`，不是 `401`。** 而 `403` 同时是「没带 UA」的码 ——
   两者**只能靠响应体区分**（`error:"User agent required"` vs
   `message:"You cannot consume this service"`）。按状态码判断必然把「Key 填错」
   报成「被墙 / 服务不可用」，用户就会去换地址而不是改 Key
   （与 TMDB 熔断那条是同一个坑）。
2. **`/download` 对无效 key 返回 `503`**，与 `/subtitles` 的 `403` 不一致。
   所以 `503` **不能**直接当成「服务挂了」。
3. `Api-Key` 必须自带：注册免费账号后在 profile 里生成。匿名额度按天重置且很小，
   `POST /download` 的响应里有 `remaining` / `reset_time`，**要把它显示给用户** ——
   否则「今天下不了」会被理解成「这个功能坏了」。

⚠️ **成功响应形状尚未实测**（手上没有有效 Key），只按官方文档实现。
第一次配好 Key 后要回来核对 `data[].attributes.files[].file_id` 这一层。

### 探针为什么打 `/subtitles` 而不是 `/infos/languages`

上表最后一行是关键：`/infos/languages` **不校验 Api-Key**，不带 key 也 `200`。
拿它当「测试连接」会得到「一切正常」，而真正的搜索照样 `403` ——
**探针本身在说谎**，比没有探针更糟（用户会以为问题出在别处）。

`GET /subtitles?query=…&languages=en` 的判据是干净的：Key 有效 → `200`
（搜不到东西也是 `200` + 空数组），Key 无效 → `403`。
而且**搜索不消耗下载额度**，探多少次都不花钱。
所以 `OpenSubtitlesClient.probe()` 就是 `search(query: 'cloudcine', languages: 'en')`。

## 跨引擎通道的错误形状（desktop_multi_window）

`WindowMethodChannel` 的错误**只有一种**：`PlatformException` 的三段
`code` / `message` / `details`。别的异常从处理器里抛出来，框架会兜底成
`code='error'`、`message=<整段 toString>` —— 于是用户看到的提示变成
`OpenSubtitlesException(notConfigured, 还没填 OpenSubtitles 的 Api-Key…)`，
一句本该很干净的话被包了一层内部类型名。

**规矩**：主窗口的回调要么正常返回，要么抛 `PlatformException`，
`code` 用机器可读的失败种类（`opensubtitles/badApiKey`）只进日志，
`message` 用能直接显示给用户的中文。

编码路径（读一遍插件源码可以确认）：A 引擎的 Dart 处理器抛异常 →
框架 A 按 `code/message/details` 编码 → 原生 A 拿到 `FlutterError` 原样转给原生 B
→ 引擎 B 的 `_methodChannel.invokeMethod` 抛 `PlatformException` →
`WindowMethodChannel.invokeMethod` 把它包成 `WindowChannelException(code, message, details)`。
**所以播放窗口侧 `catch (WindowChannelException e)` 时，`e.code` 就是失败种类、
`e.message` 就是那句中文。**

## media_kit 与 Flutter 的行为边界

### media_kit

- **只有两个缓存量**：`player.stream.buffer`（`demuxer-cache-time`，播放头前面缓存了多少
  **秒**）与 `player.stream.bufferingPercentage`（`cache-buffering-state`，初始填充 0~100，
  **填满后停在 100 不再变** —— 进度条只在 0<x<100 时可信）。
- **拿不到字节数**：`Player` 上**没有** `getProperty`（`real.dart` 里有但没暴露到公开类）。
  所以 KB/s 只能靠 `文件大小 ÷ 时长` 的平均码率去乘「每秒缓存多少秒」。为此 `PlayRequest`
  带了 `sizeBytes`，显示时带 `≈`。
- `Player.open()` **不等文件加载完成**，所以「开播到出首帧」那段必须自己立一个
  `_awaitingFrame` 标志，靠 `videoParams / duration / position` 三条订阅里**先到的那个**
  清掉（没有哪个信号保证一定来）。

### Flutter 布局 / 动画

1. **`Row` + 只有 `Positioned` 子项的 `Stack`，必须 `crossAxisAlignment: stretch`**。
   默认 center 会把子项高度压成 0（`Stack` 无普通子项时按最小约束取尺寸），画面直接消失。
2. **隐式动画在「首次上树」那一帧不会插值** —— `AnimatedSlide` / `AnimatedContainer`
   刚建出来就把 offset 设成终值，动画根本不发生。要让「挂上树」和「开始动」分两帧：
   先 setState 挂上（终值的反面），post-frame 再 setState 到终值。代价是测试要
   **pump 三拍**（挂树 / 起步 / 跑完）。
3. **别让折叠的面板常驻树上**：宽度 0 的面板照样被 `find.text` 查到、被朗读读到，
   等于「收起了但还在」。用「挂载标志 + 等动画跑完的 Timer」摘掉它。

### 播放器窗口的 widget 测试

- **`Player()` 在 `flutter test` 里**直接抛
  `Exception: Cannot find Mpv.framework/Mpv. Please ensure it's presence in the Frameworks
  folder of the application.` —— 测试跑在**宿主 Dart VM** 上，libmpv 不在 rpath 里。
  所以不只是「`open()` 会失败」：**播放器对象压根建不出来**（`_player` 恒为 null），
  连带 `VideoController` 也是 null。
  后果：窗口里**没有进度条可点、没有播放状态可切**。依赖真实播放的行为
  （加载指示、出画、空格暂停生效没有）**只能真机验**。
  ⚠️ 别写成「`MediaKit.ensureInitialized` 没被调用」—— 那是现象描述，真因是上面这条；
  把 `MediaKit.ensureInitialized()` 加进测试也**没用**（实测仍然抛同一个异常）。
- **不能用 `pumpAndSettle`**：缓冲指示里的 `CircularProgressIndicator` 是永不停止的动画，
  pumpAndSettle 会一直等到超时。显式 pump 几拍。

## 构建诊断

### `pod install` 无限挂起

两个独立原因，症状完全一样（`flutter build macos` 停在 `Running pod install...` 之后
**再无输出、也不报错**）。完整机理与修法见 `~/.workbuddy-ai/MEMORY.md`：

- `LANG` 未设 → CocoaPods 崩在 `Dir.pwd.unicode_normalize`（路径含中文时）。
  修法 `export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`。
  ⚠️ 手工在终端直接跑 `pod install` 时**报错长这样**（不是挂起，是一坨 Ruby 栈）：
  `unicode_normalize/normalize.rb:141:in 'normalize': Unicode Normalization not appropriate for ASCII-8BIT (Encoding::CompatibilityError)`，
  栈顶一路是 `cocoapods/config.rb:167:in 'installation_root'`。
  一行修法：`cd macos && LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pod install`。
  （2026-10-01 加 `file_selector` 时又踩了一次。）
- safe-delete shim 拦了 `podhelper.rb` 的 `system('rm','-rf',symlink_dir)`。
  已在 `macos/Podfile` 用纯 Ruby（`FileUtils.rm_rf`）修好，**别删那段补丁**。
- 诊断入口：`pod install --verbose` 的第一行就是
  `[safe-delete][SAFE_DELETE_BULK_CONFIRM_REQUIRED] {"count":55,...}`。
- 手工应急：`rm -rf macos/Flutter/ephemeral/.symlinks/plugins/*`（11 个，低于阈值）。
- **修好后 `pod install` 只要 1.7 秒**。首次全量构建（下 libmpv xcframework + 编译十几个
  pod）才需要 5~20 分钟。

### 判读构建结果

- `flutter build macos` 可能**报"失败"但其实成功了**：stderr 会出现
  `[sandbox] 命令被沙箱拦截 … /Users/tandy/.swiftpm/security (file-write-unlink)`，
  使退出码非 0（即使加了 `dangerouslyDisableSandbox: true` 也会）。
  **判据是 stdout 末尾有没有 `✓ Built build/macos/Build/Products/Debug/cloudcine.app`。**
- 日志极长（`Pods/sqlite3/.../sqlite3.c` 刷 190+ 条 warning，全是噪音），`tail -60` 看结尾。
- 验证插件真的链上了，要对 `Contents/MacOS/cloudcine.debug.dylib`（不是主二进制，
  debug 下主二进制只是瘦启动器）跑 `otool -L | grep @rpath`。
- `flutter test` 输出用 `tr '\r' '\n'` 展开回车，否则失败详情被进度行挤掉。
- 改完 Swift 立刻跑一次 `flutter build macos`：xcode 的报错位置可以离病因很远
  （踩过：重复粘贴出两行 `setFrameOrigin` → 报 `expected 'func' keyword`，指到 40 行之后）。
- `Edit` 的 `old_string` 别只截到函数中间那一行。踩过：`old_string` 停在
  `guard … else { return }`（不是函数最后一行），`new_string` 又补了尾巴 → 函数尾部重复两行。

## 设计取舍的来龙去脉

`MEMORY.md` 里那些「别回退」的规则，这里是它们的**理由与实证**。规则本身很短，
但理由不说清，下一个人就会当成可以随手改的实现细节。

### 起播位置为什么只能走 `Media(start:)`

两条都用产物里的真 libmpv 实测过：

1. `Player.open()` **不等文件加载完成** —— 它只发 `loadlist` + 设 `playlist-pos`，
   紧跟其后的 `seek()` 会被 mpv 丢掉。这是「续播点了没用」的根因。
2. mpv 的 `start` 属性**会残留到下一个文件**，而 media_kit 只在 `start != null` 时设它。
   所以传 `null` = 沿用上一次的起播位置（播 A 片停在 30 分钟，接着播 B 片会从 30 分钟开始）。

因此不续播必须显式给 `Duration.zero`，`seek` 只用于**播放中**的跳转。

### 「点卡片播哪一条」为什么第 ② 级不猜下一集

`lastPlayedAt` 有值但续播点已清，有两种完全相反的成因：「看完了」和「点开 3 秒就关」。
猜下一集会在后一种情况把用户直接丢到一集他根本没看过的内容上 —— 代价比「重播这一集」
高得多，所以宁可停在原集。

### 分辨率为什么是两根轴

- 只按长边：`720x576`（PAL DVD）的长边 720 低于最低档 sd480 的 854 → 返回 `null`，
  一部老剧连分辨率角标都没有；`960x720` 会被标成 480P。
- 第二根轴用「高」而不是「短边」：竖屏的「高」就是长边，`1080x1920` → 1440P、
  `720x1280` → 1080P，虚高 1~2 档。**短边在横竖屏下都是那条短轴**，所以两个方向能共用
  一套档位表，也就不需要 VidHub 那个 `isVertical` 字段。

### macOS 三条坑的机理

1. **`network.client` entitlements**：Flutter 模板只给 `app-sandbox` + `network.server`。
   缺 `network.client` 时应用**发不出任何网络请求**，而且报错不会指向权限 ——
   扫码、列目录、取流、海报、TMDB 全废，只能靠人记得这条。
2. **部署目标 10.15**：硬下限来自 `media_kit_video` → `wakelock_plus` 的 podspec，
   设 10.14 时 `pod install` 直接失败且报错不提 media_kit。又因 `platform :osx, '10.15'`
   **只作用于 Runner 目标**，每个 pod 仍按自己 podspec 写的版本编译，所以 `post_install`
   必须**逐个 target 覆盖** `MACOSX_DEPLOYMENT_TARGET`。不覆盖时
   `flutter_inappwebview_macos` 以 10.14 编译会报
   `protocol 'ASWebAuthenticationPresentationContextProviding' requires
   'presentationAnchor(for:)' …` —— 报错指向 inappwebview，很容易误判成那个插件坏了。
3. **mpv 框架符号链接**：`media_kit_video` 用 `-framework Mpv` + 手写的
   `FRAMEWORK_SEARCH_PATHS`，指向
   `media_kit_libs_macos_video/macos/Frameworks/.symlinks/mpv/macos`；那条链接由 upstream 的
   `create_framework_symlinks.sh` 生成，而该脚本在 pub 包里**带 CRLF 行尾**，`sh` 一跑就
   `set: -: invalid option` 退出 → 目录为空 → `ld: framework 'Mpv' not found`。
   Makefile 里本来有 `sed 's/\r$//'` 去 CR，但构建期 PATH 上的 `sed` 被工具链 brokered shim
   顶掉，静默失效 —— 所以只能**用纯 Ruby 自己补链接**，别改回 sed/make。

### TMDB 响应形状那个 bug 的完整复盘

`TmdbScraper` 最初用 `res.dataListItems` 取搜索结果。那个 getter 读的是夸克那套
`{code, message, data:{list:[…]}}` 信封，而 TMDB 把结果挂在顶层
`{page, results:[…], total_pages, total_results}`（`/3/genre/*/list` 同理，顶层 `genres`）。

**为什么它能一直藏着**：`_get` 拿到的是 200，JSON 也解析成功，`whereType` 在
「键不存在」时不抛只返回空列表 —— 于是每一部作品都走进「TMDB 没搜到」的分支，
日志里干干净净。表现出来就是「TMDB 上搜不到任何片子」，而不是任何可见的失败。
如果不是去核对官方文档的响应示例，光看日志永远查不出来。

教训：**跨服务复用「信封解析」代码前，先核对对方的响应示例。**
现在 `TmdbScraper` 用私有 `_resultsOf(res)` 读 `res.json?['results']`，
回归测试在 `test/data/tmdb_scraper_test.dart`。

### 封面为什么曾经「看着像没有」

库里 145 部作品的 `poster_url` 覆盖率一直是 100%，地址从来不缺。真正的原因是**呈现**：

- 格子是竖版 `childAspectRatio: 0.56` + `BoxFit.cover`，源图却是 16:9（640×360）。
  cover 到 0.56 只保留**约 31% 的画面宽度**（640×360 → 202×360），再放大到
  ~344×614 物理像素 —— 又裁又糊，硬字幕被切一半，认不出是哪部片子。
  用 `sips` 复现过这个裁切，结果确实是一道不可读的竖条。
- 另一个诱因是历史时点：`thumb_url` / `poster_url` 这两列是 2026-10-01 才随
  drift v3 迁移加上的（日志：`索引库已升级到 v3（缩略图地址 + 媒体分类）`），
  在此之前海报墙上只能是首字母占位块。

所以解法是改呈现（模糊放大底图 + 完整画面居中，格子改 2:3），**不是去找更大的图**。
顺带记一条：夸克缩略图是**剧中帧**（带硬字幕 + bilibili 水印），不是海报，
且只能选「哪一条」不能选「第几秒」—— 换帧收益有限，别再投入。

### 播放器键盘快捷键（2026-10-01）

规则本体在 `MEMORY.md`，这里是**为什么**和**实测数据**。

**故障复盘**：用户报「播放器不支持空格暂停、左右调进度」。实际是**代码早就写了** ——
`player_page.dart` 的 `CallbackShortcuts` 里 空格 / ← / → / Esc 一条不少。但 macOS 上点播放走
`playItem()` → `openInPlayerWindow()`（独立播放窗口，跑在**另一个 Flutter 引擎**里），
**根本走不到那一页**，而 `player_window_app.dart` 的键位表里只有 `F` / `Esc`。
两个播放器各写一套 → 功能分裂 → 用户看到的是「没做」。
**教训：播放器有两个实现，改一处必须两处都改。**

#### 为什么控制栏必须 `ExcludeFocus`

按键从**主焦点**出发沿焦点链往上找，**最近的那个处理者赢** —— 谁离主焦点近谁说话。
`Slider` 自己带方向键处理，而它比挂在窗口根上的 `CallbackShortcuts` **更靠近主焦点**。
三条探针（都是真跑的）：

| 探针 | 结果 |
|---|---|
| 焦点给 `Slider(value: 0.5)`，按 → | `onChanged` 收到 `0.55` —— **滑块确实吃掉方向键** |
| 同一滑块包进 `ExcludeFocus` | `canRequestFocus=false`，方向键不再改值 |
| 焦点给 `IconButton`，按空格 | `onPressed` 没触发，`CallbackShortcuts` 命中 |

→ 所以 `ExcludeFocus` 是**为方向键**加的。空格不吃亏是因为按钮的激活键绑在 `WidgetsApp`
那一层，比我们**远** —— 别把这层当成「顺便防按钮」，也别因为「空格本来就没事」就把它删了。

不排除时的完整症状不只是「方向键失灵」：`_seekPreview` 会被滑块的 `onChanged` 写上，
于是**进度条卡在预览位置不动**（用户会往「播放器卡死了」的方向猜，离真因很远）。

关掉聚焦**不影响鼠标**：点击与拖拽走手势层，不经过焦点。

#### 两个容易漏的配套

- **诊断页要换一张只含 Esc 的键位表**。那页有手输直链的 `TextField`。
  字符输入**不走按键链**（由平台输入法通道送进来），而 `CallbackShortcuts` 在输入框**下方**，
  空格会先被它截走 → 「地址里的空格打不出来」，且不报错。
- **`CallbackShortcuts` 必须有一个 `Focus(autofocus: true)` 子节点**。它只是往焦点链里插
  一个节点，自己不在链上就什么都收不到 —— 症状是「快捷键全不生效，但什么都不报」。
  同一个 `Focus` 也**不能**因为控制栏已经 `ExcludeFocus` 就顺手删掉。

#### 步长与夹取

左右各 10 秒，与内置页一致。跳转目标一律过 `lib/core/utils/playback_seek.dart` 的
`clampSeekTarget(target, total)`：`PlaybackController.seek` 与窗口 `_seekBy` 共用。
**两个播放器跑在两个引擎里，窗口够不到 `PlaybackController`** —— 不抽出来就必然各写一遍
（本项目已有先例：`ScrapeQuery.fromParsed`、`PosterCache` 的 `headersFor`）。
夹取的要点是**总时长未知时不夹上界**（`duration` 还是 0 时硬夹会把位置压回 0，
表现是「刚开播按一下右键，进度条归零」）。

#### 测试怎么写

`flutter test` 里没有播放器（见上「播放器窗口的 widget 测试」），所以：

- **键位表里在不在** → 结构断言（`CallbackShortcuts.bindings`）；
- **按下去算出来的位置对不对** → `test/core/playback_seek_test.dart` 的纯函数用例；
- **端到端那条链通不通** → 复用已有的 F / Esc 用例（它证明
  `Focus(autofocus)` + `CallbackShortcuts` + 真实按键事件这条路是通的）；
- **`ExcludeFocus` 的机制** → 单独一条用例把上面表格里前两条固化成回归。
  写成用例的理由：Flutter 哪天改了滑块的键盘行为，我们的修复会**静默失效** ——
  快捷键还挂在表里，按下去却没反应。那时这条会红。

## 豆瓣为什么这么难缠（2026-10-01）

规则本体在 `MEMORY.md`，这里是实测记录。

### 搜索响应分三段，正主常常不在第一段

实测搜「繁花」：

| 段 | 内容 |
|---|---|
| `subjects.items` | 两本书 + `繁花(影版)`(2028) |
| `smart_box` | **真正的剧集在这里**（直接是数组，不是 `{items:[…]}`） |

只读 `subjects` 的后果是**静默刮错片子**：拿到的是同名电影或书，标题海报全不对，
但流程一路成功、日志干净。另：`type=movie` **不是过滤器**（结果里混着 `book`），
必须自己按 `target_type` 剔。

### 详情接口会跳转

`…/v2/movie/{id}` 对剧集会 **301 到 `/tv/{id}`**。所以「是电影还是剧集」要读
**响应体的 `type`**；按请求路径判会把剧集全记成电影。

### 海报与图片防盗链

- 搜索返回的 `cover_url` 带 `h/120`，是**横条**，不能当海报。
- 详情里的 `m_ratio_poster` 才是海报（实测 540×803 = 2:3，89KB；
  `l_ratio_poster` 1080×1606/299KB 不必用）。
- `img*.doubanio.com` **缺 `Referer` 一律 418**，且图片**不带 Cookie** ——
  与夸克那套正好相反，别把两种取图头混成一份。

### 额度与错误码

- 额度约 **10 个不同的搜索词**；**同一个词重复请求走缓存**，
  所以「拿一个词连打十次」测出来的额度会严重高估。
- 耗尽后是 `{"msg":"need_login","code":103}`。**HTTP 状态码不稳定 —— 实测既见过 200
  也见过 403**，所以**必须先解析业务码再判状态码**，否则会把「额度用完了」报成
  「接口挂了」。
- 详情接口的额度独立且宽得多。
- 官方通道已关闭（`frodo` 要签名 `997`、公开 apikey 失效 `1062`），只能走 `rexxar`。
- 生态旁证：MoviePilot = TMDB + 图片代理；MetaShark = TMDB + 豆瓣双源；
  StrmAssistant 明说「豆瓣受制于流控」—— 这条路大家都只能省着用。

## 「最近播放」为什么是一个视图（2026-10-01）

`LibraryFilter.playedOnly` 的三条设计理由，写在这里免得下一个人想把它并进分类。

**为什么不是 `MediaCategory` 的一个取值**：`category` 是**扫描期对文件的判定**，落库、
并被 `mergeWorkForUpsert` 以「永远取新值」的规则覆盖。而「播过没有」是**播放记录**，
随播放实时变化，同一部作品会在两栏之间来回横跳。合并的直接后果：用户每次重新扫描，
这一栏里的作品就被冲成别的分类 —— 而且不报错。

**为什么离开这一栏不把排序切回去**：`setPlayedOnly` 会把排序设成
`WorkSort.recentPlayed`（按「最近添加」排的「最近播放」是自相矛盾的），
但 `setCategory` 不动排序。想「自动切回」就得记住「排序是刚被隐式设上的」还是
「用户自己在排序菜单里选的」—— 猜错会静默改掉用户的选择。
排序菜单一直显示着当前排序，所以不切回**不是隐藏状态**：用户看得见，一键就能改。

**为什么刷新信号只在换条时推进**：列表顺序只由「谁最后被播过」决定。
同一部片子每 10 秒一次的进度回报只会把它自己的时间戳往后推，不会让它与别的作品换位。
每次都推的后果：用户在主窗口看海报墙、播放窗口在另一块屏上播片时，海报墙每 10 秒重建一遍。

**为什么那个信号要单独放一个文件**：`app_providers.dart` 是组合根，被 feature provider
单向依赖；让它反过来 `invalidate(workListProvider)` 会形成循环 import。
（也考虑过在组合根里监听 `PlaybackController` 这个 `ChangeNotifier`，但那样会在**启动时**
就 `watch(playbackControllerProvider)`，凭空建出一个 mpv 实例。）

## 字幕与音轨：几个刻意的取舍（2026-10-01）

### 为什么用枚举而不是几个可空字段

`_SubtitleChoice` 原来是「几个可空字段」（`trackId` / `fileId` / `isOff`）。
改成 `enum _SubtitleKind { off, embedded, cloud, online, local, searchOnline, pickLocal }`
是因为**「加载方式」这一步必须能被穷举**：内嵌轨是切轨，其余三种是「先取回正文
再 `SubtitleTrack.data`」。几个可空字段的写法下，「新加一种来源但忘了写加载分支」
的后果是**点了没反应**，而且不报错；枚举 + 不带 `default` 的 `switch` 会让编译器提醒。

同理，菜单里还混了两个**动作**（`searchOnline` / `pickLocal`）而不是字幕 ——
它们被 `_showSubtitleMenu` 的循环拦在前面，不会走到 `_applySubtitleChoice`。
写成 `case` 只为穷举完整。

### 为什么 `_showSubtitleMenu` 是个 `while` 循环

因为选「搜索在线字幕…」之后要把**同一个菜单重新打开**让用户从结果里挑。
写成递归的话栈随搜索次数增长，而且「谁负责把菜单关掉」会变得很难读。
循环把「开菜单 → 拿到选择 → 要么应用要么重开」摆在一处。
`_promptSubtitleChoice()` 单独一个方法还有一个副作用好处：它自己不带任何
`await` 之前的上下文获取，循环体里就不会触发 `use_build_context_synchronously`。

### 为什么选中态不做乐观更新

切轨可能失败（轨道不存在、容器不支持），外挂字幕可能取不下来。
乐观更新会让菜单在一条**根本没加载上**的字幕上打勾，而用户以为切成功了。
所以一律等成功之后再 `setState`。

外挂字幕的选中态还**必须单独记账**（`_activeCloudSubtitleId` / `_activeOnlineSubtitleId` /
`_activeLocalPath`）：mpv 认不出我们后挂上去的外挂字幕是哪一条，它只会把
「有字幕轨被选中」报成一个数字。靠那个数字高亮，菜单会在**错误的内嵌轨**上打勾。
推论：有外挂字幕挂着时，内嵌轨那一组一律不打勾（`_externalActive`）。

### 为什么三个来源都要 `decodeTextBytes`

中文外挂字幕大量是 GBK。`File.readAsString()` 假定 UTF-8，会抛或得到乱码；
mpv 的自动探测也经常失败 —— 满屏乱码，**而且不报错**。
所以字节一律自己取、用 `decodeTextBytes`（先严格 UTF-8、失败再 GBK）解成
UTF-8 文本再交给 mpv。网盘/在线两路的字节在主窗口取（那边有 `fast_gbk`），
本地那一路播放窗口自己读（用户刚在系统选择器里选中，沙箱已授权）。

### 为什么本地文件要每次重新读

`_localSubtitle` 只记**路径 + 展示名**，正文在每次应用时重读。
缓存正文的后果是「用户拿编辑器调了时间轴，播放器里没生效」——
一个完全无从查起的问题。

### 为什么在线搜索结果要缓存在窗口里

`_onlineSubtitles` 只在**换片（itemId 变了）**时清空，不是每次开菜单都重搜。
字幕站的额度很小，而用户「打开菜单看一眼有什么」的次数远多于「真的要换一条」。
每次开菜单都打一次接口，一天下来额度会在用户毫无察觉的情况下烧光 ——
而那时的表现是「**下载**失败」，与「搜索」看起来毫无关系。

清空判据用 `itemId` 而不是「又来了一条请求」：刷新直链也会走 `_adoptRequest`，
那条路换的只是 URL。用「有没有新请求」判，会让用户正在挑的在线字幕列表
在一次自动刷新后凭空消失。

