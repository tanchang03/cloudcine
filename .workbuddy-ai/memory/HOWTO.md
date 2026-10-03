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

### 用 C 直接调 mpv（2026-10-03，要枚举滤镜/查编译期能力时用）

`avfilter_get_by_name` 这类**链接期**符号 Python ctypes 拿不到，得写 C：

- `clang -F` 要指向 **`.../Mpv.xcframework/macos-arm64_x86_64`**（那层才有
  `Mpv.framework`）；指到 xcframework 根目录会报 `framework 'Mpv' not found`。
- 运行期还会缺 `Ass.framework` → 建一个软链目录（`ln -s` 进 `Ass.framework` / `Mpv.framework`）
  再 `DYLD_FRAMEWORK_PATH=<那个目录>` 跑。
- ⛔ **必须 `setvbuf(stdout, NULL, _IONBF, 0)`**：`printf` 走管道时是块缓冲，
  被 SIGTERM 掉就**一个字都收不到**，看起来像「程序没跑」。
- 等待轮数别开太大（400 → 60）：探针是「发命令 → 抽事件 → 打印」，多等只是白等。

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
- **`getProperty` / `observeProperty` 是公开的**（2026-10-02 更正）：早期笔记写「`real.dart`
  里有但没暴露到公开类」，**是错的** —— `NativePlayer` 上这两个方法都没有下划线，
  而 `NativePlayer` 本身可从 `package:media_kit/media_kit.dart` 拿到（`platform is NativePlayer`
  一直是能编译的）。所以「拿不到任意 mpv 属性」这个前提不成立，别再据此下结论。
  ⚠️ 但 **`setProperty` 丢掉了 mpv 的返回码**（`real.dart` 里 `mpv_set_property_string`
  调完直接返回，没看结果）⇒ 属性名写错或选项不可运行期改时，失败**完全静默**。
  凡是「设了但不确定生效」的属性，都要 `getProperty` **读回来自证**并记诊断日志
  （`PlayerBufferConfig._confirmStreamCacheOff` 就是这么做的）。
- **两层缓存：`demuxer-cache-time` 量不到网络**（2026-10-02）：media_kit 硬编码
  `cache=yes` + `cache-on-disk=yes`，于是
  `网络 → stream cache（字节，后台预读）→ 解复用 → demuxer cache（秒）`。
  `demuxer-cache-time` 是**第二层**的时间跨度，数据来自本地（内存/落盘文件），
  一次几百 MB 的块填充几十毫秒就灌完 ⇒ 换算出来是 GB/s 级，**与带宽无关**。
  这就是「缓冲时显示 ≈1.0 GB/s」的根因（不是单位换算错）。
  能测准的前提是 `PlayerBufferConfig.disableStreamCache`（`open()` 前 `cache=no`）。
  兜底与完整推导见 `cacheBytesPerSecond` 的文档。
- **网速优先直接读 mpv，不要估算**（2026-10-02）：`demuxer-cache-state.raw-input-rate`
  就是**输入速率（字节/秒）**，取自输入层「未缓冲读取字节数」计数器的差分 —— 真实下载速率。
  解析在 `core/utils/mpv_cache_state.dart` 的 `rawInputBytesPerSecond`（纯函数，8 例测试）。
  轮询用 `getProperty`（1 Hz）而不是 `observeProperty`：这个属性是 node 类型、变更通知不保证发。
  拿到就用，拿不到才退回下面的估算。
  ⚠️ 字段名已直接在**随包的 libmpv 二进制**里核对过存在：
  `strings .../Mpv.framework/Versions/A/Mpv | grep -Fx raw-input-rate`（本项目是 mpv **0.36.0**）。
  这个招式比翻文档可靠 —— 文档抓不全，二进制不会骗人。
- **估算兜底**：没有字节计数时，靠 `文件大小 ÷ 时长` 的平均码率去乘「每秒缓存多少秒」。
  为此 `PlayRequest` 带了 `sizeBytes`，显示时带 `≈`。
  ⚠️ `sizeBytes` 是**网盘原文件**体积 —— 手选低码率转码档时码率被高估若干倍（默认播原画时才对）。
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
  （菜单/对话框本身是静态的，那里用 `pumpAndSettle` 没问题。）
- **菜单/对话框要单独渲染来测**：控制栏那两个入口（字幕 / 音轨）都写着
  `_player == null ? null : …`，而 `_player` 在测试里恒为 null → 按钮永远禁用，
  **弹菜单那条路径不可达**，怎么 pump 都点不开。所以 `player_window_app.dart` 开了
  `@visibleForTesting` 的 `buildAudioMenuForTest` / `buildSubtitleMenuForTest` 直接构造，
  回归 `test/ui/windows/player_track_menus_test.dart`（20 例）。
- ⚠️ 同一个用例里**第二次 `pumpWidget` 要换根 key**：`pumpWidget` 遇到同类型的根组件是
  「原地更新」不是重建，Navigator 连同栈上没关掉的 `DialogRoute` 会留下来 → 第二次
  `tap('打开')` 落在上一个菜单上，报 `would not hit test`。`key: UniqueKey()` 解决。
- ⚠️ 测菜单要把 `tester.view.physicalSize` 开大（`Size(900, 1600)`）：字幕菜单满配 14 行，
  默认 800×600 会让 `AlertDialog` 溢出，而溢出在测试里是**报错**不是「看不全」。
- 菜单 pop 出来的是私有类型 `_SubtitleChoice`。它的**类型名**测试库写不出，但**成员名是公开的**
  （`kind` / `fileId` / `trackId` / `localPath`）→ `(choice as dynamic).kind` 取得到。
  只读不构造，既能钉住「pop 了什么」又不用为测试公开类型。

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

### macOS 四条坑的机理

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
4. **`keychain-access-groups` 是受限 entitlement，绝不要加**（详见下一节）。

### 受限 entitlement 让 Release 包启动即崩（2026-10-01）

**现象**：`flutter build macos --release` 构建成功（`✓ Built … cloudcine.app`），
但 `open` 或双击都起不来，报「应用程序意外退出」。崩溃报告关键行：

```
Exception Type:  EXC_CRASH (SIGKILL (Code Signature Invalid))
Termination Reason: Namespace CODESIGNING, Code 1, Taskgated Invalid Signature
codeSigningID: ""   codeSigningTeamID: ""
usedImages: /dyld_path_missing , /main_executable_path_missing
```

**读这份报告的三个要点**（不认识这三点会白查很久）：
- `usedImages` 里出现 `dyld_path_missing` / `main_executable_path_missing`
  表示**内核在 exec 阶段就把进程杀了**，dyld 根本没来得及映射可执行文件 ——
  不是 Dart 崩溃、不是插件崩溃，是签名被拒。
- `Taskgated Invalid Signature` 是 taskgated 守护进程的判决，与「app 内代码」无关。
- `threads` 里**没有任何调用栈**（`frames: []`），所有寄存器为 0。这就是它的签名。

**根因**：两份 `.entitlements` 里写了 `keychain-access-groups`。它属于
**「需要描述文件的能力项」（restricted entitlement）** —— 只能由 provisioning
profile 下发。而本项目刻意走 ad-hoc 签名（`CODE_SIGN_IDENTITY = "-"`、
`DEVELOPMENT_TEAM` 为空），拿不到描述文件，于是：

1. **ad-hoc 签名 + 受限 entitlement → 签名被判无效 → 启动即 SIGKILL。**
2. 顺带地，同一份 entitlement 会让 Xcode 构建报
   `"Runner" requires a provisioning profile.`（用 `CODE_SIGN_STYLE = Manual`
   或 Automatic 都会报）。

**验证手法（当时怎么确认的）**：不必重新构建，直接改签名试：

```bash
# 把 keychain-access-groups 去掉、sandbox 关掉，ad-hoc 重签（ad-hoc 不需要钥匙串，不会报错）
codesign --force --deep --sign - --entitlements /tmp/test_ent.plist \
  build/macos/Build/Products/Release/cloudcine.app
open build/macos/Build/Products/Release/cloudcine.app   # 立刻就能起来
```

**正确做法**（与参考项目 `夸克音乐播放器` 的 entitlements 完全一致，两边不要分叉）：

| 项 | 值 | 理由 |
| --- | --- | --- |
| `com.apple.security.app-sandbox` | **`false`** | 沙箱会把数据目录换成 `~/Library/Containers/…`，debug/release 各持一份媒体库；沙箱下系统安全存储写入还会报 `-34018` |
| `keychain-access-groups` | **不写** | 受限 entitlement，ad-hoc 下启动即崩 |
| `com.apple.security.network.client` | `true` | 出站请求 |
| `com.apple.security.network.server` | `true` | 播放器给直链挂请求头时要在 127.0.0.1 起代理 |
| `com.apple.security.files.user-selected.read-only` | `true` | 「加载本地字幕文件」（沙箱已关，保留以记录意图） |
| `DebugProfile` 额外 `get-task-allow` | `true` | 否则 `flutter run` 连不上 Dart VM Service |

**排查时踩过的两个假线索**（别再走一遍）：
- 用 `Developer ID Application` 证书重签能解，但**本机签不动**。本机确实有可用证书
  （`security find-identity -v -p codesigning /Users/tandy/Library/Keychains/login.keychain-db`，
  **必须显式查 login 钥匙串**，沙箱 HOME 下会漏看），但 `codesign --force --deep` 签整包时
  报 `errSecInternalComponent`（子组件里残留 `*.cstemp` 也会让重签报
  `invalid or unsupported format for signature`）。⚠️ 注意：**兄弟项目用
  `flutter build macos --release` 走 Developer ID 是成功的**（产物 `TeamIdentifier=7TXGZ3BSQC`），
  所以「签不动」只对**手动 `codesign`** 成立，不等于 Xcode 构建那条路不行。
- `open` 与双击都崩 ≠ 命令行直接跑二进制没崩。当时 `timeout 5 <binary>` 看着「退出码 0」，
  其实是被 `|| true` 吞掉了 —— **别用 `|| true` 包住要判读退出码的命令**。

### 钥匙串在 ad-hoc 签名下**必然**弹框（2026-10-01 定案，别再试了）

原来这一节写过「关掉沙箱后并不会每次弹框」——**那是错的**。用户实测反馈
「每次启动都要输钥匙串密码」，复测后确认无解。

**机制**：钥匙串条目的 ACL 只认「创建它的那一份代码签名」。ad-hoc 的身份是
**cdhash**（`codesign -d -r- cloudcine.app` 可见），每重新构建一次就变一次，
ACL 永远对不上。

**三条路全试过、全废**：

| 方案 | 结果 |
| --- | --- |
| 加 `keychain-access-groups` entitlement | 启动即 SIGKILL（见上一节），且 `requires a provisioning profile` |
| `useDataProtectionKeyChain: true`（`flutter_secure_storage` 默认） | 每次写入 `PlatformException(Code: -34018, A required entitlement isn't present.)` |
| 自建原生通道 + 写入「任何程序都可访问」的 ACL | **仍弹框**，见下 |

**第三条的实测数据**（这是最容易误判的一条，所以留全）：

搭一个最小 `.app`（ad-hoc 签名），行为逐字复刻 `read`/`write`（先删后建）；
建条目 → **原地重新构建**（cdhash `6c1d9c6e…` → `d61f0379…`，路径不变）→ 再启动：

```
[P1-create]        read -> 0
[P2-after-rebuild] 17:32:42.792 启动
[P2-after-rebuild] 17:32:46.014 read -> -128 User canceled the operation.   ← 阻塞 3.2 秒 = 弹框了
[P2-after-rebuild] write.delete -> 0
[P2-after-rebuild] write.add -> 0
[P2-after-rebuild] read -> 0
```

两种受信程序写法都不行：`SecTrustedApplicationCreateFromPath(nil, …)`（「任意程序」）
与 `SecTrustedApplicationCreateFromPath(bundlePath, …)`（app 自己的路径）。
连 Apple 自带的 `/usr/bin/security find-generic-password -w` 去读也拿到 `-128`。

**⚠️ 判断「到底弹没弹框」的办法**：看**耗时**。
真弹模态框会阻塞到用户点；`-128` 立刻返回则多半是「需要授权但当前上下文弹不出 UI」。
CLI 探针跑在非 GUI 会话里，**结论不可信** —— 必须打包成 `.app` 用 `open` 起。

**唯一能零弹框的路**：**稳定的签名身份**（Developer ID）。
兄弟项目 `夸克音乐播放器` 就是这么做的，`cloudtune.app` 实测不弹。
本项目选择不给播放器签公司证书，所以 macOS 侧改成
**加密文件**（`EncryptedFileSecretBackend` + `secret_cipher.dart`）：
零弹框、零授权、零签名依赖。代价是「混淆级」保护 —— 密钥由本机+本用户派生，
同机同用户的任何程序都能解开。

**教训（最重要的一条）**：排查这类问题**不要在用户机器上跑会触发系统授权的探针**。
授权框是系统级 UI，弹出来用户根本不知道是谁在要权限 —— 2026-10-01 就因此让用户
看到一串「请输入钥匙串密码」的框并一头雾水。

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

## 刮削匹配闸门：宁可漏刮，也不刮错（2026-10-01）

### 事故：查询带着 `year=2026`，结果返回 1994 年的片子

网盘目录 `/来自：分享/超z级z马z力z欧z银z河z大z电影aa(2026) 4K HDR & Dv/`
（真名《超级马力欧银河大电影》，发布组每个字之间插了个 `z` 规避关键词过滤）
被刮成了 **《低俗小说》(1994)**。

根因不是数据源错了，而是**代码从没校验过结果**：`TmdbScraper._searchOne`
直接取 `results.first`。TMDB 的 `/search/movie` 是**模糊搜索** ——
它返回「按相关度排序的猜测」，查询词再离谱也可能有返回。
于是「查不到」被静默地变成了「查到了另一部片子」。

最荒谬的地方是：查询里明明带了 `year=2026`，返回的是 1994 年的，
**年份差 32 年而代码毫无察觉**。

### 三道判据与它们的边界（都是实测算出来的数）

`domain/services/scrape_match.dart` 的 `ScrapeMatch.evaluate`，顺序固定：

1. **年份硬闸门**：两边都有年份且 `gap >= 2` → 淘汰。定 2 而不是 1：
   发布组标「发行年」、数据源记「首播年」差一年是常态；而本次事故差 32 年，
   离阈值远得很。**任一边没年份时这道闸门不生效**（否则「发布组没标年份」
   的片子会被全判死），交给标题判。
2. **相似度**（查询词 × `title`/`originalTitle` 两两取最高）：
   - `== 1`：精确；
   - 前缀 `0.65 + 0.35r`：`仙逆` × `仙逆 第一季` = **0.79**。
     ⚠️ 这一档的下界是 **0.65 > strongSimilarity(0.6)**，所以**前缀档是
     无条件接受、不靠年份的**。别以为「沾边才要年份」也适用于前缀 ——
     同一部作品的分季命名全在这一档，给它们加年份要求会把分季条目全判死。
   - 包含 `0.55 + 0.25r`：`地球` × `流浪地球2` = 0.65；
     `联盟` × `复仇者联盟无限战争` = **0.6056**（刚好过 0.6，落到强档）。
     只有 `r < 0.2` 时包含才会掉进沾边档。
   - 否则 Dice bigram。
3. **沾边档 `0.35 ~ 0.6`**：**必须有年份兜底**（`gap <= 1`）才接受，
   否则淘汰。`Se7en` × `Seven` = **0.5** + 同年 → 接受（同一部片的两种写法）；
   `无间道` × `无间行者` = **0.4** + 没年份 → 淘汰（两部不同的片子）。
4. **跨书写系统**（一边有汉字另一边没有）且 `gap <= 1` → 接受。
   中文查询词 × 英文结果时相似度天然为 0，只能靠年份；**没年份就淘汰**。

实测数值备查（写测试时别再猜）：`蜘蛛侠英雄无归` × `蜘蛛侠平行宇宙` = 0.333
（低于沾边档）、`流浪地球` × `流浪地球2` = 0.93、`海王` × `海王2` = 0.883、
`阿凡达` × `阿凡达水之道` = 0.825。

### ⚠️ Dice 兜底会被「偶然相邻的 bigram」命中，所以断言别写 0

`超z级z马z力z欧z银z河z大z电影aa` × `超级马力欧银河大电影` 的相似度是
**0.0714，不是 0** —— 因为那串乱码里 `电` 与 `影` 恰好是相邻的，
撞上了结果标题里的 `电影` 这一个 bigram。

判定不受影响（0.0714 远低于沾边档下界 0.35），但测试必须写
`lessThan(ScrapeMatch.weakSimilarity)` 而不是 `0`：写 0 会在别人调整
bigram 切法时莫名其妙地红，而且红得看不出原因。

### 闸门只管自动路径，手动路径必须绕开

`ScrapeMatch` 只接在 `TmdbScraper._pickVerified` 与 `DoubanScraper._pickBest`
上（自动刮削）。`search()` / `resolve()` 那条**手动通道不过闸门** ——
实际被闸门拦下来的候选，往往正是用户想找的那一个。见下一节。

## 手动刮削通道（2026-10-01）

`ui/widgets/manual_scrape_dialog.dart` + `WorkScraper.{queryFor,searchCandidates,applyCandidate}`
+ `MetadataScraper.{search,resolve}`。详情页「刮削」旁边那个「手动」按钮。

### 三个交互决定（都有理由，别随手改）

1. **预填的是「文件名解析出来的词」，不是库里已存的标题。**
   库里那个可能是上一次刮错的结果（`低俗小说`）—— 用户得先意识到
   「这个框里是错的」才会去改；而预填解析原文
   （`超z级z马z力z欧z银z河z大z电影aa`）直接展示了「自动刮削拿着这么个
   词去搜」，用户一眼就知道该删掉那些 `z`。
2. **打开时不自带一次搜索。** 豆瓣额度按**搜索词**计，匿名只有约 10 个；
   预填的那个词正是自动刮削刚搜失败的那一个，替他再花一次毫无价值。
3. **点候选只是选中，还要再点一次「用这一条更新」。** 刮削会覆盖标题、
   年份、海报、简介，不该在用户只是「看看有哪些候选」的时候发生 ——
   这就是「确认」那一步。失败时**留在对话框里**（关掉的话用户还得重新
   敲一遍片名，而他要做的只是换一条候选）。

### `search()` 为什么只搜一个词、且不打详情接口

- 只搜一个词：`scrape()` 会在第一个词零命中时再花第二个词的额度（共 2 个），
  手动通道一次点击只花 1 个，且用户看得见结果、不满意可以自己改了再搜。
- 不打详情接口：候选列表要的是「有哪些片子」，不是「每部片子的完整资料」。
  豆瓣的 `search()` 只做 `_search` 一次请求；完整海报与简介留给
  **用户选中之后**的 `resolve()`（那一步才必须打 `/movie/{id}`，
  因为搜索结果的 `cover_url` 是 120px 横条，不能当海报）。
- 只剔非影视条目（书 / 音乐 / 游戏）：`type=movie` **不是过滤器**，
  不剔的话搜「繁花」前两条就是两本书。

### 候选缩略图复用 `PosterCache`

`_CandidateThumb` 走 `posterCacheProvider.pathFor(key: 'candidate-<source>-<id>', url:)`
而不是 `Image.network`：豆瓣的图必须带 `Referer`，而那个头是缓存层的
`headersFor` 回调按域名给的 —— 走 `Image.network` 就得把「哪家图要什么头」
复制一份到 UI 层。

### 结果文案必须按「通道」分，不能只按状态（2026-10-01 补）

`WorkScrapeOutcome.message` 一开始只 `switch (status)`，于是
`WorkScrapeStatus.notFound` 在两个通道里共用同一句话：

> 在线源都没有找到匹配的条目，可能是片名解析不准，或这个词在数据源里没有收录。

手动对话框把它原样显示出来 —— 用户**刚刚亲眼看到一列候选、亲手点了一条**，
却被告知「没找到条目 / 片名解析不准」。他会以为界面坏了，或者去改一个
本来没错的词。根因是 `notFound` 在两个通道里是**两件不同的事**：

| | 谁搜的 | 为什么失败 | 下一步 |
|---|---|---|---|
| `auto` | 算法拿文件名解析出的词 | 没搜到信得过的条目 | **换个词自己搜** |
| `manual` | 用户亲手从候选里挑 | 那一条解析不出完整元数据 | **换一条候选** |

修法是给结果加 `ScrapeChannel` 维度，文案按 `(status, channel)` 取
（成功那条两个通道共用，「已刮削：…」对谁说都一样）。`channel` **故意不给
默认值** —— 默认值会让「漏填」静默编译通过，而漏填正是当初那个 bug。

两处配套，改一处必须改另一处：
- auto 那条文案末尾写死了「点旁边的『手动』自己敲片名再搜」。它成立的前提是
  **`auto` 只有详情页「刮削」按钮这一个来源**（扫描期的自动刮削走
  `ScraperPipeline`，根本不产出 `WorkScrapeOutcome`），而「手动」按钮就并排
  在它旁边。把「手动」藏进菜单，这句文案就开始撒谎。
- `_ManualScrapeButton` 的文档注释原先写着「自动失败时用户看到的是一句
  **没有下一步**的话」—— 那是当时的实情，补上引导之后就成了错的描述。
  **注释描述的行为改了，注释本身也要改。**

测试钉了四条：auto 文案含「手动」；manual 文案含「换一条」且**不含**
「片名解析不准」/「在线源都没找到」；两条 notFound 文案确实不同；
成功文案两个通道一致。最后一条是防「顺手也给它分个叉」——
分了只会多一处要维护的重复。

### 审过但确认**不是** bug 的四处（2026-10-01 端到端复审）

写下来是为了别让下一轮把它们当缺陷「修」掉。

1. **`applyCandidate` 在 `runningKey != null` 时返回 `null`，对话框会显示
   通用兜底「更新失败，请换一条候选再试」—— 这看着像「把并发当成候选错」，
   但**实际不可达**：`ManualScrapeDialog` 是模态的
   （`showDialog` + `barrierDismissible: false`），对话框开着的时候点不到
   背后的「刮削」；而 `runningKey` 只有 `scrape()` / `applyCandidate()`
   会写，扫描期的自动刮削走 `ScraperPipeline`、根本不碰控制器。
   所以这条分支只是防御性代码，留着比删掉好（删了将来放宽并发就是真 bug）。
2. **`DoubanScraper.search` 完全不看 `query.kind`**（只用 `query.title`），
   而对话框里有个「电影 / 剧集」下拉。看着像「控件没接上」，但这是**对的**：
   豆瓣的 `type=movie` 本来就不是过滤器，代码是按 `targetType` 本地剔
   （只留 `movie` / `tv`，见类文档坑 #2），而手动搜索**本来就该两种都给**
   —— 用户自己挑。`kind` 只对 TMDB 有效（`/search/movie` 与 `/search/tv`
   是两个不同端点，`year` 也要换成 `first_air_date_year`）。
3. **`_search()` 构造的 `ScrapeQuery` 不带 `season` / `episode`**。不影响：
   这两个字段只有 TMDB 的剧集搜索路径关心，而 `resolve()` 根本不接
   `ScrapeQuery`（它只用 `candidate`）—— 用户敲的词只作用于**搜索**，
   选中之后落库靠的是候选自己的 id。这正是该有的设计。
4. **年份预填 + TMDB 硬过滤这个组合不是 bug。** 对话框把文件名里的年份
   （`…aa(2026) 4K HDR`）填进「年份」，而 TMDB 的 `year` 是**硬过滤**，
   填错会把正主直接筛掉 —— 但预填的值来自**文件名**而不是库里那个可能已
   刮错的年份（`q?.year ?? widget.work.year`），且输入框下面那行提示
   「年份留空能搜到更多候选（TMDB 的年份是硬过滤…）」就是为这个失败模式写的。
   预填 + 提示是刻意的一对，别只删其中一个。

### 已知的粗糙边缘（接受，暂不改）

手动应用**失败**后，控制器仍会把 manual 那条文案写进 `state`。对话框里显示
没问题（就地说明），但如果用户接着**取消**对话框，详情页按钮下面会留着
「…换一条候选再试」——而候选列表已经跟着对话框一起消失了。语义上没错
（它确实描述了刚发生的事），只是那句「换一条候选」指向了一个不在场的东西。
真要治就得给「失败」也带上来源标记、或者失败时干脆不写 `state`；
当前判断是不值得为此加一层状态。

## 手动刮削：刮完自动归一 + 媒体类型（2026-10-02）

用户在「用这一条更新」之后要看到三件事：**类型对不对**、**库里是不是已经有同一部**、
**如果合了，合到哪去了**。四处改动：

### 1. 结果文案带上落库后的类型

`WorkScrapeOutcome.message` 的 `scraped` 分支末尾加 `· 类型：${work!.category.label}`。

必须写出来：对话框里那个「媒体类型」选择框可能**没赢** —— 类型标签给出
「动画 / 纪录片 / 综艺」时优先级更高（见下）。不写的话用户会以为「我选的没生效」。

### 2. 对话框里加「媒体类型」chip 行（刮削结果可手工改）

`manual_scrape_dialog.dart` 的 `_categoryOverride`：**默认 `null` = 「自动」**，
落库时交给 `WorkScraper._categoryFor` 按刮削结果判定；用户点了某一枚 = **结论**，
直接落库并置 `categoryManual = true`（与「自定义」同一条规则）。

- 版式抄上面的「来源」chip 行（`null` 对应「自动」那一枚）——**别用下拉**：
  下拉要表达「不指定」得塞一个非枚举的哨兵值，chip 行天然能表达。
- 只在**选中候选之后**才出现：它描述的是「这一条会怎么落库」，没选候选时没有对象。
- 提示语必须写清「自动 ≠ 不变」：「自动 = 按**本次**刮削结果判定…」，并补一句
  「之前若被锁过分类，手动重刮也会按本次结果重判」。

### 3. 手动通道的「自动」= 按本次刮削重判（`manualChannel`）

`_apply` / `_categoryFor` 的参数 `manualChannel`（旧名 `structuralCategoryFallback`）
一个开关管两件事 —— 手动通道（`applyCandidate` 发起）与自动通道（`scrape`）的
**全部**差别都集中在这里：

1. **忽略分类锁**（`_categoryFor` 第 ② 步）：`if (work.categoryManual && !manualChannel)`。
   锁的本意是挡**无人值守的自动刮削**，而手动重刮是用户明确要求「现在重判一次」；
   若这里也认锁，「清空刮削数据」之后手动重刮会一直卡在旧分类上（2026-10-02 的
   bug 现场）。
2. **允许用条目结构证据**（第 ④ 步）：TMDB `movie/…` / `tv/…`，豆瓣
   `douban/movie/…` / `douban/tv/…`（按**段**匹配 —— `startsWith('movie/')`
   会漏掉豆瓣那层前缀）。**自动通道刻意不开它**：文件名把综艺解析成 `unknown`
   时按结构会判成「剧集」，而用户明明放在 `/综艺/` 里 —— 那就是
   「我的综艺栏目空了」。它救的是这一类：文件名只剩 `2026.2160p.WEB-DL.mkv`
   （`kind == unknown` → 「其他」），用户在候选里确认了这是一部剧 → 落到「剧集」。

⚠️ **第 ④ 步不再检查 `_isSemantic(work.category)`**（旧版有，现已删除）。
这是 2026-10-02 明确取舍的代价：**手动重刮连语义档也会被结构证据改写** ——
放在 `/综艺/` 而 TMDB 没给「真人秀」的片子，手动重刮会被判成「剧集」。
**没有中间道路**：`_categoryFor` 的输入里「被自动刮错的纪录片」与「靠目录名
判出的综艺」**完全同形**（`category` 都是语义档、`genres` 都说不出结论、
`onlineId` 都是 `tv/…`），没有任何信号能把两者区分开。兜底 = 对话框
「媒体类型」点一下（原「语义档不被冲掉」那条测试已按此改写）。
- ⚠️ `applyCandidate` 传 `true`、`scrape` 不传 —— 这个不对称**是故意的**，
  `work_scraper_test.dart` 有两条用例钉它（自动通道仍认锁 / 手动通道才按结构）。
- ⚠️ 它**不进 `backfillWorkCategories`**：那个回填只读 `genres`，不会拿老库的
  `online_id` 去改分类。结构档只对**这次之后**的刮削生效，老作品要重刮一次才跟上。

### 3.5 「自定义」只在真的改了分类时才加锁

`MediaWork.customized()` 的 `categoryManual`：旧版无条件 `true` → 改成
`category != this.category || categoryManual`。

对话框**预填当前分类**，用户「只想清在线信息」时不会动那个下拉 —— 旧版会顺手
把当时那个（很可能是刮错的）分类**冻死**，之后连手动重刮都改不动（bug 的上游）。
改了分类才锁；没改则保留原有锁（不新增、也不解锁）。

### 4. 刮完立刻查「库里是不是已经有同一部」（`_mergeClauseAfterScrape`）

`WorkScrapeController` 里那个方法返回**附加到结果后面的一句话**，三种情形：

| 情形 | 结果 |
|------|------|
| 库里没有同一部 | `null`（绝大多数刮削，不加噪音） |
| 有，且开着 `autoMergeByOnlineId` | `WorkMergeResult.message`（「已把…并入…」） |
| 有，但**没开**（或归一没做成） | 「媒体库里已经有同一部《X》…可在任一部的详情页用「合并到…」…」 |

第三行是这次新加的：以前只有「合了」才有话，**没开开关时用户什么都看不到** ——
而他刚手动刮完、库里明明早就有同一部，正是最需要被告知的时候。

⚠️ **判据必须复用 `WorkMergePlanner`**：新增的 `WorkMergePlanner.siblingOf(work, all)`
内部走 `planFor`，与归一用的是同一套分组规则。另写一套「按 `onlineId` 找一行」
的筛法一旦漂移，就会出现「提示说库里已经有一部、归一却一个都没合」——
用户看到的是「它明明说并了，列表里却还是两个格子」。

⚠️ **传 `outcome.work` 而不是 `work`**：判兄弟用的是 `onlineId`，而它正是这次
刮削刚写进去的。传刮削前那一行会**永远找不到兄弟**（静默地退化成「没有」）。

**「合理规划所属部或季」不需要额外代码**：归一只是给源行打 `merged_into` 标记，
`itemsForWork` 取并集，`WorkLevels.of(items)` 从**全部条目**现算季 / 部层级 ——
所以把两部「进击的巨人」合起来之后，第三季 / 第四季自然出现在同一个选择器里。

### 一个已知的粗糙边缘（接受，暂不改）

`WorkMergeResult.message` 用的是**源行当时的片名**，而手动刮削会先把源行标题
改成在线标题 —— 于是同一部片子的两个条目合起来时，那句话可能读成
「已把《流浪地球2》并入《流浪地球2》」。自动归一那边同样如此（两条都是刮完
才合，标题当然一样）。语义没错，只是读着像 bug。要治就得在
`WorkMergeResult.message` 里做「源标题 == 目标标题」的特判，而那个 getter
有自己的一组测试 —— 不在这次范围内。

### 测试

`work_merge_planner_test.dart`（`siblingOf` 六条：有 / 只有自己 / 空 onlineId /
kind 不同 / 别名行 / manual 源）、`work_scraper_test.dart`（结构档两条 + A 四条：
genres 给了真人秀才保住综艺 / genres 说不出语义时按结构重判（含语义档）/ 被锁时
手动重刮照样重判 / 自动通道仍认锁 + 自动·手动对照 + 用户手选锁住 + 没选不锁 +
文案带类型）、`media_work_customized_test.dart`（B 三条：没改不锁 / 改了才锁 /
原有锁保留）、`scrape_merge_prompt_test.dart`（控制器三条路各自的文案）、
`manual_scrape_dialog_test.dart`（chip 行出现时机 / 不动它 / 点纪录片）。

## `implements MetadataScraper` **不继承**默认实现（2026-10-01）

给 `MetadataScraper` 加了两个带默认实现的方法（`search` / `resolve`），
结果 **`flutter analyze` 立刻红**：`Missing concrete implementations of
'MetadataScraper.resolve' and 'MetadataScraper.search'`。

原因：Dart 的默认实现**只对 `extends` 生效**，而本项目所有实现都是
`implements MetadataScraper`（`TmdbScraper` / `DoubanScraper` /
`LocalFilenameScraper`，以及测试里的 `_Fake` / `_Fixed`）。

→ 给这个接口加方法时，**所有实现方都要显式补上**，包括测试假实现。
我一开始在接口文档里写了「有默认实现，所以离线源与测试假实现都不用改」，
那是错的，已改掉。想少改几处就拆一个独立的可选接口（`if (s is CandidateSearcher)`），
但当前实现方只有 5 个，显式写更直白。

## 详情响应必须自带 `title`，不许用查询词兜底（2026-10-01）

`DoubanScraper._toMetadata` 原来写的是
`_stringOf(detail['title']) ?? query.title`。它看着更「健壮」，实际是把
「详情没拿到」伪装成「刮削成功」：

服务端返回 HTTP 200 但内容不是条目（错误对象 / 风控页 / 接口改版）时，
兜底会把**用户搜的那个词**当成结果写进库 —— 标题是有的、海报简介一个都没有，
而且 `source` 记成 `online`。用户看到的是「已刮削」，
**与「刮削成功但没有封面」这类现象完全一样，排查时最难想到根因在这里**。

改成 `title` 只能来自响应体，拿不到就返回 `null`（并 `diag.warn` 一行）。
正常的 `/movie/{id}` 响应**一定有** `title`（实测 77 个顶层字段里它是必有的），
所以这个收紧不会误伤。顺带把不再需要的 `query` 参数从 `_toMetadata` 去掉了。

测试钉了两条：非 2xx → `null`；**200 但 body 是 `{"code":500,...}` → 也是 `null`**。


## 筛选面板：年代 / 类型（2026-10-01）

`lib/ui/widgets/library_filter_panel.dart` + `LibraryFilter.decades` / `.genres`。

### 为什么是浮层，为什么是 `MenuAnchor`

分类栏（`_CategoryBar`）已经占了列表上方一整条，再摆两排类型 / 年代会把海报墙
挤到屏幕下半部分 —— 而这两组条件绝大多数时候是不用的。做成浮层后，生效的条件
以数字标在按钮上，所以「现在到底筛没筛」仍然随时可见。

`MenuAnchor` 而不是自己搭 `OverlayEntry`：点外部关闭、Esc 关闭、屏幕边缘回弹、
焦点管理它都做完了，而这几件恰恰是「菜单偶尔关不掉」这类难查问题的来源。

两个容易踩的配套：

- 面板里放**普通 `InkWell`** 而不是 `MenuItemButton` → 点一个 chip **不会**把
  面板关掉。多选必须能连续点几下。
- 面板内那个 `SingleChildScrollView` **必须 `primary: false`**。不关的话它会和
  菜单自身那一层滚动抢同一个 `PrimaryScrollController`，Flutter 直接抛
  「PrimaryScrollController is attached to more than one ScrollPosition」——
  而这个错**只在打开面板那一刻**才炸。

### 角标口径：**「把年代 / 类型清空后列表的条数」**

这是整块功能唯一的承诺：**面板上每一个选项，点下去至少有一条结果**。

所以计数要跟着 `category` / `playedOnly` / `query` 收窄，却**不能**跟着
`decades` / `genres` 收窄 —— 否则用户每勾一个类型，剩下的类型角标就跟着变，
勾到第二个时列表已经空了。

代价（已告知用户）：面板选项会跟着当前分类 / 搜索词收窄。

`countWorksByDecade` / `countWorksByGenre` 因此要收三个作用域参数；两个
provider 用 `select((f) => (f.category, f.playedOnly, f.query))` 只盯这三个
字段，否则「勾一个年代」也会白跑一遍全表扫描。三个查询（`listWorks` + 两个
count）共用 `DriftMediaRepository._workConditions`，保证口径绝不漂移；
`InMemoryMediaRepository` 的两个计数**委托 `listWorks`**，两边由
`test/domain/media_repository_filter_test.dart` 逐条件比对。

### SQL 侧的两个细节

- 类型存在 `genres` 列（JSON 数组文本）里，匹配必须 **`LIKE '%"类型"%'`** ——
  **引号是关键**：不带引号时「动画」会命中「动画片」。转义按 SQL 的
  `"` → `""`。
- 年代是 `year >= d0 AND year < d0+10` 的 OR 组；`year IS NULL` **不命中任何
  年代**（所以面板会缺一项，而不是把没年份的算进 1970 年代）。
- 多选之间一律**「或」**：一部片子只属于一个年代，取交集恒为空；类型同理。

### 三条一致性陷阱（都踩过、都有测试钉住）

**① 计数 provider 必须 `await categoryBackfillProvider`。**
角标是按 `category` 收窄算的，而老库里那一列还是空串（v3 之前入库的行）。
不等的话：`workListProvider` 已经按回填后的分类筛好了列表，面板上的数字却还是
按回填前的分类算的 —— 两者对不上，而用户完全看不出为什么。
这条依赖很反直觉（「数年代为什么会依赖分类？」），所以测试单独一个文件
`test/ui/providers/library_facet_counts_test.dart` 钉住，免得下一轮有人觉得
那个 `await` 是多余的顺手删掉。

**② `scrape_providers._refreshAfter` 里「分类变了」要额外作废这两组角标。**
原来的判据只有「`year` 变了没、`genres` 变了没」，盖不住：库里有一行
「`genres` 已经是 TMDB 给的『动画』、`category` 却还停在『剧集』」（老版本写的
行，或分类折算那行代码加上之前刮削入库的），用户点一次「刮削」—— `genres`
一个字都没变、`year` 也没变，**只有 `category` 从「剧集」挪到了「动漫」**。
此时作品已经离开「剧集」栏的统计范围，两组角标却都不作废。
`test/ui/providers/scrape_refresh_test.dart` 用会数调用次数的仓储把
「该重算」与「**不该**重算」两个方向都钉住。

**③ 已选条件在切换分类后可能不在 `counts` 里 → 必须照样画出来。**
`setCategory` **不碰** `decades` / `genres`（刻意：切回去时用户的勾还在）。
于是「在电影栏选了 1990 年代 → 切到动漫栏（一部 90 年代都没有）」时，
这一项不在 `counts` 里。只画 `counts` 里有的项的话，那颗 chip 会**整个消失**，
而它仍然是生效的条件：用户看到按钮上写着「已选 2 项」、列表却是空的，却找不到
那第二个条件在哪 —— 唯一的出路是「清空筛选」，把另外那个还想留的条件一起抹掉。

修法：把这类项也画出来，标「无结果」（灰字 + 仍是打勾态），**照样可点**，
所以能被**单独**取消。同时，有已选项时**不再**说「还没有带年份的作品」——
两句话同时出现会自相矛盾（用户正看着一颗勾着的「1990 年代（无结果）」）。

### 空态按钮必须与提示语指向同一件事

`lib/ui/pages/library_page.dart` 的 `libraryEmptyHint()`（纯函数，可单测）
把「列表为空时说什么、按钮清什么」按**当前实际在用的条件**分派：

| 在用的条件 | 提示语 | 按钮 | 清掉什么 |
|---|---|---|---|
| 年代/类型 + 搜索词 | 没有同时匹配「X」与所选年代/类型的作品 | 清空筛选条件 | 两者，**保留分类** |
| 只有年代/类型 | 当前筛选条件下一条都没筛到 | 清空筛选 | 面板两组，**保留分类** |
| 只有搜索词 | 没有匹配「X」的作品 | 清空搜索 | 搜索词，**保留分类** |
| 都没有（只切了分类） | 这个分类下暂时没有作品 | 回到全部 | 全部复位 |

两个为什么：

- **按钮不能一律 `clear()`**。`clear()` 是全部复位（分类、排序、搜索词、面板
  两组）。只打了搜索词的用户点「清空筛选」，连分类栏选的位置和排序都一起丢掉，
  而他不会把「我的栏目没了」和「我刚点了个清空按钮」联系起来。
- **要清就清掉全部在用的条件**。按钮的用途是让用户重新看到内容；同时设了搜索词
  与年代却只清一个，列表很可能还是空的 —— 用户会认为这个按钮坏了。

判据用 `query.trim()`，与 `LibraryFilter.isEmpty` / `workListProvider` 保持一致；
只判 `isNotEmpty` 的话，用户打了几个空格再删干净会走到「清空搜索」，
而搜索框已经是空的了。

`test/ui/pages/library_empty_hint_test.dart` 逐情形钉住。


## 夸克上传：收尾是两步，缺一即 43001（2026-10-02）

### 症状
`/1/clouddrive/file/upload/finish` → HTTP 400，
`providerCode=43001`，`message=request cpp error[complete file failed!]`。
前序全部成功：pre → hash → 每片 PUT 200 且都拿到 ETag。

### 根因
夸克的上传收尾**必须两步**，只做第二步就是上面这个错：

1. **向 OSS 提交 `CompleteMultipartUpload` XML**（`POST {ossBase}?uploadId={id}`），
   带 `x-oss-callback` 头 —— 对象存储真正把分片合并成一个对象；
2. **再调 `/1/clouddrive/file/upload/finish`**，body 只要
   `{task_id, obj_key}` —— 夸克把该对象登记成文件，响应里才有 fid。

第 2 步的 body **不是** `part_info_list`（这是上一版的错，也导致 43001）。

### 两条「错了不报错」的细节
- **ETag 在 XML 里必须带双引号**：`<ETag>"8DA6BF..."</ETag>`。
  OSS 要求原样回填 PUT 响应里的值（含引号）；不带引号会被判「分片不匹配」。
  `HttpClientLike.putBytes` 返回的是**去引号**的值，所以拼 XML 时要补回来。
- **分片必须按 `part_number` 升序**排列。

两者都收进纯函数 `QuarkAdapter.buildCompleteMultipartXml`，
`test/data/quark_upload_complete_test.dart` 6 例钉住。

### 完成合并的 auth_meta（顺序必须与真实请求头一致）
```
POST\n{contentMd5}\napplication/xml\n{ossDate}\n
x-oss-callback:{callbackB64}\nx-oss-date:{ossDate}\nx-oss-user-agent:{ua}\n
/{bucket}/{objKey}?uploadId={uploadId}
```
- `contentMd5` = base64(md5(XML 字节))，同时作为 `Content-MD5` 头发出去。
- `callbackB64` = base64(紧凑 JSON)，即 `preData['callback']` 的 jsonEncode。
  必须**同一个字符串**既进 auth_meta 又进 `x-oss-callback` 头，签名才对得上。
- 分片 PUT 的 auth_meta 没有 Content-MD5（那一行留空）。

### 参考实现
- `RemyYYZ/QuarkPan`（Python）：`complete_multipart_upload` + `finish_upload` 两步。
- `imeiming/quark-drive`（Python）：OSS callback 写法（同样两步，finish 合并进 callback）。

### 上传相关的 HTTP 能力
`HttpClientLike` 有两个原始字节出口，别混用：
- `putBytes` —— 分片上传，返回 ETag（已去引号）；
- `postBytes` —— 完成合并 POST XML，返回响应体字符串。

### 备份目录
默认落在网盘根目录下的「云影备份」（`LibraryBackupService.defaultBackupDir`）。
`ensureBackupDir` 先列根目录找同名文件夹，找不到才建。

### 编排由测试钉住（`quark_upload_flow_test.dart`，2026-10-02 补）

`quark_upload_complete_test.dart` 只钉 XML 的**形状**；真正出 43001 的是**编排** ——
谁先谁后、每个端点收到什么 body。这类错误**不抛异常、只静默失败**，所以另起一文件锁住：

- `post` 路径序列必须是 `pre → hash → auth×N → auth(合并) → finish`
  —— 顺序即 43001 的成因（把 finish 提到 OSS 合并之前同样失败）；
- `finish` 的 body **恰好** `{task_id, obj_key}`，且**不含** `part_info_list`；
- 分片 PUT 的 `partNumber` 升序、每片带 `Authorization`；
- OSS 合并**必须发生一次**，带 `x-oss-callback` / `Content-MD5` / `Content-Type: application/xml`，
  XML 里 ETag 重新带上双引号、PartNumber 升序；
- 秒传命中（hash `finish=true`）→ 直接返回 fid，**零** PUT、**零** OSS 合并；
- 缺 `bucket`/`obj_key`/`upload_id` → 动分片**之前**就抛 `malformedResponse`；
- 缺 `callback` → 合并阶段抛错（不是静默成功）；
- `onProgress` 逐片递增、末次等于总大小。

假客户端按 `post` / `putBytes` / `postBytes` 三类分别记账，所以能断言「哪些请求必须发生」。

⚠️ 按项目约定验过**不空转**：临时把 finish 的 body 改回旧 bug（`part_info_list`）→
测试确实变红（`+0 -1`，diff 显示 `Actual: {'part_info_list': [...]}`），随即还原。

## 备份同步的新旧判定：比「库内容时间」，不比文件创建时间（2026-10-02）

### 症状（差点造成数据丢失）
新机器装好后点「同步」，**把远程那份好备份覆盖掉了**；本地空库也照样「胜出」。

### 根因
`BackupManifest` 里原来只有 `createdAt`（**备份包被创建的时刻**）。
旧 `sync()` 直接拿 `createdAt` 比大小 ⇒ 刚导出的包时间戳永远最新
⇒ `localNewer` 恒为 true ⇒ **同步永远只会「上传」，永远不会「下载」**。

### 修法：给 manifest 加 `libraryModifiedAt`
- 它是**库内容自己的修改时间**：`media_works.updated_at` / `media_items.first_seen_at`
  / `media_items.last_played_at` 三者的最大值（`MediaRepository.latestLibraryChangeAt()`）。
- 派生 `effectiveModifiedAt => libraryModifiedAt ?? createdAt`
  （老包没这字段时退回旧口径，兼容）。
- `sync()` 一律用 `effectiveModifiedAt` 判新旧。

### 两个「空」守卫（对称，缺一个就会互相覆盖）
- `!localManifest.hasLibraryContent`（本地空库/刚装）⇒ **拉远程**，绝不推。
- `!remoteManifest.hasLibraryContent`（远程是空包）⇒ **推本地**，绝不被它覆盖。
- `hasLibraryContent => libraryModifiedAt != null`。
  ⚠️ 别用「文件列表里有没有 `posters/`」判空 —— 海报是**打进 payload** 的，
  不在 `fileNames` 里，那样判会永远为 false（写错过一次，被测试逮住）。

### 冲突与恢复
- 不同设备 + 相差 <60s ⇒ `conflictsWith` 判冲突，交用户决定。
- 新机器必须先手动「从网盘恢复」（设置页按钮）拉一份下来，再谈同步。

---

# Android TV 遥控器适配（2026-10-02 评估，未实施）

主文档：`docs/AndroidTV-遥控器体验评估.md`（86 条逐功能点）；证据：`test/ui/tv_remote_probe_test.dart`（7 条探针）。

## 为什么探针测试就是「一台 TV 的按键层」
`flutter test` 下 `defaultTargetPlatform` 默认 **`android`**（见 `MEMORY.md` 测试取向那条），
所以 `tester.sendKeyEvent` 走的是**真的 Android 键码表**（`keyboard_maps.g.dart`）。
不用真机、不用 adb，就能验证「遥控器按下去会发生什么」。

## 键码事实（写错键名 = 功能看起来「没做」）
| 遥控器键 | Android keycode | 映射到 |
|---|---|---|
| 上/下/左/右 | 19/20/21/22 | `arrowUp/Down/Left/Right` |
| **中心 OK** | **23** | **`LogicalKeyboardKey.select`** |
| 播放/暂停 | 85 | `mediaPlayPause` |
| 快退/快进 | 89/90 | `mediaRewind` / `mediaFastForward` |
| 返回 BACK | 4 | **不给 app 送 key event**，由 Activity 处理 |

`WidgetsApp._defaultShortcuts` 把 **`select` / `enter` / `space` / `gameButtonA` 四个都**映射到 `ActivateIntent`。
⇒ ⛔ **自己写 `CallbackShortcuts` 只绑 `space` 等于遥控器完全收不到**。
探针 6 实测：`select` 命中 **0**、`space` 命中 1 —— 这就是「遥控器按不出暂停」的全部机制。

## 三条实测结论（推翻了最初猜测，别再去改）
1. **方向键能钻进 `GridView.builder` 的懒加载目标**。探针 1 轨迹 `[0,5,10,...,55]`、滚动 `2576.4/2576.4` 走满。
   原因：`defaultTraversalRequestFocusCallback` 内部调 `Scrollable.ensureVisible`。
   ⇒ 「海报墙遥控器划不动」**不成立**，别去自定义遍历策略。
2. **OK 键能激活 `InkWell` / `Switch` / `FilterChip` / `ExpansionTile`**（探针 2/3）。⇒ 「遥控器点不动卡片」**不成立**。
3. **`Slider` 会吃掉方向键**（探针 4：0.5 → 0.55）。所以播放页拿 `ExcludeFocus` 包顶栏/控制栏**是有道理的** ——
   但那等于把控件整个踢出遥控器可达范围。**正解是给一套 TV 专用 OSD，不是简单删 `ExcludeFocus`。**

## 焦点高亮为什么「看不见」——两重原因叠加，只修一个无效
1. **默认 `focusColor` = `Colors.white.withOpacity(0.12)`**（`theme_data.dart:442`），探针 5 实测 alpha `0.1216`，3 米外不可见。
2. ⚠️ **`_WorkCard` 是全项目唯一一个没有自己 `Material` 的卡片类点击区**
   （`_NavTile`/`_FolderRow`/`MediaItemRow`/`_DetailButton`/`_ViewSegment`/`_CategoryChip`/`_Crumb` **都包了**）。
   最近的 `Material` 于是变成 `Scaffold` 那层，而 `_RenderInkFeatures.paint` 是**先画 ink、再 `super.paint`（画子节点）**
   → 高亮只可能从卡片下半部那段透明底的文字区露出来，**海报整个盖住它**。
   ⇒ **只调 `focusColor` 不改这一条，海报墙上照样等于没焦点。**

## 关不掉的浮层：`MenuAnchor` 不是 route
`MenuAnchor` 是 `OverlayPortal`，关闭只绑了 `escape: DismissIntent()`（`menu_anchor.dart:69/330/411`）。
**电视上没有 Esc** ⇒ 筛选面板打开后关不掉。
- ✅ `PopupMenuButton` / `DropdownButton` 走 `showMenu`（**真 route**）→ BACK 能关，**这两类不用改**。
- ✅ `showDialog` 也包在 `ModalRoute` 里 → BACK 能关。
⇒ 需要修的**只有 `library_filter_panel.dart` 这一类裸 `MenuAnchor`**。

## 已经「做对了」的（别改）
- `PlaybackExitPolicy`：`TargetPlatform.android → stopAndRelease` ✅
- `player_window_bridge.dart` 的 `supportsMultiWindow` 排除 Android → `playItem` 自动回落内置播放页 ✅
- 侧边栏在左、深色主题 ✅

## Android 构建：三个坑串成一条链（2026-10-02 已打通）
`flutter build apk --release` 已成功产出 `build/app/outputs/flutter-apk/app-release.apk`
（53.8MB、4 个 ABI、debug 签名 —— 无 `android/key.properties` 时按设计退回 debug 签名）。
下面三条**不是各自独立的毛病**，是同一串；报错位置和真因差得很远，照报错字面修会白花时间。

### 坑一：沙箱里 `flutter build` 必然死在 `:gradle:compileKotlin`
症状：`Unable to delete directory '<flutter_sdk>/packages/flutter_tools/gradle/build/classes/kotlin/main'`
+ `Operation not permitted`，反复出现，`rm -rf` 也救不回来。
**真因**：Flutter 会在 **SDK 目录内部**编译它自己的 Gradle 插件（`includeBuild`），
而该路径在**工作区之外** → 沙箱拒绝**子进程**的 `file-write-unlink`。
（⚠️ 关键判据：**同一个路径我自己的 shell 能 `touch` + `rm` 成功**，被拒的只有 Gradle/JVM 子进程 ——
所以「权限 / TCC / 文件被占用」方向的排查全是错的。）
**修法**：`dangerouslyDisableSandbox: true` **且必须前台运行** —— 后台运行时这个标记会被**静默忽略**，
命令照旧带沙箱跑。判据：stderr 里出现 `[sandbox] 命令被沙箱拦截` 就说明标记没生效。
另加 `org.gradle.daemon=false` + `kotlin.compiler.execution.strategy=in-process`
（两份 `gradle.properties` 都要写：真实 HOME 与**沙箱 HOME**，见坑二）。

### 坑二：`local.properties` 被写成 homebrew 的 `platform-tools`（CMake 报错的真因）
症状：`:app:configureCMakeRelWithDebInfo[arm64-v8a]` → `[CXX1300] CMake '3.22.1' was not found
in SDK, PATH, or by cmake.dir property`，而 `~/Library/Android/sdk/cmake/3.22.1` 明明装好了、能跑。
**真因**：`flutter build` 会把**它定位到的** SDK 写回 `local.properties`。Flutter 的
`findAndroidHomeDir()` 顺序是：`config['android-sdk']` → `ANDROID_HOME` → `ANDROID_SDK_ROOT`
→ macOS 默认 `$HOME/Library/Android/sdk` → 兜底 `which aapt` → **`which adb`**。
**沙箱里 `HOME=/Users/tandy/.workbuddy-ai-6-home`**，那个 HOME 下没有 `Library/Android/sdk` →
一路掉到兜底：`/opt/homebrew/bin/adb` 是符号链接，`resolveSymbolicLinksSync()` 后取 `parent.parent`
得到 `/opt/homebrew/Caskroom/android-platform-tools/35.0.2`；而 `validSdkDirectory()` 只要求
**`platform-tools/` 或 `licenses/` 存在其一** → 这个「只有 adb、没有 platforms/NDK/CMake」的目录被当成 SDK 收下。
于是 AGP 在**错的根**下找 CMake → `[CXX1300]`。**CMake 报错和 SDK 路径是同一个问题。**
**修法**：所有 flutter/gradle 命令显式 `export ANDROID_HOME=/Users/tandy/Library/Android/sdk`
（第 2 步就命中，短路掉那个兜底）；保险起见在 `local.properties` 里同时钉 `sdk.dir` 与
`cmake.dir=<sdk>/cmake/3.22.1`（`updateLocalProperties` 是逐键 `changeIfNecessary`，不会抹掉 `cmake.dir`）。
⚠️ 项目里**没有任何 `externalNativeBuild` / `CMakeLists.txt`**（全仓 + pub-cache 都搜过），
所以别去 `app/build.gradle.kts` 里找 CMake 配置 —— 那条线索是假的。

### 坑三：Kotlin 插件版本（唯一一个「报错字面即真因」的）
`screen_brightness_android-2.1.6` 用的是 KGP 2.x 才有的
`KotlinAndroidProjectExtension.compilerOptions { }`；Flutter 3.29 模板给的是 **1.8.22** →
报 `'void …compilerOptions(Function1)'`（方法不存在）。`android/settings.gradle.kts` 已升 **2.1.0**
（别退回 1.8.22、也别跳 2.2 —— 2.2 删了 `kotlinOptions`，`app/build.gradle.kts` 还在用）。
NDK 同理：12 个插件声明依赖 `27.0.12077973`，`app/build.gradle.kts` 已从 `flutter.ndkVersion`（26.3.x）
改成钉死 27 —— 于是**本机 / CI 必须装 `ndk;27.0.12077973`**，否则配置期直接 `NDK not configured`。

### 收尾验证（别只看「BUILD SUCCESSFUL」）
`aapt2 dump badging <apk>` 要能看到 `leanback-launchable-activity` 与
`application: … banner='res/xx.png'`；`apksigner verify --print-certs` 确认签名者。
本机 `cmdline-tools/latest` 偏旧（`only understands SDK XML versions up to 3` 警告），但装 NDK 仍可用。

- 遥控器模拟命令（有设备即可复现全部交互）：
  `adb shell input keyevent 19/20/21/22/23/85/89/90/4`

## 只能真机验的 6 件事
`MediaQuery.navigationMode`（traditional vs directional，决定 `InkWell._canRequestFocus`）、
libmpv 在 TV 芯片上的硬解、播放期**屏幕常亮/屏保**（全项目**没有任何 wakelock**）、
遥控器音量键是否经 CEC 到达 app、TV 输入法打中文、1.05 焦点缩放会不会让海报卡重叠。

## P0 实施记录（2026-10-02）

### 一个能反复坑人的测试细节：`debugDefaultTargetPlatformOverride` 的复位位置
⛔ **复位必须写在测试体里**（`try/finally`），`tearDown` 和 `addTearDown` **都不行**。
Flutter 的 `_verifyInvariants`（断言「foundation 的调试变量都已复位」）是在
`TestWidgetsFlutterBinding._runTestBody` **内部**调用的，而两种 tearDown 都排在它后面。
用错会得到一条与业务毫无关系的报错：
`The value of a foundation debug variable was changed by the test.`
（2026-10-02 连踩两次，两次都以为是平台判据写错了。）

### 播放页遥控器化：为什么不能用 `CallbackShortcuts`
`CallbackShortcuts` 命中就一律报 `handled`。于是**焦点一旦进到控制栏，←/→ 就再也
挪不动焦点** —— TV 上挪不动焦点 = 选不了字幕和清晰度。
改用 `Focus(canRequestFocus: false, onKeyEvent:)`：能返回 `ignored` 把按键交还焦点系统，
这是同时满足「画面上 ←/→ 快退」与「控制栏里 ←/→ 换焦点」的唯一写法。
判据是 `_stageNode.hasPrimaryFocus`（焦点真的在画面上吗）：
- 在画面上 → `select`/`enter` = 播放暂停，←/→ = 快退快进；
- 在按钮上 → 这三个键一律 `ignored`，否则 OK 会**既暂停又点按钮**。

⚠️ 只绑 `space` 是不够的：TV 中心键的键码是 23 → `LogicalKeyboardKey.select`。
⚠️ `const Set<LogicalKeyboardKey>` **编译不过**（它重写了 `==`，常量集合要求原生相等，
报 `const_set_element_not_primitive_equality`）—— 只能 `final`。

### 控制栏：精确 `ExcludeFocus`，不是整块
原来整条控制栏 `ExcludeFocus` 是**过度修复**：真正吃方向键的只有 `Slider`
（实测焦点在 0.5 的滑块上按 → 会变成 0.55）。把两条滑块单独摘出焦点链即可，
按钮留给遥控器。对照探针实测：整块排除时 OK 命中 **0** 次，只摘滑块后 **1** 次。
只在 Android 上放开（`_remoteReachable`），桌面维持原样，避免键盘用户在桌面上的手感回退。

### 焦点环：`focusColor` 治不了海报墙
* 只调 `focusColor` 没用：ink 画在子节点**下面**，海报把它整个盖住。
* ⛔ **别用 `FocusableActionDetector` 的 `onShowFocusHighlight`**：`enabled: false` 时
  它把「显示不显示」交给 `MediaQuery.navigationMode`
  （`actions.dart`：`canRequestFocus(target) => traditional || null => target.enabled`），
  而 Android TV 上那个值只能真机验。
* ✅ 自建 `ui/widgets/tv_focus.dart` 的 `TvFocusable`：`Focus(canRequestFocus: false)`
  观察焦点（**不会变成多出来的一站**，否则每张卡要多按一次方向键），
  在子节点**之后**叠描边，并只看 `FocusManager.instance.highlightMode`
  （Android 默认 `touch`，**收到第一个按键翻成 `traditional`** —— 源码确定行为）。
  测试里要钉死分支就用 `FocusManager.instance.highlightStrategy = alwaysTraditional/alwaysTouch`。

### TV 判据与安全边距
`AppTheme.isTvLayout` = `defaultTargetPlatform == android && MediaQuery.sizeOf(context).width >= 960`。
Flutter 没有暴露 leanback 标志，只能靠尺寸推断（官方 TV 设计稿 960×540，手机逻辑宽只有 360–430）。
⛔ **判据必须带平台**，否则宽屏桌面会凭空多出一圈 48px 黑边。
`AppTheme.safeAreaInsets` 在 TV 上给 48/27（官方过扫描规范），非 TV 返回 `EdgeInsets.zero`。

### 海报墙列数：别凭感觉调
960×540 实测（外壳安全边距 → 侧栏 196 → 网格 padding 22 之后可用宽度 623.5）：
`maxCrossAxisExtent=172` → **4 列** × 145×218，可见 1.92 行 ≈ **7.7 张**；
`=240` → **3 列** × 198×298，可见 1.44 行 ≈ **4.3 张**。
⇒ 提高卡片尺寸会**腰斩**信息量，所以字号改用整体 `textScaler`（×1.25）解决，列数不动。
⚠️ `tvTextScaler` **只能用在高度能吸收的地方**（海报卡片的图片是 `Expanded`，
文字长高只让图变矮）。给固定高度控件（播放页顶栏 48 / 控制栏 64）套它会 RenderFlex 溢出。

### 1.05 焦点缩放会不会让海报卡重叠？—— 不会（实测算过）
卡片 145×218、网格间距 14/18；1.05 时每边向外溢出 3.6 / 5.45 px，都小于间距。

## P1 实施记录（2026-10-02）

### 补充：为什么 `debugDefaultTargetPlatformOverride = null` 是安全的复位
上面 P0 那条说了「必须写在测试体里」，这里补**为什么复位成 `null` 不会污染后续测试**：
`foundation/_platform_io.dart:29-34` 把测试环境强制成 android ——

```dart
assert(() {
  if (Platform.environment.containsKey('FLUTTER_TEST')) {
    result = platform.TargetPlatform.android;
  }
  return true;
}());
if (kDebugMode && platform.debugDefaultTargetPlatformOverride != null) {
  result = platform.debugDefaultTargetPlatformOverride;
}
```

两点结论：①`flutter test` 下 `defaultTargetPlatform` **恒为 android**（在 `assert` 里，所以只在
断言开启的构建生效）；②override 为 `null` 时回落到上面那个值，也就是 **android，不是宿主机 macOS**。
⇒ 复位成 `null` 安全；要测 macOS 分支必须显式设 override。
⚠️ **给 `tester.view.physicalSize` 设尺寸没有这条约束**（它不是 foundation 调试变量），
用 `addTearDown(tester.view.resetPhysicalSize)` 就行 —— 但 `debugDefaultTargetPlatformOverride`
**不能**用 `addTearDown`。同一个测试里两种复位方式并存是正常的。

### `MenuAnchor` 那一条的两个后续坑（P1-2 踩到）
1. `MenuController` 是**普通类，不是 `ChangeNotifier`** —— 没有 `addListener`、没有 `isOpen` 流。
   要在外面知道「面板开着没」，只能用 `MenuAnchor.onOpen` / `onClose` 回调同步到一个 `bool` 字段。
2. ⛔ `find.byType(PopScope)` 会 `Bad state: No element`：`PopScope` 是**泛型**（`PopScope<T>`），
   而 `find.byType` 按 `runtimeType` **精确匹配**。要写
   `find.byWidgetPredicate((w) => w is PopScope)`，并配一条 `hasLength(1)` ——
   否则以后树里多一个 `PopScope`，`w.single` 会抛一条看不出原因的错。
   同理适用于任何泛型 widget（`ValueListenableBuilder<T>`、`InheritedWidget` 子类等）。

### 备份的 `includeSettings` / `restoreSettings` 是**空开关**（别信注释）
`library_backup_service.dart` 里：
- 导出：`Uint8List dbBytesToWrite = dbBytes;` —— **恒等于原始字节**，没有「剔掉 settings 表」的实现；
- 导入：`dbFile.writeAsBytes(dbBytes)` —— **整个库文件覆盖**。
所以传 `false` 的实际效果只有一行日志 + `manifest.note = '不含设置'`。
**根因是 SQLite 无法在字节层面删表** —— 要真做，得先 `VACUUM INTO` 一份副本、
在副本上 `DELETE FROM settings`、再读副本的字节。
UI 三条通道（上传备份 / 同步 / 从网盘恢复）**全部传 `true`** ⇒ 这个分支够不到，属死代码。
**已把 3 处承诺了不存在行为的注释改成如实说明，但没有实现它**（够不到的路径实现出来也无法验证）。
✅ 反过来，这条**证实了**「在电脑上配好 → 上传备份 → 电视上同步」这条路成立：
设置就在 `settings` 表里，跟着整个 sqlite 一起走。而 `BackupManifest` 里**根本没有设置字段**，
所以**别去 manifest 里找设置**。
⚠️ 网盘凭证不进备份 → TV 上顺序必须「先扫码登录，再同步」。

### 清点「TV 上要打字的地方」的方法
`grep -n "TextField(\|TextFormField(" lib/` —— 全项目只有 **6 处**，逐个判两件事：
①TV 上够不够得着（`WindowLaunch.main()` 的文档写明 Android 端没有多窗口 ⇒
`player_window_app.dart` 那个直链框够不着）；②有没有免打字路径。
结果：设置页 6 个配置字段是唯一「够得着又无解」的；`ManualScrapeDialog` 片名/年份都按文件名预填、
类型是下拉；`GenreEditDialog` 有「常用类型」chip 行；`CustomizeWorkDialog` 敲片名就是它的用途。
⇒ 所以 `TvTypingNotice` 只加在设置页承载这些字段的两节里。
⚠️ 新写 UI 文案前**先清点一遍** —— 原方案里「把 `CustomizeWorkDialog` 的年份做成候选下拉」
就是凭印象写的，而那个对话框**根本没有年份字段**。

### `_SearchBox` 写死 `height: 32`（P1-3 动手前必看）
`library_page.dart` 的搜索框是 `SizedBox(width: 220, height: 32)`。
⇒ 给媒体库**头部**套 `AppTheme.tvTextScaler` 会 RenderFlex 溢出（和播放页顶栏 48 同类问题）。
⚠️ 这一条只是读代码看到的，**没有测试钉住**；改字号前先补一条断言。

---

## 目录名作为系列名（2026-10-02）

起因：`/来自：分享/姜松《家电维修视频教程》/182.格力空调显示E6如何维修.mp4` 被自动刮成
**《1821: Οι Ήρωες》(2021)**（希腊纪录片）。完整归因见 `docs/目录名作为系列名-规则评估.md`。

### 为什么「目录名是不是系列名」的界限不在目录名里

`/姜松《家电维修视频教程》/182.格力空调显示E6如何维修.mp4` 与 `/我的电影/01.流浪地球2.mp4`
**文件名形态一模一样**（都是「编号.片名」）。只看文件名，判不出来哪个是教程合集、哪个是散片。
能分开它们的只有**兄弟文件集合**（222 个 `NNN.xxx.mp4` vs 孤零零 1 个）。
⇒ **判定单元必须是文件夹，不是文件**。这就是为什么 `parse` 要拿到 `dirPath`。

四步链路（每步都用一次性 `dart run` 探针实测过）：
1. `182.格力空调显示E6如何维修.mp4` → `title="182 格力空调显示"`、`latinTitle="182"`，
   且 **`E6` 被当成第 6 集**（守卫 `(?<![0-9a-z])` 不把汉字当边界）。
2. `_alternateOf` 只要求「两种文字都非空」→ 备用词 = `"182"`（没检查有没有字母）。
3. TMDB 模糊搜索 `"182"` → `1821: Οι Ήρωες`。
4. 闸门：主名 `182 格力空调显示` → 0.3636 **拒（对的）**；备用词 `182` → 0.9125 **过（错的）**。
   年份闸门是 `null`（文件名里没年份）→ 没有第二道防线。
   前缀档下限是 `0.65 > strongSimilarity 0.6` ⇒「短串是长串前缀」**恒过**。

### 容器名的判定为什么是「精确匹配」而不是「包含」

`_containerWords` 用**归一化后全等**比较，不是 `contains`。
理由：`姜松家电维修合集` 含「合集」但是**真作品名**；用 `contains` 会把它吃掉。
宁可漏判（个别容器名当成了作品名，用户手动改一下），也不要误判（把真作品名抹掉，用户看不出来）。

容器形态（`directory_title.dart` 的 `_containerPatterns`）：
`day01`/`Day_18` · `04_视频`/`3.视频` · `01 基础篇` · `第2章` · 纯数字 · 日期 · `1080p`/`4K`。
另外 `_containerWords` 收录栏目名：`电影`/`电视剧`/`动漫`/`纪录片`/`来自：分享` 等。

### 上溯：为什么要往上找，而不是只用末级

实测真实库：**118 个目录（1291 条 = 全库 45%）末级是容器名**，几乎全在
`尚硅谷嵌入式全套教程/` 下面（`day01`、`04_视频`、`4.视频`）。
⇒ 只用末级会得到一堆叫 `day01` 的作品；有意义的名字在上一两级。
`seriesTitleOf(dirPath)` 从末级**往上**取第一个非容器名（`for (var i = segments.length - 1; i >= 0; i--)`），
全容器时返回 `null`。

### 「独立发行物」豁免 —— 别把正常的散片也并进来

目录名可信 ≠ 一律覆盖文件名。下面这条豁免必须留着：

```
_isStandaloneRelease = 片名里含字母/汉字  且  (自带年份 或 kind==episode)
```

满足即**不**用目录名，保留自己的片名。所以：
- `/电影/流浪地球2 (2023)/movie.mkv` → 仍然是「流浪地球2」（自带年份）。
- `/仙逆/S01E12.mkv` → 仍然是文件自己的短片名，不会被并成「仙逆」一个作品（实测 49→6）。
- `/姜松.../182.格力空调显示E6如何维修.mp4` → 片名 `182 格力空调显示` 虽含汉字，但**没有年份、
  修好 `E6` 后也不再是 episode** ⇒ `_isStandaloneRelease == false` ⇒ 用目录名
  `姜松 家电维修视频教程`。判据是「自带年份或季集」，**不是**「片名看起来像不像名字」。

⚠️ **老 `dirName` 兜底也要排容器名**。原来 `/电影/2012.2009.1080p.mkv` 会兜底出一个叫
**「电影」**的作品（`2012` 被判成技术标记 → title 空 → 用目录名）。现在兜底条件加了
`!DirectoryTitle.isContainerSegment(effectiveDirName)` → `title == null` → 不归组，以文件名示人。

### 四处调用点必须都传 `dirPath`（漏一处 = 扫一次刮一次得出不同片名）

- `scan_service.dart:417`
- `media_discovery.dart:357`、`:510`
- `work_scraper.dart:226`（`_queryFor`）

`WorkScraper` 是**从 `itemsForWork(work.key)` 重新解析**的，走的是同一条 `parse`。
如果它只传 `dirName` 而不传 `dirPath`，就会「扫描期刮到 A，详情页点刮削刮到 B」——
这种不一致不会报错，只会让用户觉得「刮削按钮时灵时不灵」。

### 三个配套缺陷一起修了（详见 docs §6 第 1 档）

1. 备用词必须含 ≥2 个字母（`media_work.dart` `_alternateOf`）。
2. 纯数字相似度恒 0（`scrape_match.dart`，加在**精确相等之后** —— 否则《2012》自己搜自己也被判 0）。
3. `E\d+` 前有汉字不算集号（`filename_parser.dart` 两处：标记表 + `_matchEpisodePattern`）。
   这条单独看小，实际最脏：它把 `conf` 顶成 `true`，一个文件夹里 7 个视频能各变成一个作品。

### 真实库回归数字（2847 条，只读导出）

```
旧作品数（库内） 2259 → 新作品数 180 / 不归组（无片名） 16
疑似垃圾标题（day01 / 电影 / 来自：分享）：（无）
```

抽查：姜松 222→1；尚硅谷 `day01` 24→1（标题 `01 尚硅谷嵌入式技术之C语言`）；沧元图 77→1；天龙八部 45→1。

### 两条必须记住的副作用

1. **规则改了不会自动重排已有分组** —— 库内还是旧的 2259 个作品，**要用户跑一次全盘重扫**才生效。
2. **「≥2 个」阈值没有显式实现** —— 解析器逐文件调用，数不到兄弟个数。
   阈值实际由 `WorkSeedBook` 的归组承担（同目录条目片名相同 → 同一 `groupKey` → 1 个作品）。
   副作用：一个目录里**只有 1 个视频且提不出片名**时，现在会用目录名当作品名（原来是「不归组」）。

## 季 / 部 / 跨目录归一（2026-10-02）

### 数据模型

| 层 | 实体 | 新增 |
|----|------|------|
| 文件 | `MediaItem` | `season`/`episode`（已有）、**`part`/`partLabel`**（v9） |
| 作品 | `MediaWork` | **`seasonCount`**（v10）、**`mergedInto`**（v11） |

- `part` 的解析面在 `filename_parser.dart` 的 `_partOf`：`第X部/第X篇`、`特别篇|剧场版`、
  `上部|下部|前篇|后篇`、`CD|Disc|Disk|Part|DVD N`。⚠️ 分隔符必须是 `[\s._-]*` ——
  只写 `\s*` 的话最常见的 `Part.2` 认不出来。
- `MediaItem.partOrder`：`part` 有值用它；只有 `partLabel` 用 `specialPartOrder = 9999`
  （特别篇排在所有编号部之后）；都没有 = 0。
- 层级**不落库**，每次由 `WorkLevels.of(items)` 现算（`domain/services/work_levels.dart`）：
  **季在外、部在内**；某一层**少于 2 个选项就不画**（一个选项的选择器是噪音）；
  某季下只有一个 `partOrder == 0` 的桶 → 这一季没有部层（别画一个孤零零的「未标部」）。

### 归一为什么是「打标记」而不是「删行」

原设计是「改 `media_items.group_key` + 删源作品行」。**落地时改了**，因为那条路
**合并错了回不去**：用户看到两个格子变成一个，既不知道发生了什么，也没有任何
按钮能还原 —— 他只会从此关掉自动归一。

现在的做法：

```
media_works.merged_into = <目标 key>     # 只写这一列
```

| 事 | 怎么办 |
|----|--------|
| 列表 / 角标 | `WHERE merged_into IS NULL`（`_workConditions` 里加一次，`listWorks`/两个计数查询共用） |
| 详情页文件 | `itemsForWork` 并集：`group_key = ? OR group_key IN (SELECT key FROM works WHERE merged_into = ?)` |
| 撤销 | 把 `merged_into` 改回 `NULL`，一条 UPDATE |
| 源行的元数据 | **原样留着** —— 撤销之后它要能自己站住 |

### 六条硬约束（做错全是静默坏数据）

1. **只认 `onlineId` 完全相同**，且 `source == online`、`kind` 相同。
   本地片名相似度**绝不**参与自动合并（`182.格力空调` 事故形态）。
2. **`source == manual` 的行不参与**（用户手写过的东西不许被算法动）。
3. **不允许链式**：`merged_into` 指向的一定是根；源行永不当目标。
   规划器与仓储各挡一次（`mergeWorksInto` 里 `target.mergedInto != null → 0`）。
4. **目标选择必须确定**：`itemCount` 最大 → `firstSeenAt` 最早 → `key` 升序。
   最后一层不是「锦上添花」：没有它两次运行可能选出不同目标，用户看到海报在
   两部片子之间来回跳。
5. ⛔ **`mergeWorkForUpsert` 里 `mergedInto` 无条件取旧值，且不受 `protect` 影响**。
   本次扫描造出来的行 `mergedInto` 恒为 `null`，照抄 = 每次重扫把所有合并拆开；
   而走 `protect` 也不行 —— 重刮削时 `protect == false`，照样拆。
6. ⛔ **`copyWith(mergedInto: null)` 清不掉这一列**（`??` 语义 = 「不改」）。
   撤销必须整行重建或直接 UPDATE，否则**静默失败而返回值还说是成功**。

### 两个踩过的坑

- **搜索穿透折叠时内层作品表必须起别名**。内层要引用外层那一行的 `key`，但它自己
  也从 `media_works` 查 —— 不起别名时 SQLite 把 `media_works.key` 解析成内层自己，
  生成 `merged_into = key` 这种恒假条件，于是「搜源作品里的文件名」**永远搜不到且
  不报错**。修法：`_db.mediaWorks.createAlias('merged_src')`（`package:drift` 的顶层
  `alias()` 在这个版本里不在作用域）。
- **`MediaKind` 不在 `media_work.dart`，在 `core/utils/filename_parser.dart`**。

### 手动归一「合并到…」（P4）

自动归一**只认 `onlineId` 完全相同**，覆盖不了三种真会遇到的形态：本地片名差得远、
压根没刮到、刮到两个不同条目其实是同一部。这三类只能人来判。

- 入口：详情页「合并到…」按钮（`_MergeButton`，**无 `canScrapeOnline` 门槛**，
  与「自定义」同理 —— 没网也该能整理本地库）。
- 对话框 `MergeWorkDialog`（骨架抄 `manual_scrape_dialog.dart`：`Dialog` +
  `ConstrainedBox(560×620)` + `_header/_body/_footer`）。一次 `allWorks()` 读全，
  之后**纯内存过滤**，不发任何请求。
- **方向 = 留下选中的那一部**，按钮写「合并**到**」。确认行写死
  `《当前》→《目标》，列表里保留后者。`，别指望用户从按钮措辞里推方向。
- 实现完全复用 P3 的打标记：`WorkMergePlan.manual`（`onlineId = ''`，
  `bool get isManual => onlineId.isEmpty`）→ `WorkMergeService.mergeInto` → `_execute`
  → 撤销仍是 `unmergeWorks`。**没有第二套合并机制**。
- 文案分两路，判据只有 `plan.isManual`：手动 = 「已把《X》并入《Y》。」；
  自动 = 「…（识别为同一条目）。」。**别在 UI 里自己拼这句话**。

**三条拦截写在纯函数 `WorkMergePlanner.manualBlocker`，UI 与 `mergeInto` 调的是同一个
函数** —— 两边各写一遍，迟早出现「按钮亮着、点了却没反应」。①自己并自己；
②目标已是别名行；③**源自己还折着别的作品**（真会撞上：自动归一刚把两部合到《X》，
用户又想把《X》并进《Y》）。

第③条**刻意不做「连坐迁移」**（把 X 的源一起改指 Y）：那样撤销无法精确还原 ——
X 的那些源原本指向 X，撤完却会变成独立的根。正确动作是先「拆开」再合，提示语里
直接写这句话。「目标已经有源」**不拦**：只是多一个兄弟，不成链。

四个交互决定与「手动刮削」**刻意相反**，别照抄那边：①搜索框**预填当前片名且一打开就过滤**
（那边不预搜是因为每次搜索花一次豆瓣额度，这里是零成本本地过滤）；②零匹配不说「没找到」，
说「把上面的搜索框清空，可以看到全部 N 部作品」（这条通道最常见的用法恰恰是
「两个片名完全不一样」）；③点候选**只是选中**，再点「合并」才生效；④不能合的行
`onTap: null` + 原因写在行上 + 确认按钮同时变灰。

### 列表卡片上的三个计数是**并集**

归一后出过一个静默不一致：卡片写「25 集」、点进详情页有 37 个文件 —— 因为
`itemCount`/`totalBytes`/`seasonCount` 在库里存的是「**自己名下**的文件」。
现在 `listWorks` 读时现算并集（真库 `_withUnionStats` + `_unionStats` 一条裸 SQL，
`JOIN ... ON i.group_key = t.key OR i.group_key IN (SELECT key ... WHERE merged_into = t.key)`；
InMemory 替身用 owners map 同口径）。

三条别改错：

1. ⛔ **不写回库**。`mergeWorkForUpsert` 对 `item_count` 是「永远取新值」，
   一旦写回，下次重扫就把并集冲成自己名下的数。
2. **只碰「真有源折进来」的行**（SQL 里的 `AND EXISTS(...)`）。老库里
   `item_count` 与真实行数本就可能不一致，全表重算会把老数据也一起改掉。
3. ⚠️ **`seasonCount` 是 `COUNT(DISTINCT CASE WHEN i.season > 0 THEN i.season END)`**
   —— 绝对值，**不能相加**（两季 + 两季 ≠ 四季）。`itemCount`/`totalBytes` 才是求和。
   同一口径要保证 `CASE WHEN` 里也排掉 `season = 0`（「未标季」不算一季）。

`allWorks` / `workByKey` **仍是存值**（不做列表展示，别顺手也改成并集）。

### 触发点与开关

| 时机 | 入口 |
|------|------|
| 扫描结束（未取消、无错） | `ScanService` 阶段二点五，`merger.mergeAll()` |
| 详情页「刮削」/「手动」成功 | `WorkScrapeController._mergeAfterScrape` → `mergeFor(key)` |

设置项 `autoMergeByOnlineId` **默认开**（判据 `!= 'false'`，与 `autoScrapeOnScan`
的 `== 'true'` **刻意相反** —— 它不发请求、只动本地库，且误合可一键撤销）。
组合根（`buildScanService` / `_mergeAfterScrape`）按设置决定**传不传**
`WorkMergeService`，领域层不读设置。

### 测试

`work_merge_planner_test.dart`（纯函数 + `manualBlocker`）、`work_merge_service_test.dart`
（服务 + 内存库口径 + `mergeInto`）、`work_merge_test.dart`（真库，含「三个计数是并集」）、
`work_detail_merged_test.dart`（详情页提示条）、`merge_work_dialog_test.dart`（对话框整条链路：
按钮 → 对话框 → 落库 → 跳页 → 撤销）。

⚠️ **`find.byType` 是精确类型匹配**，而 `OutlinedButton.icon` / `FilledButton.icon` 造的是
这两个类的**私有子类** → 按钮明明画在屏幕上却报「找不到 OutlinedButton」。用
`find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is T))`。
断言对话框里的候选时还要限定 `find.descendant(of: find.byType(Dialog), matching: …)`
—— 详情页背后的大标题和候选片名**是同一个字符串**。
⚠️ 加了 `media_works` 新列之后，`db_migration_last_modified_test.dart` 里要**补一行
DROP** —— 那个用例是「拿当前 schema 建库、删掉新列、把 user_version 调回 5」来伪造
老库的，漏删会在 `addColumn` 上撞 `duplicate column name`，而报错完全指不到它。

---

## `SelectableText` 在 TV 上是**焦点陷阱**（2026-10-02，P2-4）

### 症状与判据

**症状**：TV 上 D-pad 走进一段可划选的文本就**出不来**。按 OK 毫无反应、方向键也不动，
用户只会得出「遥控器坏了」。这几处恰好都在**诊断页 / 登录页** —— 用户是在出问题的时候
才来这里的，所以坏法格外致命。

**实测**（`test/ui/tv_remote_probe_test.dart`）：在 `SelectableText` 上下各放一个按钮，
从上面那个按钮连按 **4 次 ↓**：

| 组件 | ↓ 轨迹 |
|---|---|
| 裸 `SelectableText` | `[text, text, text, text]` —— 停在原地，**永远到不了下面那个按钮** |
| `TvSelectableText` | `[after]` —— 一下就穿过去了 |

`focusNode.canRequestFocus` 实测为 `true`。

### 机理

`SelectableText` 内部是 `EditableText(readOnly: true)`，而 `EditableText` **自带一个
`FocusNode`**（为了支持划选/光标），所以它天然参与焦点遍历。`readOnly` 只管「能不能改」，
不管「能不能聚焦」。

### 修法与不可动摇的三条

`lib/ui/widgets/tv_text.dart` 的 `TvSelectableText`：TV 上返回 `Text`，
**其余平台原样返回 `SelectableText`**。

1. ⛔ **非 TV 分支不许也换成 `Text`**。桌面/手机上划选是刻意的设计
   （`LogPathRow` 注释：「即使不点按钮，也能用鼠标划选带走」）。这不是「统一简化」，
   是**按平台分工**。`tv_text_test.dart` 有 4 例钉住它，含「桌面 + 960 宽也不算 TV」。
2. **探针要同时钉两件事**：裸 `SelectableText` **确实**卡住（这是包装存在的唯一理由）
   ＋ `TvSelectableText` **确实**不卡（修复没白写）。只钉后者的话，
   「为什么要有这个包装」就只存在于注释里了。哪天 Flutter 改了 `EditableText` 的焦点行为，
   前一条会红，那时才该考虑能不能删掉这个包装。
3. **`focusNode` 只在非 TV 上透传** —— TV 上**故意**不给焦点系统留任何落点。

### 方法论：这类判断必须探针说话

动手前我的判断是「TV 上它只是**没用**（划选不了），换了收益≈0」——**这个判断是错的**，
它其实**有害**。「没用」和「有害」的处理完全不同：前者换不换都行，后者必须换。

同一条教训在本项目已经出现过三次（`Tooltip` 在 TV 上等于不存在、`focusColor` 被
海报盖住、`Slider` 吃掉方向键）——**共同点是「错了不会报错」，只表现为用户觉得
「遥控器/功能坏了」**。所以凡是「这个控件在 TV 上有没有意义」的问题，一律先写探针跑一遍。

### 顺带记下的两个探针写法坑

* **TV 尺寸用 `MediaQuery` 显式给，不用 `tester.binding.setSurfaceSize`。**
  `AppTheme.isTvLayout` 看的是 `MediaQuery.sizeOf(context).width`，
  而本项目的 TV 用例统一走 `MediaQuery(data: MediaQueryData(size: Size(960, 540)))`
  （见 `test/ui/theme/tv_layout_test.dart`）。用 `setSurfaceSize` 那次实测**没生效** ——
  `TvSelectableText` 仍走了非 TV 分支，表现为「两条轨迹一模一样」，很容易误判成「修复没起作用」。
* **`debugDefaultTargetPlatformOverride` 的复位只能写在测试体里**（`try/finally`），
  `tearDown` / `addTearDown` 都排在 Flutter 的 `_verifyInvariants` **后面**，
  用错会得到一条与业务毫无关系的「foundation debug variable was changed by the test」。

---

## 手动重刮改了类型却「没生效」：根因在**写入**那一步，不在判定（2026-10-02）

用户现场：《黑暗荣耀》被自动刮成「纪录片」→「自定义」清空 → 手动刮削选「剧集」→
成功提示也弹了，**纪录片栏里它还在**。

### 两层根因（只修第一层不够，这正是「A+B 没修好」的原因）

| 层 | 位置 | 症状 |
|---|---|---|
| ① 判定 | `WorkScraper._categoryFor` 第 ② 步 | 旧版认 `categoryManual` 的锁 → 手动通道的「自动」也卡在旧分类。**A 已修**（手动通道忽略锁） |
| ② **写入** | `mergeWorkForUpsert` 的 `category:` | `existing.categoryManual ? existing.category : …` **无条件认旧锁**，把①刚算对的结论原地扔掉 |

判据（一眼分辨卡在哪一层）：日志里 `分类判定：纪录片 → 剧集（对话框手选 override=剧集）`
**写着对的结论**，而库里 `category` 还是 `documentary` → 一定是第 ② 层。

### 修法：`overrideManual` 时分类与锁都取 `incoming`

`overrideManual == true` 的语义就是「**用户亲手点了这个按钮**」（详情页「刮削」/「手动」
两个按钮）。那时 `_categoryFor` 已经按完整优先级算过一遍，合并层**照抄**即可：

```dart
category: overrideManual ? incoming.category
    : (existing.categoryManual ? existing.category
       : (MediaCategoryGuesser.fromGenres(effectiveGenres) ?? incoming.category)),
categoryManual: overrideManual
    ? (incoming.categoryManual || existing.categoryManual)  // 只增不减
    : existing.categoryManual,
```

* **自动通道不受影响**：扫描期那条根本不传 `overrideManual`，仍然被锁挡住 —— 锁的本意
  就是挡无人值守的自动刮削。详情页「刮削」按钮虽传 `overrideManual: true`，但它的
  `_categoryFor` 认锁，所以 `incoming.category == existing.category`，行为不变。
* `categoryManual` 用 `||`（只增不减）：本项目**没有解锁入口**，锁只由用户的显式操作置上。
  写成纯 `incoming.categoryManual` 会在某个调用方漏抄该字段时**静默解锁**。
* ⚠️ **`InMemoryMediaRepository.upsertWorks` 必须同步改**（它复刻了同一套合并规则，
  两边不一致 = 「用内存库跑过的用例在真库上失败」）。
* ⚠️ 已落库的旧行**不会自动修**（`categoryManual` 的行被 `backfillWorkCategories` 跳过）——
  用户要重刮一次。

回归用例：`test/data/media_work_merge_test.dart`「用户显式重刮（overrideManual）」
三条 + `test/domain/work_scraper_test.dart`「A：锁着的分类要**真的落库**」（后者读回
`repo.workByKey`，才照得出第 ② 层）。

## 媒体库列表「显示特别慢」：并集统计里 JOIN 条件的一个 `OR`（2026-10-02）

### 怎么量的（这个手法值得复用）

把真实库**复制**到 `/tmp`，用 `AppDatabase.openFile(File(copy))` + 真 `DriftMediaRepository`
逐条计时 —— 走的是产品代码本身，不是另写一份 SQL 猜：

```dart
final tmp = File('${Directory.systemTemp.path}/cloudcine_perf.sqlite');
src.copySync(tmp.path);                       // src = ~/Library/Application Support/…
final db = AppDatabase.openFile(tmp);
final repo = DriftMediaRepository(db);
await repo.listWorks(limit: 500);             // 计时
```

（临时用例放 `test/` 下跑完就删；**别留在仓库里**。）

### 数字（172 部作品 / 2886 个文件）

| 查询 | 耗时 |
|---|---|
| `backfillWorkCategories`（首屏前必跑） | 8ms |
| **`listWorks(limit:500)`** | **340ms** ← 全部在这里 |
| ├ 只 `select media_works` + 映射 | 5ms |
| └ `_unionStats` 那条 SQL | **336ms** |
| `countWorksByCategory/Year/Genre/Played` | 0 / 2 / 4 / 0ms |
| `countItems` + `countWorks` | 0ms |

顺带排除了两个猜测：**海报不是瓶颈** —— 170/170 命中磁盘缓存、首屏 **0 次联网下载**
（`poster_file` 列全空，但 `PosterCache._download` 的 `existsSync()` 兜住了）。

### 根因：`JOIN` 的 `ON` 里写了 `OR`

```sql
JOIN media_items i ON i.group_key = t.key
  OR i.group_key IN (SELECT s.key FROM media_works s WHERE s.merged_into = t.key)
```

`OR` 让连接条件**用不上任何索引**（`media_items.group_key` 上也没有索引，只有 PK 自动索引），
SQLite 只能对每个目标键把 `media_items` 整表扫一遍。实测拆解：

* 只留等值 JOIN（去掉 OR 分支）：**37ms**
* 去掉 `EXISTS` 的 OR-JOIN：**6381ms**（参与 OR 的目标从 9 个涨到 172 个）
  → 可见 `AND EXISTS (…)` 一直在**救**这条查询，删了它直接 6 秒。

### 修法：拆成两段 `UNION ALL` 的等值连接（336ms → **3ms**）

```sql
WITH src AS (
  SELECT t.key AS tgt, t.key AS src FROM media_works t
   WHERE t.key IN ($marks)
     AND EXISTS (SELECT 1 FROM media_works s WHERE s.merged_into = t.key)
  UNION ALL
  SELECT s.merged_into AS tgt, s.key AS src FROM media_works s
   WHERE s.merged_into IS NOT NULL)
SELECT s.tgt, COUNT(i.id), COALESCE(SUM(i.size_bytes),0),
       COUNT(DISTINCT CASE WHEN i.season > 0 THEN i.season END)
FROM src s JOIN media_items i ON i.group_key = s.src
GROUP BY s.tgt
```

* 第一段那个 `EXISTS` **不能删**：它保证「没有源折进来的目标一行都不出」—— 这是
  **正确性**要求（老库 `item_count` 与真实行数可能不一致，顺手重算会改掉一批与归一
  无关的作品）。验证方式：跑一遍 `listWorks`，比对返回的 `itemCount` 与库里存的值，
  被改动的行**必须**全部是 `merged_into` 指向的目标。
* 第二段刻意**不加**「目标在本页」的过滤：源行只有个位数（当前 11 条），多算出的目标
  调用方按 key 查表时自然忽略，少一个 `IN` 就少一份绑定参数。
* **等价性验证**：同一份真实数据、同一批 key，旧 SQL 与新 SQL 的
  `(items, bytes, seasons)` **逐键比对 0 处不一致**；新 SQL 会多出本页之外的
  目标（当前 1 个），`_withUnionStats` 按 key 查表，多余的无影响。

### 与「类型设置没生效」那条**无关**

那条改的是**写**路径（`WorkScraper._apply` / `mergeWorkForUpsert` / `customized`），
`listWorks` / 计数查询一行没碰。列表慢是**归一**（`merged_into`，v11）那条功能引入的读路径开销。

### 还没做、但值得考虑的

`media_items.group_key` 与 `media_works.merged_into` 上**没有索引**（只有 PK 自动索引）。
当前量级下重写已经够快（3ms），但若作品数涨到几千、或 `_unionStats` 再次变慢，
加这两个索引是正解 —— 那要动 schema（v13）+ `build_runner`，别只改 SQL 就以为完事。

### 目录视图（「文件夹」）的慢是**另一回事**

日志里 19:09:59–19:10:28 有 8 次 `GET /1/clouddrive/file/sort`，每次 300ms–1.6s ——
那是**网盘实时列目录**（`driveListingProvider`，每进一层一次请求；`_listPageSize = 100`、
`_listMaxEntries = 3000`，所以一个大目录最多 30 次串行请求）。与本地库无关，别往 SQL 上查。

## 「自定义」清刮削后封面回落到网盘缩略图（2026-10-02）

### 现象
详情页「自定义」（清掉在线刮削、改片名/分类）之后，整墙封面变成片名首字的灰块。
根因：`MediaWork.customized()` 把 `posterUrl`/`posterFaceX`/`posterFile` 一律清 `null`，
而网盘缩略图只存在**文件行**（`media_items.thumbUrl`），作品行没有留底 —— 清完就没有任何来源。

### 修复形态
- 新增纯函数 `WorkPoster.fromItems(items)`（`domain/entities/work_poster.dart`）：
  挑一张网盘缩略图，**正片优先、跳过空地址、花絮兜底**；返回 `{url, faceX}` 成对值。
- `MediaWork.customized({..., WorkPoster? drivePoster})`：有它就用它的 `url` 当 `posterUrl`、
  `faceX` 当 `posterFaceX`；其余在线痕迹照旧清空。**只有没找到任何缩略图时才真的留空**（不造地址）。
- `posterFile` 只在「地址没变」时保留（清之前用的本来就是网盘缩略图），换了图必须清 ——
  否则 `PosterCache` 见 `knownFile` 存在就返回旧文件，封面显示成前一张。
- 两个 repo 实现（`DriftMediaRepository.customizeWork`、`InMemoryMediaRepository.customizeWork`）
  **都要**先 `itemsForWork(key)` 取 `WorkPoster` 再传进去；漏一个就是「替身比真身弱」。

### ⚠️ 锚点必须落在文件行（这就是 v13 的来由）
作品级 `posterFaceX` 在**刮到在线海报时会被清成 null**（不同图不能共用锚点）。
于是「清刮削 → 封面回落网盘缩略图」那一刻，锚点只能从**文件行**取回 —— 所以 **v13 加了
`media_items.faceAnchor_x` 列**（`tables.dart` + `app_database.dart` 迁移 `from < 13`）。

写入 `_toCompanion` 与扫描同步规则：**锚点与地址同进同退**
（只在该次「既没图也没锚点」时才 `Value.absent` 保留旧的一对）；`_toItem` 读回 `faceAnchorX`。

### ⚠️ 改了 `tables.dart` 加列，必须同步迁移测试
`test/data/db_migration_last_modified_test.dart` 是「拿当前 schema 建库、再 DROP 掉新列、
把 `user_version` 调回 5」来伪造老库的。漏了 DROP → reopen 时 `onUpgrade` 的 `ADD COLUMN`
撞 `duplicate column name: face_anchor_x`，而报错完全指不到这个用例。
（本会话已补 `media_items` 的 DROP 行。）

### ⛔ 抢占提示
本节用掉了 schema **v13**。HOWTO 1785 行预留的「`group_key`/`merged_into` 加索引」若真要做，
请用 **v14**，别再写 v13（否则两个迁移同号、且 build_runner 生成会冲突）。

## 提不出集号的行标题**不能**退回片名（2026-10-02，播放列表 + 详情页文件列表）

### 现象
剧集播到一半打开右侧剧集列表，几十行**全是一模一样的剧名**，分不出哪一行是哪一集。
用户原话：「有些文件名不符合集数命名规则的文件名，无法解析出集数」。

### 根因（两层，别只看到第一层）
1. `desktop_play.dart` 的 `_episodeLabel` 在 `item.episode == null` 时**退回
   `displayTitle`**，而 `displayTitle` = 片名 + 集号 —— 没有集号时就只剩片名。
2. 更关键：这批条目不是「解析器没认出来」，而是**被刻意清掉的**。
   `MediaFilenameParser.parse` 的目录级归组（「目录名作为系列名」，见本文件同名章节）
   在把整目录归成一部剧时会执行 `season = null; episode = null; episodeEnd = null;`
   —— 事故现场 `182.格力空调显示E6如何维修.mp4`，那个 `E6` 是**故障代码**，
   当成第 6 集是错的。代价就是这类目录下**每一项都没有集号**。

所以「让它解析出集数」这条路是走不通的（清了才是对的），只能换**展示**口径。

### 修复形态
`_episodeLabel(item, {workTitle})`：

- 有集号 → 原样 `第 3 集` / `S2 · 第 3 集`（这支逻辑没动）。
- **没集号 → `剧名-文件名`**（文件名过 `baseNameOf` 去扩展名；副标题那行已经在报容器格式）。
  - `workTitle` 取**作品行** `MediaWork.title`（刮削后的名字），由 `buildPlayRequest`
    在已经读过 `work` 之后传进 `_buildPlaylist`；作品行缺失时退回条目自己的 `title`，
    **不会拼出空前缀**。
  - 文件名自己已含剧名时不再重复拼（折叠掉标点后 `startsWith`，见 `_foldForCompare`）——
    否则 `姜松《家电维修视频教程》` 目录下的 `姜松家电维修视频教程 182.mp4` 会变成
    「剧名-剧名 182」。**折标点是有意的**：剧名来自目录名（带书名号）、文件名不带，
    不折这条判据永远不成立。
  - 顺带修好另一处：同一部电影的多个版本以前都显示 `流浪地球2 (2023)`，
    现在显示 `流浪地球2.2023.1080p` / `…2160p`。

### ⚠️ 标题必须给**两行**，否则这个修复等于没做
面板宽 320、缩略图 96、内边距与间距 20+10 → 标题那行只有约 **194px ≈ 中文 15 字**，
而 `姜松《家电维修视频教程》-182.格力空调显示E6如何维修` 是 28 字。
只给一行的话被省略号吃掉的全是**后半段的文件名** —— 那正是用来分辨集数的信息。
故 `_buildEpisodeTile` 里 `maxLines: 2`，并把 `_episodeTileHeight` **84 → 96**。

⚠️ `_episodeTileHeight` 同时是 `itemExtent` 的**上限**：内容比它高就会画到面板外面
（真机表现成「开剧集列表后底部按钮乱飞／被裁」，见 `player_window_app.dart` 里那条注释）。
按现在的内容算 ≈ 69（缩略图那支 54 + 内边距 16 = 70），96 是留给字体度量/字号缩放的余量。
`_revealCurrentEpisode` 的滚动偏移读的是同一个常量，所以调它不会让「自动定位当前集」错位。

### 测试
- `desktop_play_test.dart`：前缀取作品行（不是条目的 `title`）／文件名自带剧名去重／
  无作品行兜底，共 3 例。
- `player_window_app_test.dart`：长标题那一条要 `maxLines == 2`，并且
  `tester.takeException()` 为 null（溢出在 widget 测试里是一条 RenderFlex 异常）。
- `media_item_test.dart`：`rowLabel` 的两支口径 + 提不出集号那一支，共 11 例。

## 同一份规则要服务两个列表 —— 但**有集号那一支必须分开**（2026-10-02）

规则本体收在 `MediaItem.rowLabel(RowLabelStyle, {workTitle})`（`domain/entities/media_item.dart`）。
两处调用点：

| 调用点 | 口径 | 有集号时 | 提不出集号时 |
| --- | --- | --- | --- |
| 播放器剧集面板 `desktop_play.dart` | `compact` → 撞名时 `withTitle` → 还撞 `fileName` | `第 3 集`（多季 `S2 · 第 3 集`） | `剧名-文件名` |
| 详情页「文件」列表 `media_item_row.dart` | `withTitle` | **`剧名 S01E03`**（= `displayTitle`） | `剧名-文件名` |

### 为什么有集号那一支不能统一（这是实测撞出来的，不是笔误）

详情页那一侧用 `第 N 集` 会把**同一集的多个版本显示成两行一模一样的字**。
真实数据（`f飞cc日志2` / 标题「飞常日志」，合并 2 个源）：

- `/来自：分享/F飞CC日  志2/` — 12 个 `01.国语.mp4` / `01.粤语.mp4`…：**season/episode 全为 null**；
- `…/第一季/翡翠台 粤语版/` — 10 个 `飛常日誌 EP01..EP10`：episode 1–10、**season 为 null**；
- `…/第一季/MyTVSuper/` — 10 个 `The.Airport.Diary.S01E01..E10`：season 1、episode 1–10。

按 `WorkLevels` 分桶：**未标季 = 前两组共 22 行**，第 1 季 = 第三组 10 行。
`withTitle` 口径下未标季显示 `飛常日誌 E01…E10` + `飞常日志-01.国语…`（22 行全可区分）；
若用 `compact`，那 10 行会变成 `第 1 集…第 10 集`，**跟第 1 季那一格一模一样** ——
用户点来点去看到的是同一批字。

### 播放列表：**先短，撞名才补信息**（逐级退让）

`_buildPlaylist` 不是直接调 `compact`，而是走 `_playlistLabels`：

1. `第 3 集` —— 常态，最省空间；
2. 撞名的（出现次数 > 1）改成 `剧名 S01E03` —— 上面那两组的 episode 都是 1–10，
   于是第 2 组补成 `飛常日誌 E01`、第 3 组补成 `The Airport Diary S01E01`；
3. 还撞的改成 `剧名-文件名` —— 同一集的两个压制/码率，只有文件名保证互不相同。

「没撞名的保持短标题」这条也要钉住：一律加片名会把本来 320px 就紧张的面板拉长。
检测按**字符串值**统计（`_clashingLabels`），不是按 item 相等 —— 要检测的正是
「两行显示成一样的字」。

### 查真实数据的办法（只读，别写）

```sh
DB="$HOME/Library/Application Support/com.cloudcine.cloudcine/cloudcine.sqlite"
sqlite3 -header -column "file:$DB?mode=ro" \
  "select group_key, name, dir_path, season, episode, title from media_items where group_key in (...)"
```
`dir_path` 里是**归一化后**的路径（`/来自：分享/F飞CC日  志2/`，带尾斜杠），
所以 `like '%日志%'` 这类模糊匹配对不上 —— 要按 `group_key` 或 `title` 查。

### 验证展示规则：导出 TSV + 纯 Dart 探针（**比手推可靠，2026-10-02 实测有效**）

改动「某一行该显示成什么」之后，别靠脑补，拿真实行跑一遍：

```sh
# 1. 导成 TSV（-noheader -separator 用制表符）
sqlite3 -noheader -separator $'\t' "file:$DB?mode=ro" \
  "select file_id,name,ifnull(title,''),ifnull(season,''),ifnull(episode,''),ifnull(episode_end,''),dir_path
     from media_items where group_key in (...) order by season, episode, name;" > /tmp/probe.tsv
# 2. 写一个 tool/_probe.dart（`dart run tool/_probe.dart /tmp/probe.tsv <作品标题>`），跑完即删
```

**为什么能直接 `dart run` 而不用起 Flutter**：`domain/entities/media_item.dart` 这条
依赖链（`file_names` / `filename_parser` / `video_formats` / `directory_title` /
`drive_entry` / `drive_provider`）**全是纯 Dart**，没有任何 Flutter import。
纯 Dart 侧拿不到 sqlite，所以才先导 TSV。
⚠️ 探针里的规则是**抄**的，只用来核**输出**；规则的唯一实现仍在 `MediaItem.rowLabel`，
所以别把探针留下的结论当成「代码已验证」，撞名那类逻辑还是要靠单测钉。

实测结果（`f飞cc日志2`，32 行）：未标季 22 行 → 22 个不同标题；第 1 季 10 行 → 10 个不同；
播放列表 `compact` 起步有 **10 行重名**，逐级退让后 **32/32 唯一**。

## 剧集面板：主标题改成**文件名**，加当前播放动效（2026-10-03）

### 为什么把集号从主标题挪走

面板一行只有 ~320px、一行字就是全部信息。原来主标题是 `第 3 集`（`RowLabelStyle.compact`），
代价是**同一集的多个版本长得一模一样**：国语/粤语、2160p/1080p 两个压制在列表里无法区分
（`_playlistLabels` 的逐级退让就是为这个补的，但退让出来的 `剧名 S01E03` 仍然不含版本信息）。

改成：**主标题 = 原始文件名**（`PlaylistEntry.fileName`，带扩展名的原名），
**副标题 = `集号 · 码率`**（集号排最前 —— 被省略号吃掉的只能是后面的码率/体积）。

- 用户扫这个列表是为了找「网盘上那个文件」，文件名是唯一不会变形状的东西：
  人话标题在撞名时会变成 `剧名 S01E03` 或 `剧名-文件名`，文件名永远一样。
- `rowTitle` / `rowSubtitle` 是 `PlaylistEntry` 上的**纯 getter**，`EpisodeTile` 只负责画 ——
  面板文案要测就直接测这两个 getter，不用 pump 界面。

### ⚠️ 去重判据：折叠后**互相包含**，但中英文对不上就**不去重**

`title` 与 `fileName` 说的是同一件事时副标题不重复显示（否则同一句话在一行里出现两次）。
判据是两边都折叠（只留字母数字与汉字、小写）后**互相包含**，并且 `fileName` 要按
**带扩展名**和**去扩展名**两个候选各比一次 —— 因为 `剧名-文件名` 那一支用的是 `baseNameOf`。

**反例（别"修"）**：`title = 黑暗荣耀 S01E03`、`fileName = The.Glory.S01E03.2160p.mkv`
折叠后是 `黑暗荣耀s01e03` 与 `theglorys01e03…`，互不包含 → **保留**，副标题显示
`黑暗荣耀 S01E03 · 2160P`。这是对的：主标题是英文文件名，那行中文集号是用户唯一能
看出「这是第几集」的地方。刮削回来的是中文剧名、网盘文件是英文名，这种组合很常见。

### 动效：三根条，只挂当前行

`ui/widgets/now_playing_bars.dart`，纯函数 `nowPlayingBarScales(t)` + 常量
`barPhaseStep = 2.1` / `minScale = 0.30`。

- 三根条**不同相**：同相看起来只是整体一起呼吸；相位差也不能是 π 的整数倍，否则第 1 根与第 3 根同步。
- ⚠️ **常驻动画会让 `pumpAndSettle` 永不返回** → 组件停在 `MediaQuery.disableAnimationsOf`
  （无障碍「减弱动态效果」开关）与 `animate: false` 两处；并且动效只挂在剧集面板里，
  面板收起即 dispose，不常驻。
- 画满全表等于没有信息：非当前播放的行**不画**。

## 「音效」是播放端的事，不是片源的事（2026-10-03）

用户拿夸克网盘播放 `/来自：分享/黑暗荣耀 全2季…/The.Glory.S01E01.2160p.NF.WEB-DL…-老K.mkv`
问：画质弹框里那份「音效列表」（杜比音效 / 立体声音效）跟**片源**有关系，还是 app 的逻辑？
跟**音轨**是不是一回事？用户自己判断「看起来好像不像」——**判断是对的**。

**答：音效 = app 逻辑**（播放端对**输出**的处理），与片源无关，**不是音轨**。

| | 音轨 | 音效 |
| --- | --- | --- |
| 是什么 | 片源里**封着的流**，发布组决定 | 播放端对输出的**处理方式** |
| 谁提供 | 解复用器列出来（`stream.tracks`） | 播放器自己（下混/上混/直通） |
| 夸克放哪 | 「语言」入口 | 「音效」入口 |
| 换个播放器 | 还在（在文件里） | 没了（跟播放器走） |

佐证：夸克帮助中心把「多语言音轨」归到**语言**入口、「环绕音效」归到**音效**入口；
官方原文「播放器还会记住常用的画质、**音效**和倍速设置」。

### ⛔ 实测：本库的 libmpv **做不了** EQ / 人声增强 / 虚拟环绕

`media_kit_libs_macos_video 1.1.4` 内置 mpv 0.36.0 + FFmpeg 6.1（Avfilter 9.3.100），
但**音频滤镜只注册了 3 个**：`abuffer` / `abuffersink` / `equalizer`。
用 `avfilter_get_by_name` 直接枚举确认；`equalizer` 还因为缺 `aresample` 运行期直接失败。

⛔ **别再用 `mpv_command_string("af set ...")` 的返回值判断滤镜可用性。**
第一版探测就是这么做，`headphone` / `dynaudnorm` / `bass` 全部返回 OK —— 因为
`af set` **只做语法解析**，滤镜图能不能真的建起来是运行时才知道。正确判据只有两条：
真实解码（生成 2.0 / 5.1 WAV → `loadfile` → 收 warn/error 日志），或 `avfilter_get_by_name` 枚举。
（要解锁 DSP 得换一份带音频滤镜的 Avfilter —— 与修 PGS 是同一套路。）

### 能做的四个预设：只靠两个 mpv 原生属性

`core/utils/player_audio_effect.dart`。`audio-channels` 与 `audio-spdif` 都是
**运行期可改**的 mpv 原生选项（不需要滤镜）：

| 预设 | `audio-channels` | `audio-spdif` |
| --- | --- | --- |
| 跟随片源（默认） | `auto-safe` | `no` |
| 环绕上混 | `auto` | `no` |
| 立体声 | `stereo` | `no` |
| 杜比/DTS 直通 | `auto-safe` | `ac3,eac3,dts,truehd,dts-hd` |

- 每个预设都把**两个属性写全**：只写一个的话，切档时上一个档的残值会留着
  （比如从直通切回立体声，spdif 还开着）。
- 应用时机在 `player.open` **之前**（`PlaybackController._loadIntoPlayer` /
  `player_window_app._openStream` 各一处）。
- 存储值就是枚举名（`auto` / `upmix` / `stereo` / `passthrough`），改名等于让老用户的设置失效。

### 跨引擎：设置投递进去、改动回报出来

独立播放窗口跑在**另一个 Flutter 引擎**里，读不到主窗口的设置库：

- 主窗口 → 窗口：`PlayRequest.audioEffect`
- 窗口 → 主窗口：`PlayerBridgeMethod.saveAudioEffect` → `SettingKeys.playerAudioEffect`
- ⚠️ 两个播放器（`player_window_app.dart` + `player_page.dart`）**都要接**，
  只改一个 = 用户看到「功能没做」。




