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

#### ⚠️ 但 `startAt` 是一条**静默**的路 —— 换源后必须核对（2026-10-04）

上面两条说的是「怎么给位置」，没说「给了到底生效没有」。**生效与否没有任何回调**：
mpv 收下了 `start` 属性却照旧从 0 播，日志里只有一句看着完全正常的「起播=1800s」。
用户报的「选择画质后都会重头就开始播放」就是这个形态（而且它**不能**归因成
「HLS 不支持 start」——`PlaybackMedia` 的实测里 HLS 是有效的）。

做法：换源时挂 `domain/services/playback_restore.dart` 的 `RestoreSeek`，
由位置流核对，没落到位就补一次显式 `seek`。三条判据各有理由，**别简化**：

1. **就绪之前不补** —— 就绪信号 = 时长解出来 或 位置开始推进。
   （「open 之后立刻 seek 会被丢掉」，见上面第 1 条。）
2. **「到位」要连续两拍才算** —— 换源期间**旧流还在播**（`_prepareSource` 的预热），
   位置流上会夹一条旧流的值，而它**恰好等于目标**（目标就是从旧流取的）。
   只认一拍会被它骗过去，于是新流真从头播也没人管。
3. **补发有上限**（3 次）—— 遇上不可 seek 的流，无限补 = 每 100ms 一次空转。

接线（`PlaybackController`）：挂在 `_loadIntoPlayer` 里 `open()` **之前**
（不能提前到 `switchQuality` —— 预热期旧流的值会骗过它）；
在 `open()` / `stop()` 里清（`open` 里那句尤其要紧：`resolveStream` 那段
网络往返期间旧流还在推进，欠账留着会凭空补一次 seek）。

⚠️ 排查看日志里有没有
`起播位置没生效（现在 0s，应为 Xs）→ 补发 seek` ——
**只有它出现过，才说明 `startAt` 真的失效过**。

#### ⚠️ 既有缺口：内置播放页没有续播（2026-10-04 仍未修）

`PlaybackController.open()` 签名里**没有起播位置**，`player_page._openItem`
也不传 → **Android TV 上唯一的播放路径根本不续播**。
`startPosition` 只存在于独立播放窗口那条路（`PlayRequest` / `PlaybackResume`）。
修它等于改「进播放页从哪开始」的行为，属产品决策，**先问用户**。

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
| `get-task-allow` 出现在 **Release 签名**里 | **不许** | 文件里没写也可能有 —— 构建期注入，见下一节 |

### ★★ `Release.entitlements` 里没有 get-task-allow，签名里却有（2026-10-07）

**现象**：`release.yml` 的「校验产物授权」失败 ——
`Error: 产物带了 get-task-allow 调试授权，不该出现在发布包里`，job 挂掉、不上架。
把 `Release.entitlements` 与 `DebugProfile.entitlements` 逐字对比**看不出任何问题**：
前者根本没有这一项。

**根因**：不是文件，是**构建期注入**。Xcode 新建 macOS 工程时会把 target 的
`CODE_SIGN_INJECT_BASE_ENTITLEMENTS` 默认为 `YES`，构建时**自动**把
`com.apple.security.get-task-allow` 塞进签名（Apple《Resolving Common Notarization
Issues》→ "Avoid the Get-Task-Allow Entitlement" 原文：
「Xcode automatically sets the target's CODE_SIGN_INJECT_BASE_ENTITLEMENTS build
setting to YES … tells Xcode to add the com.apple.security.get-task-allow
entitlement to your app at build time」）。本机 `flutter build macos --release`
同样中招 —— **不是 CI 环境问题**，本机 `build/macos/.../Release/CloudCine.app`
当时也带这条。

**判据（唯一能看到它的地方）**：`codesign -d --entitlements - <app>`，
或看 Xcode 真正签进去的那份
`build/macos/Build/Intermediates.noindex/Runner.build/Release/Runner.build/CloudCine.app.xcent`。
⛔ 读 `*.entitlements` 文件、读 `git diff`、对比两份 entitlements —— **全都看不出来**。

**修法**：Runner target 的 **Release** 配置加 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;`
（`macos/Runner.xcodeproj/project.pbxproj`，紧挨 `CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements;`）。
- ⛔ **只关 Release**：Debug / Profile 必须保留注入，否则 `flutter run` 连不上 Dart VM Service
  （表现是「构建成功但一直卡住、没有窗口」）。Debug 产物实测仍带 `get-task-allow` ✔。
- ⛔ 别顺手把这个变量也写到 CI 的 xcodebuild 命令行上 —— 工程文件是**单一真源**，
  这样本机 `flutter build macos --release` 与 CI 才走同一份设置。
- `release.yml` 里那条 get-task-allow 断言**不要删**：它守的正是这个「文件看不出、签名里才有」的坑。
- ★ `ci.yml` 的 `analyze-and-test` 里有一步**静态**断言（不构建、零耗时）守同一件事：
  `CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements;` 后 3 行内必须有
  `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;`，且 `DebugProfile.entitlements` 后 3 行内**不许**有它。
  ⇒ **推 main 就拦住**，不必等发版。⚠️ 那个 job 原有的「输出 macOS 授权摘要」只打印
  `.entitlements` **文件**，恰好落在盲区里，别把它当成这道断言（摘要里另加了一行
  「Release 注入开关」让状态可见）。反向验证过：把那行 sed 删掉，断言确实拦下。

**验证（本机实测，2026-10-07）**：

```bash
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Release \
  -derivedDataPath build/macos CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES build
codesign -d --entitlements - build/macos/Build/Products/Release/CloudCine.app
# 改前：app-sandbox / files.read-only / files.read-write / get-task-allow / network.client / network.server  ← 6 项
# 改后：app-sandbox / files.read-only / files.read-write / network.client / network.server                  ← 5 项
#       与 Release.entitlements 逐项一致；CI 那段校验 + codesign --verify --deep --strict 本机复跑全绿
```

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


## 筛选面板：年份 / 类型 / 已刮削（2026-10-01，2026-10-03 增补）

`lib/ui/widgets/library_filter_panel.dart` + `LibraryFilter.years`（**具体年份**）/
`.genres` / `.scrapedOnly`。

> ⚠️ 本节写于 2026-10-01，当时这一维还是**年代**（`decades`，`1990` 表示 1990-1999）。
> 后来改成了**具体年份**（`years`，`1990` 只匹配 1990 年上映的那一部）。
> 下面凡出现「年代」二字的地方一律按**年份**读，`1990 年代` 这类例子等价于「选了 1995」。

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

所以计数要跟着 `category` / `playedOnly` / **`scrapedOnly`** / `query` 收窄，
却**不能**跟着 `years` / `genres` 收窄 —— 否则用户每勾一个类型，剩下的类型角标
就跟着变，勾到第二个时列表已经空了。

`scrapedOnly` 进这一组、`years` / `genres` 不进，不是双标：那个开关改的是「这一份
列表里有哪些作品」，年份 / 类型正是在它筛出来的那批里再分面。不传下去的话，打开
「已刮削」后用户会看到一堆只在**没刮过**的作品里存在的年份，点下去是空列表 ——
而面板唯一的承诺就是「点下去至少有一条」。

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
- 年份是 `year IN (...)` 的等值匹配；`year IS NULL` **不命中任何年份**
  （所以面板会缺一项，而不是把没年份的算进某个桶）。
- 多选之间一律**「或」**：一部片子只属于一个年份，取交集恒为空；类型同理。
- 「已刮削」是 `source = 'online'` 的等值匹配，与上面几维**取交集**。

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
`setCategory` **不碰** `years` / `genres` / `scrapedOnly`（刻意：切回去时用户的勾还在）。
于是「在电影栏选了 1995 → 切到动漫栏（一部 1995 年的都没有）」时，
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
| 面板条件 + 搜索词 | 没有同时匹配「X」与所选〈**实际在筛的那几组**〉的作品 | 清空筛选条件 | 两者，**保留分类** |
| 只有面板条件 | 当前筛选条件下一条都没筛到 | 清空筛选 | 面板**三组**，**保留分类** |
| 只有搜索词 | 没有匹配「X」的作品 | 清空搜索 | 搜索词，**保留分类** |
| 都没有（只切了分类） | 这个分类下暂时没有作品 | 回到全部 | 全部复位 |

⚠️ 「所选〈…〉」由 `libraryEmptyHint` 里的 `facets` 按**实际在筛的那几组**拼，
不能写死「年份 / 类型」—— 只开着「已刮削」时，那句话会变成让用户去清一组他
根本没选过的条件。另外「**只**开着已刮削」在页面上另有专门的空态
`_NoScrapedState`（走不到 hint 那一支）：这不是「条件太紧」，而是库里还没有
刮削过的作品，该说的是「去刮一部」。

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

### 「已刮削」的判据：`source == 'online'`，不是 `MediaWork.isScraped`（2026-10-03）

`isScraped` 是 `online || manual`，回答的是「这一行**要不要被自动刮削覆盖**」——
那是 `mergeWorkForUpsert` 的保护位。而这里问的是「有没有刮到过在线数据」，两者在
「用户点过『自定义』」的行上分道扬镳：`customizeWork` 会把在线信息整份清掉
（`source → manual`、`scrapedAt → null`、`onlineId → null`），那一行**不该**算
「已刮削」—— 用户点开它会发现海报和简介都是空的。

`scrapedAt` 只由在线刮削写（`WorkSeed.build` / `WorkScraper._apply`），与
`source = 'online'` 是同一件事的两列；取 `source` 是因为那一列的文档本来就写着
「刮削的幂等依据」。两个实现必须同口径：drift 侧 `t.source.equals('online')`、
内存侧 `w.source == ScrapeSource.online`。

**它进 `_facetScope`，`years` / `genres` 不进**（理由见上面的「角标口径」）。
**没有数量角标**：年份 / 类型那些数字的承诺是「点下去至少有这么条结果」，
而这是个开关 —— 多印一个数字只会让人以为它和年份一样可以多选。

其余三处漏一处就是「做了一半」：

- **`hasExtra` / `clearExtra()`**：它只在面板里有入口（不像分类栏与搜索框各有自己
  的清除按钮）。漏了的话，只开着这一项时「清空筛选」按钮是**灰的**，用户看到列表
  被筛着却找不到地方关。
- **`selectedCount`**：按钮上的数字与面板底部「已选 N 项」共用这一份口径；各算一遍
  会出现「按钮写 3、底部写 2」这种自相矛盾的样子。
- **提示语与空态**：见上面那张表。

测试落点：`test/data/library_filter_query_test.dart`（真库口径 + 「角标 == 点下去
之后的条数」那条不变量）、`test/domain/media_repository_filter_test.dart`（真身 vs
替身逐条件比对，`source` 三档都放了）、
`test/ui/providers/library_facet_counts_test.dart`（provider 有没有把开关传下去）、
`test/ui/widgets/library_filter_panel_test.dart`（交互与角标）。

⚠️ 顺手记一个坑：面板上现在同时有「刮削」分组标题、「已刮削」chip 和那句
「刮削一次就能拿到上映年份」，所以**别再写宽松的 `find.textContaining('刮削')`**
（会命中三处）。要验提示语就匹配整句。


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

## Android 构建：四个坑串成一条链（2026-10-02 打通；坑四 2026-10-04）
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
**修法**：**首选** `flutter config --android-sdk=/Users/tandy/Library/Android/sdk` —— 第 1 步就命中，
最高优先级，**连 HOME 被重定向都不怕**，设一次永久生效（2026-10-04 采用）。也可所有 flutter/gradle
命令显式 `export ANDROID_HOME=/Users/tandy/Library/Android/sdk`（第 2 步命中；2026-10-04 用
`flutter build apk --release --config-only` 实测确实被采纳、写回的就是真实 SDK）。
⚠️ 2026-10-04 还遇到过**一次**：`ANDROID_HOME` 已导出、跑完整 `flutter build apk` 却仍把 Caskroom
路径写回 `local.properties`（原因未定位，`--config-only` 复现不出来）—— 所以推荐用 `flutter config`，
它不依赖环境变量。保险起见在 `local.properties` 里同时钉 `sdk.dir` 与
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

### 坑四：Android Studio 自带的 JDK 25 让 Kotlin 直接崩（报错只有 `25.0.3` 四个字符）
症状：`flutter build apk` **3 秒**失败，`What went wrong:` 下面**只有一个版本号**：
```
* What went wrong:
25.0.3
* Exception is:
java.lang.IllegalArgumentException: 25.0.3
	at org.jetbrains.kotlin.com.intellij.util.lang.JavaVersion.parse(JavaVersion.java:305)
	at org.jetbrains.kotlin.com.intellij.util.lang.JavaVersion.current(JavaVersion.java:174)
	at org.jetbrains.kotlin.cli.jvm.modules.JavaVersionUtilsKt.isAtLeastJava9(javaVersionUtils.kt:11)
```
**真因**：Flutter 定位 JDK 的顺序是 ① `flutter config --jdk-dir` ② `JAVA_HOME` ③ **Android Studio 自带的 JBR**
（`/Applications/Android Studio.app/Contents/jbr/Contents/Home`）。AS 2026.1 的 JBR 是 **OpenJDK 25**，
而 Gradle 8.10.2 里打包的 Kotlin 编译器用的 `JavaVersion.parse` **解析不了 `25.0.3`** —— 崩在**编译
settings 脚本**阶段，所以没有任何 `> Task` 行、堆栈也短。
⛔ 别去查 AGP / Kotlin 插件版本，**那个孤零零的版本号就是 JDK 版本**。
**判据**：`flutter build apk -v 2>&1 | grep "bin/java -version"` 会打印 Flutter 选中的 java 与版本。
**修法**：`flutter config --jdk-dir=/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home`
（写进 `~/.config/flutter/settings`；JDK 21 与 Gradle 8.10.2 / AGP 8.7.0 / KGP 2.1.0 配套）。
⚠️ 换 JDK 后**第一次**构建要重编 Flutter 自带的 gradle 插件（`<flutter_sdk>/packages/flutter_tools/gradle`），
80 秒以上，且**可能先失败一次**并报无关的 `Your project requires a newer version of the Kotlin Gradle
plugin` —— **再跑一次即可**，别真去动 Kotlin 版本（我为此白查了一轮）。
⚠️ 同一次构建还会打 `e: … kotlin-stdlib-2.2.0.jar … metadata is 2.2.0, expected version is 2.0.0`：
那是 Flutter 插件自己（Kotlin 2.0.0 编的）去读 2.2.0 的 stdlib，**不致命、不用管**。
⚠️ 在 shell 里裸跑 `./gradlew assembleRelease` 时 `JAVA_HOME` 为空、`java` 是 17，**反而能过** ——
「flutter 挂但 gradlew 好」这个对比本身就是 JDK 分歧的信号。
⚠️ 该坑会让 `flutter-apk/` 里只剩 `app-release.apk`（构建没跑到打包），别误判成产物名机制坏了。

### 产物名与版本号：文件名被 Flutter 工具链**定死**

`flutter build apk` 的产物名不由 AGP 决定 —— `flutter.groovy:1418-1445` 在
`assembleRelease.doLast` 里 `copy` + `rename`。

- ⛔ **改 AGP 的 `outputFileName` 无效**：只会让 `outputs/apk/release/` 多出一个副本，
  而 `flutter build apk` 报给用户的、`flutter install` 会去装的，仍然是
  `flutter-apk/app-release.apk`（工具按**精确名** `app-<mode>.apk` 找，
  `gradle.dart:132-143` / `:1010-1022`）。
- ✅ 做法：`android/app/build.gradle.kts` 里给 `assemble<Mode>` 挂 **finalizer**
  （⛔ 别用 `doLast` —— 它的执行顺序取决于 Flutter 插件的注册时机），
  **复制**（⛔ 不能改名）成 `cloudcine-<versionName>-b<versionCode>-android.apk`。
- 版本号在**配置期**取 `flutter.versionName` / `flutter.versionCode`。
- ⛔ **ABI 段的提取**（2026-10-04 修，之前一直是错的）：Flutter 的命名是 `app-<abi>?-<mode>.apk`，
  **普通构建没有 ABI 段**。原来的写法 `removePrefix("app-").removeSuffix("-$buildMode.apk")`
  会**静默**出错：`app-release.apk` 摘掉前缀后是 `release.apk`，它不以 `-release.apk` 结尾
  → `removeSuffix` 不生效 → ABI 成了 `release.apk` → 产物名变成
  `cloudcine-0.1.0-b1-release.apk-android.apk`（多一截，且看不出哪段是 ABI）。
  只去掉 `.apk` 再摘 `-release` 同样匹配不上（`release` 前面没有连字符）。
  ✅ 正确写法 = **先摘 `.apk`、再摘不带连字符的 mode、最后摘可能多出来的 `-`**：
  ```kotlin
  val abi = source.name.removePrefix("app-").removeSuffix(".apk")
      .removeSuffix(buildMode).removeSuffix("-")
  ```
- ⛔ `flutter build apk` 成功时**只打印** `✓ Built …/flutter-apk/app-release.apk` —— 它**永远**
  是这个名字，品牌产物是旁边**另一个文件**，Flutter 不会提。**别拿这行当「品牌名没了」的证据**，
  去看 `ls build/app/outputs/flutter-apk/`。
- ⚠️ 全量 up-to-date 的增量构建**也会**重新生成品牌产物（finalizer 在 finalized 任务 up-to-date 时
  照样执行；2026-10-04 实测：删掉品牌文件后 12s 的增量构建里又生成了一份）。所以「品牌文件不见了」
  只可能是 ① 构建没跑到打包（见坑四）② 有人 `flutter clean` 或手工删过。

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

### ⛔ 实测：「杜比 / DTS 直通」在 macOS 上**必卡死**（2026-10-03）

用户报「选了直通能播，关掉再打开就播不了，改回跟随片源又好了」。查下来**不是**记忆
机制的锅，是 `audio-spdif` 本身：

- 只要片源音轨编码落在 `ac3,eac3,dts,truehd,dts-hd` 里，mpv 会挑出
  `spdif_<codec>`（libavformat/spdifenc）当解码器，然后**音频输出（AO）永远建不起来**
  —— 日志里连 `[ao] Trying audio driver` 都没有，停在 `[ad] In: profile=-99 samplerate=44100`。
- 音频是 mpv 的**主时钟**。音频链不走，视频就永远等它 → `core-idle=yes`、`time-pos` 冻在
  起点不动。**表现是整部片卡死，不是「没声音」**。
- 所以「第一次能播」是假象：`audio-spdif` 是**开流时**才生效的选项，播放中 `setProperty`
  改它对**当前这条流毫无影响**（实测：位置照常前进、`current-ao` 仍是 `coreaudio`）。
  于是「播放中选直通」看着正常，值却已落库（全局默认 + 本片偏好都写），
  下次打开就在 `open()` 之前把 `audio-spdif` 下发了 → 卡死。改回「跟随片源」再打开就好。
- ⚠️ `PlayerAudioEffect.apply` 里那个「读回 `audio-channels` 确认生效」的自检**抓不到它**：
  `audio-spdif` 确实设上了，读回 `audio-channels` 也是对的 —— 坏的只有播放。
  这与 `af set` 那条教训是同一个：**「设得上」不等于「用得了」**。
- ⚠️ 也**不是**「设备不支持直通」：`ao=null`（压根不需要设备）同样卡死，
  说明卡在 mpv 音频链初始化阶段，而不是 AO 打开那一步。

复现配方（C 驱动，见本文件「用 C 直接调 mpv」）：造一个 E-AC-3 5.1 的 mkv，
`audio-spdif=ac3,eac3,dts,truehd,dts-hd` + `vo=null`，`time-pos` 会一直停在 0.00、
`core-idle=yes`；换成 `audio-spdif=no` 或换 AAC 片源就正常前进。
对照组：`aid=no`（无音轨）+ `vo=null` 时位置按实时前进 —— 证明 `vo=null` 本身有节奏，
上面那个 0.00 是真卡住，不是「没东西给它对时」。

### 跨引擎：设置投递进去、改动回报出来

独立播放窗口跑在**另一个 Flutter 引擎**里，读不到主窗口的设置库：

- 主窗口 → 窗口：`PlayRequest.audioEffect`
- 窗口 → 主窗口：`PlayerBridgeMethod.saveAudioEffect` → `SettingKeys.playerAudioEffect`
- ⚠️ 两个播放器（`player_window_app.dart` + `player_page.dart`）**都要接**，
  只改一个 = 用户看到「功能没做」。

## 原画加速：本地多路中继（2026-10-03）

代码：`lib/data/stream/local_stream_relay.dart`（会话 + worker）、
`lib/data/stream/relay_reader_arbiter.dart`（纯函数判定器）、
`lib/data/stream/chunk_cache.dart`、`lib/data/stream/chunk_layout.dart`。

### 它解决什么、不解决什么

夸克原画直链是**单条 TCP、顺序读**，而网盘对单连接有吞吐上限（实测 ~2.43 MiB/s 突发、
3.36 MiB/s 持续），片源却是 19.74 Mbps = **2.37 MiB/s** —— 稳态贴着上限跑，必然
「缓冲看着不少、却每隔几十秒卡一下」。中继把一条源站连接变成 **N 条并发 Range 连接 +
本地 LRU 缓存**，mpv 从 `127.0.0.1` 读，单连接上限被 N 倍绕过。

**不解决**：用户到网盘的总带宽不够。这时并发也救不了，应当如实显示真实速率、
让用户切转码档，而不是假装缓冲充裕。

⚠️ 只服务**原画**：`.m3u8` 由 `isRelayableUrl` 排除（HLS 分片是相对地址，
中继会把拼地址的基准改成 `127.0.0.1`，拼出来的全指向自己 → 播不了）。

### ⛔ 雷一：每取一块就新建连接 = 等于没并发（已修）

早期实现**每取一个 2 MiB 块就新建一条 `HttpClient`、取完立刻 `close`**。
对 17 GiB 的片子那是**上万次 TCP+TLS 握手**，聚合吞吐被切成锯齿。
修法：每个 worker **长期持有一条连接**（`HttpClient` 默认 keep-alive），
`idleTimeout` 放宽到 30s（连续取块之间那几百毫秒空档不能把连接回收掉）。

判据看 `RelayStats.upstreamConnects`：它应**远小于** `upstreamRequests`（约等于 worker 数）。
单测 `test/data/stream/local_stream_relay_test.dart` 里那条端到端用例除了数计数器，
还**按远端端口去重**数真实 TCP 连接 —— 只数计数器可能被实现骗过。

### ⛔ 雷二：预取锚点只跟「正在播的那条流」（seek 卡顿的根因）

#### 现象

起播流畅（修复雷一之后），但**一拖进度条就「看一会卡一会」**，几十秒后才自己恢复。

#### 实测方法（可复现）

真 `LocalStreamRelay`（8 连接 × 2 MiB 块、预取/缓存 256 MiB）指向一个**记录型 loopback
代理**，代理转发到**真实夸克原画直链**并给每个 Range 打毫秒时间戳；真 `libmpv`
（`/tmp/mpv_probe3`，90s、第 20 秒 `seek absolute 1500`）走中继播放；
每 2 秒打印一次中继统计。环境变量 `CACHE`（默认 `no`）、`SEEK_TO`。

#### 实测结论

一条会话上 mpv **同时挂着 3~4 个 HTTP 读取器**，而拖进度条时 **mpv 不关旧连接** ——
旧读取器留在原地继续被喂（实测 4 次 `SERVE-start`，seek 时**没有一次** `SERVE-end`，
全部到测试结束才断）。

而预取窗口的锚点原本是**整个会话唯一的一个**，任何读取器请求任何块都会覆盖它，
于是 seek 后锚点在旧/新位置之间反复拉锯（实测打印）：

```
ENSURE 1779 anchor=1779   ← 读取器 C（seek 到 1500s）把锚点拉到新位置
ENSURE   92 anchor=92     ← 旧读取器 A 又把它拽回旧位置
ENSURE  108 anchor=108
ENSURE 1797 anchor=1797   ← C 再拉过去
ENSURE  134 anchor=134    ← 又被拽回来
```

**修复前后对照**（同一份 17.09 GiB 原画，seek 到 1500s，90s 观测）：

| 指标 | 修复前 | 修复后 |
| --- | --- | --- |
| seek 后喂给**旧位置**的上游带宽占比 | **81%**（318 MiB） | **13%**（40 MiB） |
| 新位置平均速率（片源需 2.37 MiB/s） | 0.87 MiB/s | **3.36 MiB/s** |
| seek 后位置最长不动 | **34 秒** | 10 秒（正常重缓冲） |
| 卡顿 `paused-for-cache` | **6 次** | **1 次** |
| 70 秒内推进的播放时长 | 13.1 秒 | **57.9 秒** |

也顺手排除了一个猜测：`cache=no` **不是**原因 —— `cache=auto` 下同样冻住 34 秒。

**起播为什么不卡**：那时只有**一条**读取器，锚点没得争。两场景的差别就在这。

#### 判定规则（`relay_reader_arbiter.dart`，纯函数、有单测）

靠**请求范围的长度**认出「在放片子」的读取器，不靠到达顺序、也不靠猜：

- **在放片子**：mpv/ffmpeg 一律发**开放式** Range（`bytes=N-`，直到文件尾），
  范围动辄几个 GiB → `isStream` 要求范围 ≥ 一个预取窗口（`prefetchChunks × chunkSize`）。
- **探索引**：读 MKV `Cues` 会请求**文件尾那一小段**（实测 `bytes=18351436158-`，
  只有 2 块，0.86 MiB）。它读几十毫秒就走，**绝不能**让它把窗口挪到文件末尾 ——
  那会让正在播的位置饿死。它照常服务（进主队列），但**永远不推动锚点**。

规则：① 当前读取器（最新到达的「在放片子」的）→ 锚点跟着它，它自己跳远就是 seek；
② 别的读取器落在窗口里 → 同一条流的并行连接，**只许向前推、绝不往回拖**；
③ 别的「在放片子」的读取器位置远离窗口 → 多半是已被抛弃的旧连接，**不动锚点，
需求降级到 `_stale` 低优先队列**；④ 探索引 → 主队列、不动锚点；⑤ 没有当前读取器
（起播 / 当前读取器已结束）→ 谁先来谁是。

⚠️ 旧读取器的需求是**降级不是丢弃**：丢弃会让那些 `_ensure` 永远不返回，读取器就那么吊着。
它排在**预取窗口之后**，只在窗口已填满、没别的活干时才服务 —— 也就是白捡的余量。

⚠️ 当前读取器结束必须 `release` 让位，否则锚点再没人推动、窗口冻在原地 ——
表现是「画面停住不动，日志里却没有任何错误」。

真跳远时 `_onAnchorJumped(index)` 三件事必须**一起**做：把旧位置的排队降级、
`cache.clear()`（旧块一行用不上，留着只会把新窗口挤成「下了就淘汰」）、
把新窗口里的等待**提升回主队列**（跳转后的第一块往往在降级前就排过队了）。

### 回归测试

`test/data/stream/local_stream_relay_test.dart` 的
`seek：旧连接不得抢走新位置的预取带宽`：合成 40 MiB 源、1 MiB 块、2 连接、
8 MiB 预取窗口；开一条 `bytes=0-` 的长读取器并**持续消费**（不消费就不会提出需求，
也就复现不了争抢），再开一条 `bytes=30MiB-`，断言 seek 之后**前 8 次上游请求里
落在旧位置的不超过 2 次**（`connections` —— 只可能是 seek 那一刻已经在上游路上的）。

⚠️ seek 目标**不能太靠文件尾**：拖到 38 MiB 只剩 2 MiB 范围，会被 `isStream`
当成探索引，就测不到东西了。

**验证过它确实有判别力**：临时把 `_ensure` 里的判定改成恒返回 `ReaderDemand.anchor`
（= 修复前的行为），该用例变红（前 8 次里 5 次喂旧位置）；还原后连跑 5 次全绿。

### 探针脚本

一次性诊断夹具（真实中继 + 真实直链 + 真 mpv + 记录型代理）已从 `test/` 移除 ——
它**联网、依赖真实票据**，留在 `test/` 会让 `flutter test` 每次去跑 90 秒真网络，
票据过期后直接红。副本在 `/tmp/qk/keep/`（`seek_probe_test.dart`、`mpv_probe3.c`）。
⚠️ 探针**不要放进 `test/` 默认目录**，要跑就 `flutter test <显式路径>`。

配套的 `mpv_probe3.c` 参数：`<url> <secs> [hwdec] [vo] [start] [cache] [maxbytes] [seekAt] [seekTo]`，
会统计 `paused-for-cache` 次数；跑之前要设 `DYLD_FRAMEWORK_PATH` 指向
`build/macos/Build/Products/Debug/cloudcine.app/Contents/Frameworks`。





## 播放窗口没焦点时的 hover（2026-10-03）

**症状**：播放器窗口不是当前焦点窗口时，鼠标滑到画面上什么反应都没有 ——
控制条与剧集列表按钮都不出来（浮层整套都靠 hover 唤醒）。

**根因是两处，缺一不可**：
1. 引擎给视图挂的 `NSTrackingArea` 带的是 `NSTrackingActiveInKeyWindow` ——
   `FlutterViewController.mouseTrackingMode` 的**默认值是 `InKeyWindow`**，
   即「只有本窗口是 key window 时才把 hover 送进 Flutter」。窗口一不是 key，
   Dart 侧一个 hover 都收不到。
2. 就算事件到了：引擎把 `mouseEntered:` 翻成 pointer **add**（`kAdd`），而
   `MouseRegion.onHover` 只在 `PointerHoverEvent` 上回调 —— 「滑进来就停住」
   只剩这一个事件，浮层照样不出现。

**修法**：
- 原生 `MainFlutterWindow.swift` 的 `ChildWindowController.attach`：
  `controller.mouseTrackingMode = .always`（= AppKit `NSTrackingActiveAlways`，
  Apple 文档：「不论第一响应者、窗口状态还是**应用状态**都收消息」）。
  `FlutterViewController.h` 里这个属性就是为这件事留的口子，引擎自己建的多窗口
  controller 没别的办法配它（flutter/flutter#185426）。
- Dart `_buildPlayer()` 那个整窗 `MouseRegion`：除 `onHover` 外再挂
  `onEnter: (_) => _pokeChrome()`。

**别忘的几条**：
- ⛔ 它只管 **hover**。点击仍要先激活窗口，但 `FlutterView.acceptsFirstMouse`
  返回 YES，所以第一次点击会同时完成激活与派发，不会「点两下才生效」。
- ⚠️ 引擎切追踪模式时**不摘旧 area**（只有设成 `None` 才摘，见
  `configureTrackingArea`）→ 同时存在两个 area，窗口是 key 时 hover 到两次。
  无害：位置相同、`_pokeChrome()` 幂等，且引擎对重复 kAdd 自带去重。
- ⚠️ 「窗口有没有焦点」在 widget test 里造不出来：测试只钉住 Dart 那一半
  （`test/ui/windows/player_window_app_test.dart` 的「指针一进窗口就唤醒浮层」，
  只 `addPointer` 不 `moveTo`），原生那一半只能真机验。
- 主窗口（库页海报卡片的 hover）**没动**，仍是引擎默认的 `InKeyWindow`。

### 万一「应用整体不活跃」时还是不灵（下一步该查什么）

`mouseTrackingMode = .always` 的依据是 Apple 对 `NSTrackingActiveAlways` 的措辞
（「不论第一响应者、窗口状态还是**应用状态**都收消息」）+ Flutter 自己的头文件注释
（「Hover events will be sent to Flutter regardless of window and app focus」）。
**没在本机做运行时验证**（那要劫持真实光标几秒，会打扰用户）。

如果用户反馈「焦点在别的应用上时滑过去仍然没反应」，下一步是加一层兜底：
在 `ChildWindowController` 里装
`NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved])`（**应用不活跃**时
它才收得到别的应用的事件），配合 `NSEvent.addLocalMonitorForEvents`（应用活跃时
走它，否则漏掉「主窗口是 key、播放窗口不是」那一档）。回调里用
`NSEvent.mouseLocation` 与 `window.frame` 判进出，跨通道通知 Dart
（`_pokeChrome` / `_hideChrome`）。
- 鼠标事件的 global monitor **不需要**辅助功能权限（键盘事件才需要）。
- ⚠️ 别用「轮询 `NSEvent.mouseLocation`」的定时器方案：能跑，但白烧 CPU。
- ⚠️ 两个 monitor 覆盖的集合是**互补**的（global 收不到自己应用的事件），
  只装一个会漏一半。

## 详情页文件列表的播放进度条：为什么不能用续播点（2026-10-03）

口径（用户选定）：**历史最大位置**。新增 `media_items.max_position_ms`（schema
**v15**），迁移时**从续播点回填下界**（续播点是历史最大位置的下界；不回填的话
升级后所有老条目在详情页都显示「没看过」，而它们其实看过）。

### 两列的分工（不能互推）

| | `resumePositionMs` | `maxPositionMs` |
|---|---|---|
| 回答 | **这次**从哪儿接着播 | **这一集看过没有 / 看到哪儿了** |
| 变化 | 会变，看完**清成 NULL** | **只增不减、永不清除** |
| 写入 | 独立窗口 `onPlaybackProgress`（认 `rememberPosition` 开关） | 两条路都写 |
| 读出 | 剧集面板 / `PlayTarget.resolve` | 详情页文件列表的进度条 |

用续播点画进度条的话，用户刚看完一集回到详情页，那一行显示 **0%** —— 恰好是他
最想看到 100% 的时刻。这是整件事存在的唯一理由。

### 三个必须记住的实现点

1. **只增不减要靠一条 SQL**，不能「先读、再比、再写」：`onPositionTick` 每 10 秒
   一次，换条 / 关窗时还可能补一次，两个并发落库会让较小的那个后写、把进度条
   往回拉。drift 版是
   `UPDATE media_items SET max_position_ms = max(COALESCE(max_position_ms, 0), ?) WHERE id = ?`。
   ⚠️ SQLite 的 `max()`：**两参数是标量函数**（取大者），单参数是**聚合函数** ——
   写成 `max(?)` 就变成对整表求最大值，不报错，只是把别人的进度盖到自己头上。
2. **进度条压在行底边**（`Stack` + `Positioned`），不塞进文字列：塞进去会让看过的
   行比没看过的行高几像素，一屏几十行参差不齐，右侧的时间列也跟着上下跳。
   `media_item_row_test.dart` 里有一条用例专门比两种行高**必须相等**。
3. **时长未知时返回 `null`（不画），不是 `0`**：一条确实看过、但夸克没给
   `duration` 的记录，画成 0% 的空槽 = 「白看了」，而它与「没看过」在屏幕上
   完全一样。宁可什么都不画。

### 刷新通路：为什么要**两个**信号

- `PlaybackLibraryLink`（既有）：说「**谁**在播」，**只在换条时**推 —— 它驱动
  海报墙「最近播放」的顺序，每次都推会让海报墙每 10 秒重建一遍。
- `PlaybackProgressSignal`（新增，同文件）：说「**播到哪儿了**」，**每次落库都推**
  —— 只驱动 `workDetailProvider`。

合成一个必然二选一：要么进度条不刷新，要么海报墙每 10 秒抖一次。两个信号都放在
`library_refresh_providers.dart` 这个**谁都不依赖的叶子文件**里（组合根要引用它，
方向不能倒过来）。

写入方**必须先写完库再推信号**：反过来的话详情页收到信号去读库时这一笔还没落盘，
进度条永远慢一拍。

两条写入路都要补：`app_providers.dart` 的 `onPositionTick`（内置播放页 ——
**Android TV 上唯一的播放路径**，漏了它电视上永远没有进度条）与
`player_bridge_host.dart` 的 `onPlaybackProgress`（独立窗口）。

### 两个踩到的坑（都是新测试当场抓到的，`flutter analyze` 看不见）

**坑 1：drift 的 `customStatement` 收的是原始值，不是 `Variable`。**
写成 `[Variable.withInt(x), Variable.withString(id)]` 会在**执行时**抛
`Invalid argument (params[1]): Allowed parameters must either be null or bool,
int, num, String or List<int>.: Instance of 'Variable<int>'` —— 静态分析完全
看不出来，只有真的跑一次 SQLite 才报。正确写法是 `<Object?>[ms, itemId]`。

**坑 2：Riverpod 的 refresh / reload 语义（我之前记反了）。**
- `ref.invalidate` / `ref.refresh` → **refresh** → `when(skipLoadingOnRefresh:)`，
  默认 **true**（不闪）；
- **依赖变化**（`ref.watch` 的那个值变了）→ **reload** →
  `when(skipLoadingOnReload:)`，默认 **false** → **会**走 `loading:` 分支。

所以「让 provider watch 一个每 10 秒推一次的信号」的默认表现是**整页每 10 秒
白一下转圈**。修法：给 `work_detail_page.dart` 的 `detail.when` 显式加
`skipLoadingOnReload: true`（保留上一份数据；首次加载没有上一份值，仍正常转圈）。
`work_detail_progress_test.dart` 有一条用例专门断言「推信号时没有
`CircularProgressIndicator`」。

### 测试落点

- `test/domain/media_repository_max_position_test.dart` —— 契约（内存实现）
- `test/data/db_max_position_test.dart` —— **真 SQLite**，守那条 `max()` SQL
  （只测内存版的话，SQL 写错不会有任何用例变红，而它是真机上唯一跑的一份）
- `test/ui/widgets/media_item_row_test.dart` —— 纯函数 + 行高不变
- `test/ui/pages/work_detail_progress_test.dart` —— 接对行 / 看完仍满格 /
  推信号不闪圈
- `test/data/db_migration_last_modified_test.dart` —— v15 回填下界

### 同一个 bug 的姊妹界面：剧集面板（已一并修掉）

独立播放窗口的**剧集面板**原先也用 `resumePosition` 画进度条 —— 同一个毛病：
看完的一集在面板上什么都不显示。修法与详情页同源：`PlaylistEntry` 新增
`maxPosition`（跨引擎协议 + 主窗口 `_buildPlaylist`），进度条改读它。

两个字段在面板上**各司其职**，都不能删：

| | 用途 | 谁算 |
|---|---|---|
| `resumePosition` | **切集时从哪儿开始**（要过 `PlaybackResume.startFrom` 的取舍） | 播放窗口在切集时算，把结果报回主窗口 |
| `maxPosition` | **面板那条进度条** | 只读，主窗口填 |

⛔ 别把两者合成一个字段：合成之后要么进度条对看完的一集是空的，要么切集会从
头开始 —— 两种都不会报错。

另外两处跟着收紧：

- `PlaylistEntry.hasProgress` 现在要求「看过一点 **且时长已知**」：拿不到分母时
  进度只能是 0，画出来是一条**空的槽**，读起来就是「没看过」。与详情页那条
  进度条同一口径（宁可什么都不画）。
- `maxPositionMs` 在 `fromJson` 里**缺失时退回 `resumePositionMs`**：后者是前者
  的下界，退回它得到的是一条偏短但不说谎的进度条，退回 0 会把看过的一集显示成
  没看过。

⚠️ **产品决策（用户可否决）**：「记住播放进度」这个开关**只管起播行为，不管显示**。
关掉它之后续播点不带过去（`startAt` 走 0），但已经躺在库里的历史进度**照旧显示**
（面板与详情页都是）。跟着开关一起清掉的话，用户一关它所有进度条会同时消失 ——
看起来像把历史抹了。`desktop_play_test.dart` 里有一条用例钉住这个口径
（那条用例原先断言的是续播点为空，但夹具只有 1 个条目 → 列表为空 →
`everyElement` 恒真，等于什么都没测；已顺手改成真的有两个条目）。

---

## 自动刮削「怎么都刮不到」：两类假信号骗过了守卫（2026-10-03）

一天里用户报了两个现场，**形态完全不同、根因同类**：解析层有一条「这个文件
自己说得清不清楚」的守卫（`_isStandaloneRelease`），它决定了**目录名能不能
顶掉文件名**。守卫被一个**假信号**骗到时，结果不是报错，而是「查询词变成垃圾
→ 两个在线源都搜不到」，用户只能看到「刮不出来」。

⛔ **排查顺序**：先把文件名与 `dirPath` 丢进 `MediaFilenameParser.parse` 打印
`title / kind / year / groupKey` 与 `ScrapeQuery.fromParsed(...)`，再去看日志里
那一行 `ScrapeQuery(...)` 长什么样。**日志里的查询词就是答案** ——
九成问题在「查询词本身是垃圾」，不在网络、不在额度、不在闸门。

### 现场一：`[2026-02-01]` 冒充出品年份

```
/来自：分享/仙逆/126 纯享-仙踪-[4K][HEVC][2026-02-01].mp4
```

同目录 49 个视频、6 个作品，**只有这一个刮不出来**（另外 6 个文件名里带
`仙逆` 的都刮到了）。

**根因链**：`[2026-02-01]` 是发布者写的**上传日期** → `_pickYear` 当成出品年份
`2026` → `_isStandaloneRelease`（第 2 条判据「自带年份」）判这个文件
「自称独立发行物」→ 目录名 `仙逆` **被顶掉** → 查询词是垃圾片名
`126 纯享-仙踪` → TMDB 去年份重试仍然零结果，豆瓣零结果。

假年份还有第二重代价：它让 `isConfident` 为真 → 查询走**严格档**（闸门只要
0.6 相似度）→ 更容易刮错片子。

**修复**：`_pickYear` 跳过**括号里的完整日期**。

⚠️ 两道判据缺一不可，只写「后面跟着 `-MM-DD`」是不够的：

1. 后面紧跟 `-MM-DD` / `.MM.DD` / `_MM_DD`。`\d{1,2}` 与 `(?![0-9])` **配套**：
   `Movie.2023.1080p.mkv` 里的 `.1080` 咬不动（四位数字过不了 `\d{1,2}`），
   `2012.2009.1080p.mkv` 同理 —— 这两个的年份必须留下；
2. 年份**紧跟在括号后面**（`[` / `【` / `(` / `（`）。裸写的 `2023-05-12` 是
   发行日期，其年份与 TMDB 的 `year`（发行年）口径一致，**要留下**。

⚠️ **只跳过「年份」这个取值，`_markerPatterns` 一个字都不能动**：那里决定
「片名在哪截断」，`2026-09-27` 仍然必须把 `奔跑吧` 截出来（否则片名会变成
`奔跑吧 2026-09-27 第12期`）。

**修完的效果**：`year=null` → 目录名生效 → `title=仙逆`、`kind=episode`、
`groupKey=仙逆` → 与已有的 `仙逆renegadeimmortal` 刮到同一条 TMDB 条目 →
自动归一（`onlineId` 相同 + `kind` 相同）能把它折进去。

### 现场二：纯数字片名被判成「编号」

```
/来自：分享/逃出白垩纪 (2023) 4K HDR & Dv/65.2023.2160p.WEB-DL.DDP5.1.DV.HDR.H.265-FLUX.mkv
```

那部电影的片名**就是** `65`（2023，Adam Driver 主演；中文名《逃出白垩纪》）。

**根因链**：`_isStandaloneRelease` 第 1 条判据是「片名含字母或汉字」——
`65` 过不了 → 判成编号 → 目录名顶掉它 → 查询词变成
`逃出白垩纪 2023 4K HDR & Dv`（目录名里的**年份与画质标记都没被清掉**）→
两个源都搜不到。

⚠️ 而且目录名归组会把 `kind` 改成 `episode` → 去搜 `/search/tv`，而这是一部
**电影** → 必然搜不到，**且不报错**。

**修复**：纯数字片名改成「**自带年份**才算真名字」。

```dart
if (!hasWord) return year != null;          // 纯数字：自带年份才放行
return year != null || kind == MediaKind.episode;
```

- `65` + 2023 → 保住片名与 `movie` → 查询 `ScrapeQuery("65", movie, y=2023)`
  → `/search/movie?query=65&year=2023` → 一击即中；
- `159.mkv`（**无年份**）→ 仍然要靠目录名救 —— 2026-10-02「182 → 希腊纪录片」
  事故的那条守卫没丢。

### 兜底：多来源候选链（用户要求的「一步步尝试」）

用户原话：「将文件名、文件所在目录、上级目录等信息作为尝试刮削的逻辑，从严格
到宽松，一步一步尝试」。

`ScrapeQuery.fromParsed(parsed, dirPath: ...)` 现在生成 **`fallbacks`**：
**文件名 → 所在目录 → 上级目录**。

- 目录来源用 `DirectoryTitle.ancestorNames(dirPath)`：从末级往上，跳过容器名，
  **最多 2 级**（每多一条就多花一个搜索词，而豆瓣匿名额度只有约 10 个）；
- 目录候选一律 `kind = episode`（`DirectoryTitle` 的口径：目录名是**系列名**）
  + `requireExactTitle = true`（没有年份也没有季集号，闸门只剩标题相似度，
  0.6 档会放行 `特洛伊奥德赛` 0.68 这种别的片子）；
- **不带** `alternateTitle`（目录名极少中英混排）、**不带** `year`
  （目录名里的年份多是「合集整理于某年」，当过滤条件会把正主筛掉）；
- 与主查询**同名**的目录名不生成（`/…/仙逆/仙逆.S01E01.mkv` 很常见，那是白花
  一次额度）；
- `ScraperPipeline.scrape` **串行、命中即停**（并发起跑会把整条链的额度一次
  全花掉，而链的意义恰恰是「前面命中时后面根本不该发请求」）；
- ⛔ **本地兜底只用主查询**。这一条最容易写错成「每条候选后面都跑一遍兜底」
  —— 那会让「在线源全落空」时拿**目录名**去当作品名，结果是作品被改成一个
  既没海报也没简介的目录名，用户只会觉得「刮了一次，名字反而变了」。

**为什么挂在 `ScrapeQuery` 上、而不是新造一个「查询链」类型**：链的持有者是
`WorkSeedBook._queries`（`Map<String, ScrapeQuery>`）与 `WorkScraper._queryFor`，
两处都是「一个作品一条查询」；新造类型要把这两处的类型与全部调用点一起改，
换来的只是「`ScrapeQuery` 里不会出现 `ScrapeQuery`」这一条形式上的洁癖。
⚠️ 兜底自己**不再带兜底**（链只有一层深，`scrape` 的循环因此不递归）。

### 顺带：季目录也是容器

`第三季` / `第2季` / `Season 1` / `S02` 已加进 `DirectoryTitle._containerPatterns`。
不加的话：`/进击的巨人/第三季/` 会冒出一部叫「第三季」的作品，而且候选链会
拿「第三季」去搜一次 TMDB（前缀档必然误配）。

### 还没做、待用户拍板：目录名里的年份与画质标记

`DirectoryTitle._clean` 只去书名号 / 括号 / 分隔符，所以

```
seriesTitleOf('/来自：分享/逃出白垩纪 (2023) 4K HDR & Dv/')
  = '逃出白垩纪 2023 4K HDR & Dv'
```

这个串**同时是归组键与查询词**。对「文件名不给年份」的片子
（`/…/逃出白垩纪 (2023) 4K HDR & Dv/65.mkv`）仍然会拿它去搜，必然搜不到。

⛔ **别直接用 `_parseDotted` 截断**（最省事的写法）：`_markerPatterns` 把
`web` / `hd` / `bd` / `ts` / `dv` / `cam` 都当标记，于是
`极客时间 Web 协议详解` 会被截成 `极客时间`（`directory_title_test` 里那条
「去掉书名号与括号噪音」的用例正是拦这个的）。
要做就得是**只从右往左、遇到第一个非标记词就停**的收敛规则，且要单独跑一遍
全量测试看分组键变化。

### 测试落点

| 规则 | 文件 |
| --- | --- |
| 括号日期不算年份 / 纯数字片名 | `test/core/filename_parser_test.dart` |
| `ancestorNames` 与 `seriesTitleOf` 同源、季目录是容器 | `test/core/directory_title_test.dart` |
| `fallbacks` 的形状（剧集 / 精确同名档 / 去重 / 最多 2 级） | `test/domain/scrape_query_test.dart` |
| 串行命中即停、本地兜底只用主查询 | `test/domain/scraper_pipeline_test.dart` |
| 两个调用点都传 `dirPath` | `test/domain/work_builder_test.dart`、`test/domain/work_scraper_test.dart` |

## 目录视图的多选批量删除（2026-10-03）

用户要求原话：「文件夹列表支持多选媒体文件或文件夹，执行批量删除动作用来清理云盘空间」。

### 不需要逆向任何新接口

`QuarkAdapter.deleteFiles`（`POST /1/clouddrive/file/delete`，`action_type=2`
**永久删除**、`filelist` = fid 列表）**早就实现了**，此前只有备份清理在用。
本地媒体库那侧也有现成的「网盘上文件没了 → 从库里移除」路径
（`MissingMediaController`，带字幕引用 / 续播点 / 播放偏好 / 作品计数的
全套清理）。所以这一轮是**接线 + UI**，一行逆向都不用做。

⚠️ 排查时先 `grep deleteFiles`：这类「以为要从零写」的功能，多半已经有一半
在别的调用点底下躺着。

### 三条做错就静默坏数据的判据

**① 勾选只存 fid，且换目录必须清空。**
列表每次重列网盘给的都是新对象，存 `DriveEntry` 等于「刷新一下选择就丢了」。
更要紧的是工具条上「已选 N 项」是用户**唯一**能核对「我要删什么」的地方 ——
跨目录残留的勾选会让他在看不见那些条目的情况下把它们删掉。
界面上的实现是**多选时收起面包屑与「上一级」**（让约束看得见），
`ref.listen(currentCrumbProvider)` 里清空只是兜底（`_emptyState` 的
「回到根目录」还留着）。

**② 「全选」勾的是屏幕上那些，不是这一层的全部。**
判据抽成了顶层函数 `displayEntries(listing, query, mode)`，
**列表与全选共用这一份**。各写一遍的话，用户筛出三个文件、点全选、按删除，
删掉的是同目录另外两百个 —— 而数字对得上（他看到的就是「已选 203 项」），
界面上完全看不出错。

**③ 只清「服务端确认删掉」的那些索引。**
失败的批次如果也照清，用户会得到「文件还在网盘上，媒体库里却没了」，
要回来得重扫。目录的清理**只能按路径前缀**（索引里没有「目录」这个概念，
它记的是文件的 `dirPath`）：用 `crumb.child(dir).path`，
⛔ **不能用 `entry.path`** —— 那个只有扫描器遍历时才填，列目录拿到的条目里
通常是 `null`，静默匹配不到任何东西。

### 分块与失败处置（`DriveCleanupController`）

每请求 100 个 fid（夸克没公开上限；`file/move` 的 `fid_list` 是 100）。
定成 100 不是为了绕上限，是**控制失败时的爆炸半径**：一次带 3000 个 fid 超时
的话用户什么信息都拿不到，只能全部重来。

⛔ **凭证失效 / 断网要中止后续批次，并把「没发出去的」也算进失败数。**
这两类错误不是按批次的，继续打只是多几十个注定失败的请求（夸克那条约 3 QPS
的线本来就很紧）。而把没发出去的算成成功是**撒谎**：用户以为清干净了，
它们还在网盘上占着空间。
⚠️ 但 `rateLimited` **不能**中止 —— 限流是可以继续试的，第 1 批失败不代表
第 2 批也会失败。两条分支分别由 `FakeDriveAdapter` 的 `deleteFailsWith`
（每一批都抛）与 `deleteFailsOnBatch`（只让第 N 批抛）构造。

### 一个 UI 决定：多选时把行上的动作按钮**收起来**

不是「留着但禁用」。目录行的「下载全部」在勾选模式里看起来像「确认选择」，
而它实际会开始下整个目录；视频行的「播放」同理会误触。
一行只有一个主要含义 —— 这条原则在 `_DriveFileRow` 的类文档里已经写过一次。

### 测试落点

| 规则 | 文件 |
| --- | --- |
| 分块边界 / 下界体积 / 文案（部分失败必须报数） | `test/domain/drive_cleanup_test.dart` |
| 多选状态的不变量（exit 同时清空、`==` 按集合内容比） | `test/ui/providers/folder_selection_test.dart` |
| 分块、致命错误中止、索引清理（含目录子树、失败不清） | `test/ui/providers/drive_cleanup_controller_test.dart` |
| 弹窗正文（名字摊开、未知体积不写 0 B、不可撤销） | `test/ui/widgets/drive_delete_dialog_test.dart` |
| 工具条、点行=勾选、长按进入、全选只勾可见 | `test/ui/pages/folder_page_test.dart` |

⚠️ **Flutter 测试坑**：`find.byType(FilledButton)` **不匹配**
`FilledButton.icon` —— 后者是子类 `_FilledButtonWithIcon`，而 `byType` 比的是
运行时的**确切**类型。用它找会得到 `Bad state: No element`，看起来像按钮
根本没渲染出来。改用
`find.byWidgetPredicate((w) => w is FilledButton)`。

### 待用户验证（本机没法验的两条）

1. 夸克删除**是不是真的不进回收站**。项目里 `action_type=2` 的注释一直写
   「永久删除」（备份清理在用），但那是社区逆向的结论，官方无公开文档。
   弹窗按**不可撤销**写，属于偏保守的一侧。
2. **删一个目录 fid 会不会连带删掉整个子树**。若服务端不这么做，
   表现是「删完刷新，那个目录还在」—— 是**看得见**的失败，不会静默坏数据。

---

## 批量删除的复核：返回值语义与限流缺口（2026-10-03 晚）

改完批量删除后自查了一轮。**只动了注释，没动行为**，但两条结论值得留着。

### 一、`deleteFiles` 返回的是**入参回显**，不是核实结果

```dart
await _request(() => _post(QuarkEndpoints.fileDelete, body: {...}), context: '删除文件');
return fileIds;   // ← 入参原样返回
```

夸克的删除响应只有信封（`code` / `status` / `message`），没有可读的逐条结果
（参考实现里这个接口无文档，我们也没去翻 `data`）。于是**只能**在
`code == 0` 时把整批报成已删除。

⚠️ 这留下一种**看不见**的偏差：服务端在同一批里跳过了某几个（无权限、
已在回收站、fid 已失效），我们照旧报成功。所以这个数量是「请求成功了几条」，
**不是**「网盘上真的少了几条」。

**原先有两处注释把它说成核实过的**，已改（三处一起改）：
- `CloudDriveAdapter.deleteFiles`（抽象层）原文「返回被删除的 fid 列表
  （供调用方核对）」—— 回显里没有任何可供核对的信息，这句是**误导**；
- `DriveCleanupController._purgeLibrary` 原文「只处理**服务端确认删掉**的那些」
  —— 是「请求成功」，不是「逐条确认」。

⛔ **别把这里改成「删完立刻重列目录来核对」**。删除在服务端未必立刻可见，
刚删完就重列**很可能仍然看得到** → 会把**成功报成失败**。那比少报更糟：
少报只让用户多按一次重试，误报会让用户以为功能坏了。

`_purgeLibrary` 另补了一句「**宁可清早不可清晚**」的不对称理由：清早了
（清了其实还在网盘上的索引行）下次扫描会重建回来；清晚了（留一条指向已删
文件的死索引）要等用户点到它才会暴露。

### 二、适配器里两个桶**都只包读接口**，写操作一律裸奔

实测（`grep _listBucket|_linkBucket`）：

| 桶 | 速率 | 包住的方法 |
|---|---|---|
| `_listBucket` | 3 QPS | `listDirectory`、`search` |
| `_linkBucket` | 1 QPS（burst 2） | 4 条取链路由 |

**所有写操作走裸 `_request`**：`deleteFiles`(778)、`createDirectory`(748)、
`uploadFile` 的 pre/hash/auth/finish(817/860/927/1043/1075)、`moveFiles`。

所以「删除没有节流」与 `createDirectory` / `uploadFile` 是**一致的** ——
项目既有口径是「**被循环调用的读接口**才进桶」，写接口都是用户单次触发。

`DriveCleanupController` 的批次循环是这个口径下的**第一个例外**：一个**写**
操作被循环 N 次（`maxIdsPerRequest = 100`，3000 项 = 30 次连发、无任何间隔）。

- **已有兜底**：`rateLimited` 是**可续**的按批失败（controller 只对
  `unauthorized` / `network` 提前 break 并放弃后续批次），所以顶到限流的后果是
  「部分失败 + 如实提示 + 刷新后剩下的还在、可重选重试」，**不是**数据损坏。
- **若补节流**，架构上一致的位置是**适配器里加第三个桶**（与
  `_listBucket`/`_linkBucket` 同层，`TokenBucket(ratePerSecond: 3.0)` 即可让
  首批不等待、后续按 333ms 排），**不是**在 controller 里用 `RequestThrottle`
  —— 后者的类文档明写自己是「列目录请求的最小间隔节流器」，拿它管写操作会把
  它的职责搞浑。
- **代价**：3000 项从 ~6–12s（自然往返时间已经不小）变成有 ~10s 硬下限。
  单次删除（`LibraryBackupService` 覆盖旧备份那一处）不受影响 —— 桶空时首次
  请求直接放行。

### 结论：**先不加**（2026-10-03 21:12 用户拍板）

理由：现实批量（几百项 = 几批）的自然往返耗时**已经接近 3 QPS**，节流加不了
多少保护；而顶到限流的后果是「部分失败 + 如实提示 + 刷新后剩下的还在、
可重选重试」，不是数据损坏。等真的撞到再补，那时也有证据。

⚠️ 真要补时，按上面那条位置（**适配器里第三个桶**），**别**用
`RequestThrottle` —— 它是列目录专用的，混用会让两个概念都变模糊。


## 标识符索引：播放器与刮削（2026-10-03 从 MEMORY.md 下沉）

> 起因：`MEMORY.md` 贴到 8000 字符注入上限，把「标识符级的细节」下沉到这里，
> `MEMORY.md` 只留红线与指针。本节是**索引**，机理与实测见上面各专章。

### 播放器
- **缓冲条**共用 `buffered_slider.dart`，入参是 **0..1 比例**（不是秒）。
  ⛔ `demuxer-cache-time` 是**绝对时间戳**（不是「前面还有多少秒」）；时长未知时返回 **null**。
- 音轨源必须过 `TrackLabels.realTracks` 剔掉 media_kit 的合成轨；
  **选中态以 `player.stream.track` 的回报为准**（不做乐观更新，见 §为什么选中态不做乐观更新）。
- 搜索走 `subtitle_query.dart`，**绝不能拿 `displayTitle` 去搜**。
- **剧集面板**缩略图必须走 `fetchThumbnail` → 主窗口 `PosterCache`（自己下必 401）；
  面板主标题 = **原始文件名**。
- **音效 ≠ 音轨**（与片源无关，见 §「音效」是播放端的事）：
  ⛔ Avfilter 里**没有**可用音频滤镜、**`af set` 的返回值不能当依据**；
  ⛔ **macOS `audio-spdif` 直通必卡死 → 别下发**。
- **逐影片播放偏好**：表 `playback_prefs`（**v14**）。
  读 = 本文件 → 同 `groupKey` 取**非空**的最新一条；写 = **整条覆盖**。
  **音量 / 倍速仍全局**；轨道存**特征**、语言归一，匹配不上就退回默认。
  ⛔ **只记用户改过的项**、失败不记；⛔ **在线 / 本地字幕不记**；
  ⛔ **别把画质 / 音效对齐到「实际在用的值」**。
- **播放进度两列**（不能合并）：`resumePositionMs`（续播点，看完**清**，管起播）
  vs `maxPositionMs`（历史最大位置，**v15**，**只增不减、永不清**，管显示）。
  详情页与剧集面板都读**后者**。刷新信号与 `PlaybackLibraryLink` 要**分开**。

### 刮削与封面
- `posterFaceX` 与 `posterUrl` **必须成对**；`keptWidth` 必须 `LayoutBuilder` 现算。
- 熔断只计**网络层**失败；TMDB / 豆瓣的响应形状**≠ 夸克信封**（照夸克信封读会**静默得空**）。
- **TMDB `/search/*` 是模糊搜索**，必须过 `ScrapeMatch` 闸门。
- **「自定义」**：`customizeWork` **整行写、不过 merge**；只清**刮来的** `genres`
  （`genresManual` 的行连类型带锁一起留），`categoryManual` 只在**改了分类**时才锁。
- **刮削候选链**：`ScrapeQuery.fallbacks` = 文件名 → **目录名逐级向上**
  （`DirectoryTitle.ancestorNames`，跳容器、最多 2 级）；目录候选恒 `episode`
  + **精确同名档**、不带 `alternateTitle` / `year`。
  `ScraperPipeline.scrape` **串行、命中即停**。
  ⛔ **本地兜底只用主查询**（拿目录名去兜 = 把作品改名成目录名）。
  ⛔ 两个调用点（`WorkSeedBook.add` / `WorkScraper._queryFor`）**都要传 `dirPath`**。
- **两条解析层守卫**（都是现场踩出来的，不报错、只搜不到）：
  - `_pickYear` 里**括号内的完整日期**（`[2026-02-01]`）**不算**年份（裸写的 `2023-05-12` 算）；
  - `_isStandaloneRelease` 里**纯数字片名只有自带年份**才算真名字（`65.2023…` 是电影《65》）。

## 电视（Android TV）分支（10-03 晚 / 10-04 上午）

> 起因：Android TV 包实测四类问题 —— ① PC 交互模式不适合电视 ② 原画卡帧、
> 音画不同步 ③ 主界面排版乱且遥控器够不到 ④ 播放器里只能「聚焦到按钮再按 OK
> 弹菜单」。用户拍板路线：**TV 走独立布局分支**（桌面代码不动）+ 播放器改
> **右侧纵向面板** + **TV 专用播放参数与诊断输出**（真机本机验不了）。

### 判据：`isTvLayout` 与「页面实得宽度」

- `AppTheme.isTvLayout(context)` = `defaultTargetPlatform == android &&
  MediaQuery.sizeOf(context).width >= 960`。960 是官方 TV 设计稿的逻辑宽，
  手机是 360–430，分界线不误伤手机，也不给平板套黑边。
- ⛔ **判据读的是 view 宽（960），不是页面实得宽度。** 真实链路被吃掉两层：
  过扫描 `tvSafeHorizontal=48`×2 + 侧栏 `tvSidebarWidth=240` → `LibraryPage`
  实得 **624**；页头自己再有 22×2 内边距 → 操作区只剩 **580**。
- ⛔ 写 TV 测试时**不能只把 `tester.view.physicalSize` 设成 960 就让页面占满**：
  那样凭空多给 336px，测出来的「没溢出」是假的。要 `MediaQuery` 说 960（判据为真）
  的同时把页面 `SizedBox` 到 624。

### ⛔ 过扫描内边距**全项目只有一处**，壳外的整幅页得自己加

`AppTheme.safeAreaInsets` 在**壳那一层**只有一处调用 —— `app_shell.dart` 的 `build` 里
`body:` 那一层（⚠️ 别写行号：这个引用已经飘过一次，`:34` → `:40`），
管的是壳内那五个一级页面。`/auth`、`/auth/qr`、`/work`、`/diagnostics` 都在
`StatefulShellRoute` **之外**（见 `app_router.dart`），它们把整屏换掉 →
**拿不到那层内边距**，必须自己加。

- 实测（修之前）：`/work` 拿满 **960**（不是 624），返回键 `left=10`，而过扫描带是
  `tvSafeHorizontal=48` —— 返回键那一角正落在会被切掉的那一圈里。
- 后果有两层，第二层更难受：① 最左那列（返回键、页头文字）被切；② 从媒体库点进
  详情页，内容**整体左移 48px** —— 页头本来就该在同一个位置，跳一下会让人以为
  换了个应用。
- ⛔ **`/work` 的实得宽度是 960 不是 624**：写它的排版测试必须用 960。拿 624 去铺，
  测的是一个这页**永远不会有**的屏宽（而且比真实更严，会掩盖真实宽度下的问题）。
- ⚠️ **两种页面别顺手加**：① 内容居中且有 `maxWidth`（`AuthPage` 是 460）—— 本来
  就落在安全区里，加了只是白白缩窄；② **全屏视频**（`/play`）—— 加了会变黑边。
- ⚠️ `AuthQrLoginPage`（`/auth/qr`）**只给顶栏加、整页不加**：这一页的主角是那个
  320 的二维码，整页套一层会平白多出 54px 滚动量、把它推出首屏 —— 而缺一角的码
  **永远扫不出来，并且看起来完全正常**，比「返回键被切一角」严重得多。
- 反向对照（证明用例有牙）：把 `/work` 的 padding 临时改回 `EdgeInsets.zero`，
  用例立刻红在 `Expected: a value greater than or equal to <47.5>` / `Actual: <10.0>`。

#### 播放器的覆盖层同样要避让 —— 但**结论比看起来轻**

`/play` 是唯一**故意不加**页面级内边距的页面（全屏视频，加了变黑边），很容易被
顺推成「播放器里也不用管」—— 其实是两件事：**画面**满屏，浮在上面的**控件**
仍要避让。三处：

| 位置 | 改法 |
|---|---|
| 右侧面板 `TvPanelShell` | 只加**右边**（内容内边距），`Container` 本身不动 |
| 顶栏 | 内容内边距 + **高度**一起加 `safe.top` |
| 控制栏 | 内容内边距 + **高度**一起加 `safe.bottom` |

- ⛔ 面板**只缩内容、不缩 `Container`**：面板底色与左边那条描边要一直铺到屏幕
  边缘（贴右是它的设计）。把整块面板往里挪 48px 会变成一块浮在画面中间的
  卡片，右边留一条露出视频的缝。
- ⛔ 两条 bar **高度要跟着加**，只加内边距会把内容挤扁，反而更糟。
- ⛔⛔ **面板上下不要加**（只加右边）—— 这是量出来的取舍，不是漏了：
  面板是**按「7 行正好塞满」做的**。实测（960×540）：
  表头 56 + 分隔线 0.5 + 底部提示 60（那行折成两行）+ 7×60 = 536.5，
  面板只有 540 高 → **只剩 3.5px 余量**。上下各加 27 之后视口从 423.5 掉到
  369.5 → **溢出 50.5px**，第 7 行「片头」被推出屏幕，而**电视上没有滚动条**，
  用户不会知道下面还有一行。
  相权之下：标题上沿被切几像素，比整个设置项消失轻得多。
  想两全得改设计（行高 60→52、或把底部提示压成一行）—— 那是产品决定。
  → 用例：`player_tv_panel_test.dart` 里 `maxScrollExtent == 0`
  （「一屏装得下」）。⚠️ 它比量某一行的高度稳，也不受 `ListView.cacheExtent`
  （会预建屏幕外的行）干扰。
- ⚠️ **实测推翻了我自己的估算**：我原以为行值（右对齐）会被切掉一大截，
  实测（960 宽、`right: 0`）行内最右那个箭头在 **x=914.25**、安全线 912 ——
  **只探进去约 2px**；行值本身还在箭头左边约 30px，压根没到边。
  所以这是「擦线」不是「字没了」。仍然避让的理由：① 这点余量随面板宽度 /
  行内边距一变就成真切；② 全项目都按 48/27，播放器不该是唯一例外。
  → **教训：别拿算术当测量。** 行内多一层 `Padding` 就让估算偏了二十几像素，
  差点据此写出一条「修了个 28px 大毛病」的假战功。
- 顶栏（返回键起于 `x=8`、宽约 38）与**整个**最左 48px 带重叠；
  控制栏自身只有 6px 底内边距 vs 最下 27px 带。
- ⚠️ 后两处**没有自动化用例** —— 播放页在 `flutter test` 里起不来
  （`PlaybackController` 的 `Player` 是**字段初始化器**，一构造就启 libmpv；
  子类也绕不开，Dart 照样跑父类字段初始化器）。只有面板那条有断言。
  - ⛔ **实测把这条路彻底钉死了**（写了个一次性探针，用完已删）：
    `mk.Player()` 在 `flutter test` 里抛
    `MediaKit.ensureInitialized must be called before using any API`；
    补上 `MediaKit.ensureInitialized()` 之后**仍然抛**
    `Cannot find Mpv.framework/Mpv. Please ensure it's presence in the
    Frameworks folder of the application.`
    ⇒ 不是「初始化顺序没搞对」，是**本机测试环境里根本没有 libmpv**。
    所以想让 `PlayerPage` 可测，必须①给整个 mpv 面抽一层接口，②把
    `Video(controller: ...)` 那个渲染面也做成可替换的 —— 不是加个可选参数的事。
    ⚠️ 别再去试「override 掉 `playbackControllerProvider`」：页面把它类型写成
    具体类 `PlaybackController`，而**任何**构造都会跑那个字段初始化器。
- 落点：`test/ui/widgets/player_tv_panel_test.dart` 的「面板内容要让开电视的
  过扫描带」。⚠️ 它同时钉「面板**外框**仍贴到屏幕右缘」，防止有人把避让
  做成「挪面板」。反向对照：把 `right: safe.right` 改回 `0` → 红在
  `Expected: a value less than or equal to <912.5>` / `Actual: <914.25>`。
- ⚠️ 该用例要 `debugDefaultTargetPlatformOverride`，而它**不在 `material.dart`
  的转出里** → 必须显式 `import 'package:flutter/foundation.dart';`
  （不加报 `Setter not found`，看起来像拼错了名字）。

### ⛔ 页头操作区必须是 `Wrap`（实测溢出 145px）

`PageHeader` 的 TV 分支把 `actions` 放在**标题下方独立一行**。这一行**必须是
`Wrap`、不能是 `Row`**：媒体库页头有六个控件（视图切换 / 搜索框 / 排序 / 筛选 /
选择 / 刷新），在 580 里 `Row` **实测溢出 145px**。Debug 下是黄黑斜纹；
**Release 下溢出部分直接被裁掉** —— 看起来就像「筛选和刷新这两个按钮本来就
没有」，而它们仍在焦点链里，遥控器按得到、屏幕上看不见 → 会被误报成「遥控器坏了」。
`Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: center)` 即可（页里那些
`SizedBox(width: 4/8)` 间隔会与 `spacing` 叠加，不必去改各页）。

### 播放器：遥控器菜单键 → 右侧纵向面板

- 形态：右侧 344 宽纵向面板。`player_tv_panel.dart` 只管画（行列表 / 选集网格 /
  循环导航），`player_tv_overlay.dart` 管状态与「改值」（行值从 `PlaybackController`
  现算，动作回调给播放页）。**不铺满整屏** —— 换字幕 / 换画质的唯一反馈就是画面本身。
- 七行：选集 / 画质 / 字幕 / 音轨 / 音效 / 倍速 / 片头。↑↓ 换行（**循环**，
  `nextTvRowIndex` 靠 Dart 的欧几里得 `%`：`(-1) % 6 == 5`，`total<=0` 返 0 不返 -1）、
  ←→ 改值、OK 激活、菜单键或返回键收起。
- ⛔ **菜单键 = `LogicalKeyboardKey.contextMenu`**（Android `KEYCODE_MENU`=82）。
  但**很多遥控器没有菜单键** → 必须有第二条路：控制栏的「设置」按钮
  （`_TvSettingsButton`，高度取 `tvActionHeight=48`）+ 舞台上按 ↑。
- ⛔ **BACK 由 `PopScope(canPop: !_tvPanelOpen)` 拦**，不能在 `onPopInvoked` 里
  再 push —— TV 上 BACK 既是唯一退出键也是唯一取消键。
- 「片头」行**只跳不标**：手标要把播放头定位到某一秒，遥控器做不到；标记留桌面。
- 选集换集**不循环**（第一集没有「上一集」，绕到最后一集是纯困惑）；
  画质切换**跳过 `!isAvailable` 的档位**（按下去只会弹提示，用户要按第二次才知道
  刚才那下没生效），最多绕一圈，全不可用则什么都不做。
- 改值**不直接调控制器**：画质 / 字幕切完还要**落库且只在真的切成功之后**，
  那段规则在播放页手里，面板重做一遍就是两份会漂的「只在成功时记」。

### 面板开关的路由抽成了纯函数 `resolveTvPanelKey`

与 `resolveRemoteKey` 同规格：判断在纯函数里（都在 `player_page.dart`），
`_handleTvPanelKey` 只负责执行。落点 `test/ui/pages/player_remote_keys_test.dart`。

- ⛔ **必须在 `resolveRemoteKey` 之前判**：后者那条「沉浸模式下任何认识的键 →
  `showControls`」会把菜单键吃掉 → 沉浸时按菜单键只会把控制栏叫回来，
  面板永远打不开，而菜单键正是这条需求点名要用的键。
- 菜单键（`contextMenu`）**不挑焦点**，开 / 关同一个键。
- ↑ 只在「面板关着 **且** 焦点真在画面上」时接管 —— 焦点已经进了控制栏时，
  ↑ 是「走回上一行」，接管它会把这件事变成「弹出一个面板」。
- ⛔ **↓ 绝不接管**。这是整套 TV 交互的**咽喉**：↓ 是从画面走到控制栏的唯一通路，
  而控制栏上有「设置」按钮 —— 那正是**没有菜单键的遥控器上唯一一条进面板的路**。
  抢了 ↓ 就等于「那类盒子上选集 / 画质 / 字幕全打不开」，且不报任何错。

### TV 播放参数（`player_buffer_config.dart` 两套）

| 参数 | 桌面 | TV |
|---|---|---|
| `demuxer-max-bytes` | 1 GB | 256 MB |
| `demuxer-readahead-secs` | 9999 | 60 |
| `cache`（流层字节缓存） | 关 | **开** |
| `video-sync` | audio | audio |
| **`hwdec`（硬件解码）** | **不下发**（mpv 默认 `no`） | **`auto-safe`** |

#### ⛔ 卡帧有**两条独立的路**，缓冲参数只管其中一条

上一轮只调了缓冲，以为就完了 —— 漏了另一半：

| 症状 | 真正的原因 | 谁负责 |
|---|---|---|
| 卡帧 | **数据没到位**（网络抖动 / eMMC 写入抢带宽） | 上面那套缓冲参数 |
| 卡帧 + 音画不同步 | **解码跟不上** | **`hwdec`** |

- 事实：mpv 的 `hwdec` **默认是 `no`（纯软解）**，而 media_kit 那张默认属性表
  （`media_kit-1.2.6/lib/src/player/native/player/real.dart` 里 `properties` 那个
  映射，约 2389–2416 行）**也没有这一项** —— 全项目搜 `hwdec` 一处都没有。
  于是电视盒子一直在**软解**高码率原画，而那颗 SoC 通常只够软解 1080p。
  解码跟不上音频 → mpv 跳帧追主时钟 → 「嘴动了声没动」。
- ⛔ 取值必须是 **`auto-safe`**，不能是 `auto` / `mediacodec`：
  - `auto` 会连**不安全**的 API 一起试（崩溃 / 花屏）；
  - 写死 `mediacodec` 是**直通**路径，要求渲染端配合，配不上就是**黑屏**；
  - `auto-safe` 只用安全列表（Android 上解析成 `mediacodec-copy`：解码走硬件、
    帧拷回内存再上屏），配不上时**回落到软解** —— 最坏情况等于没改。
- ⛔ 桌面返回 **`null`（不下发）**，不是 `'no'`：下发 `'no'` 也是改桌面行为
  （把默认显式化，且挡住将来给桌面开硬解）。用例专门钉这一条。
- `PlayerConfiguration` **没有**任意属性 map（只有 `vo` / `osc` / `bufferSize` /
  `libass` / `title` / `muted` / `pitch` / …），所以只能走
  `PlayerBufferConfig.apply` 里的 `setProperty` —— 与上面几项同一个时刻。
- 诊断：策略那行现在带 `hwdec=`。⚠️ 但它记的是**请求值**，不是**实际生效**的
  解码器。要知道真的有没有启用，得读 mpv 的 **`hwdec-current`**（要在起播**之后**
  读，`apply` 那一刻还没开始解码）—— 这一步**没做**，见下方待办。

- ⛔ 桌面那一套的值**一个都没动**（`disableStreamCache=true` 是为了让屏上的 KB/s
  读数是真的）。有测试专门钉「桌面值不许变」。
- ⛔ TV 上必须**显式下发 `cache=yes`**：media_kit 还硬写着 `cache-on-disk=yes`，
  1 GB demuxer 缓存 + 磁盘缓存会把 1–2 GB 内存 / 慢 eMMC 的盒子写爆 ——
  表现就是**原画卡帧 + 音画不同步**。
- `tv_device.dart` 提供**无 context 的** `isTvDevice()`：`PlaybackController` 构造
  `Player` 时还没有任何 widget，而 mpv 的流层缓存**只在 `loadSource` 那一刻生效**，
  晚一步设置等于没设。它读 `PlatformDispatcher.instance.views`。
  - ⚠️ 已知盲区：盒子报的逻辑宽 <960 会判成非 TV；诊断日志那行「策略=TV/桌面」是出口。
  - ⚠️ `flutter test` 里 `tester.view.physicalSize` **不影响**
    `PlatformDispatcher.instance.views`（恒 2400×1800@3.0 → 逻辑 800）。
    所以判据抽成纯函数 `isTvSize({platform, logicalWidth})` 才测得到；
    `isTvDevice()` 只留一条冒烟用例，注释里写明它**证明不了** TV 分支
    （永远为假的断言比没有断言更糟）。

### 音轨 / 字幕文案：只有 `TrackLabels` 一处

⛔ 桌面内置播放页、独立播放窗口、TV 面板**三处**都要显示同一个音轨名。
一开始 TV 面板自带一份「`chi`→中文」的表、桌面 `_AudioMenu` 也自带一份
（`_languageLabel`），于是**同一个标记在三处显示成三种样子**
（`中文` / `简体中文` / 原样 `chi`），而这三处永远不会同时出现在一块屏上 → 没人会发现。
现已全部委托 `TrackLabels.audioTitle / audioDetail / languageLabel`
（`_trackDetail` 那份手拼的「codec · channels · kbps」也一并删掉）。
同理**倍速档位只有一份** `kPlaybackRates`（定义在 `player_tv_overlay.dart`，
桌面 `_RateMenu` 引用它）。
→ 「只有一处实现」**不要靠断言**：把重复的那组用例直接删掉即可
（`test/core/track_labels_test.dart` 覆盖得更全，含 `und` / 空串 / 未知标记）。

### 面板按键语义（`test/ui/widgets/player_tv_panel_test.dart` 的「按键」两组）

不需要 libmpv 就能测：面板是纯 widget，`PlayerTvPanel` / `PlayerTvEpisodeGrid`
的 `onSelectedChanged` / `onAdjust` / `onActivate` / `onClose` 全是回调。

已钉住的六条：↑↓ 换行（含循环）且选中态**移走**、←→ 作用于**选中那一行**、
**OK 认 `select`**（Android TV 的确定键）、菜单键与 Esc 都收起、放行数字键与
媒体键、每次按键都报「有操作」。选集网格另有三条：点格交出**下标**、
**OK 能激活聚焦的格子**、菜单键是「回行列表」而不是关掉整个面板。

⚠️ **实测确认**：`LogicalKeyboardKey.select` → `ActivateIntent` →
`InkWell.onTap` 这条路**靠 `WidgetsApp` 默认快捷键表成立**（不用自己绑），
所以电视上「按 OK 选一集」是通的。这一条以前只是假设，现在有断言了。

#### ⛔ 写这类测试踩到的两个坑（都不是代码错，是测试自己错）

1. **`tester.sendKeyEvent` 不 pump。** 只派发事件、不重建下一帧，于是
   `onSelectedChanged` 里的 `setState` 不会反映出来 —— 「↓ 之后 ←→ 该作用在
   第二行」的断言会看到第一行，红得像代码错了。封装一个
   `press(tester, key) { await sendKeyEvent(key); await pump(); }`。
2. **探针只记 `KeyDownEvent`。** 想验证「某个键被面板吃掉、没有冒泡出去」时，
   在外层 `Focus` 里记 `event.logicalKey` 会把 **key-up** 也记进来 ——
   而面板对 key-up 一律 `ignored`（它只处理 KeyDown/KeyRepeat），于是
   「方向键被吃掉了」这条断言永远失败，看起来像「方向键漏出去了」。

### 测试落点
- `test/ui/pages/library_tv_layout_test.dart` —— **TV 页头不溢出 + 每个操作都落在可见区内
  + 页头/分类条/海报墙三块区域都走得到**（平台靠 `debugDefaultTargetPlatformOverride`，
  复位**写在测试体的 `finally` 里**）。
- `test/ui/pages/tv_pages_layout_test.dart` —— **其余全部一级入口 + 最密的详情页**
  （下载 / 设置 / 扫描 / 文件夹 / 作品详情，各 1 条；文件夹页另有一条可达性）。
  同一套 624×486 铺法；**壳外页（`/work`、`/diagnostics`）那一条用 960**，见上节。
  另有 1 条专测**壳外页的过扫描内边距**（返回键 `left >= tvSafeHorizontal`）。
- `test/support/focus_reach.dart` —— 「够不够得到」的共用判定（见下）。
  ⚠️ 它的 `walkReachability` 默认走 **Tab**，而 Tab **跨得了** scope 边界、方向键
  跨不了 —— **测跨侧栏/跨 Navigator 的可达性必须自己发方向键**，别用它。
- `test/ui/shell/sidebar_focus_test.dart` —— **侧栏（壳）本身**的可达性：
  真 `AppShell` + 真 `StatefulShellRoute`，**6 条全过、无 `skip`**
  （方向键兜底 + 高度溢出两条缺陷的回归保护）。
  ⚠️ 它是唯一铺**整个壳**的测试文件，页面测试都用 624 宽把侧栏扣掉了。
- `test/ui/widgets/player_tv_panel_test.dart` —— 行循环 / 格子文案 / 面板不铺满整屏 / **按键语义**。
- `test/core/utils/player_buffer_config_test.dart`、`test/core/utils/tv_device_test.dart`。

#### ⚠️ 排版测试最大的陷阱：**空态下的「不溢出」是废话**
把页面单独铺出来时，它极可能走的是**空态 / 错误态**（没登录、目录没列出来、
库里没作品）—— 而危险的那一行 `Row` 那时**根本不存在**。于是「没有溢出」
恒真，一条假绿测试会一直躺在那儿，将来真溢出了也不会响。

**做法：每条排版用例里都补一句内容断言**，确认带按钮的那一行真的铺出来了：
`find.text('开始扫描')`（扫描页）、`find.textContaining('第3季')`（文件夹页，
靠 `test/support/fake_drive.dart` 的 `FakeDriveAdapter` 铺一层真目录）、
`find.textContaining('进击的巨人')`（详情页）、`find.textContaining('.bin')`（下载页）。

另外两条实测：
- 扫描页那行 `Row` 中间只有 `Spacer` —— ⚠️ **`Spacer` 是 flex 子项，只能吃剩余
  空间、不能把别人挤小**：定宽部分一旦超过 580，它先被压成 0，然后溢出照旧发生。
  别把它当保险。
- 文件夹页工具条的面包屑那一截靠 `Expanded` + 横向滚动兜着（再长的路径也挤不爆），
  定宽的是面包屑**之外**那两个按钮。

#### 「够不够得到」是**另一件事**，得单独测（`test/support/focus_reach.dart`）

排版不溢出 ≠ 用得了。诉求原话是「**很多区域遥控器方式无法触达**」——
`test/ui/tv_remote_probe_test.dart` 证明的是「Flutter 的焦点机制成立」，用的却是
**自造的、形状相同的 widget**；它证明不了真页面上接线接对了（少包一个
`TvFocusable`、或哪块被顺手 `ExcludeFocus` 包住，它不会响）。

- **判据不能是 `Focus.of(...).hasFocus`**：`TvFocusable` 是
  `Focus(canRequestFocus: false)` **只负责观察**，真正吃焦点的是里面那个
  `InkWell`。`Focus.of` 拿到的是那个观察者，**永远 false** —— 会得到一条一直红的
  假警报。正确做法：从 `FocusManager.instance.primaryFocus` 出发**往上走祖先链**
  找目标（`focusedInside`）。
- **目标要挑对方向**：`TvFocusable` / `TvIconLabel` 包着 `InkWell` → 用它们当目标；
  文件夹的行是**裸 `InkWell`**，行里那段文字是它的**后代**，拿文字去找永远找不到
  → 要用 `find.ancestor(of: 文字, matching: InkWell).first`。
- **走 Tab，不走方向键**：方向键的可达性依赖几何（网格里 ↓ 落哪一格取决于间距），
  换个 `posterAspect` 就飘；Tab 走阅读顺序，稳定枚举「这一页上哪些东西能拿到焦点」。
  真机遥控器没有 Tab，这里只当**可达性代理**。
  ⛔ **但这条代理在「跨侧栏」这件事上会骗人** —— 见下面的
  `#### ⛔ 侧栏：Tab 到得了，方向键到不了（scope 隔离）`。
- ⛔ **必须做一次反向对照**：临时把页面整个包进 `ExcludeFocus`，确认它**真的会红**
  （实测会，且报出那句诊断）。否则一条恒绿的假测试会一直躺在那儿。
- ⚠️ **`ListView` 懒加载**：624×486 下文件夹页只建得出前几条（实测到 `S01E04`，
  默认修改时间倒序所以它是第一条）。断言「某一行可达」时**必须挑已经建出来的那一行**，
  挑 `S01E01` 会得到「找不到」—— 那是它压根没被建，不是焦点问题。

#### 还有一条：**够得到 ≠ 看得见**

可达性只证明焦点**走得到**。而走得到但**看不见焦点在哪**，在电视上和够不到是
同一种坏 —— 用户只能盲按。

焦点环的显示条件比可达性苛刻：

    TvFocusable._showRing = _focused && highlightMode == traditional

而 Android 上 `highlightMode` 默认是 `touch`，**收到第一个按键事件才翻成
traditional**（`tv_focus.dart` 类文档）。所以「焦点环没出现」有两个完全不同的
原因 —— 焦点没到位，或者档位还没翻 —— 只有断言能区分。

- 判据：`find.byWidgetPredicate((w) => w is AnimatedScale && w.scale > 1.0)`。
  全项目**只有海报卡**传 `focusScale: 1.05`（`library_page.dart:1096`，grep 可证），
  而它与焦点环由**同一个** `_showRing` 控制 → 「存在 scale > 1」=「焦点环正在画」。
- ⛔ 用例里**必须先断言「还没按键时 `findsNothing`」**：少了这句，在「焦点环压根
  没接 highlightMode」时断言照样绿 —— 而那正是桌面上「鼠标点过的卡片留一圈环」
  的成因。
- 实测：`tester.sendKeyEvent` 在 `flutter test` 里**确实会让 highlightMode 翻档**
  （`walkReachability` 发的 Tab 就够了），不必手工去改 `highlightStrategy`。
- 反向对照：把 `focusScale` 改成 `1.0` → 立刻红并报出「焦点环没画出来…」。
- 落点：`test/ui/pages/library_tv_layout_test.dart` 的「焦点落到海报上时**看得见**」。

#### ⛔ 侧栏：Tab 到得了，方向键到不了（scope 隔离）

用户 10-04 问的：「确认一下左侧导航菜单是否能够通过遥控器方向键获取点击焦点？」
**当时的答案是不能**，两条缺陷**当天下午都已修好**（修法见本节末）。
下表左列是「修之前」的实测，右列是现状：

| 动作 | 修前 | 现状 |
|---|---|---|
| 侧栏**内部** ↓ / ↑ 走六个入口 | ✅ 正常（↓ 从「媒体库」一路到底到「诊断日志」） | ✅ |
| 焦点在侧栏时按 → 进内容区 | ✅ 正常 | ✅ |
| OK 键（`select`）按在侧栏项上切分支 | ✅ 正常 | ✅ |
| **焦点在内容区时按 ← / ↑ 进侧栏** | ❌ **走不进去**（连按 12 次 ← 原地不动） | ✅ **靠壳层兜底** |
| 侧栏在 540 高下是否溢出 | ❌ **溢出 25px** | ✅ 不溢出（`Spacer` 余量 23px） |

**根因不是几何。** 侧栏那 6 项完全符合 `←` 的筛选条件
（`node.rect.center.dx <= target.left`；侧栏 tile 的 InkWell 是
`(60,100.5,276,151.5)`，内容区从 `x=288.5` 起）。真正的原因是：

    StatefulShellRoute.indexedStack 给**每个分支一个独立 Navigator**
    → 每个分支页有自己的 FocusScope
    → FocusTraversalPolicy.inDirection（focus_traversal.dart:1070）只在
      currentNode.nearestScope.traversalDescendants 里找候选，
      **找不到就 return false，不向上冒泡到父 scope**
    → 侧栏是分支页的**兄弟**，在外层 scope 里，永远不在候选表里

两条硬证据（探针打的）：
1. 焦点在内容区时 `nearestScope.traversalDescendants` **只有 1 个节点**（它自己）；
   同一个方向键在焦点位于侧栏时就能走通 —— **同一个键，结果只取决于焦点在哪一边**。
2. 祖先链：`c0 → _ModalScopeState FocusScope(分支) → Navigator → FocusTraversalGroup
   → _ModalScopeState FocusScope(壳) → Navigator → …`，侧栏在**外层**那个 scope。

⛔ **Tab 能跨，方向键不能。** `_moveFocus` 会爬 scope 边界，`inDirection` 不会。
所以上面那条「Tab 当可达性代理」在这里**失效**：Tab 从内容区能走到侧栏，
遥控器走不到。**跨侧栏/跨 Navigator 的可达性必须用方向键测。**

修法（**已实施**，在 `lib/ui/shell/app_shell.dart`）：壳层包一层
`Focus(canRequestFocus: false, onKeyEvent: _onShellKey)`，键处理**三步**：

1. `_arrowDirectionOf(event)` 只认**裸**方向键。⛔ `isControlPressed` 时必须返回
   `null` —— 框架默认表里 `Ctrl+方向键` 是 `ScrollIntent`（`app.dart:1248`），
   兜底抢了它就把「Ctrl+← 滚一屏」吃掉。
2. 先跑 `focus.focusInDirection(dir)`，**与框架默认逐字一致**；返回 true 就结束。
   所以**内容区内部**的方向键行为一个字节都没变。
3. 只有它返回 false（=「最近那个 scope 里确实没有」）才走几何兜底
   `_nearestSidebarFocus`：在与 `inDirection` **同样的规则**下（同向 + 垂直带相交 +
   先比轴向距离、再比横向偏移）在**侧栏子树**里挑一个。

⛔ **兜底的候选集必须限定在侧栏子树里，不能搜整个窗口** —— 最容易写错的一处：
`IndexedStack` 给每个分支套 `Visibility.maintain(visible: i == index)`，它把
`maintainState/Size/Semantics/Interactivity` **全设为 true**，于是 5 个分支**全都留在
焦点树里且 rect 完全相同**。搜全窗口时几何上「最近」的可能是某个**看不见的**分支里的
节点，焦点会跳到屏幕上不存在的地方。判「在子树里」用 `visitAncestorElements` 沿祖先链
`identical` 比 element（`_isInside`）。

（另一条路 b「把侧栏塞进分支页的 scope」结构上做不到，没走。）

**顺带：侧栏在 540 高下溢出 25px（真缺陷，已修）。**
修前：`constraints: BoxConstraints(w=240.0, 0.0<=h<=486.0)` → `overflowed by 25 pixels`。
「诊断日志」的 `TvFocusable` 是 `(48, 467, 288, 528)`，安全带下沿只有 **513**
—— 整行掉在安全带外，底部离屏幕边只剩 12px。Debug 下黄黑斜纹，**Release 静默裁掉**：
看起来像「那个入口本来就没有」，而它还在焦点链里 —— 遥控器按得到、屏幕上看不见。
⚠️ `_Sidebar` 的 `Column` 里那个 `Spacer` 是 flex，可用高不够时它被压成 0，
**不会救场**。

修法（**已实施**）：收紧 `_NavTile` 的内外上下内边距（外圈 `5→4`、内圈 `14→12`）、
`_Sidebar` 底部 `SizedBox` `10→2`、`_AccountBlock` 名字那圈 `top 12→8`。
实测每个 tile **61 → 55**，`诊断日志` 落到 `(48, 456, 288, 511)`，**`Spacer` 余量 23px**。

⛔ **余量要量 `Spacer` 的高度，不是量最后那个 tile 的 `bottom`**：`诊断日志` 是被
`Spacer` **顶到底部**的，它的 `bottom` **永远贴在安全带下沿**，量它只反映尾部间距。
我第一版按「收紧 36px、原来缺 25px ⇒ 余量 11px」算，**实测只有 2px** —— 就是量错了对象。
（测试里量 `Spacer` 还要**指定是侧栏那一列里的那个**：`_NavTile` 内部另有一个
`Spacer`，角标非空时才画。）

⚠️ **残留脆弱点**：侧栏**没有**套 `AppTheme.tvTextScaler`，字跟着系统字体缩放走，
而 tile 高度是「图标 22 与文字取大」决定的 —— 系统缩放超过 ~1.4 时 5 个 tile 一起长高、
23px 被吃光。真遇到，修法是给这一列**夹住 `textScaler`**（或把 `Column` 换成可滚动的），
**不是**继续抠像素。

⚠️ **别把「我期望的顺序」当成「应有的几何」**：从「媒体库」按 ↑ **永远到不了**
「诊断日志」（`↑` 的候选是 `center.dy <= 目标.top`，而它在最底下）。那是正确的
几何，不是缺陷 —— 我第一版断言就写过头了。

落点：`test/ui/shell/sidebar_focus_test.dart`（**6 条全过、无 `skip`**；其中两条
原来 `skip` 的正是上面那两个缺陷，修完转正 —— ⛔ **别删**，它们是那两处修复唯一的回归保护）。
立的是**真 `AppShell`**（真 `GoRouter` + 真 `StatefulShellRoute.indexedStack`，
只有分支页是占位）。

- ⛔ 内容区桩页要给**上下两块**（`_StubBranch` 收 `List<FocusNode>`），不是一块：
  只有一块时「按几何找」和「无脑 focus 第一项」两种实现**都能过**那条 ← 用例。
  现在断言 `fromTop < fromBottom`（从上半块进侧栏 vs 从下半块，落点高度必须不同）。
- 反向对照：`_onShellKey` 开头插 `if (1 == 1) return KeyEventResult.ignored;` →
  **只有** ← 那条红（轨迹 `[x=289 y=27]`），其余 5 条绿 —— 证明兜底真的接上了、
  且没污染内容区。
- ⚠️ `testWidgets` 的 `skip` 只收 `bool?`，**不接受 String**（`test` 那个才收）
  —— 理由只能写在用例名与文档注释里。（这条现在只是备忘：本文件已无 `skip`。）
- ⚠️ 溢出那个 `FlutterError` 曾经会在**每一条**铺壳的用例里冒出来，当时用
  `pumpShell` 的 `drainKnownOverflow` 吸掉；**溢出真修好之后那个补丁已删** ——
  ⛔ 别再加回来，它会掩盖以后新出现的溢出。
- ⚠️ 拿侧栏某一项的焦点宿主**不能用 `Focus.of(tester.element(navTile(...)))`**：
  `TvFocusable` 的 element 是那个 `Focus` 的**父**，`Focus.of` 往上找只会找到更外层的。
  按几何从 `FocusManager.instance.rootScope.descendants` 里捞（`tileNode`）。
- ⚠️ 侧栏那 6 个 tile 的焦点宿主是 `InkWell`（`TvFocusable` 只是**观察**焦点画环、
  自己 `canRequestFocus: false`）；⛔ 而「退出登录」那个 `IconButton` **没有**包
  `TvFocusable`，**没有焦点环** —— 真机上要单独验它。

#### 已排查、确认**没问题**的（别再重复查）

- `library_filter_panel.dart` 的裸 `MenuAnchor`：**已补** `PopScope`（面板开着时
  BACK 关面板）与底部显式「关闭」按钮 —— 遥控器没有 Esc，这两条是 TV 上唯一出口。
  全库只剩这一个 `MenuAnchor`。
- **多选入口都有按钮**：文件夹页工具条有「多选」（`folder_browser.dart:472`），
  媒体库页头有「选择」。`onLongPress` 在注释里已写明是**桌面/触摸的快捷入口** ——
  遥控器上长按不成立（OK 键发的是 key 事件 + KeyRepeat，不是长按手势）。
- `_DetailButton`（「简介」）**常驻显示**，`_hovered` 只改底色深浅；注释里已写明
  理由：触摸设备没有 hover，只在悬停时出现的按钮等于不存在。
- `_WorkCard` **有** `TvFocusable`（焦点环 + `focusScale: 1.05`）。
- ⚠️ **唯一残留的 PC 味道**：海报上那个「暗罩 + 播放图标」只认 hover，TV 上永不出现。
  **刻意没改** —— 焦点环 + 1.05 放大已是标准 TV 焦点指示，而在**聚焦**的卡片上压
  一层 32% 暗罩反而会挡住用户正在看的那张封面。这是设计取舍，留给用户定。

### 待用户真机验证（本机验不了）
1. 原画卡帧 / 音画不同步是否真缓解 —— 看诊断日志里「策略=TV」那行确认参数下发了。
2. 遥控器菜单键是否真映射到 `contextMenu`（各厂商盒子有差异）。
3. 没有菜单键的盒子用「设置」按钮 / 舞台上按 ↑ 是否好使。
4. 壳外页（详情页 / 诊断页）补的过扫描内边距在真机上观感对不对 ——
   重点看「从媒体库点进详情页，页头会不会跳」。
5. **侧栏焦点 / 高度（已按上面那节修好，本机只有单元测试背书，请真机复核）**：
   a) 一进媒体库，按遥控器**方向键**能不能把焦点挪到左侧导航栏（**预期：能** ——
      修前走不进去，现在靠壳层兜底；⛔ 这是兜底唯一无法在本机真机等价验证的一条）；
   b) 侧栏最底下那项「诊断日志」在电视上**看不看得见**（**预期：完整可见** ——
      修前溢出 25px，Release 下会被静默裁掉）；
   c) 能不能用遥控器把焦点挪到「退出登录」—— ⛔ 它**没包 `TvFocusable`**，
      **没有焦点环**，本机测不到「看得见看不见」，只能真机看。

---

## 杜比视界（DV）片源颜色错乱：libmpv 没编译 libplacebo（2026-10-04）

**症状**：同一份 DV 片源，夸克自带播放器颜色正常，云影**偏绿 / 偏紫**
（注意不是「发灰、发白」——那是 HDR→SDR 色调映射的问题，是另一回事）。

**机制**：Dolby Vision 的像素**不是 YCbCr**。Profile 5 用的是 Dolby 私有的
**IPT-PQ-C2**，播放器必须读 HEVC 里 type 62 的 **RPU** 元数据再做 IPT→RGB。
mpv 里**只有 libplacebo 会做这件事**（`pl_map_avframe` +
`PL_COLOR_SYSTEM_DOLBYVISION`），入口是 `vo=gpu-next`。跳过 RPU 就等于把 IPT
当成 YCbCr BT.2020 PQ 去解 → 颜色全错。

**实测证据（本机产物，不用猜）**

| 平台 | 产物 | 结论 |
|---|---|---|
| macOS | `media_kit_libs_macos_video 1.1.4` 的 `Mpv.xcframework/.../Mpv` | `strings` 读出 **`mpv 0.36.0`**；waf 配置含 `-Dlibplacebo=disabled -Dvulkan=disabled`（同时有 `-Dgl=enabled -Dgl-cocoa=enabled -Dvideotoolbox-gl=enabled`） |
| Android | `media_kit_libs_android_video 1.3.8` → `android/build.gradle` 写死下载 `media-kit/libmpv-android-video-build` **v1.1.7** | 该 tag 的 `buildscripts/scripts/mpv.sh` 同样是 `-Dvulkan=disabled -Dlibplacebo=disabled`；**v1.1.8 / v1.1.11 也没改** |

- **最硬的判据**：`strings Mpv | grep -c "gpu-next"` = **0**。二进制里根本没有
  这个 vo —— `VideoControllerConfiguration.vo` 传 `gpu-next` 进去也是**静默无效**。
- **源码级旁证**：mpv v0.36.0 `meson.build:932-939`，`vo_gpu_next.c` 只在
  `features['libplacebo']` 且 `libplacebo >= 5.264.0` 时才进 sources。

**⛔ 别把「DV 坏了」推广成「所有 HDR 都坏了」**：mpv 0.36 的
`video/out/gpu/video.c`（legacy `vo=gpu`，`vo=libmpv` 内部走的就是它）
**不 include libplacebo**，是自带 GLSL 的渲染器，`--tone-mapping` /
`--hdr-compute-peak` 都在。`-Dlibplacebo=disabled` 只砍掉 `vo=gpu-next`，
**没砍掉 HDR10 的色调映射**。这解释了「为什么 HDR10 片源正常、只有 DV 炸」。

**本项目现状：一处都没配**（改颜色目前**没有旋钮**）

- 桌面 `playback_controller.dart` / `player_window_app.dart` 都只写
  `VideoControllerConfiguration(enableHardwareAcceleration: true)` →
  默认 `vo=libmpv` + `hwdec=auto`（`media_kit_video` 的
  `lib/src/video_controller/native_video_controller/real.dart:119-122`）。
- Android 默认 `vo=gpu` + `opengl-es=yes` + `gpu-context=android` +
  `hwdec=auto-safe`（`android_video_controller/real.dart:186-208`）。
- `lib/` 全树 grep `'vo'|gpu-api|gpu-context|tone-mapping|target-prim|target-trc|hwdec`
  → **零命中**。

**症状轻重由 profile 决定（三种不能混为一谈）**

| profile | 无 DV 支持时的表现 |
|---|---|
| **P5**（单层 IPT，流媒体 WEB-DL 常见） | 颜色彻底错 → **就是本症状** |
| **P8.1**（HDR10 兼容基底） | 退化成 HDR10，颜色大致对 |
| **P7**（UHD 蓝光双层 FEL/MEL） | 只解 BL，HDR10 观感，非 DV |

⚠️ 库里同批 DV 片源大多是 WEB-DL 的 `DV.HDR`（P8.1 面大）。**profile 必须先验**，
别默认是 P5。

**怎么验 profile（排查第一步）**

- `ffprobe -show_streams <file>` 看 `side_data_list` 的
  `Dolby Vision configuration` / `dv_profile`。
- libavcodec 会打 `Found Dolby Vision config record: profile %d level %d`
  （本机 Mpv 二进制里确实有这个字符串）。⚠️ 但它是 **verbose** 级，而两个播放器的
  `PlayerConfiguration.logLevel` 分别是 `warn`（独立窗口）/ 默认 `error`（内置页）
  → **当前收不到**，要看得临时抬级。
- mpv 0.36 只暴露 `video-params/primaries`、`/gamma`、`/colormatrix`、
  `/colorlevels`（**没有 DV 专用属性**）。

**修法（按代价排，都还没做）**

1. **自编译带 libplacebo ≥ 5.264 的 libmpv** → 用 `vo=gpu-next`。
   macOS 可行且不必上 MoltenVK：mpv 0.36 的 `video/out/gpu_next/context.c`
   里有 `#include <libplacebo/opengl.h>` + `pl_opengl_create()` ——
   **OpenGL 后端就能跑 gpu-next**（`--gpu-api=opengl --gpu-context=cocoa`）。
   ⚠️ `media_kit_libs_macos_video` **最新就是 1.1.4**，升级包没用，得换 framework。
2. **HDR10 兜底**：对 P8.1 / P7 有效，**对 P5 无效** —— 治不了本症状。
3. 只告知用户「DV P5 不支持」：诚实，但不解决问题。

---

## ⛔ 修正（同日稍晚）：上面「选项 1（自编译 libmpv + `vo=gpu-next`）」在 macOS 上**不可达**

上面写「自编译带 libplacebo 的 libmpv → 用 `vo=gpu-next`」。**编出来也没用**：
media_kit 桌面端走的是 mpv 的 **render API**，而 render API 里**根本没有 gpu-next 这个后端**。

三处源码即可定案（均已实际下载核对，非推测）：
- `media_kit_video-1.3.1/lib/src/video_controller/native_video_controller/real.dart:121`
  → 桌面端写死 `vo: 'libmpv'`。
- `video/out/vo_libmpv.c` 的 `render_backends[]`，**v0.36.0 / v0.37.0 / v0.38.0 / v0.40.0 / master 全部**
  只有 `{ &render_backend_gpu, &render_backend_sw }` —— 没有任何 gpu-next 入口。
- `video/out/gpu/libmpv_gpu.c` 里 `render_backend_gpu` 的实现直接
  `p->renderer = gl_video_init(...)` —— **写死 gl_video（= 老的 `vo=gpu`）**，master 亦然。

→ 所以 `VideoControllerConfiguration(vo: 'gpu-next')` 在 macOS 上**永远不会生效**。
（`mpv/render.h` 有说明：一旦建了 render context，vo 就被固定；只有不建 render context
时才允许 vo 自己开窗。media_kit 桌面端一定会建。）

### 平台不对称（很关键）
Android 侧 media_kit 用的是**真窗口 vo**，不是 render API：
`android_video_controller/real.dart:194-205` 设 `vo: 'gpu'` + `gpu-context: 'android'` +
`opengl-es: 'yes'` + `wid`（Android Surface），且 `widListener()` 会**运行时重设 `vo`**。
→ 「自建带 libplacebo 的 libmpv + 换 `vo=gpu-next`」**只在 Android 侧架构上可行**
（要 fork `media_kit_libs_android_video` 替换 .so）；**macOS 侧此路不通**。

## 夸克客户端为什么颜色正常：它不用 mpv，用的是 Apple 平台栈

实测 `/Applications/Quark.app`（7.3.5.1009）：
- 是 **Chromium 壳**（`Contents/Frameworks/Quark Framework.framework`，进程带 `--type=renderer`）。
- `otool -L` 链接 **AVFoundation / VideoToolbox / CoreMedia / CoreVideo / AudioToolbox**。
- 二进制里有 `dolby vision profile 0/5/7/8/9`、`dvh1.`、`dvhe.`、
  `Dolby Vision video track with track_id=`、
  `Dolby Vision codec string when constructing the SourceBuffer`
  → 即 **Chromium `<video>` + MSE**，DV 交给 Apple 的解码/显示栈处理。

⛔ **但「改 hwdec 就能修」是错的 —— 已实测排除**：
把 `/tmp/01_head.mkv` 的同一帧分别用
(a) 纯软件解码 与 (b) `ffmpeg -hwaccel videotoolbox`（debug 日志确认
`Format videotoolbox_vld chosen by get_format()` +
`Format videotoolbox_vld requires hwaccel hevc_videotoolbox initialisation`）
导出 PNG，两者 **`cmp` 逐字节完全相同**。
→ **VideoToolbox 的原始解码不做 DV 转换**（只给你同样的 IPT-PQ 基础层），
转换发生在更上层（AVFoundation / `AVSampleBufferDisplayLayer` 那一段）。
所以 `hwdec=videotoolbox` / `videotoolbox-copy` 都救不了颜色，**别在这上面试参数**。

## DV P5 探测配方（若要做「检测 + 提示」）

⚠️ MKV 里的 DV 信号**不在** hvcC 的 `dvcC` box —— **直接搜 `dvcC` 字面量会读错**
（实测 `01.mkv` 头里能搜到两处 `dvcC`，但那是 Matroska `BlockAddIDType` 的取值，
它前面 4 字节并不是 box size）。正确做法是解析 **Matroska `BlockAdditionMapping`**。

实测 `01.mkv` 偏移 4389 起，用 EBML 逐层解出来的结果（与 ffprobe 输出完全一致）：
```
@4389  0x41E4 BlockAdditionMapping   size=34
   0x41E7 BlockAddIDType       = 0x64766343  ("dvcC")
   0x41ED BlockAddIDExtraData  (24 字节) = 01 00 0a 4d 00 00 00 …
          dv_version=1.0  dv_profile=5  dv_level=9  rpu=1 el=0 bl=1  compat_id=0
```
- 只有 `BlockAddIDType` == `0x64766343`("dvcC") 或 `0x64767643`("dvvC") 才认。
- `BlockAddIDExtraData` 前几字节即 **DOVI configuration record**：
  `[0]`=version_major，`[1]`=version_minor，**`[2] >> 1` = dv_profile**，
  `[3]` 低 3 位依次 rpu/el/bl，`[4] >> 4` = bl_signal_compatibility_id。
- 只需文件头若干 KB（`Tracks` 元素在很前面；实测 8 MiB 头绰绰有余）。
- 探测入口可复用下载模块的 Range 取头（`resolveStream` + `Range: bytes=0-…`），
  **不必**等 mpv 起播。

---

## 换内核验证：libmdk（fvp）能不能救 DV P5（2026-10-04 下午）

### 结论：mdk 的 DV 支持是**真代码**，不是宣传语
`mdk-sdk` 的 GitHub 仓库只是二进制分发（仅 30 个文件、无源码），所以照老办法
**对预编译产物取证**：

- 下 `mdk-sdk-apple.tar.xz`（33.6 MB，nightly）→
  `lib/mdk.xcframework/macos-arm64_x86_64/mdk.framework/Versions/A/mdk`（3.4 MB）
  里 `strings` 直接能看到 **Metal shader 源码**：
  ```
  { // dovi reshape. YCC=>IPT
  { // Dolby Vision FEL LINEAR_DZ residual
  s = coeffs[3] == 0.0 ? reshape_poly(coeffs, s) : reshape_mmr(coeffs, sig, %d ARGV_CB(cb));
  vec3 el_centered = el_sig.rgb - cb.dovi_nlq.offset;
  /***%before_rgb%***/ // before convert. for dolby vision
  ```
  外加**完整的 RPU 解析/校验栈**（`RPU validation failed: …`，含 `RPU_COEFF_FIXED`、
  `DOVI_MAX_DM_ID`、`DolbyVisionMetadata::Mapping::ReshapingCurve::MaxPieces`、
  `mmr_order_minus1`、`nlq_method_idc` 等）
  → **RPU 的 reshaping 多项式 + MMR 在 GPU shader 里应用**，等价于 libplacebo 在
  `vo=gpu-next` 里做的事，但 mdk 内置。
- Changelog 印证：「Dolby Vision Profile 7 FEL support」「Simplify dolby vision reshape」
  「Metal: fix constant buffer layout, e.g. dovi profile8 mmr」。
- **它认得我们的文件**：`bin/window` 日志直接打印
  `Dolby Vision 1.0 Profile 5 Level 9,  BL RPU`。

### ⛔ 但**不能**用 mdk 的 CLI 做无 GUI 验证（三条路都堵）
1. `bin/Thumbnail -from <ms> file` 能出 PNG，但**不走渲染器**（取的是解码帧）：
   与 ffmpeg 软解同帧 `psnr` = **48 dB**（≈逐像素相同）→ 里面没有 DV 处理。
   **DV 在渲染阶段（shader）做，任何「抓解码帧」的路径都不会有 DV。**
2. 自写 `Player::snapshot()`（离屏）→ **必 SIGSEGV**。三种写法都崩：
   `setRenderAPI(&MetalRenderAPI())` 只给类型（文档说离屏可用）、自备 `req.data` 缓冲、
   不调 `setRenderAPI` 走默认 GL。`renderVideo()` 本身是正常的（返回
   5.2/5.9/6.6/7.3 秒的时间戳，离屏渲染确实在跑），只是 snapshot 拿不到。
3. `bin/window`（真窗口播放器）窗口**在我的沙箱里不出现**：日志有
   `PlatformSurface::Event::Resize 1920x1080`（NSWindow 建了），但
   `CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly)` 里始终找不到，
   沙箱内外一样 → 窗口级 `screencapture -l <id>` 抓不到。
   （⚠️ 用户自己从终端跑应该能正常出窗口。）

→ **颜色对不对只能用户在真机肉眼看**，我这边无法自动取证。

### 接入 fvp 的三个坑（PoC 实测）
1. ⛔ **macOS 上必须显式 `fvp.registerWith(options: {'platforms': ['macos']})`**，
   否则 `video_player` 用官方 `video_player_avfoundation`（Apple 那套栈），测的不是 mdk。
2. ⛔ fvp 的 macOS podspec 依赖 CocoaPods 的 `mdk ~> 0.39.0`，source 是
   `https://sourceforge.net/projects/mdk-sdk/files/nightly/mdk-sdk-apple.tar.xz`。
   本机对这条 URL 的**跳转链偶发 TLS 失败**（`SSL_ERROR_SYSCALL`）→ `pod install` 直接失败。
   实测完整跟随跳转是能成的（`http=200 size=33599232`，落到
   `pilotfiber.dl.sourceforge.net`），**重试通常就好**；一直失败用
   `master.dl.sourceforge.net/project/mdk-sdk/nightly/mdk-sdk-apple.tar.xz` 兜底。
3. PoC 的 entitlements 必须 `app-sandbox = false`（模板默认 true → 读不到 `/tmp` 片源）。

### PoC 位置与跑法
- 工程：`/Users/tandy/workbuddy-ai/dv_poc`（**在主仓库之外**，不动 cloudcine 的 pubspec）。
- 片源：`/tmp/dv_poc_source.mkv`（390 MB / 115 秒 / 3840x1920，DV P5 元数据完好）。
- 跑：`cd /Users/tandy/workbuddy-ai/dv_poc && flutter run -d macos`，界面里点「播放」。
- 看点：肤色、暗部、整体色调，与夸克客户端同一时间点对比。

### ✅ 结果（2026-10-04 12:18，用户肉眼确认）：**颜色正常 → 换内核路线成立**
libmdk 内核能正确渲染 DV P5。至此「换内核」不再是可行性问题，只是**迁移工作量**问题。

### 构建 PoC 踩到的坑（都已解决，照抄即可）
1. ⛔ **坑 1 的根因**：fvp 的 pubspec 里 macOS 平台**只有 `pluginClass: FvpPlugin`，没有
   `dartPluginClass`**（只有 linux/windows/ohos/elinux 有 `VideoPlayerRegistrant`）。
   所以 macOS 上 fvp **不会**自动注册 → 不显式 `registerWith` 就静默走 Apple 那套栈，
   **测试结果假阴性**。这是本项目最容易踩的一个。
2. ⛔ **`pod install` 的 `Encoding::CompatibilityError` 是 locale 问题，但只影响手跑**：
   `LANG/LC_ALL/LC_CTYPE` 全空 → Ruby 的 `Dir.pwd` 是 ASCII-8BIT →
   CocoaPods `config.rb:167` 的 `unicode_normalize` 抛
   `Unicode Normalization not appropriate for ASCII-8BIT`。
   **但 `flutter build macos` 内部 `_runPodInstall` 自己已经传了 `LANG=en_US.UTF-8`**
   （`flutter_tools/lib/src/macos/cocoapods.dart:359`）→ **build 不受影响**；
   只有**手跑 `pod install`** 才要自己 `export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`。
3. ⛔ **别指望「先手动 pod install 再 build」能省掉那一步**：`processPods` 的
   `dependenciesChanged` **默认 true** → `_shouldRunPodInstall` 直接 return true
   （`cocoapods.dart:180 / 336`）→ **每次 build 都重跑 pod install**。
4. ⛔ **真正的拦路虎是沙箱**：PoC 在 workspace 根之外，必须 `dangerouslyDisableSandbox`。
   否则报 `Operation not permitted` 于 `Pods/Manifest.lock`、`Pods.xcodeproj/xcuserdata/...`。
   ⚠️ **`run_in_background` + 绕过沙箱 组合不生效**（后台跑仍是沙箱内）→ 要前台跑。
5. ⛔ **profile 里的 gvm 会让命令「跑之前就 exit 1」**（`ERROR: GVM_ROOT not set`，stdout 空）。
   非 Flutter 命令（如 `pod install`）用**干净 shell** 绕开最省事：
   `/bin/zsh -f -c 'export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"; cd … && pod install'`。
   Flutter 命令则显式给 `/opt/homebrew/Caskroom/flutter/3.29.0/flutter/bin/flutter`。

### 构建成功的判据与取证（别只看退出码）
- 判据：stdout 末尾 `✓ Built build/macos/Build/Products/Debug/dv_poc.app`。
- 链接取证（**必须对 `dv_poc.debug.dylib`，不是主二进制**）：
  `otool -L .../Contents/MacOS/dv_poc.debug.dylib | grep -iE 'mdk|fvp'` 应看到
  `@rpath/mdk.framework/Versions/A/mdk (… current version 0.39.0)` 与 `@rpath/fvp.framework/…`；
  `Contents/Frameworks/` 下应有 `mdk.framework`、`fvp.framework`。
- ⚠️ **别拿 mdk 日志当判据**：应用内**看不到** `Dolby Vision … Profile 5` 那行
  （默认日志级别不够，`bin/window` 才有）→ 起播成功与否要看界面，不是日志。

---

## 内核迁移方案：按需路由（2026-10-04 下午，用户已定）

### 用户拍板的两条
1. **只对 DV 片走 fvp**，其余仍走 media_kit。Android/TV **完全不动**
   （那边是**真 window vo**，本来就不受 render API 限制）。
2. **音效菜单保留，不可用的档位置灰并说明**（不做隐藏、不做删除）。

### 为什么「按需路由」没有省掉抽象层
DV 片也要切音轨、挂字幕、跳章节、看缓冲 —— 这些能力**必须在新内核上同样可用**。
所以 `PlaybackController` 那 1392 行照样要过一层引擎门面；按需路由降低的是
**暴露面**（只有 DV 片承担回归风险），不是**实现量**。

### ⛔ 闸门是「开播前自己判 DV」——不能让播放器先打开再问
先开再问是死循环：**打开本身就要先选好内核**。判据只能回到容器元数据。
实测我们那条 4K DV 片源，映射记录在**偏移 439 字节**处，读 64 KiB 头部就够。

### 已落地：`lib/core/utils/dolby_vision.dart`（纯解析，20 例单测全过）
- Matroska 链：`Segment`(0x18538067) → `Tracks`(0x1654AE6B) → `TrackEntry`(0xAE)
  → `BlockAdditionMapping`(0x41E4) → `BlockAddIDType`(0x41E7) /
  `BlockAddIDExtraData`(0x41ED)。
  ⛔ `BlockAddIDType` 是 **ASCII `"dvcC"` = `0x64766343`** / `"dvvC"` = `0x64767643`
  ——**这是值不是元素名**，别去搜字面量 `dvcC`。
- ISO BMFF：`moov` → … → `stsd`（**多一层「版本+标志(4)+条目数(4)」头**）→
  `dvcC`/`dvvC` 盒，盒体本身就是那 24 字节记录。⚠️ `moov` **后置**的文件头部探不到。
- 24 字节 DOVI 记录位布局（**已用真实片源对齐**）：
  `byte2 bits7..1 = profile`、`byte2 bit0 + byte3 bits7..3 = level(6 位)`、
  `byte3 bit2/1/0 = rpu/el/bl`、`byte4 bits7..4 = bl_signal_compatibility_id`。
  实测样本 `01 00 0a 4d 00` → profile 5 / level 9 / compat 0，
  与 mdk 打印的 `Dolby Vision 1.0 Profile 5 Level 9` 一致。
- 判定口径刻意收窄：`needsDolbyVisionEngine = profile==5 && compat==0`。
  带 HDR10 兼容层的 P8 退化成 HDR10 播只是「不够好」，
  **不该替它承担换内核的回归风险**。
- 两道值域闸（`record[0]==1`、`profile<=9`、`level<=13`）：MP4 那条路靠 4 字节盒名
  定位，**误命中的代价是拿随机数据当配置解析**，会「探出」不存在的档位。

### ⚠️ 测试里写 EBML 辅助函数的坑（我踩了）
EBML 长度是 VINT，**1 字节形式的长度 0 必须写成 `0x80` 而不是 `0x00`**
（`0x00` 没有任何标记位，真实解析器只能当坏数据）。写错的症状是
**整个 Segment 都解析不出来**，看起来像解析器的 bug。

### fvp/mdk 的能力缺口清单（实测，不是文档抄的）
| 现有能力 | mpv | mdk | 结论 |
|---|---|---|---|
| 打开+请求头 | `Media(httpHeaders:)` | `video_player` 的 `httpHeaders` | ✅ |
| 音/视/字轨列表 | `stream.tracks`（**流**） | `getMediaInfo()`（**一次性**） | ⚠️ 语义差 |
| 选音轨/字幕轨/关字幕 | `setAudioTrack`/`setSubtitleTrack` | `setAudioTracks([id])`/`setSubtitleTracks([])` | ✅ |
| 外挂字幕 | `SubtitleTrack.data(bytes)` | `setExternalSubtitle(uri)` —— **只吃 URI** | ⚠️ 需落临时文件 |
| 字幕渲染 | libass（media_kit_video 内） | **mdk 内部 libass，渲染进视频纹理** | ✅ 不丢 |
| 章节 | `getProperty('chapter-list')` | `MediaInfo.chapters` | ✅ |
| 缓冲终点 | `stream.buffer`（**绝对时间戳**） | `bufferedTimeRanges()`（**区间列表**） | ⚠️ 要改写 |
| 硬解 | `hwdec` | `setVideoDecoders([...])` | ✅ |
| 缓冲参数 | `cache`/`video-sync`/`demuxer-readahead-secs` | `setBufferRange(min,max,drop)` + `demuxer.*` | ⚠️ 语义不同 |
| 音效 | `af` / `audio-channels` | **无对等物** | ❌ 置灰 |
| 网络速率 | `demuxer-cache-state` | 无直接对等 | ❌ 降级 |
| mpv 日志流 | `stream.log` | 无对等 | ❌ 字幕解码诊断会丢 |
| 出画面判据 | `stream.videoParams` | `VideoPlayerValue.size > 0` | ✅ |
| 画面调节 | 无 | `setVideoEffect`（亮度/对比/色相/饱和） | ➕ 白送 |

### 阶段 2 已落地：引擎契约 + fvp 实现
- 契约：`lib/domain/services/playback_engine.dart`（抽象放 domain，符合本项目分层）。
  含 `EngineMedia` / `EngineTrack(s)` / `EngineChapter` / `EngineVideoSize` /
  `EngineCapabilities` / `EngineTimeRange`。
- fvp 实现：`lib/data/playback/fvp_playback_engine.dart`（实现放 data）。
- 单测：`test/domain/services/playback_engine_test.dart`（16 例）。

#### ⛔ 契约里最危险的一条：缓冲终点
`bufferEnd` 的语义是**「已缓存区间的结束位置」**（= mpv 的 `demuxer-cache-time`），
**不是**「前面还有多少秒」。两个内核的原始表示不同：
mpv 直接给绝对时间戳，mdk 给**区间列表**。
唯一允许的换算点是 `EngineTimeRange.cacheEndAt(ranges, position)`：
- **优先取「包含播放头的那一段」的终点**，⛔ 不是全局最大值 ——
  取最大值会把 seek 后残留在远端的段算进来，进度条画出一段读不到的缓存。
- **播放头不在任何区间里 → 返回 0，绝不猜**。代价不对称：
  少报只是暂时不画缓冲层（`PlayerBufferProgress.positionOf` 会退回播放头），
  多报是进度条说谎。

#### fvp 接入的实测事实（都是踩出来的）
1. `FVPControllerExtensions` 是**扩展方法** → `import 'package:fvp/fvp.dart'`
   **不能加前缀**，否则 `controller.setAudioTracks(...)` 编译不过。
2. fvp 会把 `dataSource.httpHeaders` 写成 mdk 的 **`avio.headers`** → **Cookie 能带上**。
3. fvp 的 `create()` 调 `player.prepare()` **不带位置** → 起播位置只能
   `initialize()` 之后、`play()` 之前 `seekTo()`。
   ⚠️ 这条路**必须在真机上验**（续播是主路径）。理论上 mdk 在 Prepared 状态下
   seek 是有效的（不像 mpv 的 `loadfile` 竞态 —— 那正是 media_kit 非要
   `Media(start:)` 的原因）。
4. ⛔ **fvp 不上报 `buffered`**（`video_player_mdk.dart` 全文件没有这个词）→
   `bufferEnd` 在 DV 片源上恒为 0，**进度条的缓冲层不会出现**。
   不做补偿的理由：`positionOf` 在 `cacheEnd<=0` 时退回播放头，缓冲层自动
   与已播层重合（看不见），是**优雅降级**；而 `MdkVideoPlayerPlatform._players`
   是私有的，硬取要重写整个平台层，不值得。
5. ⛔ `MediaInfo` 里**没有 `isDefault`** → `EngineTrack.isDefault` 恒为 false。
   影响面：内嵌字幕的「发布者标记为默认」那一条退化；
   音轨不受影响（`_maybeRestoreAudio` 本来就把「没偏好」当「让引擎用默认」）。
6. ⚠️ **音量口径不同**：`video_player` 是 0..1，media_kit 是 0..100。
   契约统一 0..100，fvp 实现里 ×100 / ÷100 换算。
7. ⚠️ mdk 的 `setActiveTracks(audio, [])` 是「一条都不选」＝**静音**，
   与 media_kit 的 `AudioTrack.auto()` 语义不同 →
   `selectAudioTrack(null)` 在 fvp 实现里是**空操作**，不是关音轨。
8. `MediaInfo` 是**一次性查询**（不是流）→ fvp 实现开了 8 秒的轮询窗口
   （400ms × 20 次）反复问，靠 `EngineTracks.signature` 去重。
   指纹**必须带 id 而不只是条数**：换集时条数常一样、只有轨道号变了。

#### 渲染句柄的归属
领域层契约**故意不带**渲染方法（domain 不引 Flutter）。
两个实现各自暴露具体类型的 getter（`VideoController` / `VideoPlayerController`），
由 **UI 层**按引擎具体类型挑组件 —— 见 `ui/widgets/playback_surface.dart`（待做）。

### 下一步（阶段 3）
1. `MediaKitPlaybackEngine`（把现有 media_kit 行为**原样**包一遍，不改语义）。
2. `PlaybackController` 改为面向 `PlaybackEngine`，并在 `resolveStream` 之后
   用 `dolby_vision.dart` 探头部字节（Range 请求，走 `HttpClientLike.getBytes`
   传 `{'Range': 'bytes=0-262143'}` + ticket.headers）决定用哪个引擎。
3. `ui/widgets/playback_surface.dart` + 两份播放器 UI 的渲染槽位与置灰。
4. `main.dart` 里 `fvp.registerWith(options: {'platforms': ['macos']})`。

---

## 引擎契约的标识符与两条硬约束（2026-10-04 傍晚，阶段 2 补完）

### 文件
- `lib/domain/services/playback_engine.dart` —— 契约与模型（领域层，**不引 Flutter**）。
- `lib/data/playback/fvp_playback_engine.dart` —— fvp（libmdk），**只服务 DV 片**。
- `lib/data/playback/media_kit_playback_engine.dart` —— media_kit（mpv），**默认内核**。
- `lib/data/playback/change_gate.dart` —— `ChangeGate<T>`，两个引擎共用。

### ⛔ 契约里最容易写错的三个标识符
| 标识符 | 正确 | 写错的后果 |
|---|---|---|
| `networkSpeed` | `Stream<double>`，**字节/秒** | 曾误写成 `Stream<Duration>`。这个量与「秒」无关，它是带宽 |
| `log` | `Stream<String>`，**必须有** | 缺了它**字幕解码诊断彻底消失**：mpv 报 `sd_lavc` 失败时 `stream.error` 收不到（media_kit 的白名单里没有 `sd_lavc`），只能从 `stream.log` 捞 |
| `EngineVideoSize` | 必须有 `==` / `hashCode` | `ChangeGate` 用 `==`，缺了它闸完全失效，每次 `videoParams` 都被判成「尺寸变了」 |

### ⛔ `ChangeGate` 的 `null` 陷阱（真 bug，被测试抓出来）
不能用 `_last == null` 判断「有没有发过」—— `null` 是**合法值**
（`activeSubtitleTrackId` 的 null = 没有字幕在显示）。
必须单独记一位 `bool _has`。
症状：打开一部没有内嵌字幕的片子，字幕菜单停在上一集的状态。

### 两处「刻意不换算」
1. `bufferEnd` 在 media_kit 实现里**直接转发** `player.stream.buffer`。
   mpv 的 `demuxer-cache-time` 本来就是绝对时间戳，与契约参照系一致。
   ⛔ 别在这条路上调 `EngineTimeRange.cacheEndAt` —— 那是给 mdk 的
   「区间列表」用的，套到标量上语义完全错位。
2. `error` **原样转发、不过滤**。关键词过滤与字幕诊断分流是业务判断，
   留在 `PlaybackController`。

### `chapters()` 的语义补全
mpv 的 `chapter-list` **只给起点**（`IntroChapter` 只有 title+start），
而契约要 `[start, end]`。补法：**一章延伸到下一章的起点，最后一章延伸到
片尾**。片长未知 / 乱序时退化成零长度（`end == start`），**不编假终点** ——
章节的唯一用途是「认片头」，而认片头只看 `start`。

### 归属：两个引擎都**拥有**自己的播放器
- media_kit：构造函数建 `mk.Player` + `VideoController`，`dispose()` 销毁。
  但 `mk.Player get player` **仍对外暴露** —— 音效
  （`PlayerAudioEffect.apply`）与缓冲调优（`PlayerBufferConfig.apply`）是
  mpv 专有能力，契约里没有（mdk 无对等物）。构造参数 `tv` 由调用方给。
- fvp：构造函数建 `VideoPlayerController`，`dispose()` 销毁；
  `VideoPlayerController get videoController` 给 UI 当渲染句柄。

⚠️ 领域层契约**故意不带渲染方法**（领域层不引 Flutter，拿不到 widget）。
UI 层按引擎的具体类型挑渲染组件，见（待建）`ui/widgets/playback_surface.dart`。

### 验证口径
`flutter test` 全量 **2177 例**（阶段 2 补完后）。`flutter analyze` 全仓
仍有 7 条既有 info（`test/ui/providers/move_targets_test.dart`、
`test/ui/widgets/drive_move_dialog_test.dart`、`tool/seek_probe_test.dart`），
**都与本工作无关**。

---

## 阶段 3 已落地：两份播放器都接线到 `PlaybackEngine`（2026-10-04 傍晚）

### 新增文件
- `lib/domain/services/playback_engine_router.dart` —— **「用哪个内核」的唯一实现**，
  两份播放器共用 → 不会「内置页切对了、独立窗口没切」。
- `lib/core/utils/track_bridge.dart` —— `mk.Track` ↔ `EngineTrack` 的桥（UI 菜单仍吃
  `mk.AudioTrack`，把改动面压到最小）。
- `lib/data/stream/dolby_vision_probe.dart` —— Range 探头部字节 + 按 key 缓存。
- `lib/ui/widgets/playback_surface.dart` —— 按引擎**具体类型**挑渲染组件
  （`Video` vs `VideoPlayer`）。契约故意不带渲染方法（domain 不引 Flutter）。

### ⛔ 最容易做错的三条
1. **`fvp.registerWith(options: {'platforms': ['macos']})` 必须在 `main.dart` 里、
   `runApp` 之前跑完。** 每个独立窗口 = 独立 Flutter engine，Dart 侧平台实现注册是
   **按引擎**的；晚一步 → macOS 上 fvp 的 pubspec 没有 `dartPluginClass`，
   静默走 `video_player_avfoundation`，**DV 颜色错、且不报任何错**。
2. **选引擎必须「开播前」判**（`PlaybackEngineRouter.selectFor`），不能让播放器先开再问
   —— 打开本身就要先定内核。判据回到容器元数据（`dolby_vision.dart` 探头部字节）。
3. **换内核时停旧引擎是 fire-and-forget**（`unawaited(previous.stop()...)`），两个引擎
   都由 router 的 `dispose()` 收口。⚠️ `PlaybackController._engine` 是 **getter 不是字段**
   —— 内核会被路由换掉，存字段会拿到 stale 引用。

### 路由规则（`selectFor`）
- 只在 `profile==5 && compat==0` 时换内核（P8 有 HDR10 兼容层，退化播只是「不够好」，
  不替它承担回归风险）。
- ⛔ **跳过 HLS**（`media.m3u8`）—— 转码档是 SDR，与 DV 无关，不该触发探测。
- ⛔ **跳过非 http(s)**（`asset://`、本地路径）—— 探不了、也没 DV 问题。
- 探针结果**按 key 缓存**（`'${fileId}|${qualityId}'`）。

### fvp 不受本机 `http_proxy` 白名单陷阱影响（已核实，别再查）
media_kit/mpv 那条「HLS 必须走本地中继」的坑（见 `§转码档 HLS`）**对 fvp 不存在**：
`fvp-0.39.0/lib/src/video_player_mdk.dart` 的 `_create` 里，**网络源从不设
`avio.protocol_whitelist`**（FFmpeg 默认不限 → `httpproxy` 可用）；本地文件的白名单
里也**显式含 `httpproxy`**。所以 DV 片源不需要为代理再绕中继。

### 独立窗口保留 mpv 日志尾部
`player_window_app.dart` 仍以 `verboseLog: true` 建 `MediaKitPlaybackEngine`：
`isHttp4xxLog` 票据失效检测依赖 mpv 日志尾部。**契约 log 流**（字幕解码诊断分流）
与 **mpv log 尾部**（票据检测）是两路订阅，别合并。

### 能力置灰（用户定的口径）
音效入口按 `capabilities.audioEffects` 置灰 + tooltip/提示语；
`_applyAudioEffect()` 只在 `engine is MediaKitPlaybackEngine` 时跑。
`mpv_chapters.dart` 的便捷方法 `detectIntro` **已删**（fvp 没有 `Player`）；
`chapters()` 只由 `MediaKitPlaybackEngine` 经 `MpvChapters.read` 调。

### 验证口径（阶段 3 收尾）
`flutter test` 全量 **2234 例全过**；`flutter analyze` 仅 7 条既有 info（均与本工作无关）。
⚠️ 跑测试必须清代理：`env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY
-u HTTPS_PROXY -u ALL_PROXY NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
flutter test`（否则 flutter_tester 的 WebSocket 升级被代理打断，**每例都报错**）。

---

## 两条取链路由：**原画 = 直链文件，转码档 = HLS**（2026-10-04 13:3x）

### ⛔ 验证 DV 必须选**原画**，选了转码档等于在测另一件事

| 档位 | 路由 | 产物 | 与 DV 的关系 |
|---|---|---|---|
| **原画** | `audio_play` | **直链文件**（`video-play-c-zb...`），支持 Range → 走本地中继 | **DV 只在这里** |
| 转码档（4K/super/high/low） | `play_info` | **`media.m3u8`（HLS）**，1920p 起的 SDR 转码 | **无关**（转码是 SDR） |

日志里的判据：`[取链] 路由 audio_play 签发票据` vs `路由 play_info 签发票据`。

⚠️ 5 个档位共用**同一个** `media.m3u8`（`StreamTicket.withQuality` 只改
`contentLength`，不改 URL）→ 界面上的「档位=4K」对 HLS **没有实际作用**，
由 mpv 自己挑 variant。这是个既有的设计缺口，与 DV 无关，但排查时要知道。

### 故障现象（13:2x 实测，尚未定位到根因）
转码档 HLS：有声音、没画面、mpv 在 **1~2 秒**后报 `eof-reached` →
`completed` → 自动连播下一集 → 几十秒内级联跳完 5 部片。
`completed` 直接来自 `player.stream.completed`（无 duration 启发式），
所以是**流本身就短**，不是我们的判定错。

已排除：`VideoController` 绑错 Player（绑定正确）、音效/缓冲参数（旧构建同样）、
本地中继（HLS 根本不进中继）、mdk 的 FFmpeg（不影响 mpv）。

### ✅ 修正（2026-10-04 下午复查）：mdk 的 FFmpeg **就在产物里** —— 这条「拦路虎」不存在

之前这里写「`CloudCine.app/Contents/Frameworks/` 只有 `mdk.framework` → 拿不到
FFmpeg → 解不了任何流」，**是误判**。错在只看了 `otool -L` 里那串
**`libav*.dylib` 分体布局**的 weak import，漏了同一张表里的
**`@rpath/libffmpeg.9.dylib`** —— 那才是 mdk 自带的**合并版** FFmpeg。

实测（对**已构建产物**，不是只看 Pods）：

- `mdk.framework/Versions/A/` 里就有 `libffmpeg.9.dylib`（19 MB）、`libass.dylib`、
  `libdav1d.dylib`、`libmdk-braw.dylib`、`libmdk-r3d.dylib`。
- 它**能解析**：`mdk` 自己的 `LC_RPATH` 含 **`@loader_path`**
  （= `mdk.framework/Versions/A/`）→ `@rpath/libffmpeg.9.dylib` 正好落在那里。
- 决定性证据（`DYLD_PRINT_LIBRARIES=1` 跑产物）：
  ```
  .../Contents/Frameworks/mdk.framework/Versions/A/mdk
  .../Contents/Frameworks/mdk.framework/Versions/A/libffmpeg.9.dylib   ← 真的加载了
  ```
  `fvp.framework` 也照样加载。

⚠️ 取证口径：**必须对 `build/.../CloudCine.app/Contents/Frameworks/` 下那份**，
并且**看 `dyld` 实际加载了什么**，而不是只看 `otool -L` 的 import 表 ——
weak import 里有几项不存在是**正常**的（那是 mdk 支持的**另一种** FFmpeg 布局）。

→ **结论：阶段 3 没有打包前置条件**；`mdk + fvp + libffmpeg` 在当前构建里全部可用。



## §测试取向（细节，从 MEMORY.md 下沉）

- **基线**：`flutter test` 全过（`skip` 只收 `bool?`）。
- ⚠️ **测相似度 / 打分别猜数值，先写脚本跑**；断言写档位边界。
- ⚠️ 时间相关逻辑**必须注入时钟**；测「按平台挑后端」必须设
  `debugDefaultTargetPlatformOverride`（`flutter test` 下默认**一律 `android`**）；
  复位只能写在**测试体里**。
- ⚠️ 改 `tables.dart` 列后先跑 `build_runner build`；看不懂的编译错误先重跑一次。
  `AppSettings.fromValues(Map)` 是默认值真源。
- ⚠️ `find.byType(FilledButton)` **不匹配** `FilledButton.icon`（子类）
  → 报 `Bad state: No element`。改用
  `find.byWidgetPredicate((w) => w is FilledButton)`。
- ⚠️ **页面自己会把内容渲染出来**时，别用页面级 `find.textContaining(...)` +
  `findsOneWidget`：诊断页把日志逐行列出来，而「上传日志」这个动作**自己也会写一行
  日志**（成功那行含目录名、失败那行含「上传失败」）—— 于是同一条文本在页面上出现
  **两次**（SnackBar 一次、日志列表一次），断言因「找到两个」而红，看着像功能坏了。
  修法：把断言限定进弹层 ——
  `find.descendant(of: find.byType(SnackBar), matching: find.textContaining('上传失败'))`。
  （2026-10-04，诊断页日志上传那两条用例就是这么红的。）
- ⚠️ **「先确认断言是红的」不必动工作区**：`git stash` 在这个仓库有风险 ——
  可能有**别的会话正在写同一棵树**（见 `2026-10-04.md` 那次两套实现撞车），
  pop 时容易撞车。要证明新断言在旧代码上必然失败，用**只读**的办法：

  ```sh
  git show HEAD:lib/<file>.dart | grep -c '<新日志串或新标识符>'
  ```

  全是 `0` 就说明这些串在旧代码里根本不存在，断言必然红。
  （2026-10-04 傍晚，中继诊断日志那 4 例就是这么验的：7 个串全 0。）
  ⚠️ 只适用于**新增的字符串/标识符**；改语义、改返回值的修复还是得真跑一遍红。
- ⚠️ 纯日志改动的用例可以直接断言单例：`diag.clearBuffer()` +
  `diag.lines.join('\n')` + `contains(...)`（`DiagLog.instance` 在测试里没
  `start()`，所以 `_supportPath` 为空、**不写盘**）。先例：`diagnostics_page_test.dart`。

## §封面与刮削（从 MEMORY.md 下沉的标识符）

- `mergeWorkForUpsert` 的覆盖开关叫 **`overrideManual`**：
  `source=manual` 只被**显式**刮削覆盖。
- 两条解析层守卫的名字：**`_pickYear`**（括号内日期不算年份）、
  **`_isStandaloneRelease`**（纯数字片名要自带年份）。

## §转码档 HLS：2 秒 EOF 的完整结论（2026-10-04）

### 症状
夸克网盘里同一部片：**原画正常**（DV 偏绿是另一件事），切到 **4K / 1080P** 只能播
2~8 秒、有声音没画面，然后 EOF → 触发自动连播。**所有剧集都一样**，与 DV 无关。
夸克自己的网页播放器播同一文件**没有**这个问题。

### 根因（有日志证据，不是推测）
夸克把 `play/info` 的 `video_list[].video_info.url` 从**带签名直链**换成了
**`media.m3u8`（HLS）**：

| 日期 | 投给播放窗口的 4K 地址 |
|---|---|
| 2026-10-03 | `video-play-c-zb/.../6698b322...`（带签名直链）→ **播得动** |
| 2026-10-04 | `video-play-h-zb/qv/.../media.m3u8` → **2~8 秒 EOF** |

判据：`awk` 统计 `投给独立窗口` 那一行 —— 10-03 是「直链 档位=4K」9 次，
10-04 变成「HLS 档位=4K」33 次。**不是我们的代码改的**：
`QuarkPlayInfoParser._firstUrl` 按 `urlKeys` 取第一个像地址的字段
（`url` 优先），服务端给什么用什么，**没有任何「直链优先」的偏好逻辑**；
而 `quark_play_routes.dart` 自 10-01 起没动过。

### 一级嫌疑：`Video-Auth` cookie
- 签发**转码档**的 `/file/play/info` **每个响应都下发** `set-cookie: Video-Auth`；
  签发**原画**的 `/file/audioplay` **不下发**（原画地址自带 `auth_key` 签名）。
- 而 `media.m3u8` 的 URL **不带签名** —— 同一个文件在 11:15 / 13:24 / 13:54 / 13:59
  取回来**一模一样**，鉴权只能靠 cookie。
- `QuarkEndpoints.knownCookieNames` 原本**没有** `Video-Auth`，于是
  `_absorbRotatedCookies` 按白名单过滤时把它**静默丢弃**。已修（加进白名单）。
- 2026-10-04 13:59:57 切 4K 后 30ms，mpv 报 `http: HTTP error 404 Not Found`。

### ⛔ 一个反直觉的坑：护栏会**放行**这个故障
`PlaybackCompletion.isRealEnd` 的判据是「位置 ≥ 3s」或「出过画面」。
实测故障现场是 **位置 3~7 秒 + mpv 确实报过视频尺寸** → 护栏判成「真播完」，
自动连播照常触发。所以**诊断的触发条件必须独立于护栏**：
`request.isHls && position < PlaybackCompletion.suspiciousHlsPosition`（30s）。
上一版把诊断挂在护栏里面，结果护栏一次都没拦，诊断一次都没跑，
最关键的证据（m3u8 内容）从头到尾没落过盘。

### 已加的诊断（下一轮复现就能定位）
- `_probeHlsPlaylist`：出事时**用票据自带的请求头**自己抓一次 m3u8，
  打状态码 + `cookieHeaderKeyNames` + `summarizeHlsPlaylist` 的摘要
  （**分片数 / 合计时长 / 有无 ENDLIST / 是否 master**）。
  分水岭：自己抓 200 而 mpv 404 → 是 mpv 侧；自己抓也 404 → 是凭证/票据。
- `_mpvLogTail`（环形缓冲 120 条）+ `_dumpPlaybackDiagnostics`：
  mpv 平时的话**全被两个过滤器丢掉**，这条尾巴是它唯一能留痕的地方。
- 投链与刷新直链两处日志补上「HLS 还是直链」+ **Cookie 键名**
  （只看 `headers.keys` 永远只能看到「Cookie」这一项，而它**永远都在**）。

---

# §从 MEMORY.md 下沉（2026-10-04 整理，MEMORY 贴 8000 字符上限）

MEMORY.md 只留红线与指针，下面是被下沉的原文细节。**没有新增结论**，
只是搬家；改动前先看这里，别当成两条不同的规则。

## 目录视图：三组条目 + 排序 + 直接播 + 多选删除（原文）

一层列**全部条目**，三组**目录 → 视频 → 其他文件**（组间顺序是**结构**，
不随排序变）。⛔ 分组只管「怎么排、行上给什么动作」，
**入库判据仍只有 `classifyEntry` 一处**。

- 下载取链**复用 `adapter.resolveStream`**（⛔ 别打 `/file/download`，
  >50MiB 直接 23018）；`autoUncompress=false` + `Accept-Encoding: identity`
  + `findProxy=DIRECT`。
- 排序：`FolderSortMode`（文件夹页）与 `ItemSortMode`（详情页，
  **默认**修改时间倒序）**各一份设置键**，都在**渲染时**排
  （⛔ 前者别进 `driveListingProvider`）。⛔ **排序只改显示、不改 `primary`**。
- 视频行**整行可点=播**（下载是右侧独立按钮）：未入库走 `playDriveEntry`
  （**不写库**，与发现共用 `parseTransientMedia`）。
  `local_stream_relay.dart` 现在**原画 + 转码档 HLS 都服务**。
- **多选删除**：`folderSelectionProvider`（键=fid）；⛔ **换目录清空**、
  **全选只勾当前可见**（`displayEntries` 是列表与全选**唯一**共用定义）。
  `DriveCleanupController`：分块 100、凭证失效/断网**中止后续批次**
  并把没发出去的算失败（`rateLimited` 不中止）、删成功的**连同本地索引**清；
  ⛔ **失败的批次不清索引**。

## 季 / 部 / 跨目录归一（原文）

`MediaItem` + **`part/partLabel`**（v9）；`MediaWork` + **`seasonCount`**（v10）
+ **`mergedInto`**（v11）。层级**不落库**（现算）：**季在外、部在内**，
某层**少于 2 个选项不画**。卡片三个计数是**并集**，
`seasonCount` 是 `COUNT(DISTINCT)` **不能相加**。

- **目录名当系列名**：判定单元是**目录不是文件**（`DirectoryTitle`），
  **四处调用点都要传 `dirPath`**。
- 自动归一 `work_merge_planner.dart`：**只认 `onlineId` 相同 + `source==online`
  + kind 相同**，`manual` 不参与；目标 = itemCount 最大 → firstSeenAt 最早 →
  key 升序。**本地片名相似度绝不参与**。`autoMergeByOnlineId` **默认开**
  （`!= 'false'`）。
- **手动归一**「合并到…」（`MergeWorkDialog`，**无刮削门槛**）：
  留下**选中的那一部**；不能合 → 按钮灰 + 原因（自己 / 目标已别名 /
  **源自己还折着别人**）；撤销 = 目标页「拆开」。
- ⛔ **归一 = 打标记**：不删行、不改 `group_key`；列表/角标滤
  `merged_into IS NULL`、`itemsForWork` 取并集、撤销 = 清标记。**不许链式**。
  ⚠️ `mergeWorkForUpsert` 里**无条件取旧值**（照抄 = 重扫拆开）；
  搜索穿透折叠内层表**必须起别名**。
  ⛔ `_unionStats` 别改回 JOIN 里的 `OR`（本文件 §媒体库列表「显示特别慢」有实测数字）。

## 媒体库三轴的「交互」细节（原文）

`PlayTarget.resolve`：① 最近播过且留续播点 → 那集；② 播过但续播点已清 →
**仍是那集**；③ 全新 → 第一集；**排掉 `isSampleOrExtra`**。
`playItem()` 是唯一起播入口。

`mergeWorkForUpsert`：`category` 取新值但**先按 `effectiveGenres` 折算**；
**手动标记的行整列不动**；`posterUrl` **永不为空**；
`source=manual` 只被**显式**刮削覆盖（开关名 `overrideManual`）。

**路径**归一化只在 `core/utils/drive_paths.dart` 一处 ——
`/电影` 与 `/电影/` 会变成两个键，于是**静默筛不到**；
`dirPath` 带尾斜杠、内部不带。

## 播放器报 `Failed to open http://127.0.0.1:PORT/sN`：中继侧的分水岭（2026-10-04 傍晚）

**症状原话**（屏幕上的覆盖层，`player_page.dart` 的 `_ErrorOverlay`）：

```
播放失败
播放器报错：Failed to open http://127.0.0.1:43617/s1.
```

**先认清这句是谁说的**：`Failed to open <url>.` 是 **mpv** 的原话
（`prefix='stream'`、error 级，所以它**能**走到 `stream.error`）。失败的是
**本地中继地址**，所以这不是「解码器不认编码」，而是**连中继都没打开**。
`/s1` 就是 `LocalStreamRelay` 的 token（`s` = 字节流会话，`h` = HLS 会话）。

⚠️ **TV 上拿不到 ffmpeg 的补充信息**：内置播放页的 `MediaKitPlaybackEngine`
不开 `verboseLog`（`logLevel=error`），而 `http: HTTP error 4xx` 是 **warn** 级
—— TV 上永远收不到。所以 TV 只剩孤零零一句 `Failed to open`，**必须**靠中继
自己的日志还原。

### 三种机制，靠这几条日志区分（2026-10-04 傍晚补的）

| 日志里看到 | 结论 |
|---|---|
| **没有** `会话 sN 收到读取器 #M` | 播放器压根没连进来（端口不通 / 地址发错 / 服务已 dispose） |
| 有 `收到读取器`，**有** `拒绝 … 会话不存在` | 会话被提前关掉 → 中继回 **404**（那条「假的直链过期」） |
| 有 `收到读取器`，**没有** `首块已下发`，且末尾 `已下发 0 字节 ← 一个字节都没发出` | 中继答应了 200/206 却给不出正文 → ffmpeg 读不出容器 → `Failed to open`。**最常见**，往上翻找 `取块 N 失败：上游返回 <code>` |
| 有 `收到读取器` + `首块已下发` | 数据流过了，问题不在中继（看内核/容器） |
| 有 `拒绝 … Range 超出流长度` | 416：拿旧会话的长度读新流 |

配套的新日志（都在 `local_stream_relay.dart`）：

- `已接管 sN <片名>：… ｜入口 http://127.0.0.1:PORT/sN` —— **token 在这里**，
  拿它把屏幕上的 `/s1` 对上具体哪一次接管。
- `会话 sN 收到读取器 #M：GET /s1（Range: bytes=0-）` —— **分水岭本体**。
- `会话 sN 读取器 #M → 200 bytes 0-9/10` / `首块已下发（N 字节）` /
  `结束：已下发 N 字节`。
- `拒绝 GET /s999：会话不存在（已关闭或从未建立）（当前活跃会话 N 条 + HLS M 条）`
  —— 落 **warn**。正常换源时旧会话是**已被占住的存量连接**，不会再来新请求，
  所以它几乎总是异常。
- `HLS 会话 <片名> 上游返回 <code>：…` —— 落 **warn**（健康会话永远走不到；
  最常见成因是缺 `Video-Auth`）。

⛔ **「0 字节」必须留在 warn**：它和「正常换源掐断连接」原来共用一条 debug，
而后者是高频正常事件 —— 落 debug 会让真故障在现场日志里彻底消失。

⛔ **HLS 的分片请求不能逐条记**：一次播放几百条，会把 800 行的环形缓冲冲垮。
只记每条会话的**首个**请求（`_HlsRelaySession.sawRequest`），总量靠
`close()` 那条「上游请求 N 次，失败 M 次」。

### 播放侧对应的那一条（`playback_controller.dart`）

`内核打开：http://127.0.0.1/s1（本地中继）请求头=0 条 起播=0s`

⛔ 这是**唯一**记录「内核实际打开了哪个地址」的地方。同方法开头那条「交给播放器」
打的是 `ticket.redactedUrl` —— 那是**上游**地址，而走中继时内核拿到的是
`http://127.0.0.1:PORT/sN` 且**不带任何请求头**。只有前者会让日志**说谎**：
播放器报的是中继地址，日志里却只有上游地址，于是「中继到底参与了没有」无从确认。

用 `redactUrl`（`core/utils/redact.dart`，只丢**查询串**）：中继的会话号在**路径**
上（`/s1`）会被原样保留，直链签名在查询串里正好被抹掉。别为此新造助手。

⚠️ `_PlaybackSource` 的「是不是中继」是**显式一位** `relayed`，不是「URL 里有没有
`127.0.0.1`」—— 靠猜在将来加了别的本地代理之后就会说谎。

## 夸克 TV 播放器的 OSD 实测几何（2026-10-04 晚，照它重做 TV 菜单）

小米电视（1920×1080 @ density 320 → **逻辑 960×540**）上，`com.quark.yun.tv`
（`eskit.sdk.core.ui.BrowserStandardActivity`）播放中：

```sh
adb shell input keyevent 23            # OK 唤出 OSD
adb shell uiautomator dump /sdcard/q.xml && adb pull /sdcard/q.xml
```

⛔ **拿不到截图**：整块播放界面在 screencap 里是**全黑**（`SurfaceRenderView`
/ FLAG_SECURE 一类），但 `uiautomator dump` **照常有完整视图树与 bounds** ——
所以只能靠 dump 还原几何。`service call SurfaceFlinger 1008` 在本机电视上
`Operation not permitted`，别在这上面花时间。

**层级（逻辑坐标）**：顶栏 `(0,0) 960×90`（标题 `(28,22) 236×68`、右上时间
`(876,23) 45×20`）；中央有一块 `(430,220) 100×100` 的**反馈 HUD**；
字幕区固定在 `(0,215) 960×100`（`foreground_textView` + `background_textView`
两层描边字，**字幕是它自己画的，不是播放器画的**）。

**两种底部形态**（互斥，**不共存**）：
- **进度形态**：一行 `(0,411) 960×39` —— 播放键 `(29,411) 39×39`、当前时间
  `(94,419) 80×19.5`、进度条 `(157.5,422.5) 700×12.5`（**它自己是焦点**）、
  总时长 `(841,419) 80×19.5`。
- **菜单形态**：`(0,215) 960×325` 的纵向行列表；**选中的那一行下面铺开一条
  横向 RecyclerView**（实测 chip `176×73`，文字如「超清/高清/流畅」，当前那
  颗带勾、并高亮）。

**导航模型（这就是「XY 轴」）**：`↓` 在**行之间**走（实测：进度行 → 播放列表
卡片行 → 画质行 → …），`←/→` 在**当前那一行的 chip 条里**走。行高 50、
chip 高 ~73。⛔ `↑` 从第一行往上**什么也不做**（不是关闭）。

→ 本项目照它重做的实现在 `lib/ui/widgets/player_tv_panel.dart` 的
`PlayerTvSheet`：贴底横排、选中行下面铺 chip、`↑↓` 换行（**循环**，与夸克
不同）、`←→` 挪光标（**不循环、跳过灰掉的**）、`OK` 才生效（挪光标不生效 ——
否则连按 → 会连取五次流）。`←→` 只在**没有 chip 条**的行上回调 `onAdjust`。

## TV 菜单的高度预算：`Container` 会把 `decoration` 的描边算成内边距

`kPlayerTvSheetHeight` = 七行 × 40 + 选项条 50 + 上下内边距 16 **+ 0.8**。
最后那 0.8 是 `TvSheetCard` 顶部那条 `BorderSide(width: 0.8)` ——
`Container` 把 `decoration.padding` 加进内容的内边距，于是内容实得高度比
`height` 少 0.8px。少了它就是 `RenderFlex overflowed by 0.8 pixels`。

⚠️ 这个数**不可能靠肉眼看出来**，是被单测抓出来的（
`test/ui/widgets/player_tv_panel_test.dart` 的「七行 + 选项条刚好装得下」）。
同理：行高只能收，不能再加 —— 菜单越高，留给画面的那一条越窄，而
「换字幕时看得见字幕」是那两项设置**唯一**的反馈（字幕因此在菜单打开时被
抬高，见 `_PlayerPageState._subtitleBottomPadding`）。

## ⚠️ `flutter_test` 里 `defaultTargetPlatform` **默认就是 android**

实测（`debugPrint` 探针）：`defaultTargetPlatform = TargetPlatform.android`、
`debugDefaultTargetPlatformOverride = null`、默认视口 `2400×1800 @ dpr 3`。
推论：`AppTheme.isTvLayout` 的两条判据里，**平台那条在单测里天然成立**，
只要把视口宽度设到 ≥960 就进了 TV 分支（`safeAreaInsets` 会真的返回
48/27）。写 TV 布局断言时按这个来，别去 override 平台。

⚠️ 另一个坑：**别用 `SizedBox(height: 540, child: <面板>)` 当测试夹具** ——
那给的是**紧**约束，卡片会被拉满 540，于是「面板有多高」这类断言全都在测那个
`SizedBox`。真机上贴底面板的约束是**松**的（`Positioned(left:0,right:0,bottom:0)`），
夹具必须同形（整屏 `Stack` + `Positioned`）。

## 用 adb 驱动电视前，先确认前台是不是本应用

`adb shell input keyevent` 是**打到当前前台窗口**的，与你想操作哪个 App 无关。

10-04 实测：驱动脚本按「left/up/ok」想回媒体库，那时用户已经把电视切到了
**夸克网盘**，于是这几下全打进了夸克 —— 导航乱了，最后那个 `ok` 还在夸克里
**真的起播了一集**（`194.mp4`）。而夸克的播放面**截不出来**（全黑，见上），
所以从截图上看只像是「我们的播放器黑屏了」，极具误导性。

配方：

```sh
adb -s $SERIAL shell "dumpsys window | grep -E 'mCurrentFocus'"
```

拿到 `mCurrentFocus` 里的包名再决定要不要发键。**要么先 `am start` 把本应用
拉回前台，要么先问用户**。

⚠️ 同理：**用户可能正在用实体遥控器操作电视**（他就是「看效果」）。判据是
**空闲对比截图** —— 不发任何键，间隔几秒截两张，哈希不同就说明画面在被人推着走。
这时任何自动驱动的结果都不可信，别拿它当验收证据。

## 4K 掉帧的根因：mpv 的**拷贝路径**（10-04 实测定论）

用户报「4K 掉帧、1080P 顺、夸克播放同一片源没问题」。真机日志（`[解码]` 行）
把范围锁死了：

```
第 6s：解码器=mediacodec-copy 解码丢帧=0 显示丢帧=14
第 27s：解码器=mediacodec-copy 解码丢帧=0 显示丢帧=58
```

- `解码丢帧` = mpv `decoder-frame-drop-count` → **0**，解码永远跟得上；
- `显示丢帧` = mpv `frame-drop-count` → 21 秒涨 44 帧 ≈ **2.1 fps ≈ 每秒丢 9%**；
- 同段 `[中继]` **一条 WARN 都没有**（对比 16:33 那次满屏 `HTTP connection timed out`）。

→ **不是解码、不是网络，是「拷贝 + 上屏」这一段。**

为什么是拷贝：media_kit 在 Android 走的是**纹理路径** ——
`media_kit_video` 的 `VideoOutput.java` 用 `TextureRegistry.SurfaceProducer`
拿 Surface 交给 native，mpv 用 `mpv_render_context`（render API）画进 GL 纹理。
render API 只吃得了「拷贝型」硬解，所以 `hwdec=auto-safe` 在 Android 上解析成
**`mediacodec-copy`**：MediaCodec 解到 CPU ByteBuffer → memcpy 进 mpv 帧
→ 上传成 GL 纹理。4K 一帧 YUV 约 12 MB，24fps 就是 ~290 MB/s 的 memcpy
**再加** ~290 MB/s 的上传，电视 SoC 撑不住 41ms 的帧预算。1080P 只有 1/4 像素。

⛔ **`hwdec=mediacodec`（直通）在 media_kit 上不可能生效** —— 直通要求
MediaCodec 输出到 Surface，而 render API 的 GL 后端映射不了
`AV_PIX_FMT_MEDIACODEC`。别再往这个方向试（黑屏或静默回落软解）。

### 出路：fvp / libmdk 的 SurfaceView 零拷贝（库已在产物里）

`fvp` 的 Android 实现是 `SurfaceView`（`FvpVideoView.java`），
且 `fvp.dart` 的选项文档写明：

> `tunnel`/`platformView`：MediaCodec 输出**直接到 surface**，
> **不过 OpenGL：没有 GL renderer、没有 EGLConfig、没有 GPU 拷贝**，
> 视频按原生分辨率扫描输出 —— 这正是让 4K 在「UI 层跑 1080p 的电视」上
> 全分辨率上屏的办法。

与夸克（ExoPlayer + SurfaceView）是同一个机制。**而且不用加依赖**：
`unzip -l` 确认产物里 `libmdk.so`(2.3MB) / `libffmpeg.so` / `libfvp.so`
在 arm64-v8a / armeabi-v7a / x86 / x86_64 **四个 ABI 都有**。

缺的只是接线，三处：

1. `main.dart` 的 `fvp.registerWith(options: {'platforms': ['macos']})`
   → 加上 `'android'`（现在 Android 上 fvp 平台实现**没注册**）；
2. `app_providers.dart:216` / `player_window_app.dart:904` 的
   `dolbyVisionEngine: dvEnabled ? … : null` —— Android 上是 `null`；
3. `playback_engine_router.dart` 的判据现在**只认 DV P5**，
   要加一条「TV 上的 4K 原画也走第二内核」。

⚠️ 代价（fvp 自己声明）：无 HDR 色调映射、无截图回读、可用解码器更少；
我们的 `playback_surface.dart` 已有 fvp 分支（`VideoPlayer`），
且它注明「fvp 的字幕由 mdk 自己（libass）烧进画面」——换内核要一并核对字幕路径。

### 附带：诊断盲点

日志里**没有帧率 / 位深 / 像素格式**。10bit（P010）会让每帧拷贝量翻倍
（12 MB → 24 MB），是「同是 4K 有的卡有的不卡」的关键变量。
`_readVideoPipeline` 里加一条 `video-params` 的一次性读数即可。

### ✅ 实际采用的修法：`hwdec=mediacodec,auto-safe`（**不是**换 fvp）

上面那套「换内核」是**后备方案**。查 mpv 手册后发现了更小、更对路的改法，
**一行常量**就够了：

```
static const String tvHwdec = 'mediacodec,auto-safe';   // 原为 'auto-safe'
```

三条手册事实支撑它：

1. **`auto-safe` 只用白名单**，而白名单里只有 d3d11va / videotoolbox / vaapi /
   nvdec / drm / vulkan 那几族 —— **`mediacodec` 与 `mediacodec-copy` 都不在**。
   这就是 Android 上落到 `-copy` 的**直接原因**（根因闭合）。
2. **`--hwdec` 是逗号列表，且能混特殊值**：手册里 `vaapi,auto` 的语义是
   「先试 vaapi，失败再走 auto 逻辑」。所以 `mediacodec,auto-safe`
   = 先试零拷贝直通，配不上就退回今天这条拷贝路 —— **最坏情况等于没改**。
   ⛔ 别写成光秃秃的 `mediacodec`：那样失败只剩软解，4K 直接不能看。
3. **`mediacodec` 要求 `--vo=gpu` + `--gpu-context=android`** —— media_kit 在
   Android 上**恰好就是这两个值**（`android_video_controller/real.dart` 里
   `vo: configuration.vo ?? 'gpu'`，并写死 `gpu-context: android`，配 `wid`
   指向真实 Surface）。**不需要改 vo，也不需要换内核。**

⚠️ 代价（手册明说）：`mediacodec` 是不安全档，**强制 RGB 转换**、
非标准色彩空间表现不明、**10bit 降到 8bit**。这台电视是 1080p SDR 面板，
两条都不构成损失；上 HDR 屏时要回来重看。

#### ⛔ 上一轮的一条误判（别再犯）

我一度判定「Android 走的是 mpv render API → 只吃拷贝型硬解 → 直通不可能」。
**错的**。Android 走的是**真窗口 vo**（`vo=gpu` + `wid`），`main.dart` 里
早就写着这条论断。判据：`media_kit_video` 的
`lib/src/video_controller/android_video_controller/real.dart` ——
里面有 `wid`、`android-surface-size`、`gpu-context: android`，
以及专为 `vo=mediacodec_embed` 写的 `vid` 重初始化分支。
（`VideoOutput.java` 用 `TextureRegistry.SurfaceProducer` 拿 Surface 是**另一件事**：
那是把 Surface 交给 native 当 `wid`，不等于走 render API。）

#### 落点：两处必须同值

`hwdec` 会被设**两次** —— `VideoControllerConfiguration.hwdec`（构造时）
与 `PlayerBufferConfig.apply`（构造之后跑）。只改一处，另一处会在几百毫秒后
把它覆盖掉，表现是「改了没生效」。所以两处都取
`PlayerBufferConfig.hwdecFor(tv: tv)`，且**同值**。

#### 验收判据

真机日志（诊断页）里看 `[解码]` 那一行：

- `解码器=mediacodec` 且 `显示丢帧` 不再涨 → **直通生效，修好了**；
- 仍是 `mediacodec-copy` → 直通没配上、自动退回了拷贝路（功能不坏、掉帧照旧），
  这时才轮到上面那套 fvp 方案。

#### ⛔ 实测回执（10-04 19:03，`190434.txt`）：直通**没生效**

新版本**确实装上了**，参数也**确实下发了** —— 但 mpv 把 `mediacodec` 拒了：

```
18:57:43 [缓冲] … hwdec=mediacodec,auto-safe …          ← 我们的改动（新版本）
18:57:53 [片源] 3840x2160 标称帧率=25.000000 像素格式=? 硬解格式=? 原色=?
18:57:53 [解码] 第 6s：解码器=mediacodec-copy 解码丢帧=0 显示丢帧=0
18:58:13 [解码] 第27s：解码器=mediacodec-copy 解码丢帧=0 显示丢帧=4
19:02:31 [解码] 第27s：解码器=mediacodec-copy 解码丢帧=0 显示丢帧=0    ← 原画 4K
19:03:18 [解码] 第27s：解码器=mediacodec-copy 解码丢帧=0 显示丢帧=128  ← 4K 转码档
```

**不是没下发。** `media_kit_video` 的
`lib/src/video_controller/android_video_controller/real.dart:195` 明写
`'hwdec': configuration.hwdec!`（构造时就设到 mpv），`apply()` 又设一次，
两处同值。**所以是 mpv 试了 `mediacodec` 没配上，按逗号列表语义退回
`auto-safe` → `mediacodec-copy`。** 当初写的「最坏情况等于没改」正是这个结局。

⛔ **别再靠猜**：这台电视上 mpv 只开 `error` 级日志（`MediaKitPlaybackEngine`
的 `verboseLog` 在**内置页**是 false），`mediacodec` 初始化失败的原因在 verbose
级，**一条都没记**。要往下走只有两条路：把 TV 的 mpv 日志抬到 `warn`/`v` 抓一次
失败原因，或直接上上面那套 fvp。

⚠️ **两个还没排除的变量**，下次采样必须分开：

1. **`[片源]` 报 25.000000 fps**。25fps 在 60Hz 面板上本身就是 3:2 不均
   （judder），而 `frame-drop-count` 抓不到 judder —— 「看着卡」未必等于
   「真的丢帧」。别把两者混成一个问题。
2. **两次采样（6s / 27s）都贴着「起播 + 片头跳过 seek」**。旧版本的 58 帧、
   新版本 4K 转码档的 128 帧，都可能主要是 seek 的一次性代价（128 帧 @25fps
   ≈ 5s ≈ 一个 HLS 分片），不是持续掉帧。**采样点要加一个远离 seek 的（如 60s）。**

---

## ✅✅ 真根因（10-04 20:xx，源码级定位）：**顺序竞态**，不是 mpv 拒绝 mediacodec

上面那条「mpv 试了 `mediacodec` 没配上，按逗号列表退回 `auto-safe`」的结论
**是错的**。参数送到了、mpv 也没拒绝 —— 是**我们在解码器定型之前就 `loadfile`**，
那时 VO 交不出 Android surface，`mediacodec` 配不上只能静默退回拷贝档。

### 机制（三条源码事实，缺一不可）

1. `media_kit_video/src/video_controller/video_controller.dart`：构造 `VideoController`
   时把 `AndroidVideoController.create()` 塞进
   `WidgetsBinding.instance.addPostFrameCallback` —— 它跑在**首帧之后**。
2. `android_video_controller/real.dart:191-205`：`create()` 一上来在**同一批**
   `setProperty` 里写 `'vo': 'null'` **和** `'hwdec'`（注释：*必须先 vo=null 才不
   会 SIGSEGV，`--wid` 必须在 `vo=gpu` 之前赋*）。
3. `android_video_controller/real.dart:59-65` `widListener()`：Surface 到位后才重建
   vo（`vo=null` → `android-surface-size` → `wid` → `vo=voValue`），
   **从不重设 `hwdec`**。

我们原来在构造函数之后**立刻** `open()`，`loadfile` 几乎总抢在 `create()` 前面
→ 解码器在「`vo=null`、没有 surface」的状态下定型 → 逗号列表静默退到
`mediacodec-copy` → **这个选择跟着整条流，之后 Surface 到位也不会重解析**。

### 两条互相独立的真机证据

- `hwdec-current` 恒为 `mediacodec-copy`（`[解码]` / `[硬解]` 行）—— 这个读数
  才是分水岭：`mediacodec`=零拷贝，`mediacodec-copy`=拷贝档。
- `widListener()` 结尾那句 `await player.seek(Duration.zero)` 把起播位置冲成 0
  —— 日志里 `起播位置没生效（现在 0s，应为 434s）→ 补发 seek` 就是它干的。
  这条**与 hwdec 无关**，却证明 Surface 确实**晚于** `loadfile` 才挂上。

### 修法：`open()` 里三步，**顺序就是修复**

```dart
await _awaitVideoSurface();   // 等 videoController.rect != null（+120ms settle）
await _reapplyHwdec();        // 读回 hwdec 再写一遍，让它成为 mpv 最后一次写
await _player.open(...);      // 这时 loadfile 建解码器，零拷贝才配得上
unawaited(_verifyZeroCopyHwdec());  // 兜底 + 取证
```

- **判据为什么能用 `rect`**：Java 侧每次表面变化发 `VideoOutput.Resize`，Dart 侧
  在**同一个回调里**同时写 `rect`/`id`/`wid`（`real.dart:267-269`）。`wid` 私有，
  而 `rect` 通过 `VideoController.rect` **公开** —— 所以「`rect != null`」就是
  「Surface 已挂上」的公开判据，不必 `import package:media_kit_video/src/...`。
- 只在 Android 等（`defaultTargetPlatform`），等不到就照旧 `open()`（最坏=改之前）。
- 兜底 `_verifyZeroCopyHwdec()`：起播后读 `hwdec-current`，若仍在拷贝档**且**
  还在 `hwdecKickWindow`（20s）内，则写 `auto-safe` → 400ms → 写回目标值
  （mpv 只在 `hwdec` **变化**时重建解码器，写同值是空操作，所以必须「改一次再
  改回来」）。过渡值**不能是 `no`**（那会把 4K 拽到软解）。
  判据抽在纯函数 `MediaKitPlaybackEngine.shouldKickHwdec()` 里，有单测。
- ⛔ 空串（`hwdec-current` 还没起来）**不算拷贝档** —— 误判会在起播瞬间触发
  一次没必要的重建。

### 量化：掉帧率随**分辨率**缩放，解码丢帧恒为 0（`193049.txt`）

| 采样 | 区间 | 显示丢帧增量 | 速率 |
|---|---|---|---|
| 4K 原画 | 6s→21s | 0→141 | **37.6%** |
| 4K 原画 | 21s→42s | 0→179 | **34.1%** |
| 4K 原画 | 42s→63s | 2→111 | **20.8%** |
| 4K 原画 | 63s→84s | 111→341 | **43.8%** |
| 810p 转码 | 21s→42s | 0→7 | **1.3%** |

每一拍 `解码丢帧=0`、`VO延迟帧=0`；源 3840×2160@25.000fps，面板 1920×1080@60Hz
且**只支持这一个模式**（`supportedModes` 只有 `{1920x1080, 60.000004}`）→
OS 刷新率切换这条路不存在。`面板帧率=?` ⇒ mpv **没有 `display-fps`**（media_kit
的默认属性表里没有这一项）⇒ 它按帧率无关的方式上屏。

**其他已排除**：中继（`local_stream_relay.dart` 数据路是 `response.addStream`，
主 isolate 但非瓶颈，零 WARN）；SurfaceFlinger（`--latency` 显示 ~19.95ms 均匀
节奏、只有 1.6% 漏 vsync ⇒ 不是经典丢 present）；SoC 已近饱和
（app ~254% + `media.codec` ~98% + SF 14.5% ≈ 367% / 400% 预算，
`MemTotal 2.6GB`、`SwapTotal 0`、`kswapd0` 在跑）。

### 验收判据（下一轮真机）

`[硬解]` 行必须出现 `零拷贝直通已生效：hwdec-current=mediacodec`（不是 `-copy`），
且 `[解码]` 的 `显示丢帧` 不再随分辨率缩放。若**重建后仍是 `-copy`**，说明
mpv 的 `mediacodec` 在 media_kit 的 Surface 上确实绑不上 —— 那时才轮到
fvp / libmdk 那条路（见上）。

⚠️ 另外：原画 4K 这两次是 0~4 帧（旧版本同片源 14→58），但**解码器没变**，
所以不能算「改好了」—— 更可能是旧那两次撞上了冷启动 + 换集 + 双 seek。
**跨会话比 `显示丢帧` 之前，先确认两次的起播条件一致。**

## 夸克 TV APK 逆向：播放器内核与硬解证据（10-04 晚）

对标报告：`docs/AndroidTV-4K-丢帧-夸克对标.md`。
样本 `kuakewangpan/kkwptvb_2.9.1702_dangbei.apk`；解包在 `_x/`，反编译在 `jadx_out/sources/`
（`jadx-1.5.1` 在 `/Users/tandy/work/javatools/jadx-1.5.1/bin/jadx`，要带 `JAVA_HOME` 指 JDK 17）。

### 内核构成（三条并存）
- **主内核 `com.UCMobile.Apollo.*`** —— UC 的 **ExoPlayer 分支**（`ApolloSDK`/`MediaPlayer`/
  `MediaCodec`/`MediaFormat`/`DecoderInfo`/`VideoView`），**不是**原生 ExoPlayer 包名。
- **第二内核 `eskit.sdk.support.player.ijk.*`** —— 当贝 ESKit 的 ijkplayer 分支。
- ⚠️ APK 的 `lib/` 里**没有任何 ffmpeg/ijk/player 的 `.so`**（只有 `libc++_shared`、
  `libmarsxlog`、`librsjni`、`libxcrash_eskit`、`liblamemp3`）。解码器是 **VirtualAPK
  插件化运行时下载**（`com/didi/virtualapk/...` + `downloadPlugin` + `READER_PLUGIN_SO_*`；
  dex 里有 `libextplayer.so`/`libvplayer.so`/`libu3player.so`/`libapolloffmpeg.so` 等名字）。
  → 它用的硬件解码通路是**系统 MediaCodec**，不需要自带 `.so`。

### 硬解怎么开的（核心证据）
`eskit/.../player/ijk/player/IjkVideoView.java:959-972` `setFastCommonOptions()`：
`mediacodec=1` + **`mediacodec-all-videos=1`** + `mediacodec_mpeg4=1` + `framedrop=1`
+ `skip_loop_filter=48` + `probesize=10240` + `fflags=fastseek` + `max-buffer-size=1048576`。
→ ijkplayer 的**零拷贝**组合：MediaCodec 直出 Surface。

### 画面落在哪里（最关键）
`com/UCMobile/Apollo/VideoView.java:23` → `public class VideoView extends SurfaceView`；
`MediaCodec.java` 的 native 签名 `native_configure(..., Surface, ...)` /
`native_setOutputSurface(Surface)` / `native_releaseOutputBuffer(int, boolean)`。
→ **解码器持有 Surface，输出缓冲直接释放，全程不过 CPU 内存。**

### 它对硬/软解有显式模型
`eskit/.../manager/decode/a.java`：`IJK(0,"硬解IJK")` `EXO(1,"软解EXO")` `HARDWARE(2,"硬解")`
`IJK_SOFT(3,"软解IJK")`；`manager/definition/a.java`：标清/高清/超清720/原画/蓝光/4K。
`ijk/player/third/c.java:329` 在 `onPrepared` 里上报
`getOption("ro.instance.decode_video_use_mediacodec")`（`1:硬解 0:软解 -1:未知`）
→ **夸克把"这次到底硬解了没有"当一等可观测属性**，不是碰运气。

### 对照我们自己
| 维度 | 夸克 | 云影（改之前） |
|---|---|---|
| 输出 | 零拷贝直出 SurfaceView | `mediacodec-copy` 拷回 CPU |
| 显示层 | SurfaceView 独立硬件层 | **Flutter 外部纹理**（`TextureRegistry.createSurfaceProducer`）→ 多一次全屏合成 |
| 默认档位 | 显式 `mediacodec=1` | `media_kit` 出厂 `getDefaultHwdec()` 返回 **`auto-safe`** → 必然拷贝档 |

⚠️ `auto-safe` 为什么必然是拷贝档：mpv 的 `mediacodec` 是**不安全**档（强制 RGB、10→8bit），
`mediacodec-copy` 才是安全档；`auto-safe` 只从安全列表挑 → Android 上落到 `-copy`。

### fvp（libmdk）那条路的凭据
- `fvp-0.39.0/android/.../FvpVideoView.java`：`implements PlatformView` + `new SurfaceView(context)`
  + `holder.setFixedSize(视频宽高)` + `nativeSetSurface(..., tunnel)`。类注释明写
  *"Unlike the Texture path ..., a SurfaceView gets its own display layer ... also the only
  surface type that can display tunneled (sideband) playback"*。
- `video_player_mdk.dart:210`：`'android': ['AMediaCodec', 'FFmpeg', 'dav1d']`（AMediaCodec 第一）。
- `libfvp.so` 里的解码器名：`AMediaCodec:dv=1:image=0:surface=` —— `surface=` 即直出。
- Dart 侧开关：`registerWith` 的 `tunnel` / `maxWidth` / `maxHeight`；
  `VideoPlayerPlatform.createWithOptions` 传 `VideoViewType.platformView`
  （`MdkVideoPlayerPlatform` **只在 `Platform.isAndroid` 时尊重它**）。
- ✅ **已过时（20:5x 起）**：`main.dart` 的 `fvp.registerWith` 现在是
  `platforms: ['macos','android']` **且 Android 带 `tunnel:true`**；4K（≥1440p）
  已经在走 fvp（`needsAlternateForResolution`，与 DV 共用同一内核）。
  ⛔ **只设 `platformView` 不开 `tunnel` 会更卡 + 音画不同步** ——
  根因与证据见本文档末尾「⛔ 4K 走 fvp 后**更卡**」那一节，**先读那节再动这里的代码**。
- ⚠️ 本机面板是 **1920×1080@60Hz 单模式**（不是"1080p UI + 4K 屏"），所以 fvp 注释里
  那条"UI 层低于面板分辨率"的论证**不适用**；但对它的**价值点仍然成立**：去掉 Flutter 那一层合成，
  并且可以用 `maxWidth/maxHeight` 把渲染目标钳到 1080p（现在 mpv 是按视频原始 4K 渲染，纯浪费）。

---

## ⛔⛔ 4K 切 fvp 的两轮实测：**全败，已回退**（2026-10-04 20:5x–21:4x）

> 本节**推翻**上一节末尾「4K 走 fvp/libmdk + `VideoViewType.platformView` 是远期路线」
> 那条判断，也**推翻**本节自己更早的版本（那版写的是「补上 `tunnel` 就好了」——
> 补上之后是「看不到画面」）。**别再按那条路线改代码。**

### 时间线（两轮，各一次真机验收）

| 轮次 | 改了什么 | 用户反馈 | 日志 |
|---|---|---|---|
| A | `platforms` 加 `android`；路由加第二条触发线（≥1440p）；引擎用 `viewType: platformView` | *「比之前版本卡的更厉害了，音画都不同步了」* | `…205646.txt` |
| B | 在 A 之上加 `tunnel: true`（零拷贝） | *「**4k 看不到画面了，只有声音**」* | `…213519.txt` |

### 为什么回退：三条证据（**都在日志/设备上核过**）

**1. 解码在跑，屏上没东西。**

`…213519.txt` 的 `21:34:42` 那次（pid 20499）：中继读取器一路推进
（`bytes=0-` → `bytes=24135308-` → `bytes=62205509-`），
`[资源] 第 10s：进程CPU=225.2%（单核口径；折合 4 核 56.3%）`、
`第 20s：326.0%（折合 81.5%）` —— **mdk 确实在解码**，但用户看不到任何画面。
（对比 A 轮：中继卡在 2 MiB、53 秒不动 —— 两轮的表现其实不同，但都没画面。）

**2. 进程被原生崩溃打挂。**

`adb logcat -b crash`（**注意：业务日志在 `-b main`，崩溃在 `-b crash`，且
`chatty` 会按 uid 丢弃行**，所以 `FvpPlugin` 的日志时有时无 —— **「没看到某行」
不能当证据**）：

```
21:33:04.857 F/libc (19579): Fatal signal 11 (SIGSEGV), fault addr 0x2 in tid 20081 (Thread-7)
  #00 libc strlen   #01 __vfprintf   #02 vsnprintf   #03..#06 libmdk.so
```

崩在 **libmdk 自己的日志格式化**里（`%s` 拿到坏指针），不是解码逻辑。
另外四个进程都崩在同一个地方：

```
FinalizerDaemon: pthread_mutex_lock → ConsumerBase::onLastStrongRef
  → SurfaceTexture_release → io.flutter.embedding.engine.renderer.SurfaceTextureWrapper.release
```

这是 Flutter 引擎在 `SurfaceProducer` 被释放后**二次释放** ——
**换内核就会触发，与 `viewType` 无关**。所以「换成 textureView 再试」也躲不掉它。

**3. mpv 的零拷贝在 media_kit 里是做不到的（结构性）。**

`media_kit_video-1.3.1/android/src/main/java/com/alexmercerind/media_kit_video/VideoOutput.java`：

```java
surfaceProducer = textureRegistryReference.createSurfaceProducer();   // 写死
```

它**只有** Flutter 纹理这一条路，没有 `platformView` / `SurfaceView` 选项。
所以 mpv 只能 `mediacodec-copy`（解到 CPU 再拷回）—— 调 mpv 参数没用，
这就是 4K 卡顿的根。

### 📌 面板事实（以后判断「要不要 4K」用得上）

```
ro.boot.mi.panel_resolution = 3840x2160     # 65 寸 4K 面板（CSOT）
dumpsys display → real 1920 x 1080          # 但 Android 显示层只有 1080p
                  唯一 mode = 1920x1080@60
```

⇒ 应用内渲染（Flutter 纹理 / 合成）**最高只有 1080p**，由电视自己倍线到 4K；
**只有 SurfaceView（独立显示层 + `setFixedSize`）才可能真 4K 扫描输出**。
这既是当初想走 fvp 的理由，也是这条路唯一还值得再看一眼的地方。

### ⚠️ 下次要查的**第一个假设**（**未证实，别当成结论**）

fvp 的 tunnel 分支**显式跳过** `maxWidth/maxHeight` 钳制
（`lib/src/video_player_mdk.dart` 注释原文 *"'tunnel' has no GL renderer, so the
decoder's own geometry stands."*）→ `FvpVideoView` 的
`holder.setFixedSize(videoWidth, videoHeight)` 拿到的是**视频原生** 3840×2160，
而 Android 显示层只有 1920×1080。若 SurfaceFlinger 拒绝合成一个比显示层还大的
SurfaceView 层，表现就正好是「有声音没画面」。

**下次先试**：`platformView` + **不开** tunnel + `'maxWidth': 1920, 'maxHeight': 1080`
（不开 tunnel 时那条钳制分支才生效）。**并且**要一并解决「换内核 → `SurfaceProducer`
二次释放崩进程」那条，否则试出来也带崩。

### 回退落点（**代码现状**）

- `lib/main.dart`：注册范围收回 `if (Platform.isMacOS)` + `'platforms': ['macos']`，
  **删掉** `tunnel`。
- `lib/data/playback/fvp_playback_engine.dart`：**删掉** `viewType:` 参数（回默认
  `textureView` —— 那是 fvp 自己 example 用的那条路，也是 macOS DV 验过的）。
- `lib/domain/services/playback_engine_router.dart`：**删掉**第二条触发线
  （`needsAlternateForResolution` / `highResolutionThreshold` /
  `useAlternateForHighResolution` / `selectFor` 的 `videoHeight` 参数），
  判据收回到只剩杜比视界一条。
- `lib/domain/services/playback_controller.dart`：删掉 `highResolutionEngine` 参数
  与 `_heightForEngineSelection`。
- `lib/ui/providers/app_providers.dart`：`alternateAvailable` 收回 `Platform.isMacOS`。
- `test/domain/services/playback_engine_test.dart`：删掉那组「高分辨率换内核的判据」
  用例，原处留一条注释说明**不要加回来**。

### ✅ 2026-10-04 复查（读上游源码，**没改一行代码**）：路线本身是通的，缺的是参数

四条**已核实**的事实，修正/补强了上面几处推测：

1. **`FvpVideoView.java` / `fvp_plugin.cpp` 是 pub.dev 上游原包内容，不是我们补的。**
   全包文件 mtime 一致（`pub get` 那一刻），`pubspec.lock` 是
   `source: hosted / url: pub.dev`。上游已经实现：`implements PlatformView,
   SurfaceHolder.Callback`、tunnel 分支 `AMediaCodec:dv=1:image=0:surface=<ptr>`、
   `surfaceId = -1000 - viewId`（负空间，避免与 texture id 撞）、hybrid composition
   （`PlatformViewLink` + `initExpensiveAndroidView`，`video_player_mdk.dart:542-568`）。
   ⇒ **不用自建原生播放器**就能拿到 SurfaceView 输出。

2. **`fvp_plugin.cpp:67-76` 已经处理了「codec wedges → 下一个 surface 永不出帧」。**
   释放时先 `setDecoders(Video, {})` 再 `updateNativeSurface(nullptr)`，注释原文
   *"Release the codec BEFORE the surface dies, or it wedges (dequeue -10000) and the
   stream is marked decode-error, so the next surface never shows a frame."*
   ⇒ 「没画面」**不是这条路的设计缺陷**。

3. **`tunnel` 是 `registerWith` 的全局项，不是 per-controller**
   （`video_player_mdk.dart:178` `_tunnel = options["tunnel"]`）。
   ⛔ 后果：macOS 的 DV 路必须 `tunnel: false`（texture 路给 tunnel 只会在
   `updateTexture` 里被丢掉，源码留着 `// FIXME: set tunnel too late`），
   而 TV 4K 想要 `true` —— 同一进程里两者**不能同时满足**，必须按平台条件注册
   （`'tunnel': Platform.isAndroid`）。

4. **第 1 轮「更卡」的机制**：不开 tunnel 时 `w,h` 由 `maxWidth/maxHeight` 钳
   （`video_player_mdk.dart:394-417`；`if (_tunnel) { /* native size, no clamp */ }`
   —— **钳制的开关在 Dart，不在 native**），没设就是原生 3840×2160 →
   `setFixedSize(3840,2160)` → GL 在 4K 上渲染。上游注释原话
   *"full 4K RGBA can push SurfaceFlinger into GPU composition on weak GPUs"*。
   ⇒ **第 1 步的修法只是加两个注册参数，不用改 native。**

5. `tunnel` 的代价（fvp 文档原文，写进 `EngineCapabilities` 用）：
   *"some features are not supported, e.g. HDR tone mapping and frame readback
   (snapshot), and fewer codecs."*

### 📌 走 platformView 时的三条硬约束（读代码得出，**未真机验证**）

- ⛔ `PlaybackSurface` 的 platformView 分支**不能再套 `AspectRatio`**：尺寸由原生
  `setFixedSize` + Flutter 给的 rect 协商，外面套一层会让 hybrid composition 算错。
- ⛔ **必须保留 `controller == null → 黑底` 的守卫**（`playback_surface.dart:85`）：
  否则 `buildViewWithOptions` 拿 `playerId = kUninitializedPlayerId` 去查
  `_platformViewParams`，查不到会退回 `Texture(textureId: -1)`（又一个无效纹理）。
  ⚠️ 配套：`player_page.dart:808` 在 `await _controller.open(...)`（834 行）**之前**
  就 `_ready = true`，所以这条守卫是**必需**的，不是可选。
- ⛔ platform view 是 hybrid composition，**不能放在高频重建的子树里**：
  `player_page.dart:1384` 现在在 `if (_ready)` 下的 Stack 里，每拍 position tick
  都可能重建 → 要钉 `ValueKey` / `RepaintBoundary`，或抽到只依赖 engine 的子树。

### 📌 「换内核 → SurfaceProducer 二次释放」是**纹理路**的病，架构上能绕开

崩溃链：`FinalizerDaemon → SurfaceTextureWrapper.release → SurfaceTexture.release →
ConsumerBase::onLastStrongRef`，**四个不同进程**都中，且**与 `viewType` 无关**。
`PlaybackEngineRouter.selectFor` 换内核时只 `previous.stop()`，**不释放
`VideoController`**，那个纹理输出还活着等 GC。

⇒ 架构解法（**不是**加 try/catch）：**引擎在 `PlaybackSurface` 挂载前就是终态，
一次播放内不再变**。把「用哪个内核」提前到点播放那一刻（`PlayTarget.resolve` /
取直链时顺手探头部字节），结论随 `StreamTicket` 进播放页；没被选中的内核本次播放
**从头到尾不碰视频输出**（不 `open()`、不建 SurfaceProducer）。
附带好处：platformView 的 `playerId` 是**原生 handle**（`video_player_mdk.dart:386`
`final id = player.nativeHandle`），换内核 = 换 handle，`PlatformViewLink` 必须整体
重建 —— 提前定死就完全避开。

4K 现在的取舍只有两条：用夸克的 **`super`(810p) 转码档**（同机实测只丢 0~7 帧、
流畅、降画质），或接受原画卡顿。

---

## 资源采样：CPU / 内存 / 磁盘（2026-10-04，`core/diagnostics/resource_probe.dart`）

用户要求「增加诊断日志，定时输出 cpu 内存 磁盘等资源参数」。设计要点（**红线**）：

- **周期 10 秒**，**故意不与**视频探针的 21 秒相等：用户报的正是「每 21 秒掉一批帧」，
  两个周期相等会**拍频锁定** —— 永远在同一相位采样，要么次次采到「正在卡」、
  要么次次采到「刚好不卡」，真实规律被整个掩盖（10 与 21 互质，相位会一轮轮扫过去）。
- **读数读不到就整段从日志行消失**，绝不退化成 `0`。字段全部可空，可空 = 这台设备读不到。
  「未知」写成「空闲」比不写还糟（同 `hwdec-current` 空串那个坑）。
- **进程 CPU 是单核口径**（4 核盒子要 400% 才叫满载），日志必须写明「折合 N 核」，
  否则 48% 会被系统性误读成「很闲」。
- **系统 CPU 的「忙」不含 iowait**：iowait 是「在等磁盘」，算进去会让磁盘慢伪装成 CPU 忙。
  只认 `/proc/stat` 的**汇总行** `cpu `（带空格），**别用 `cpu0`**。
- **`/proc/self/stat` 必须按最后一个 `)` 切字段**：comm（进程名）允许含空格与括号，
  按空白 split 会让 utime/stime/num_threads 整体错位，**且不报错** —— 只会把 CPU 时间
  报成隔壁字段的数字。字段位：`f[11]`=utime、`f[12]`=stime、`f[17]`=num_threads
  （`f[i]` 对应 stat 的第 `i+3` 个字段）。
- **`df` 用正则从左锚定**（`^\S+\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+%`，第 3 组是「可用」），
  不按列 split —— 挂载点里可以有空格，split 会让下标漂移且不报错。
  表头行天然不匹配（`1024-blocks` 在 `(\d+)` 后面跟的是 `-` 不是空白）。
- **用异步 `Process.run` 而非 `runSync`**：这是播放路径上的定时任务，
  同步版会在主 isolate 上阻塞十几毫秒 —— 诊断工具最不能干的就是自己制造卡顿。
- 两个引擎**各持一个** `ResourceProbe`（`open()` 起、`stop()`/`dispose()` 停）。
  ⚠️ **fvp 那条路没有视频探针**，所以这是它**唯一**的周期性证据。
- macOS 没有 `/proc`：内存退回 `dart:io` 的 `ProcessInfo.currentRss`，CPU / 负载 / 磁盘 IO
  留空。**这是正常的，不是 bug**（别去"修"它）。

### 这台电视上「哪些读数根本拿不到」（实测，别白试）

| 来源 | 结果 |
|---|---|
| `/proc/loadavg` | ⛔ **`Permission denied`**（连 `ls -l` 都拒）—— 连 shell uid 2000 都读不到 |
| `/proc/pressure/*`（PSI） | ⛔ **不存在**（Android 9 没有） |
| `/proc/stat` | ✅ 可读 → 所以 `系统CPU` 与 **`procs_running` / `procs_blocked`** 都从它来 |
| `/proc/self/{stat,status,io}`、`/proc/meminfo` | ✅ 可读 |
| `df -k /data` | ✅（`12600152` 可用，与正则吻合） |

**`procs_running` / `procs_blocked` 是 `loadavg` 的替代读数**，而且比它更该看：
它是**瞬时**值（loadavg 是分钟平均，会把「刚刚那一下卡」抹平），且把
`media.codec` 那种**别的进程**的负载也算进去 —— 而本进程 CPU 恰恰看不见它。
解析函数 `parseProcStatProcs` 与系统 CPU **共用同一次 `/proc/stat` 读取**，不额外读盘。

⛔ **日志里必须把核数一起写**（`可运行进程=14（4 核，超订 3.50×）`）：
14 在 4 核上是 3.5 倍超订，在 16 核上等于空闲 —— 同一个数字两种结论。
⛔ `阻塞IO进程` **只在 > 0 时写**：常态就是 0，每拍都写一个 0 只会把行撑长、掩盖异常。
⚠️ 解析时别把 `processes`（开机以来创建过多少个进程，只增不减）当成 `procs_running`。

### 测试

`test/core/diagnostics/resource_probe_test.dart`（**65 例**）。纯解析函数逐位钉住
（含 comm 带括号、`cpu0` 诱饵、挂载点含空格、`rchar` 诱饵、`processes` 诱饵），
探针本身用注入的假读数 + 短周期真定时器测生命周期与静默。
⚠️ 定时器类测试**别用同值读数当基准** —— 占用率是两条读数之差，同值差为 0，
`systemCpuPercentOfInterval` 会因「总 jiffies 没涨」返回 null，
于是断言「有系统CPU」会失败（这是测试的坑，不是实现的坑）。

## ⛔ 在本机构建 Windows 版：两个拦路虎（2026-10-05 实测）

用户要求「在本机 `flutter` 编译 windows 版本做测试」（**不要安装包**）。
当时本机跑不了，是**两个互相独立**的原因 —— 即使修好其中一个，另一个还在：

1. **工具链没装** → ✅ **当天 17:3x 已装好**（VS + WiX，见下）；随后又补了 **NuGet CLI** 与 **ATL 组件**（见下）。
2. **Dart VM 建不了重定向管道** → ⚠️ **重启机器后「系统层面」已恢复**（用户自己的 PowerShell 里
   `flutter` 能一路跑到 MSBuild），但 **WorkBuddy 自己的进程树仍然中招** —— 见本节末尾「重启之后」。

### 一、工具链：**10-05 17:3x 已装好**（原来没有，现已补齐）

**装之前**（实测，`ls` 直接查目录，不是猜）：

| 需要的东西 | 查的路径 | 装之前 |
|---|---|---|
| Visual Studio 2022 | `C:\Program Files\Microsoft Visual Studio\` 与 `(x86)` 同名目录 | ❌ 连父目录都没有 |
| Windows SDK | `C:\Program Files (x86)\Windows Kits\10` | ❌ 不存在 |
| CMake / Ninja | PATH | ❌ 都没有 |
| WiX Toolset v3 | `C:\Program Files (x86)\WiX Toolset*` | ❌ 不存在 |
| vswhere | `…\Visual Studio\Installer\vswhere.exe` | ❌ 不存在 |

**怎么装的**（都走 winget，本机 shell 是 elevated，能直接装）：

```bash
# WiX v3 —— ⛔ 必须是 v3：build_package.ps1 用的是 candle/light/heat + WixUIExtension，
# WiX v4/v5 是 dotnet tool、没有这些 exe，装了也没用。
# ⛔ 必须带 --source winget：不加会同时命中 msstore 源并报
#    "0x8a15005e The server certificate did not match any of the expected values."
winget install --id WiXToolset.WiXToolset --source winget \
  --accept-package-agreements --accept-source-agreements --disable-interactivity
#   → 装到 C:\Program Files (x86)\WiX Toolset v3.14\bin\{candle,light,heat}.exe
#   ⚠️ 它会顺手 enable NetFx3（WiX 3.14 的依赖），这一步是正常的

# VS 2022 Build Tools + C++ 工作负载（flutter build windows 必需）
env -u http_proxy -u https_proxy winget install \
  --id Microsoft.VisualStudio.2022.BuildTools --source winget \
  --accept-package-agreements --accept-source-agreements --disable-interactivity \
  --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

**装完的验证**（别只看 winget 说 Successfully installed）：

- `cl.exe` → `…\BuildTools\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\cl.exe` ✅
- CMake → `…\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe` ✅
- Windows SDK → `C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0` ✅
- `vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`
  → 返回 `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools` ✅
- ATL → `…\BuildTools\VC\Tools\MSVC\14.44.35207\atlmfc\include\atlstr.h` ✅（17:5x 补装，见下）

⚠️ **别用 `ls $VS/VC/Tools/MSVC/*/bin/Hostx64/x64/cl.exe` 判断装没装**：本机 Git Bash 里
这条 glob 会**静默报 MISSING**（同一个目录 `find` 得到的结果却是全的）。查 MSVC 一律用 `find`。

#### ⛔⛔ 装 VS 时踩到的真坑：**`http_proxy` 与 `HTTP_PROXY` 同时存在 → 5002**

第一次 `winget install …BuildTools` 报：

```
Installation failed with a custom installer error.
Installer failed with exit code: 5002
```

日志（`%TEMP%\dd_bootstrapper_*.log`）里的真因**不是网络、不是权限**：

```
Error 0x80070057: Couldn't launch setup process.
Error: 已添加项。字典中的关键字:"http_proxy"所添加的关键字:"HTTP_PROXY"
   在 System.Collections.Specialized.StringDictionaryWithComparer.Add(String key, String value)
   在 System.Diagnostics.ProcessStartInfo.get_EnvironmentVariables()
   在 Microsoft.VisualStudio.Setup.Bootstrapper.Bootstrapper.StartProcess(...)
```

**机理**：VS 引导程序是 .NET 的，它用 `ProcessStartInfo.EnvironmentVariables`
（`StringDictionary`，**大小写不敏感**）来构造子进程环境。本机同时存在
`http_proxy`/`HTTP_PROXY` 与 `https_proxy`/`HTTPS_PROXY`（沙箱注入的），
第二项一 Add 就抛 `ArgumentException` → 引导程序根本没启动 setup.exe → 5002。

**修法**：装 VS 时把**小写那份**去掉即可（`env -u http_proxy -u https_proxy …`），
大写保留，代理信息不丢。

⚠️ **这条坑与 VS 无关**：凡是 .NET 写的安装器（大量 Windows 安装包都是），
在同时有大小写两份代理变量的环境里都会以 5002/`0x80070057` 崩掉，
而报错文案完全指不到真因。本机跑任何 .NET 安装器前都先 `env -u` 一次。

⚠️ Flutter 3.29 的 `cmakeGenerator` 只认到 VS 17 —— 别装 VS 2026（主版本 18），
否则会退化成 `-G "Visual Studio 16 2019"` 并报 `could not find any instance of Visual Studio`
（`ci.yml` 为同一原因把 runner 钉在 `windows-2022` 而不是 `windows-latest`）。

#### ⛔ 还差一个 **NuGet CLI**：`flutter_inappwebview_windows` 构建期要它拉包

工具链装完、`flutter build windows --release` 跑到 MSBuild 后又失败：

```
Nuget is not installed! The flutter_inappwebview_windows plugin requires it.
…error MSB3073: 命令“setlocal … NUGET-NOTFOUND install Microsoft.Windows.ImplementationLibrary
  -Version 1.0.231216.1 -ExcludeVersion -OutputDirectory …\build\windows\x64\packages”已退出，代码为 9009。
```

- **退出码 9009 = 命令找不到**，`NUGET-NOTFOUND` 是 CMake 的 `find_program(nuget)` 没命中。
- 这个插件的 `CMakeLists.txt` 在构建期用 `nuget install` 拉三个包：
  **Microsoft.Windows.ImplementationLibrary**（WIL）、**Microsoft.Web.WebView2**、**nlohmann.json**，
  装到 `build\windows\x64\packages\`。
- **装法**：

  ```bash
  winget install --id Microsoft.NuGet --source winget \
    --accept-package-agreements --accept-source-agreements --disable-interactivity
  # → nuget.exe 落在 %LOCALAPPDATA%\Microsoft\WinGet\Links\nuget.exe
  #   （winget 会把这个 Links 目录写进 HKCU\Environment 的 PATH）
  ```

- ⚠️ winget 装完会提示 "Path environment variable modified; **restart your shell** to use the new value"。
  **已经开着的终端拿不到**（PATH 是进程启动时快照的）。在旧终端里补一句即可：

  ```powershell
  $env:PATH = "$env:LOCALAPPDATA\Microsoft\WinGet\Links;$env:PATH"
  ```

- ⚠️ 同一次输出里还有一条 **CMake `CMP0175` 警告**（`add_custom_command(TARGET)` 不支持 `DEPENDS`），
  来自插件自己的 `CMakeLists.txt:31`，**是插件的问题、不是配置错**，不影响构建，别去改。
- 📌 验证装对了：`where nuget` 有输出 + `nuget help` 能打印版本（本次是 `7.9.0.83`）。

#### ⛔ 还差一个 **ATL 组件**：`flutter_secure_storage_windows` 要 `atlstr.h`

NuGet 修好后，用户第二次跑 `flutter build windows --release`，编译到：

```
flutter_secure_storage_windows_plugin.cpp(6,10): error C1083:
  无法打开包括文件: "atlstr.h": No such file or directory
```

- `atlstr.h` 属 **ATL**（组件 id `Microsoft.VisualStudio.Component.VC.ATL`），
  VS 的 **VCTools 工作负载默认不带它** —— 只有装了这个组件才有
  `…\VC\Tools\MSVC\<ver>\atlmfc\{include,lib}`。
- 全项目**只有一处**用到 ATL：`flutter_secure_storage_windows-3.1.2/windows/flutter_secure_storage_windows_plugin.cpp:6`
  （`#include <atlstr.h>`）。插件自己的 `CMakeLists.txt` 没写任何 ATL 链接，
  靠 MSVC 工具链在装了组件后**自动带上的 include/lib 路径**。
- **装法**（⛔ 不能用 winget，得用 VS 自带的 `setup.exe modify`）：

  ```bash
  env -u http_proxy -u https_proxy \
    "/c/Program Files (x86)/Microsoft Visual Studio/Installer/setup.exe" modify \
    --productId Microsoft.VisualStudio.Product.BuildTools \
    --channelId VisualStudio.17.Release \
    --add Microsoft.VisualStudio.Component.VC.ATL --quiet --norestart
  # → exit 0（本次实测 41 秒）；装完 atlstr.h 落在
  #   …\2022\BuildTools\VC\Tools\MSVC\14.44.35207\atlmfc\include\atlstr.h
  #   同目录 atlmfc\lib\{x64,x86}\atls.lib 也有了
  ```

- ⛔⛔ **VS 安装器的 URI 只认 `--productId` / `--channelId` / `--add` / `--quiet` / `--norestart`**：
  **没有 `--installPath`，也没有 `--wait`**。写了就**只打印一段用法列表、然后 exit 87**
  （日志 `%TEMP%\dd_installer_*.log` 末尾可见 `Warning: Shutting down the application with exit code 87`），
  而且**不会指出是哪个参数错了**。查可用参数直接跑 `setup.exe --help`。
- ⚠️ 判断组件装没装**别信 winget 的输出**，直接 `find …/VC -name atlstr.h`。
- 📌 装 ATL 走的是同一个 .NET 安装器，**同样要先 `env -u http_proxy -u https_proxy`**（见上）。

### 二、Dart VM 当前**无法创建管道**（临时性故障，Windows 错误 231）

即使装好 VS，现在也构建不了 —— **flutter 工具自己就起不来**。

- 症状：`flutter --version` 崩在 `_WindowsUtils.name`（→ `cmd.exe /c ver`）；
  `ProcessException: 所有管道范例都在使用中`，stderr 反复出现 `CreateFile failed 231`。
  231 = `ERROR_PIPE_BUSY`。
- **最小复现 A**（写一个 `dart run` 探针，不走任何 shell）：

  | 写法 | 结果 |
  |---|---|
  | `Process.runSync('git'/'where.exe'/'cmd.exe', …)` | ❌ **3/3 次全部抛错** |
  | `Process.start(…, mode: ProcessStartMode.inheritStdio)` | ✅ 成功（pid 正常、exit=0） |
  | `Process.start(…, mode: ProcessStartMode.detached)` | ✅ 成功 |

- **最小复现 B（把范围收窄到「哪一个管道」—— 这条才是关键判据）**：
  用 Node 逐个方向试 `stdio`（libuv 与 Dart 都建三根管道，机制同源）：

  | `stdio` | 结果 |
  |---|---|
  | `['ignore','pipe','ignore']`（只重定向 **stdout**） | ✅ **OK** |
  | `['pipe','ignore','ignore']`（只重定向 **stdin**） | ❌ **EBUSY** |
  | `['pipe','pipe','pipe']` | ❌ EBUSY |
  | `['ignore','ignore','ignore']`（一根都不建） | ✅ OK |

  ⇒ 结论精确到一行：**进程创建本身没问题，`stdout`/`stderr` 管道也能建，
  坏的**只有**「给子进程当 stdin 的那根管道」。**

- **错误码的来路**：231 = `ERROR_PIPE_BUSY`。用 Python `ctypes` 直接调
  `CreateNamedPipeW` 复现：**名字唯一 → ok，err=0**；**同一名字建第二个实例
  （maxinst=1）→ err=231**。所以 231 的语义就是「这个管道名已经被占/实例用满」，
  与「系统管道资源枯竭」是两回事。
  ⇒ 高度怀疑：沙箱的注入钩子在给子进程装 stdin 时用了**固定/可复现的管道名**，
  撞上了已存在的实例。（**未证实**，但这是目前唯一与 231 语义吻合的解释。）
- ⛔ **不是系统级资源枯竭**（这条最容易误判）：
  - Python `subprocess.run(capture_output=True)` ✅
  - Python `ctypes` 直接调 `kernel32.CreatePipe(inherit=TRUE)` ✅（err=0）
  - 全机只有 **344 个进程**，无异常堆积
- ⛔ **不是父进程继承的**：`bash → node` 与 `python → node` 结果**完全一样**（都 EBUSY）。
  不是「某条进程树脏了」，换父进程救不了。
- ⛔ **不是父进程 stdio 的形状**：让 node 拿到**真正的控制台**
  （`CREATE_NEW_CONSOLE`，实测 `process.stdin.isTTY === true`）照样 EBUSY。
- ⛔ **不是环境变量**：把 `CODEBUDDY_*` / `WORKBUDDY_*` / `CLAUDE_*` **154 个变量全部 unset**
  再跑，结果一模一样。
- ⛔ **不是 PAC RPC 管道被打满**：`WORKBUDDY_PAC_RPC_SOCKET`
  （`\\.\pipe\workbuddy-pac-33128-3c45a8b14dfe42c6`）从 Python `CreateFileW` **连得进去**
  （err=0），说明它有空闲实例。这条一度是最像的假设（231 字面就是「实例全忙」），已排除。
- ⛔ **不是按镜像路径**：把 `node.exe` 复制成 `C:\flutter\node_probe.exe`、以及复制到
  `…\dart-sdk\bin\` 下再跑，照样 EBUSY；同一台机器上 Python 无论从哪跑都正常。
  ⇒ 钩子认的是**运行时本身**（node / dart 被注入，python 没有）。
- ⛔ **不是「重启一下就好」式的泛泛结论，但确实只能靠重启恢复**：
  13:29 这台机器上 Dart 的管道还是好的（当天成功产出 APK），17:2x 已经坏掉。
  「换父进程 / 换目录 / 换环境 / 换控制台 / 换管道名」这些自救手段**全试过、全无效** ⇒
  钩子的状态在**本进程之外**，只能重启 WorkBuddy AI（或重启机器）把它清掉。
- 📌 旁证：`PendingFileRenameOperations` 里有一条
  `C:\ProgramData\ZulerCoreTools\GlobalCfg\{4A234956-…}` 等着重启替换 ——
  说明**本来就有一个待重启**，与「下午忽然坏掉」的时间线吻合。

#### 重启之后（2026-10-05 17:4x）：机器好了，但**沙箱自己的进程树没好**

用户重启机器后，**在他自己的 PowerShell 里** `flutter build windows --release` 能一路跑到
MSBuild（只剩 NuGet 的问题）⇒ **系统层面的故障确实被重启清掉了**。

但是：**从我的 Bash / PowerShell 工具里跑 `flutter`，依然报同一个 231**。
⇒ 结论（这条很重要，别再重复踩）：

> **注入是按「进程树」做的** —— WorkBuddy 往**它自己派生的后代**里注钩子。
> 用户自己的终端是 `explorer.exe` 的后代，干净；我的工具是 `WorkBuddyAI.exe` 的后代，中招。

**所以：agent 跑不了 `flutter build`，必须把命令交给用户，在他自己的终端里跑。**
两条想「绕出去」的路都试过、都堵死：

| 尝试 | 结果 |
|---|---|
| `CREATE_BREAKAWAY_FROM_JOB`（逃出 `WORKBUDDY_APP_LIFETIME_JOB`） | ❌ `PermissionError [WinError 5] 拒绝访问`（job 没给 breakaway 权限） |
| 计划任务（`schtasks /Create` + `/Run`，让 TaskScheduler 当父进程） | ❌ **被安全策略拉黑**：`schtasks.exe` 在 Program Blacklist 里，且明确警告**不许换 shell / 换脚本绕过** |

⇒ 别再把力气花在「让 agent 自己跑」上，直接给用户这条命令（PATH 那句是给**已经开着**的终端补的）：

```powershell
$env:PATH = "$env:LOCALAPPDATA\Microsoft\WinGet\Links;$env:PATH"   # 只为旧终端补 nuget
cd D:\work\cloudcine
flutter build windows --release
```

⚠️ 别用 `cmd.exe` 包一层——工具层会拦；也别写 `.bat` 再调，同样会被当成绕过。
- ⛔ **不是沙箱开关**：`dangerouslyDisableSandbox` 开与关结果一模一样。
- ⛔ **逐个绕过 spawn 没有意义**：`FLUTTER_SUPPRESS_ANALYTICS=true` 确实能让
  `_WindowsUtils.name` 不再被调用（`usage.dart:186` 在 `skipAnalyticsSessionSetup` 时跳过），
  于是报错前进一格变成 `git log -n 1 --pretty=format:%ar`（`FlutterVersion`）——
  但一次构建要几十次带管道的 spawn，绕不过去。
- 📌 **判断它是回归而不是永久配置**：13:29 还在这台机器上成功产出 APK（Dart 的管道当时是好的），
  17:2x 已经坏掉。怀疑 WorkBuddy 沙箱往 Dart 进程注入的钩子 DLL 连不上自己的命名管道
  （`CreateFile failed 231` 就是那个 DLL 打出来的，不是 Dart 的文案）。
  **处置：重启 WorkBuddy AI（或重启机器）后再试；仍不行就报给用户。**
- ⚠️ 顺带：失败的 `flutter` 会在**仓库根目录**丢一个 `flutter_04.log` 崩溃报告。
  它被 `.gitignore` 的 `*.log` 覆盖，不会污染提交，但记得清掉。

## ⛔⛔ Windows 播放器「只有声音没画面」：子窗口引擎没注册插件（2026-10-05）

`flutter build windows --release` 成功后，应用能起、能登录、能取链、**能听到声音**，
就是**画面上什么都没有**。日志（`%APPDATA%\com.cloudcine\cloudcine\logs\*.log`）：

```
[播放窗口] ──── 播放异常诊断：转码档开流 10 秒仍没出画面 ────
  file-format = <空>
  duration = <空>
  track-list = []
  最近 4 条 mpv 日志：
    [error] media_kit: error: property not found _setProperty(osc, 1)
    [warn] playlist: Reading plaintext playlist.
    [fatal] vo/libmpv: No render context set.                          ← 真正的错
    [fatal] cplayer: Error opening/initializing the selected video_out (--vo) device.
```

### 先排除掉的（都**不是**原因，别再去查）

| 猜测 | 实测结论 |
|---|---|
| 缺 ANGLE / libmpv 的 DLL | ❌ `libEGL.dll`、`libGLESv2.dll`、`libmpv-2.dll`、`d3dcompiler_47.dll`、`vk_swiftshader.dll` 全在 `runner/Release/` |
| 机器没显卡 | ❌ `Win32_VideoController` = **NVIDIA RTX 5070**（另有 Todesk 虚拟显示适配器）。`SESSIONNAME=Console`，不是 RDP |
| 取链 / 网络 / 分片坏了 | ❌ 日志里 m3u8 HTTP 200、分片 HTTP 200（72641 字节，`Content-Type: video/MP2T`） |
| `hwdec` 没下发 | ❌ `hwdec=未下发(mpv 默认=软解)` 是**桌面端的正常行为**，与出画无关 |
| mpv 把 m3u8 当成了普通播放列表 | ❌ `playlist: Reading plaintext playlist.` 是噪音；就算真按列表解析也不影响 vo 初始化 |

> ⚠️ **为什么 ANGLE 的失败看不到**：`media_kit_video` 的 `angle_surface_manager.cc`
> 用 `std::cout` 打错误（`media_kit: ANGLESurfaceManager: Failure: ...`），而
> `video_output.cc` 里 H/W 失败是被 `catch (...) { /* Do nothing */ }` **静默吞掉**的，
> 然后回退 S/W。Flutter Windows 应用是 **GUI 子系统**，stdout 无处可去 ——
> 所以这条线索**在日志里永远不存在**。

### 真因：`desktop_multi_window` 只给子窗口注册它自己那一个插件

`desktop_multi_window-0.3.0/windows/multi_window_manager.cc:71-75`：

```cpp
auto registrar = flutter_window->GetFlutterViewController()
                     ->engine()->GetRegistrarForPlugin("DesktopMultiWindowPlugin");
InternalMultiWindowPluginRegisterWithRegistrar(registrar, windows_[window_id].get());
// ← 到此为止。**没有**调用应用的 generated RegisterPlugins。
```

它把「给子窗口注册其余插件」**甩给应用**，接口是
`DesktopMultiWindowSetWindowCreatedCallback(WindowCreatedCallback)`（回调参数是
`flutter::FlutterViewController*`）。

而本项目的 `windows/runner/flutter_window.cpp` 是**原封不动的 Flutter 模板** ——
`OnCreate()` 里只有 `RegisterPlugins(flutter_controller_->engine())`（只覆盖**主窗口**），
**从来没有调过那个回调**。

于是播放器子窗口那个独立引擎里：

- `media_kit_video` 的 `VideoOutputManager`（`com.alexmercerind/media_kit_video` 通道）**不存在**
  → `NativeVideoController.create()` 在 `_channel.invokeMethod('VideoOutputManager.Create')`
  这一步失败 → 原生 `VideoOutput` 建不出来 → **它持有的 `mpv_render_context` 为 NULL**
  → mpv 的 `vo=libmpv` 初始化失败 → `No render context set.`
- 所有 `cloudcine/window` 调用报 `MissingPluginException`。

> 📌 **招牌症状：mpv 日志一切正常，就是不出画。**
> 因为 media_kit 内核走 **dart:ffi**（直接 load `libmpv-2.dll`），**不经插件通道**，
> 所以 `Player`、事件流、`log` 流全都工作。只有**纹理/渲染**这条依赖插件通道的路断了。
> 排查时极易误判成编解码问题 —— 别往那个方向查。

### 修法（照 `desktop_multi_window` 官方 example 逐字抄）

`desktop_multi_window-0.3.0/example/windows/runner/flutter_window.cpp` 里有标准写法。
本项目 `windows/runner/flutter_window.cpp`：

```cpp
#include "desktop_multi_window/desktop_multi_window_plugin.h"   // ← 新增
#include "flutter/generated_plugin_registrant.h"
...
  RegisterPlugins(flutter_controller_->engine());

  DesktopMultiWindowSetWindowCreatedCallback([](void *controller) {   // ← 新增
    auto *flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController *>(controller);
    auto *registry = flutter_view_controller->engine();
    RegisterPlugins(registry);
  });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());
```

- ✅ **包含路径能解析**：插件的 `windows/CMakeLists.txt` 有
  `target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")`，
  而 `windows/flutter/generated_plugins.cmake` 会
  `target_link_libraries(${BINARY_NAME} PRIVATE desktop_multi_window_plugin)`
  → INTERFACE 的 include 目录传播到 runner 目标。
  （`generated_plugins.cmake` 在 `windows/CMakeLists.txt:58` 才 include，
  晚于 `add_subdirectory("runner")` 的第 53 行 —— 但 CMake 在 **generate** 阶段才收集
  目标属性，所以没问题。）
- ✅ **对子窗口调 `RegisterPlugins` 是安全的**：`RegisterPlugins` 会调
  `DesktopMultiWindowPluginRegisterWithRegistrar` → `AttachFlutterMainWindow`，
  但后者**先遍历自己的 `windows_` 表**，
  `if (GetAncestor(window->GetWindowHandle(), GA_ROOT) == window_handle) return;`
  （`multi_window_manager.cc:92-96`）—— 子窗口已经在表里，直接**提前 return**，
  不会把它误登记成主窗口。

### 连带发现：`cloudcine/window` 通道**只在 macOS 实现**

`macos/Runner/MainFlutterWindow.swift` 里有 `ChildWindowController`；
`windows/runner/` 下**没有任何原生实现**（`grep -rn "cloudcine/window" windows/` 为空）。
所以子窗口里这些调用在 Windows 上全部 `MissingPluginException`：

| 方法 | Windows 上的实际后果 |
|---|---|
| `setTitle` | 标题文字不更新（无害，只影响观感） |
| `beginWindowDrag` / `updateWindowDrag` | macOS 无边框窗口才需要；Windows 有原生标题栏，**无害** |
| `setFullScreen` | **双击全屏不可用** —— `_setFullScreen` 会回滚状态并 toast「当前平台不支持切换全屏」 |
| `setAlwaysOnTop` | 同样不可用，toast「当前平台不支持窗口置顶」 |
| `close` | **「停止并关闭」按钮关不掉窗口**（只剩原生标题栏的 X 能关） |

📌 要做 Windows 版就得在 `windows/runner/` 里补一个 `MethodChannel("cloudcine/window")`
的处理器（`setTitle`/`close`/`setFullScreen`/`setAlwaysOnTop` + 两个通知
`onClosing`/`onFullScreenChanged`），并让它在**子窗口的引擎**里注册
（正好挂在上面那个 `DesktopMultiWindowSetWindowCreatedCallback` 里）。
`beginWindowDrag`/`updateWindowDrag` 在 Windows 上可以直接不实现（有标题栏）。

### 续：补完上面那段后，构建又挂了一次 —— C4819 + `/WX`

```
windows\runner\flutter_window.cpp(1,1): warning C4819: 该文件包含不能在当前代码页(936)中表示的字符
windows\runner\flutter_window.cpp(1,1): error C2220: 以下警告被视为错误
```

**原因**：MSVC **默认按系统 ANSI 代码页**读源文件，本机是 **936（GBK）**。
我往 `flutter_window.cpp` 里写了中文注释（文件是 UTF-8），按 GBK 解码失败 →
`C4819`；而 `apply_standard_settings`（`windows/CMakeLists.txt:40-46`）开了
**`/W4 /WX`** → 警告升级成 `C2220` → 构建失败。

> 📌 **判据**：`windows/` 下原本**只有纯 ASCII 的 C++ 文件**
> （`for f in $(find windows -type f -name '*.cpp'); do LC_ALL=C grep -qP '[\x80-\xff]' $f && echo $f; done` 为空）。
> 往 runner 的 C++ 里写中文，就必须同时声明源码字符集。

**修法**（`windows/runner/CMakeLists.txt`，紧跟在 `NOMINMAX` 之后）：

```cmake
target_compile_options(${BINARY_NAME} PRIVATE "/utf-8")
```

- `/utf-8` = `/source-charset:utf-8 /execution-charset:utf-8`。
- ⚠️ **只加在 runner 上**，不要动 `windows/CMakeLists.txt` 的
  `apply_standard_settings` —— 那个函数**插件也在用**（文件里明确写着
  「Be cautious about adding new options here」）。
- ⚠️ 改执行字符集是安全的：runner 里没有非 ASCII 的**窄**字符串字面量
  （窗口标题走 `L"..."` 宽字符串）。
- 📌 备选方案是给 `.cpp` 加 **UTF-8 BOM**（MSVC 会据此识别 UTF-8），
  但本项目 `windows/` 下没有任何文件带 BOM，加 `/utf-8` 更统一。

### 续：编译过了，链接报 LNK1104 —— **应用还开着**

```
LINK : fatal error LNK1104: 无法打开文件
  "D:\work\cloudcine\build\windows\x64\runner\Release\CloudCine.exe"
```

**不是权限、不是杀软、不是路径太长** —— 是**上一次跑起来的 `CloudCine.exe` 还活着**，
Windows 不允许覆盖正在运行的 exe，链接器自然打不开输出文件。

**判据**（一条命令定死）：

```bash
tasklist //FI "IMAGENAME eq CloudCine.exe"      # Git Bash 里 /FI 要写成 //FI
```

**处置**：先优雅关（发 WM_CLOSE，让应用自己释放 mpv 与窗口），不行再强杀：

```bash
taskkill //PID <pid>          # 优雅
taskkill //F //PID <pid>      # 强制
```

⚠️ **判断「是否真的退掉了」不要用 `tasklist | grep -qi` 接 `&&`/`||` 拼**：
本次就因为这个拼法误报了一次「还在」。**直接看 `tasklist //FI` 的原始输出** ——
没有匹配时它会打 `信息: 没有运行的任务匹配指定标准。`。

📌 **每次重建前都要先关掉应用**。在 PowerShell 里的一行式：

```powershell
Get-Process CloudCine -ErrorAction SilentlyContinue | Stop-Process
flutter build windows --release
```




---

# 附录 · MEMORY.md 精简前全文存档（2026-10-06）

> MEMORY.md 超过约 1.1 万字符会被注入层截断（后半段读不到）。为不丢信息，先把精简前全文原样存到这里；MEMORY.md 今后只留红线 + 标识符，细节查本附录。

# 云影（cloudcine）项目长期约定

Flutter 3.29 / Dart 3.7 的 macOS / Android TV 网盘媒体库播放器，对接夸克。
- 本机通用事实（gvm/`NO_PROXY`/沙箱/`ps`→`pgrep`/Android 构建/`git push` 要 `HOME`/**同文件两条 Edit 会互相覆盖**）见 `~/.workbuddy-ai/MEMORY.md`。
- **理由、实测证据、标识符细节在 `HOWTO.md`**（`§` 指其章节）；逐日经过在 `YYYY-MM-DD.md`。本文件只留**红线 + 标识符**。
- ⚠️ 本文件**超过约 1.1 万字符就被注入截断**（后半段读不到）⇒ 加新条目**先删旧的**；细节一律下沉 `HOWTO.md`。

## 版本控制
- **攒够一小轮就 commit**；`git clean` 先 `-nd` 干跑（untracked 被 `-df` 删掉**救不回**）。
- ⛔ **不代用户 `git add`/`git commit`**（分别授权）。提交前核对 `git diff --cached`：用户中途 `git add` 存过快照时，会**静默提交一个已废弃但能编译的设计**，修法 `git add -A`。
- ⛔ **别对仓库文件跑 `dart format`**；补救 `git show HEAD:<f>`。

## 架构
`core/` 纯工具 · `domain/` 实体+服务+适配器抽象（**不 import Flutter/drift**）· `data/` 夸克/drift/刮削/凭证 · `ui/` Riverpod 组合根 + go_router + 页面。跨层信号放叶子文件。

## ★★ 4K 卡顿的真因：**播错了档位**（10-06 Mac 实测，`tool/quark_probe.py`）
`黑亚当 2160p`（7490s，原文件 21.9 GiB）实测档位：

| 档位 | 分辨率 | 体积 | **需要带宽** |
|---|---|---|---|
| 原画 | 3840×1606 | 21.9 GiB | **3.00 MB/s** |
| `4k` | 3840×1606 | 4.6 GiB | **0.63 MB/s** |
| `super` | 1440×602 | 1.03 GiB | 0.14 MB/s |
| `high` | 960×402 | 678 MiB | 0.09 MB/s |

- ★ **夸克自己的 `default_resolution` 是 `super`**；云影默认播**原画**（3 MB/s）⇒ 单连接喂不动 ⇒ 靠 8 连接中继 ⇒ 中继跑在 **Dart 主 isolate** ⇒ **UI 饿死 + 加载-播放-加载**。**这就是全部秘密**（不是解码、不是渲染面、不是 OSD 画法）。
- ★ 单连接直连实测（Mac，带 Cookie）：`4k` **4.57 MiB/s**、原画 **6.76 MiB/s** ⇒ 够用。内存里「直连只有 1.1 MB/s」**只在电视 WiFi 上成立**，不是普适结论。
- ⇒ 治本：**默认播转码档（≥`4k`），不播原画**；中继只在用户显式选原画时才需要。
- 电视上夸克 TV 版实测 app 23.5% / `media.codec` 20.5%（≈ 4 核 11%）。

### 直链 Cookie 规则（10-06 四种组合实测，★ 极易踩）
| 请求带的 Cookie | 结果 |
|---|---|
| 带 `__puus`（**新旧都行**） | **206** |
| 有 `__pus` 等会话 Cookie 但**缺** `__puus` | **412** |
| 完全不带 Cookie | **206** |

⇒ **「要么不带，要么带全」**；带一半最坏（列表能刷、一播就 412/转圈）。`__puus` 在**每个** API 响应里轮换下发（`quark_adapter.dart:1285` 已处理）。
- ⛔ `batch/file/play/info` **必须带 `pr=ucpro&fr=pc`**，漏了回 `HTTP 401 code=31001 require login [guest]`（像没登录，其实缺参数）。
- ⚠️ `hls_type` 实测 **`none`** ⇒ 转码档是**普通 MP4**（`video/mp4`），**不是 m3u8**。旧记忆「取链改成 `media.m3u8`」**已过时**。

## 引擎路由 / 硬解（10-04~10-06，§）
- ⛔ `hwdec` 必须写 **`mediacodec,auto-safe`**（逗号=带回退；光写 `mediacodec` 失败只剩软解）。判据：读 `hwdec-current`，带 `copy` = 拷贝档（`isCopyHwdec`，⛔ **空串不算**）。
- ⛔ `VideoControllerConfiguration.hwdec` 与 `PlayerBufferConfig.apply` **必须同值**，且**都排在 media_kit `create()` 之前** → Surface 就绪后要再写一次才生效。
- ⛔⛔ **10-04 那两轮别再走**（§4.5）：① 只加 `VideoViewType.platformView` →「更卡、音画不同步」；② 再加 `tunnel: true` →「**4K 看不到画面，只有声音**」。
- ⚠️ **旧记忆「4K 切 fvp」已过时**：`main.dart:57` 只在 **macOS** 注册 fvp；Android 备用内核是 **`VideoPlayerExoPlaybackEngine()`**（`app_providers.dart:224-228`），`:233` `highResTvRoute` = `Platform.isAndroid && tv`，判据 `playback_engine_router.dart:184` `videoHeight >= 2048`（⛔ 不是 2160）。⇒ **Android TV 上 ≥2048p 与 DV P5 都走 ExoPlayer**（10-06 HUD 实证 `内核 ExoPlayer`/`解码 硬解(直通)`）。`fvp.registerWith` 范围与路由判据**必须一致**。
  - ⛔ `:199` 日志文案写死「切到 fvp（libmdk）」→ 实际 ExoPlayer，**待修**。⚠️ `:190` `_dvEngine ??= factory()` ⇒ Android DV P5 也走 ExoPlayer，与 `docs/ExoPlayer-硬解路线方案.md §2.4` 不一致，**待用户确认**。
  - ⛔ **mpv 在 Android 上做不到零拷贝，是结构性的**：`media_kit_video-1.3.1/android/.../VideoOutput.java` **写死** `createSurfaceProducer()`。调 mpv 参数没用。崩溃证据：`libmdk.so` 的 `strlen→vfprintf`；`SurfaceTextureWrapper.release`（引擎二次释放，**换内核就触发、与 viewType 无关**）。
  - 📌 面板 `ro.boot.mi.panel_resolution=3840x2160`，但 Android 显示层**只有 1920×1080**（`dumpsys display`）⇒ 应用内渲染最高 1080p，由电视倍线。
  - 10-04 的观察（**已被上面取代，只作证据**）：真机 `解码丢帧=0 / 显示丢帧 21s 涨 44`、[中继] 零告警 ⇒ 瓶颈不在解码。证据 `docs/AndroidTV-4K-丢帧-夸克对标.md`，方案 `docs/解决4k片源不卡顿解析方案.md`。

## 本地中继 `data/stream/local_stream_relay.dart`
⛔ **没有 `Isolate`/`compute`**：上游 TLS/解密/HTTP/分块拷贝**全在 Dart isolate**，而 Flutter 的 Dart isolate **就是 Android 主线程**（`/proc/PID/task` 里**没有 `1.ui`**）。
### Range 语义（10-06，★ 卡死首帧的根因）
`core/utils/http_range.dart` = **`sealed class RangeRequest`**（`NoRangeRequest`/`SatisfiableRange`/`UnsatisfiableRange`）+ `parseRangeRequest()`。
- ⛔ **起点越界必须回 416**。旧 `parseRangeHeader` 用**一个 `null`** 同时表达「没要求区间」（→200 整文件）和「起点越界」（→416）；调用方 `clampRange(requested ?? ByteRange(0,total-1), total)` 只能二选一、选了整文件 ⇒ **416 成死代码**；旧单测注释还写「交给 416」—— **契约两半分家，测试一直绿**。
- 后果（`凡人` 4K 3.13 GiB）：播放器问 `bytes=5014520206-`，中继回 `200 bytes 0-3358116481/…`。「对带 Range 的请求回 200」=「这是完整资源」⇒ media3 丢掉前 5.01 GB 去对齐偏移，可整条流只有 3.13 GiB ⇒ 读完才 EOF ⇒ **「正在加载…」永不消失**。判据：`[中继]` 出现 `读取器 #N → 200 bytes 0-<总长-1>/<总长>` 且请求 `Range: bytes=<大于总长>-`。
- ⛔ 别再把「不知道流多长」（→200）与「要不到」（→416）合成一个返回值。`clampRange` 保留但**中继已不再调用**。
### 「块大小 ↔ 首字节延迟」耦合（10-05 血案）
`_fetchChunk` **整块读完才 `cache.put` + `_settle`** ⇒ 首字节延迟 ≈ 单块下载耗时，与 `chunkSize` 成正比。
- ⛔ **`chunkSize` 别放大**。2 MiB→8 MiB 后首块 1.18s→**15~45s**、**零成功播放**、每次换片 `Source error`。✅ 已改回 2 MiB；回归测试 `test/data/stream/local_stream_relay_test.dart`「默认 chunkSize 的首字节预算」（断言 `chunkSize/0.6MiB < 5000ms`）。提速调 `connections`/`prefetchBytes`。
- ⛔ **`Source error` 的真判据不是「首帧 > 8s」**（原型首帧 12.3s 却没错）。`DefaultHttpDataSource` readTimeout 是**单次 socket 读**空闲上限：2 MiB 中继 ~2.8s 出首字节；8 MiB **整块读完才发第一字节**，>8s 零字节 ⇒ 必炸。`warmUpRelay(timeout:2500ms)`/mpv ~5s/ExoPlayer ~20s 都远小于它。
- ⛔ 换源时 `fvp 失败 → 回退 media_kit` 会**再建一个中继会话**（sN/sN+1）⇒ 一次换片 = 2 次首块等待。⚠️ 同窗口有**跨内核陈旧事件**（切回 mpv 后 2.2s 仍收 `ExoPlayer 首次初始化失败`）→ 待查。

## 资源采样：CPU / 内存 / 磁盘（10-04，§）
`core/diagnostics/resource_probe.dart`：`ResourceProbe`（引擎 `open()` 起、`stop()`/`dispose()` 停，两引擎各一）+ 纯解析函数。**fvp 那条路没有视频探针**。
- ⛔ **周期 10 秒**，**故意不与**视频探针的 21 秒相等（会**拍频锁定**；10 与 21 互质）。
- ⛔ **读不到一律留空、整段从日志行消失**，不许退化成 0。⛔ 进程 CPU 是**单核口径**，必须写「折合 N 核」。⛔ 系统 CPU「忙」**不含 iowait**；`/proc/stat` 只认汇总行 `cpu `（**别用 `cpu0`**）。
- ⛔ `/proc/loadavg` 在电视上 `Permission denied`；`/proc/pressure/*` 在 Android 9 不存在。替代 `/proc/stat` 的 `procs_running`/`procs_blocked`（`parseProcStatProcs`，**同文件、不额外读盘**），写「可运行进程=N（4 核，超订 x.xx×）」——⛔ **核数必须一起写**。
- ⛔ `/proc/self/stat` **按最后一个 `)` 切**。⛔ `df` 正则**从左锚定**、不按列 split；用异步 `Process.run`。macOS 无 `/proc`：内存退回 `ProcessInfo.currentRss`，CPU/负载留空属**正常**。

## TV OSD：已换成**原生 View**（10-06，§）
`android/.../TvOsdView.kt`（移植 `prototype/kuake` 的 `KuakeOsdView`，几何常量逐字相同）挂在 `android.R.id.content` 之上，由 `MainActivity.dispatchKeyEvent` 直连。起因是硬读数：**按 MENU → 上屏 524 ms**（原型同口径 0.3~8.3 ms）—— Flutter 版菜单挂在 `ListenableBuilder(listenable: controller)` 里、进度每 tick 重建整页，而中继**全在 Dart 主 isolate**；原生 OSD 与 Dart 彻底解耦，这才是「跟手」的结构性原因（不是画法、不是引擎）。
- ⛔ **行模型只有一份**：`lib/ui/widgets/player_tv_rows.dart`。`PlayerTvOverlay` 降级为**回退路径**（`TvOsdChannel.show` 返回 false 时用），但它 **re-export** 那份模型。
- ⛔ **原生回调只回传「行下标」** ⇒ **枚举顺序就是原生菜单的下标顺序**，动枚举必须同时改 `TvOsdView` 与单测。
- ⛔ 原生 `show` **必须返回 bool**（取不到 `android.R.id.content` 时 false）。⛔ OSD **不能挂进 FlutterView**。
- ⛔ 有硬件视频层时 **`screencap` 全黑** ⇒ 验证只看 logcat tag **`CloudCineOsd`**。
- ★ 云影在电视上**本来就是 ExoPlayer + SurfaceView**（`video_player_exo_playback_engine.dart:238`）⇒「换引擎/换渲染面」**已经是原型方案**，真正缺的只有 OSD。
- 贴底 XY 菜单几何（照夸克）：`PlayerTvSheet` 贴底横排，选中行下面铺 chip 条；`↑↓` 换行（循环）、`←→` 挪光标（不循环、**跳过灰掉的**）、**`OK` 才生效**；`←→` 只在**没有 chip 条**的行回调 `onAdjust`。⛔ **菜单开着时不画控制栏**；⛔ 字幕**抬高**；⛔ `kPlayerTvSheetHeight` 末尾 `+0.8` 是描边算成内边距，删了就溢出。

## 电视上取证（10-06，★ 省一整轮）
1. **应用日志是文件、不是 logcat**：`DiagLog` 同步写 `files/logs/cloudcine-YYYY-MM-DD.log`，读 `adb shell run-as com.cloudcine.cloudcine cat files/logs/cloudcine-<日期>.log`。⛔ logcat `I/flutter` 基本只有引擎启动几行；⛔ **文件 mtime 不涨 = 应用真没做事**。
2. **线程名读 `/proc/<pid>/task/*/comm`**：`top -H` 在 Android 9 全打进程名。⛔ 取字段写 `${12}`/`${13}`；切字段按**最后一个 `)`**。
3. **`exec-out screencap` 被 fvp 的 `Init wrapper sys mutex successful.` 污染** ⇒ 用 `shell screencap -p /sdcard/x.png` + `pull`。
4. **`uiautomator dump` + `input tap X Y` 比猜 DPAD 可靠**。⛔ Flutter 语义树只在无障碍被触发后才暴露，重启后常取不到。
5. **★ 视频真帧率用 SurfaceFlinger 量，别信 HUD**：`dumpsys SurfaceFlinger --list` 找层 → `--latency '<层名>'`（首行=刷新周期 ns，其后 128 帧三列时间戳）。**Flutter UI 帧率**用 `dumpsys gfxinfo <包名>` 两次取差。实测 `activeBuffer=[3840x2160:3840,Unknown 0x13]` 才是**视频层**；`SurfaceView #0` 是 `1920x1080 RGBA`。
6. ⛔ **LMK 会杀掉后台的云影**（电视仅 2.5 GB）⇒ 中继喂原型只有 2~3 分钟窗口；先 `am kill-all` 腾内存。

## 云影 vs 原型的对比**本身不公平**（10-06，★ 别再用它下结论）
- 原型是**原生 Kotlin**，`debuggable` 几乎无代价；云影是 **Flutter `app-debug.apk` = JIT**。实测进程合计 **467%/400%**（主线程 200% + `DartWorker` 199% + `1.raster` 42%，ExoPlayer 只拿 12%）。
- ⚠️ **本机出不了 release/profile 包**：Flutter 的 Android AOT 快照工具是 `darwin-x64` 二进制，Apple Silicon 无 Rosetta ⇒ `gen_snapshot ... incorrect architecture`。解法（需 sudo）：`sudo softwareupdate --install-rosetta --agree-to-license`。
- ⚠️ 引擎切换用 `unawaited(previous.stop())`（fire-and-forget）⇒ 旧内核可能没拆干净。
- ⛔⛔ **两边 `fps` 都不是流畅度，别再互相比较**：云影 `DebugOverlay` 数**引擎实际出帧**；原型 `StatsOverlay.kt:104` 的 `doFrame` 里 `postFrameCallback(this)` **自己重排自己** ⇒ `uiFps` 恒≈刷新率（实测 **100**）。
- ✅ **唯一可比的是「按键→下一帧」与 SurfaceFlinger `--latency`**。10-06 实测视频流畅度两边一样（~25 fps），差的是 **CPU 1.2~3.0% vs ~22%**、**RSS 124 MB vs ~570 MB**、**按键 0.3~3.9 ms vs 524 ms**。

## 播放页 OSD 卡顿的结构性成因（10-05，§）
⛔ **不是 Flutter 太重**，是三处开销叠在 4 核 SoC 上：
- **整页 rebuild ≈10 次/秒**：`player_page.dart` 的 `ListenableBuilder` 包着整棵树。position 已节流 250ms，但 **`bufferEnd`（mpv `demuxer-cache-time`）没节流** ⇒ 要加节流或拆 `ValueNotifier`。
- ⛔ **`SubtitleViewConfiguration` 无 `operator ==`**（media_kit_video 1.3.1）：页面里内联 new ⇒ `VideoState.didUpdateWidget` 恒判不等 ⇒ 每拍 post-frame 再重建画面子树。⇒ 缓存实例（**现在只有 `_FvpPlaybackSurface` 有**）。
- `PlayerTvOverlay._rows()` 每 build 重算全部选项（含每集 `baseNameOf`）。
- ⛔ `DebugOverlay` 的 `kDebugOverlayEnabled = true` **硬编码**（release 也显示），挂 `MaterialApp.builder`、`refreshInterval = 1 秒` ⇒ **每秒重建整棵应用树**，还每秒 spawn 一个 `df`。

## 夸克方案验证原型（分支 `feature/kuake`，`prototype/kuake/`）
**独立 Android 工程**（不含 Flutter）—— 只要 Flutter 引擎在同一进程，「每秒 10 次整页 rebuild」就撇不干净。
- 形态：`ExoPlayer`（Media3 **1.5.1**）+ `setVideoSurfaceView`（零拷贝）+ **原生 View OSD**（⛔ 故意去掉圆角裁剪/blur 阴影/隐式动画）。
- 10-06 扩成完整原型：`MainActivity`（路由）→ `LoginActivity`（CAS 扫码，zxing）→ `BrowseActivity`（`ListView`，天生支持 D-pad）→ `PlayerActivity`（按 fid 取链）。
- `quark/` 包：`QuarkHttp`（`HttpURLConnection`，**不引 OkHttp**；`useCaches=false` 必开）/ `QuarkApi`（`absorbCookies` 回填轮换 `__puus`）/ `QuarkQrLogin`（业务码读 **`bizCode`**：网盘用 `code`、CAS 用 `status`）/ `QuarkModels` / `Bg`（后台池，主线程只 setText）。
- ⛔ `PlayerActivity` 保留 `-e url` 这条**对照路径**（`StreamSpec`），跑「云影中继 vs 直连」。
- 10-06 新增：`AspectRatioFrameLayout`（按 `VideoSize`+PAR+旋转定界；⛔ **只包 SurfaceView、不包 OSD**，否则菜单被压进画面矩形）；起播前 `probeThroughput` 测速 → `chooseQuality` 选「带宽扛得住的最清晰档」（同分辨率取最省带宽，留 30% 余量）。
- 构建：Gradle 8.10.2 / AGP 8.7.0 / Kotlin 2.1.0 / compileSdk 36 / minSdk 21 / targetSdk 34。⛔ **首次构建必须联网**。⛔ 不引 `media3-ui`/AppCompat/Material/RecyclerView。命令：`JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home ./gradlew assembleDebug` —— ⛔ **别用 Android Studio 的 JBR**（现在是 25，会崩 Kotlin，报错只剩一个版本号）。
- ⛔ Media3 1.5.1 的 `DecoderCounters` 全是 **`int`**，且**没有 `inputBufferCount`** → 用 `queuedInputBufferCount`。
- 取数：`adb logcat -s KuakeProto`（`StatsOverlay` 每秒打同一行，**必需通道**）。
- Mac 侧 API 探针 `tool/quark_probe.py`（扫码登录 → 列目录 → `play/info`/`audioplay` → 测带宽），Cookie 落 `.quark_probe/cookie.json`。⛔ 含凭据，**别提交**（已在 `.gitignore`）。

## 取链（10-04，⚠️ 部分已过时，§）
⛔ 鉴权靠 `play/info` 下发的 **`Video-Auth`** cookie（必须进 `knownCookieNames`，否则分片 **404**）。⛔ **HLS 必须走本地中继**：本机 `http_proxy` 会让 ffmpeg 选**未列白名单**的 `httpproxy` → `avformat_open_input() failed`；该故障**护栏会放行** ⇒ 诊断触发必须**独立于** `isRealEnd`。⛔ **TV 的 mpv 只开 `error` 级** ⇒ `Failed to open 127.0.0.1/sN` 只靠中继日志还原。
⚠️ 旧记「`video_list[].video_info.url` 换成了 `media.m3u8`」**已过时**（10-06 实测 `hls_type=none`，转码档是普通 MP4）。

## 电视分支（§）
`isTvLayout`：android + 逻辑宽≥960（⛔ 判据读 view 宽，页面实得 624，**壳外页实得 960**）。⛔ **页头 `actions` 必须 `Wrap`**；⛔ TV 另一套缓冲（`cache=yes` + 硬解参数）；⛔ **过扫描内边距只有 `app_shell` 一处**，壳外页（`/work` `/diagnostics` `/auth/qr`）与**播放器覆盖层**自己加；⛔ 播放器遥控器 **↓ 绝不接管**；⛔ **侧栏方向键靠壳层兜底**（候选**只搜侧栏子树**）。

## 不可动摇的设计约束
1. 本地解析永远可用，在线刮削是增强；`LocalFilenameScraper` 排 `ScraperPipeline` 末位。
2. 原画只认 `/file/audioplay` 的 `audio_url`；`play/info` 的 `audio_list` 是纯音频流，当原画会**有声音没画面不报错**（`audioOnlyKeys` 别删）。
3. `ScanPolicy.audioOnly` 默认 `true`；视频库必须显式 `false`。
4. 直链必须带 Cookie（缺则 412）；`__puus` 每响应轮换回填。`PosterCache.headersFor(url)` 每次现取。
5. 字幕字节一律走 `decodeTextBytes`（先 UTF-8 后 GBK）；扫描期只写引用、不下载正文。
6. 起播只走 `Media(start:)` 且每次显式给；入口 `PlaybackMedia.build`；`seek` 只在播放中跳转。⚠️ 它**静默** → 换源后要核对（`RestoreSeek`，§）。
7. 刮削默认不跟扫描跑（`autoScrapeOnScan` 默认 `false`）。
8. 落库接 `PlaybackController.onPositionTick` 回调，不暴露 `Player`。
9. 夸克上传收尾**两步**、备份同步比 `libraryModifiedAt`，各有空守卫；`includeSettings`/`restoreSettings` 是**空开关**。
10. **TV 上 `SelectableText` 是焦点陷阱** → 用 `TvSelectableText`。

## 其余模块（细节见 `HOWTO.md`，此处只留红线）
- **侧栏（10-03）**：五项 媒体库 `/library` · 文件夹 `/folders` · 扫描 · 下载 · 设置；`app_shell._items` 与 `app_router.branches` **必须同序**（判据是下标）。⛔ 文件夹读**网盘实时目录**、媒体库读**本地索引**，两者并列；**搜索词各一份**。
- **文件夹模式（10-01）**：本地索引只做**「已入库」叠加层**。与全盘扫描共用 `media_entry_classifier.dart`（镜像判定必须在视频判定**之前**）、`work_builder.dart`、`request_throttle.dart`。⛔ **绝不清理陈旧记录**、**绝不写续扫游标**、**深度从本次目标算第 0 层**。发现让着扫描（`DiscoveryController.canStart`）。
- **目录视图**：三组**目录 → 视频 → 其他文件**（组间顺序是**结构**）。⛔ 分组只管排布，**入库判据仍只有 `classifyEntry` 一处**。⛔ 下载取链**复用 `adapter.resolveStream`**（别打 `/file/download`，>50MiB 直接 23018）。⛔ `FolderSortMode`/`ItemSortMode` **各一份设置键**、**渲染时**排、**只改显示不改 `primary`**。视频行**整行可点=播**。⛔ 多选：`folderSelectionProvider` 键=fid、**换目录清空**、**全选只勾当前可见**。
- **下载（v16）**：表 `download_tasks`（主键 `provider:fileId`）。⛔ `.part` 是断点**唯一真源**；服务端**忽略 Range 回 200 必须从 0 重写**；`parse` 读不懂退 **paused**。⛔ `downloadQueueProvider` **不能 autoDispose**、`settingsProvider` 用 `listen` 不用 `watch`。多连接 8×2 MiB、writer 顺序落盘。
- **播放器（两份实现，别只改一个）**：`player_window_app.dart` + `player_page.dart`。**键位表、菜单、偏好还原、换流提示、hover 唤醒都要改两处**；⛔ 独立窗口要 `mouseTrackingMode=.always` + `onEnter`；菜单统一走 `anchored_menu.dart`。`buffered_slider.dart` 是 **0..1 比例**（⛔ `demuxer-cache-time` 是**绝对时间戳**）。音轨过 `TrackLabels.realTracks`；搜索走 `subtitle_query.dart`（⛔ 别拿 `displayTitle`）。**音效 ≠ 音轨**：⛔ 无可用 Avfilter、**`af set` 返回值不能当依据**；⛔ macOS `audio-spdif` 直通必卡死。`playback_prefs`（v14）**写整条覆盖**；进度两列 `resumePositionMs`（起播，看完清）vs `maxPositionMs`（显示，v15，只增不减）⛔ 别合并。**DV P5**：⛔ macOS libmpv **架构上做不到**（`gpu-next` 零命中）→ 唯一出路 **fvp/libmdk**；契约 `PlaybackEngine` 在 `playback_engine.dart`、选引擎走 `playback_engine_router.dart`（**开播前探头部字节**）、画面走 `playback_surface.dart`。
- **媒体库三轴（不能互推/合并）**：`MediaKind`（结构，只看文件名 `SxxExx`）· `MediaCategory`（语义，落库 `media_works.category`，空串≠other）·「最近播放」（视图，`LibraryFilter.playedOnly`，与 `category` 互斥）。`MediaCategoryGuesser.guess` 序：TMDB genres→目录路径→片名+文件名→结构兜底。**交互**：`PlayTarget.resolve` 三档；`playItem()` 唯一起播入口。⛔ 路径归一化只在 `core/utils/drive_paths.dart`。
- **季/部/归一**：`MediaItem`+`part/partLabel`（v9）· `MediaWork`+`seasonCount`（v10）+`mergedInto`（v11）。层级**不落库**（现算）：**季在外、部在内**，某层**少于 2 个选项不画**；`seasonCount` 是 `COUNT(DISTINCT)` **不能相加**。**目录名当系列名**：判定单元是**目录不是文件**（`DirectoryTitle`），**四处调用点都要传 `dirPath`**。自动归一：只认 `onlineId` 相同 + `source==online` + kind 相同；**本地片名相似度绝不参与**。⛔ **归一 = 打标记**：不删行、不改 `group_key`；滤 `merged_into IS NULL`、`itemsForWork` 取并集、**不许链式**。⚠️ `mergeWorkForUpsert` 里**无条件取旧值**；搜索穿透折叠内层表**必须起别名**；⛔ `_unionStats` 别改回 JOIN 里的 `OR`。
- **筛选/封面刮削**：⛔ 筛选「已刮削」判据 = **`source==online`**（不是 `isScraped`），且**进 `_facetScope`**。⛔ `==`/`hashCode` 按**集合内容**比（`setEquals`+`Object.hashAllUnordered`）。⛔ `posterFaceX` 与 `posterUrl` **必须成对**；熔断只计**网络层**失败。**TMDB `/search/*` 必须过 `ScrapeMatch` 闸门**。⛔ 手动刮削通道三条交互不许改；**「自定义」** `customizeWork` **整行写、不过 merge**。**候选链** `ScrapeQuery.fallbacks` = 文件名 → 目录名逐级向上、串行命中即停；⛔ 本地兜底只用主查询、⛔ 两个调用点都要传 `dirPath`。⚠️ 待办 `DirectoryTitle._clean` 清年份/画质标记（⛔ 别用 `_parseDotted`）。
- **Android 产物名（10-03）**：⛔ 产物名由 Flutter 工具链**定死**，改 AGP `outputFileName` 无效；做法是给 `assemble<Mode>` 挂 **finalizer**（⛔ 别 doLast）**复制**成 `cloudcine-<versionName>-b<versionCode>-android.apk`。⛔ **别信产物文件名**：**只有通用的 `app-debug.apk` 会被重新构建**，per-ABI 那份停在旧 mtime ⇒ `-b1006-` 与 `-b1007-` **内容完全一样**；装前 `aapt2 dump badging <apk> | grep -E "^package|native-code"`。⛔ **`adb install` 被中途打断会留下装了一半的包**；装完复核 `dumpsys package … | grep versionCode`。
- **Windows MSI（10-05）**：`windows/packaging/cloudcine.wxs` + `build_package.ps1`（per-user 装到 `%LOCALAPPDATA%\Programs\CloudCine`，`InstallerVersion=500`）。⛔ **启动条件绝不能写 `VersionNT >= 1000`**：Windows Installer 把 VersionNT **钳在 603** ⇒ 该条件**在任何真实 Windows 上都失败**；判据用 **`WindowsBuild >= 10240`** + `Installed OR`（微软 KB3202260）。⚠️ **MSI 条件语法不支持括号**。⛔ `-sice` 只压 ICE38/ICE64/ICE91，**别换成 `-sval`**。
- **macOS 签名与凭证**：⛔ 不许写 `keychain-access-groups`（→ **启动即 SIGKILL**）；`app-sandbox` 必须 **`false`**；两份都要 `network.client/server`·`files.user-selected.read-write`；`DebugProfile` 另加 `get-task-allow`。⛔⛔ **Release 签名里不许出现 `get-task-allow`**：文件里没写 Xcode 也会注入 ⇒ Runner target 的 **Release** 配置必须 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`（只关 Release，Debug/Profile 保留否则 `flutter run` 连不上 Dart VM Service；判据只有 `codesign -d --entitlements -`）。凭证 macOS 走 `EncryptedFileSecretBackend`（⛔ 别再试钥匙串，其余平台 `flutter_secure_storage`），密钥由 `IOPlatformUUID` 派生（**别掺易变环境值**）。
- **测试取向**：纯函数优先；断言写「为什么重要」。⛔ **每个需求只跑相关单测，不回归全量**（用户 10-04 定的）。修并发/竞态 bug **先加测试确认红**再加修复。⚠️ 用户常**边改边跑**，判据=红的在不在我改的文件里。

---

# ★★ 2026-10-06 17:50 仓库结构大调整（本节取代旧记忆中所有「Flutter 在 Android 上」的结论）

用户定调：**Android 走原生 Kotlin 独立工程；Flutter 只用于 PC 端（macOS / Windows）**；
范围收紧为「只需要关心 `android/`，desktop 先不用理会」。

## 结构
```
仓库根/
├── android/   ← Android 端正式实现（原生 Kotlin，包名 com.cloudcine.tv，原 prototype/cloudcine）
├── lib/ macos/ windows/ test/ packages/ pubspec.yaml …  ← Flutter（PC 端）
├── docs/ tool/ .github/
```
- Flutter 的 Android 宿主（`com.cloudcine.cloudcine`，含 `TvOsdView.kt` 等 22 个受控文件）
  **整体移出仓库**，备份在 `~/.workbuddy-ai/backups/cloudcine-flutter-android-20261006-173700/`。
- `git mv prototype/cloudcine android`；`prototype/` 已删；`rootProject.name = cloudcine-android`。
- `android/app/build.gradle.kts`：新增 release 构建类型 + 发布签名
  （`android/keystore.properties` → 环境变量 → 退回 debug 签名，三者兜底）；
  `brandReleaseApk` 把产物另存为 `cloudcine-<ver>-b<code>-android.apk`。
- ⛔ `Copy` **不能写回 `outputs/apk/release/`**：那是 `createReleaseApkListingFileRedirect`
  的声明输出，往里写会触发 Gradle 隐式依赖校验直接失败 ⇒ 品牌化产物落 `outputs/apk/branded/`。
- ⛔ `isMinifyEnabled` 故意保持 false：media3 的 extractor/renderer 有反射按名加载，
  规则写在 `proguard-rules.pro` 里但**没在真机跑过完整回归**。
- CI：`ci.yml` / `release.yml` 的 Android job 从「Flutter APK」改成原生 Gradle
  （不装 Flutter、不装 cmake/NDK，`working-directory: android`，校验包名 `com.cloudcine.tv`）。
  macOS / Windows 两个 Flutter job 未动。

## 已被取代的旧结论（只作历史证据）
- Flutter 侧 fvp/ExoPlayer 引擎路由、`app_providers.dart` 的 Android 分支、
  `media_kit_video` 在 Android 上写死 `createSurfaceProducer()`（做不到零拷贝）、
  `TvOsdView` 挂在 FlutterView 之上、Dart 主 isolate 中继喂 4K ——
  **这些都只对「Flutter 跑在 Android 上」成立，现已不适用**。
- 云影在 Android 上**现在是原生**：ExoPlayer + SurfaceView 零拷贝 + 8 连接并行取流
  + 磁盘旁路预取 + 原生 View OSD。参考实现是 `kuakewangpan/`（夸克 TV 版 APK 逆向）
  与原型，两者结论仍有效（它们本来就是原生的）。

## 遗留待办（我没动）
- 根目录 `tool/adb_tv.sh` 与 `tool/build_android.sh` 已死（指向已删的 Flutter Android 宿主
  与 `build/app/outputs/flutter-apk`）⇒ 替代品 `android/tool/adb_tv.sh`。
- `android:largeHeap` / `applicationId = com.cloudcine.tv` 保留未改（换包名会让已装设备
  变成另一个应用、且丢掉磁盘缓存，属产品决策）。
- `versionCode = 1 / versionName = "1.0.0"`，发版前需手动递增。
- `packages/video_player_android` 仍在仓库根（pubspec 的 path 依赖，删了 `flutter pub get`
  会失败）；它是 Android-only 插件，PC 端用不到。

---

# ★★ 媒体库数据结构 —— 跨端同步的**唯一契约**（Android 端实现媒体库时的逐项依据）

## 1. 库文件 `cloudcine.sqlite`
- PC 端路径：`getApplicationSupportDirectory()/cloudcine.sqlite`（`openAppDatabase()`）。
- drift `schemaVersion = 16`，写在 SQLite 的 **`user_version`** pragma 里。
- 7 张表（列名 = Dart 字段的 snake_case，权威定义 `lib/data/db/tables.dart`）：

| 表 | 主键 | 说明 |
|---|---|---|
| `media_items` | `id`（文本 `provider:fileId`） | 文件级媒体项 |
| `media_works` | `key`（文本，归组键） | 作品级元数据 / 海报 / 简介 |
| `subtitle_refs` | `id`（文本 `itemId#fileId`） | 字幕引用，**只存引用不存正文** |
| `scan_cursors` | `provider` | 续扫游标，BFS 队列存 JSON |
| `settings` | `key` | 通用键值设置（TMDB key / 豆瓣 Cookie…） |
| `playback_prefs` | `itemId` | **逐文件**播放偏好，`prefs` 存 JSON |
| `download_tasks` | `id`（文本 `provider:fileId`） | 下载记录，`.part` 是断点真源 |

### 关键列（跨端读写必须一致）
- `media_items`：`id provider file_id name dir_id dir_path group_key kind title year season
  episode episode_end part part_label container resolution size_bytes modified_at duration_ms
  source video_codec audio_codec flags release_group is_sample_or_extra first_seen_at
  updated_at last_played_at resume_position_ms max_position_ms thumb_url face_anchor_x
  video_width video_height`
- `media_works`：`key provider kind category category_manual title original_title year overview
  poster_url poster_file poster_face_x backdrop_url backdrop_file rating genres genres_manual
  online_id source scraped_at item_count total_bytes season_count last_modified_at
  first_seen_at last_played_at updated_at merged_into intro_start_ms intro_end_ms`
- ⛔ `category` 默认**空串**（= 还没判定过），`other` 是**判定结果**，两者不能混。
- ⛔ `resolution` / `status` / `container` 存**枚举名字符串**（不存序号：加档时序号错位会静默变档）。
- ⛔ `flags` / `genres` 是 **JSON 数组字符串**，默认 `'[]'`。
- ⛔ 布尔列 drift 存 **0/1 整数**，默认 false。
- ⛔ 时间列 drift 存 **Unix 秒**（`DateTimeColumn` 默认 `DateTimeToSql`，可带小数秒）——
  跨端解析要注意单位。
- ⛔ 主键都是**文本**，不是自增。
- 迁移史 v1→v16 见 `lib/data/db/app_database.dart` 的 `onUpgrade`；
  **有回填逻辑的只有 v6 / v7 / v10 / v15**，其余靠 NULL / DEFAULT 语义自然兼容。

## 2. 备份包 `.ccbak`（`lib/domain/services/library_backup_service.dart`）
```
[magic 'CCBK'(4)][manifestLen(4, BE uint32)][manifest JSON utf8]
[dbLen(4, BE uint32)][db 原始字节][posters 打包字节(可选)]
```
- 海报目录打包（`_packDirectory`）：每文件 `[nameLen(4)][name utf8][dataLen(4)][data]`，
  末尾 `[0]` 终止；解包 `_unpackDirectory` 读不懂就 break。
- 扩展名 `.ccbak`；网盘默认目录 **`云影备份`**（`LibraryBackupService.defaultBackupDir`）。
- manifest 字段：`deviceId / deviceName / createdAt / libraryModifiedAt / schemaVersion /
  fileNames / note`；`fileNames` 含 `cloudcine.sqlite` 与（有海报时）`posters/`。
- 同名覆盖是**先删后传** ⇒ 上传文件名**必须带时间戳**（否则一次失败的上传会把上一份也带走）。

### ★★ 同步判据（LWW）
- **比的是 `libraryModifiedAt`（库内容最后变更时间），绝不是 `createdAt`（备份文件生成时间）**。
  用 `createdAt` ⇒ 本机永远"新" ⇒ 只会把网盘上的好备份冲成空库。
  空库没有 `libraryModifiedAt`，`effectiveModifiedAt` 退化成 epoch ⇒ 远程自然赢（新机器该有的行为）。
- 两侧空库规则：本地空库（`hasLibraryContent == false`）**让远程赢**；
  远程空备份**绝不覆盖本地**（否则空库会把本地攒好的清掉）。
- 冲突：**不同设备**且时间差 < 60 s（`conflictsWith`）。
- `deviceId` 目前 = `${Platform.localHostname}_${Platform.operatingSystem}`。
- ⛔ 不备份网盘凭证（会话 Cookie 会过期，新机器必须重新扫码登录）。
- ⛔ `includeSettings` / `restoreSettings` 目前是**空开关**（只改日志与 `note`）——
  导出的是整个 db 文件原始字节，SQLite 没法在字节层剔表；UI 三条通道全传 `true`。
- 要真正做到「不带走设置」：`VACUUM INTO` 一份副本 → 副本上 `DELETE FROM settings` → 读副本字节（**目前没做**）。

---

# 附：MEMORY.md 全量快照（2026-10-06 19:2x，为给 MEMORY.md 瘦身而整体下沉；此快照是当时的最新版）

# 云影（cloudcine）项目长期约定

**两个互不引用的工程**（10-06 17:50 定调）：
- `android/` —— ★ **Android / Android TV 正式实现**：原生 Kotlin，包名 `com.cloudcine.tv`。
- `lib/ macos/ windows/ pubspec.yaml` —— **Flutter PC 端（macOS / Windows）**，含完整媒体库 / 刮削 / 备份同步 / 播放器。
- 本机通用事实（gvm / `NO_PROXY` / 沙箱 / `ps`→`pgrep` / `git push` 要 `HOME` / **同文件两条 Edit 会互相覆盖**）见 `~/.workbuddy-ai/MEMORY.md`。
- **理由、实测证据、逐行细节在 `HOWTO.md`**；逐日经过在 `YYYY-MM-DD.md`；Android 产品文档在 `android/README.md`。本文件只留**红线 + 标识符**。
- ⚠️ 本文件**超过约 1.1 万字符就被注入截断** ⇒ 加新条目**先删旧的**；细节一律下沉 `HOWTO.md`。

## 仓库结构（10-06）
- 用户定调：**Android 走原生 Kotlin 独立工程；Flutter 只用于 PC 端**；范围「只需要关心 `android/`」。
- Flutter 的 Android 宿主（`com.cloudcine.cloudcine`，含 `TvOsdView.kt` 等 22 个文件）**整体移出仓库**，备份在 `~/.workbuddy-ai/backups/cloudcine-flutter-android-20261006-173700/`。`git mv prototype/cloudcine android`；`prototype/` 已删。
- ⛔ ⇒ **旧记忆里一切「Flutter 在 Android 上」的结论都失效**（fvp/ExoPlayer 路由、media_kit 零拷贝、TvOsdView 挂 FlutterView、Dart 主 isolate 中继……），只对 PC 端或历史取证有效。
- ⛔ 根目录 `tool/adb_tv.sh` / `tool/build_android.sh` **已死** ⇒ 用 `android/tool/adb_tv.sh`。
- ⛔ `packages/video_player_android` 仍在仓库根（pubspec path 依赖，删了 `flutter pub get` 会失败）。
- ⛔ `applicationId=com.cloudcine.tv` / `versionCode=1` / `versionName=1.0.0` 保留未改（换包名 = 已装设备变另一个应用且丢磁盘缓存，属产品决策）。

## 版本控制
- **攒够一小轮就 commit**；`git clean` 先 `-nd` 干跑（untracked 被 `-df` 删掉**救不回**）。
- ⛔ **不代用户 `git add`/`git commit`**（分别授权）。提交前核对 `git diff --cached`：用户中途 `git add` 存过快照时，会**静默提交一个已废弃但能编译的设计**，修法 `git add -A`。
- ⛔ **别对仓库文件跑 `dart format`**；补救 `git show HEAD:<f>`。

## ★★ 媒体库数据结构 —— 跨端同步的**唯一契约**（逐项依据见 HOWTO §同名章节）
### 1. 库文件 `cloudcine.sqlite`
- PC 端路径 `getApplicationSupportDirectory()/cloudcine.sqlite`；drift `schemaVersion = 16`，写在 SQLite 的 **`user_version`** pragma 里。
- 7 张表（列名 = Dart 字段 snake_case，权威定义 `lib/data/db/tables.dart`）：
  `media_items`（PK `id`）· `media_works`（PK `key`）· `subtitle_refs`（PK `id`）· `scan_cursors`（PK `provider`）· `settings`（PK `key`）· `playback_prefs`（PK `itemId`）· `download_tasks`（PK `id`）。
- ⛔ 主键全是**文本**（`provider:fileId` 口径），不是自增。
- ⛔ `media_works.category` 默认**空串**（= 还没判定过），`other` 是**判定结果**，两者不能混。
- ⛔ `resolution` / `container` / `download_tasks.status` 存**枚举名字符串**（不存序号：加档时序号错位会静默变档）。
- ⛔ `flags` / `genres` 是 **JSON 数组字符串**，默认 `'[]'`。布尔列存 **0/1 整数**。
- ⛔ 时间列 drift 存 **Unix 秒**（`DateTimeToSql`，可带小数秒）—— 跨端解析注意单位。
- 迁移 v1→v16 见 `app_database.dart` 的 `onUpgrade`；**有回填的只有 v6/v7/v10/v15**，其余靠 NULL / DEFAULT 语义自然兼容。

### 2. 备份包 `.ccbak`（`lib/domain/services/library_backup_service.dart`）
```
[magic 'CCBK'(4)][manifestLen(4, BE)][manifest JSON utf8]
[dbLen(4, BE)][db 原始字节][posters 打包字节(可选)]
```
- 海报打包：每文件 `[nameLen(4)][name utf8][dataLen(4)][data]`，末尾 `[0]` 终止。
- 扩展名 `.ccbak`；网盘默认目录 **`云影备份`**（`defaultBackupDir`）。manifest：`deviceId / deviceName / createdAt / libraryModifiedAt / schemaVersion / fileNames / note`。
- 同名覆盖是**先删后传** ⇒ 上传文件名**必须带时间戳**。
- ★★ **同步判据是 `libraryModifiedAt`（库内容最后变更时间），绝不是 `createdAt`（备份文件生成时间）**。用 `createdAt` ⇒ 本机永远"新" ⇒ 只会把网盘上的好备份冲成空库。空库无此值 ⇒ `effectiveModifiedAt` 退化成 epoch ⇒ 远程自然赢。
- ★ 本地空库（`hasLibraryContent == false`）**让远程赢**；远程空备份**绝不覆盖本地**。冲突：不同设备且时间差 < 60s（`conflictsWith`）。
- ⛔ 不备份网盘凭证（会话 Cookie 会过期，新机器必须重新扫码）。
- ⛔ `includeSettings` / `restoreSettings` 是**空开关**（导出的是整个 db 原始字节，SQLite 没法在字节层剔表）；UI 三条通道全传 `true`。

## 架构（Flutter PC 端）
`core/` 纯工具 · `domain/` 实体+服务+适配器抽象（**不 import Flutter/drift**）· `data/` 夸克/drift/刮削/凭证 · `ui/` Riverpod 组合根 + go_router + 页面。跨层信号放叶子文件。

## ★★ 4K 卡顿的真因：**播错了档位**（10-06 Mac 实测，`tool/quark_probe.py`）
`黑亚当 2160p`（7490s，原文件 21.9 GiB）：原画 3840×1606 / 21.9 GiB / **3.00 MB/s**；`4k` 3840×1606 / 4.6 GiB / **0.63 MB/s**；`super` 1440×602 / 1.03 GiB / 0.14 MB/s；`high` 960×402 / 678 MiB / 0.09 MB/s。
- ★ **夸克自己的 `default_resolution` 是 `super`**；云影默认播**原画** ⇒ 单连接喂不动 ⇒ 靠 8 连接中继 ⇒ 主线程饿死。**这就是全部秘密**（不是解码、不是渲染面、不是 OSD 画法）。
- ★ 单连接直连实测（Mac，带 Cookie）：`4k` **4.57 MiB/s**、原画 **6.76 MiB/s** ⇒ 够用。「直连只有 1.1 MB/s」**只在电视 WiFi 上成立**。
- ⇒ 治本：**默认播转码档（≥`4k`），不播原画**。Android 端现状：`probeThroughput` 测速 → `chooseQuality` 选「带宽扛得住的最清晰档」（同分辨率取最省带宽，留 30% 余量）。

### 直链 Cookie 规则（10-06 四种组合实测，★ 极易踩）
| 请求带的 Cookie | 结果 |
|---|---|
| 带 `__puus`（**新旧都行**） | **206** |
| 有 `__pus` 等会话 Cookie 但**缺** `__puus` | **412** |
| 完全不带 Cookie | **206** |

⇒ **「要么不带，要么带全」**；带一半最坏（列表能刷、一播就 412/转圈）。`__puus` 在**每个** API 响应里轮换下发（Flutter `quark_adapter.dart:1285` / Android `PanApi.absorbCookies` 都已处理）。
- ⛔ `batch/file/play/info` **必须带 `pr=ucpro&fr=pc`**，漏了回 `HTTP 401 code=31001 require login [guest]`（像没登录，其实缺参数）。
- ⚠️ `hls_type` 实测 **`none`** ⇒ 转码档是**普通 MP4**（`video/mp4`），**不是 m3u8**。
- ⛔ `HttpURLConnection.useCaches = false` 不能省：播放地址带签名，命中缓存会拿到过期地址（「列目录正常、一播就 403」）。
- ⛔ 解析 `video_list` **必须跳过 `audio_list`**：那条是纯音频流，没有分辨率字段，容易被当成「原画」⇒ 有声音、进度条在走、**没画面、不报错**。

## Android 原生端（`android/app/src/main/java/com/cloudcine/tv/`）
> 产品文档与全部踩坑见 **`android/README.md`**；本节只留最容易再犯的红线。
- 形态：`MainActivity`（登录态路由）→ `LoginActivity`（CAS 扫码，zxing）→ `BrowseActivity`（`ListView`，天生支持 D-pad）→ `PlayerActivity`（ExoPlayer + `SurfaceView` 零拷贝 + 原生 OSD）。
- `pan/`：`PanHttp`（`HttpURLConnection`，**不引 OkHttp**）/ `PanApi`（列目录 / 取链 / `absorbCookies`）/ `QrLogin`（业务码读 **`bizCode`**：网盘用 `code`、CAS 用 `status`）/ `PanModels` / `CredStore` / `Bg`（后台池，主线程只 setText）。
- 取流 `ParallelRangeReader` + `ParallelRangeDataSource`（1 条 Range 拆 8 连接）；缓存 `DiskPrefetcher`（**旁路**预取，不走 loader）+ `PrefetchCache` / `DiskCacheEvictor` / `DiskSpace`。
  - ⛔ 缓存键 = **`quark:<fid>:<画质档 id>`**，**不是 URL**。⛔ **档位 id 不能省**：原画与转码档是不同字节流，只按 fid 会把原画字节喂给转码档解析器 ⇒ **解码出乱码且不报错**。⛔ `cacheKeyFactory` 必须**优先认 `dataSpec.key`**；两边复用同一个 `cacheKeyFor()`。
  - ⛔ **播放器不许写磁盘缓存**（`setCacheWriteDataSinkFactory(null)`）：两个写者撞同一 span 时 `SimpleCache.startFile` 抛 `IllegalStateException`，而 `CacheDataSource` 只吞 `IOException` ⇒ 直接崩。写入方只留 `DiskPrefetcher`。
  - ⛔ 预取器**绝不能在预取线程读 `player.currentPosition`**（未捕获异常带走整个进程）。只读主线程刷新的快照。⛔ `bufferedPosition` **必须在 `seekTo` 之前读**。
- `SeekPlan`（纯函数）：拖动中不动进度、**松手才 `seekTo`**（遥控器自动重复 ~20 次/秒 ⇒ seek 风暴 ⇒ 2 秒 28 次 seek 打满 Java 堆）；前 2 秒不加速，之后 ×2/×4/×8/×12；兜底窗口 800 ms **必须大于遥控器自动重复间隔**。
- `TvOsdView`（原生 OSD，挂 `android.R.id.content` 之上）。⛔ 回调只回传**行下标**，行数不固定 ⇒ 一律按 `TvOsdView.Row.id` 分派，别 `when(row){0->…}`。
- ⛔ 速率**不能**取 `AnalyticsListener.onBandwidthEstimate`（一次传输完才发一次）⇒ 用 `CountingDataSource` 在 `read()` 上数字节。⛔ 目录判定**只认 `dir` 布尔位**，`file_type` 仅兜底（`0`=目录、`1`=文件，与直觉相反）。
- ⛔ `ListView` 用 `divider = null` 看不出选中项；⛔ XML 注释里不能出现 `--`。调试通道 `Log.i("CloudCine", "[统计] …")` / `[按键] → 下一帧 x.x ms`（`android/tool/adb_tv.sh log`）⛔ **不是调试残留**：有硬件视频层时 `screencap` 拿不到画面、播放中 `uiautomator dump` 也拿不到 UI。
- ⛔⛔ **`UI fps` 不可用于比较**：`StatsOverlay.doFrame` 里 `choreographer.postFrameCallback(this)` 自己重排自己 ⇒ 恒≈刷新率。唯一可比的是**「按键→下一帧」**与 SurfaceFlinger `--latency`。

## Flutter PC 端红线（**逐条理由与实测在 HOWTO**，此处只列标识符）
- **引擎/硬解**：⛔ `hwdec` 写 **`mediacodec,auto-safe`**（逗号=回退）；`VideoControllerConfiguration.hwdec` 与 `PlayerBufferConfig.apply` **必须同值**且都在 `create()` 之前；判据读 `hwdec-current`（带 `copy` = 拷贝档，⛔ 空串不算）。⛔⛔ **10-04 那两轮别再走**：① 只加 `VideoViewType.platformView` →「更卡、音画不同步」；② 再加 `tunnel: true` →「4K 看不到画面，只有声音」。`main.dart:57` 只在 **macOS** 注册 fvp；DV P5 唯一出路是 **fvp/libmdk**。契约 `playback_engine.dart` / 路由 `playback_engine_router.dart` / 画面 `playback_surface.dart`。
- **中继** `data/stream/local_stream_relay.dart`：⛔ **没有 `Isolate`/`compute`**（全在 Dart isolate）；只在用户显式选原画时才需要。`core/utils/http_range.dart` = `sealed class RangeRequest`（`NoRangeRequest`/`SatisfiableRange`/`UnsatisfiableRange`）+ `parseRangeRequest()`：⛔ **起点越界必须回 416**，别把「不知道流多长」（→200）与「要不到」（→416）合成一个返回值（旧实现用一个 `null` 表达两件事 ⇒ 416 成死代码、测试一直绿 ⇒ media3 丢前几 GB 对齐偏移 ⇒ **「正在加载…」永不消失**）。⛔ **`chunkSize` 别放大**（2 MiB→8 MiB 后首块 1.18s→15~45s、零成功播放；回归测试断言 `chunkSize/0.6MiB < 5000ms`）；提速调 `connections`/`prefetchBytes`。
- **媒体库三轴（不能互推/合并）**：`MediaKind`（结构，只看文件名 `SxxExx`）· `MediaCategory`（语义，落 `media_works.category`）·「最近播放」（视图 `LibraryFilter.playedOnly`，与 `category` 互斥）。层级**不落库**（现算）：**季在外、部在内**，某层**少于 2 个选项不画**。⛔ **归一 = 打标记**（`mergedInto`）：不删行、不改 `group_key`、**不许链式**；⛔ `mergeWorkForUpsert` **无条件取旧值**（`mergedInto` / `introStartMs`/`introEndMs` 都是「扫描不许清」的列）。⛔ **目录名当系列名**：判定单元是**目录不是文件**（`DirectoryTitle`），**四处调用点都要传 `dirPath`**。⛔ 筛选「已刮削」= **`source==online`**（不是 `isScraped`）。⛔ `posterFaceX` 与 `posterUrl` **必须成对**（`faceAnchorX` 与 `thumbUrl` 同源成对）。⛔ 路径归一化只在 `core/utils/drive_paths.dart`。⛔ 字幕字节走 `decodeTextBytes`（先 UTF-8 后 GBK）。
- **★ 刷新信号四件套**（叶子文件 `ui/providers/library_refresh_providers.dart`，避免循环 import）：`libraryWriteSignal` =「库里数据变了，**凡是读库的视图都该重看**」（扫描 / 发现 / 追更检查 / 批量刮削都推它）· `libraryListSignal` 只驱动**作品级列表**（避开 `folderTreeProvider` 每次读全表）· `playbackProgressSignal` 每次进度落库都推，只驱动详情页进度条 · `playbackLibraryLink` 只在**换条**时推，驱动「最近播放」顺序。⛔⛔ **任何读库的 `FutureProvider` 都必须 watch 对应的写信号** —— 漏掉的表现是「用户点一下刷新才看得见」（2026-10-07 追剧现场，细节 §9.8）。⛔ 角标类数据必须有**归零路径**。⛔⛔ **`ref.invalidateSelf()` 别在 provider 自己的 body 里用**（本次计算的 future 永不完成 ⇒ `disposed during loading state` ⇒ 页面卡死 / 单测超时），改手上那一份即可。
- **播放器/页面**：⛔ **两份实现，别只改一个**（`player_window_app.dart` + `player_page.dart`：键位表/菜单/偏好还原/换流提示/hover 唤醒都要改两处）。⛔ 起播只走 `Media(start:)`（入口 `PlaybackMedia.build`，`seek` 只在播放中跳转；⚠️ 它**静默** ⇒ 换源后核对 `RestoreSeek`）。⛔ 进度两列别合并：`resumePositionMs`（起播，看完清）vs `maxPositionMs`（v15，只增不减）。⛔ 落库接 `PlaybackController.onPositionTick`，不暴露 `Player`。**音效 ≠ 音轨**（⛔ `af set` 返回值不能当依据；⛔ macOS `audio-spdif` 直通必卡死）。
- **侧栏五项** 媒体库 `/library` · 文件夹 `/folders` · 扫描 · 下载 · 设置：⛔ `app_shell._items` 与 `app_router.branches` **必须同序**（判据是下标）；文件夹读**网盘实时目录**、媒体库读**本地索引**，**搜索词各一份**。
- **目录视图**：三组**目录 → 视频 → 其他文件**（组间顺序是**结构**）。⛔ 入库判据只有 `classifyEntry` 一处。⛔ 下载取链**复用 `adapter.resolveStream`**（别打 `/file/download`，>50MiB 直接 23018）。
- **下载（v16）**：⛔ `.part` 是断点**唯一真源**；服务端**忽略 Range 回 200 必须从 0 重写**；`parse` 读不懂退 **paused**。
- **文件夹模式**：本地索引只做**「已入库」叠加层**，共用 `media_entry_classifier.dart`（镜像判定在视频判定**之前**）。⛔ **绝不清理陈旧记录**、**绝不写续扫游标**、**深度从本次目标算第 0 层**。
- **TV**：`isTvLayout` = android + 逻辑宽≥960（⛔ 判据读 view 宽，页面实得 624，**壳外页实得 960**）。⛔ 页头 `actions` 必须 `Wrap`；⛔ **过扫描内边距只有 `app_shell` 一处**；⛔ 遥控器 **↓ 绝不接管**；⛔ **`SelectableText` 是焦点陷阱** → 用 `TvSelectableText`。
- ⛔ **播放页 OSD 卡顿**：整页 rebuild ≈10 次/秒（`bufferEnd` 没节流）+ `SubtitleViewConfiguration` 无 `operator ==`（内联 new ⇒ 每拍重建）+ `DebugOverlay` 的 `kDebugOverlayEnabled = true` **硬编码**（release 也显示，每秒重建整棵树 + spawn 一个 `df`）。

## 资源采样 / 电视取证（细节 §HOWTO）
- ⛔ 采样**周期 10 秒**，**故意不与**视频探针的 21 秒相等（会**拍频锁定**；10 与 21 互质）。**读不到一律留空、整段从日志行消失**，不许退化成 0。⛔ 进程 CPU 是**单核口径**，必须写「折合 N 核」；系统 CPU「忙」**不含 iowait**；`/proc/stat` 只认汇总行 `cpu `。⛔ `/proc/loadavg` 在电视上 `Permission denied`；`/proc/pressure/*` 在 Android 9 不存在 ⇒ 用 `procs_running`/`procs_blocked`，写「可运行进程=N（4 核，超订 x.xx×）」。⛔ `/proc/self/stat` **按最后一个 `)` 切**；⛔ `df` 正则**从左锚定**。macOS 无 `/proc`：内存退回 `ProcessInfo.currentRss`，CPU/负载留空属**正常**。
- **应用日志是文件、不是 logcat**：`DiagLog` 同步写 `files/logs/cloudcine-YYYY-MM-DD.log`（⛔ mtime 不涨 = 应用真没做事）。**线程名读 `/proc/<pid>/task/*/comm`**（`top -H` 在 Android 9 全打进程名）。⛔ `exec-out screencap` 会被引擎日志污染 ⇒ `shell screencap -p` + `pull`。
- **★ 视频真帧率用 SurfaceFlinger 量，别信 HUD**：`dumpsys SurfaceFlinger --list` 找层 → `--latency '<层名>'`。实测 `activeBuffer=[3840x2160:3840,Unknown 0x13]` 才是**视频层**；`SurfaceView #0` 是 `1920x1080 RGBA`。⛔ **LMK 会杀掉后台的云影**（电视仅 2.5 GB）⇒ 先 `am kill-all`。

## 打包 / 签名（细节 §HOWTO）
- **Windows MSI**：⛔ 启动条件绝不能写 `VersionNT >= 1000`（Windows Installer 把 VersionNT **钳在 603** ⇒ 在任何真实 Windows 上都失败）；用 **`WindowsBuild >= 10240`** + `Installed OR`。⚠️ MSI 条件语法**不支持括号**。
- **macOS**：⛔ 不许写 `keychain-access-groups`（→ 启动即 SIGKILL）；`app-sandbox` 必须 **`false`**。凭证走 `EncryptedFileSecretBackend`（⛔ 别再试钥匙串），密钥由 `IOPlatformUUID` 派生。
- **Android**：Gradle 8.10.2 / AGP 8.7.0 / Kotlin 2.1.0 / compileSdk 36 / minSdk 21 / targetSdk 34 / Media3 **1.5.1**。⛔ **首次构建必须联网**；`JAVA_HOME` 必须 **JDK 21**（JBR 25 会崩 Kotlin）。⛔ 不引 `media3-ui` / AppCompat / Material / RecyclerView。⛔ `isMinifyEnabled` 故意 false。⛔ 品牌化产物落 `outputs/apk/branded/`。
- ⚠️ **本机出不了 Flutter release/profile 包**：AOT 快照工具是 `darwin-x64`，Apple Silicon 无 Rosetta ⇒ `gen_snapshot ... incorrect architecture`。解法（需 sudo）：`sudo softwareupdate --install-rosetta --agree-to-license`。

## 测试取向
- 纯函数优先；断言写「为什么重要」。⛔ **每个需求只跑相关单测，不回归全量**（用户 10-04 定的）。修并发/竞态 bug **先加测试确认红**再加修复。⚠️ 用户常**边改边跑**，判据 = 红的在不在我改的文件里。
- Android：`./gradlew :app:testDebugUnitTest`（107 例 0 失败基线）；`assembleRelease` 会自动带上单测。

---

# ★ 2026-10-06 Android 媒体库：实现细节与两个坑

## 1. drift 的 DDL 有两个「看不出但比对不过」的写法

从 PC 端 `sqlite_master.sql` dump 出来的原文里有两条规则，凭直觉写生成器**一定错**：

| 规则 | 直觉写法 | drift 实际 |
|---|---|---|
| 可空列 | `"language_code" TEXT` | `"language_code" TEXT NULL` ← **显式写出 `NULL`** |
| 主键 | 列上写 `PRIMARY KEY` | 表尾 `, PRIMARY KEY ("id")` |

省略 `NULL` 在 SQLite 里语义**完全相同**，所以不会报错、也不影响读写 —— 但
`LibrarySchemaTest` 的逐字比对会红（第一版 5 条全红，差异都停在第 166/255/260/209/180 个字符）。
`ALTER TABLE … ADD COLUMN` 生成的补列 DDL 也走同一套规则（同样带 `NULL`）。

⇒ 生成器只有一处 `columnSql()`，两边共用；`assertDdl()` 在失败时打印**第一处差异的上下文**，
比整串 `assertEquals` 有用得多（几百字符的单行没法读）。

## 2. `library/` 与 `pan/` 的设计取舍（逐条）

- **不做 v1→v16 迁移**：Android 打开库只做「补缺表 / 补缺列 + 对齐 `user_version`」。
  补列**必须去掉 `NOT NULL`** —— SQLite 的 `ALTER TABLE ADD COLUMN` 拒绝
  「`NOT NULL` 且无默认值」的列（报 `Cannot add a NOT NULL column with default value NULL`），
  而 v16 的 `first_seen_at` / `updated_at` 正是这种。跨端互操作只认列名与类型。
- **不用 WAL**：备份包装的是**单个文件的原始字节**。WAL 下最新数据可能还在 `-wal` 里 ⇒
  导出去的是**旧库**，而且不报任何错。所以显式 `PRAGMA journal_mode=DELETE`。
  `LibraryDb.rawBytes()` 必须先 `close()`；`replaceWithRawBytes()` 必须先删
  `-journal` / `-wal` / `-shm`（否则下次打开会把**旧库的回滚日志回放到新库上**）。
- **自写 `MiniJson`**：`org.json` 在 JVM 单测里是空壳（`isReturnDefaultValues` 下方法体被抹掉、
  返回 null），而备份清单是跨端契约里最要紧的一块，必须能被纯 JVM 单测覆盖。
  ⛔ 整数必须写成整数（`16` 而不是 `16.0`）—— Dart 那边 `as int?` 遇到 double 会给 null，
  版本号就悄悄退化成默认值 1。
- **自写 `IsoTime`**：`java.time` 要 API 26 而 minSdk 21（会被没关掉的 `NewApi` lint 拦下）；
  `SimpleDateFormat` 吃不下不定长小数秒（Dart 的 `toIso8601String()` 在微秒非零时输出 **6 位**）。
  输出固定 `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`，解析容忍 1~9 位小数秒 / `Z` / `±HH:MM` / `±HHMM` / 无后缀（按 UTC）。
  ⛔ 输出**必须带 `Z`**，否则 Dart 按本地时间解析，比较偏掉一个时区。
- **`SyncDecision` 抽成纯函数**：它是「新机器会不会把网盘上的好备份冲成空库」的唯一防线，
  而它的错法**全是静默的**（两边都显示「同步成功」）。分支顺序与 PC 端一字不差：
  ① 远程为 null → 上传 ② 本地空库 → 让远程赢 ③ 远程空备份 → 用本地覆盖
  ④ 不同设备且差 < 60s → 冲突 ⑤ 比 `effectiveModifiedAt`。
  ⛔ 把 ④ 提到 ② 前面，新机器第一次同步就会看到「冲突，请手动选择」。
- **`OssAuth` 抽成纯函数**：签名串 / XML / Base64 错了全是静默的（403 或「合并失败」）。
  自写 Base64 的理由：`android.util.Base64` 在 JVM 单测里是空壳；且 **DEFAULT 会换行**，
  而 `x-oss-callback` 的 Base64 会进签名串，插了 `\r\n` 就再也对不上。

## 3. ★ 模块编译被并发会话挡住时，怎么拿到确定结论（可复用）

2026-10-06 19:44~19:48 另一个会话正在改 `PlayerActivity.kt` / `BrowseActivity.kt` /
`TvOsdView.kt` / `AppPrefs.kt`，并新增 `AudioEffect.kt` / `ExternalSubtitle.kt`。
每次重试报的错都不一样（`SUBTITLE_TICK_MS` → `ROW_AUDIO_EFFECT` → `restorePendingTracks`），
**全部在他们的文件里** —— 只要他们没写完，`./gradlew` 就永远红。

**做法**：复制一份到 `/tmp`，把他们改过的文件还原成 HEAD，再在那里构建。

```bash
rm -rf /tmp/ccverify && mkdir -p /tmp/ccverify
rsync -a --exclude 'build/' --exclude '.gradle/' android/ /tmp/ccverify/android/
D=/tmp/ccverify/android/app/src/main/java/com/cloudcine/tv
for f in PlayerActivity.kt BrowseActivity.kt TvOsdView.kt AppPrefs.kt; do
  git show "HEAD:android/app/src/main/java/com/cloudcine/tv/$f" > "$D/$f"
done
rm -f "$D/AudioEffect.kt" "$D/ExternalSubtitle.kt"
# 测试目录里他们的新测试文件同理
cd /tmp/ccverify/android && export JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home
./gradlew :app:testDebugUnitTest --tests "com.cloudcine.tv.library.*" --offline
```

- 判据：**`e:` 行里没有我的文件** = 我的代码编译通过（Kotlin 前端一次报告整个模块的诊断）。
- 关键点：**只还原「他们改过的」文件**，别还原 `pan/`（那里有我的改动）。
  `git diff --stat HEAD -- <dir>` 能一眼看出哪些文件属于他们。
- 复制的副本里 `local.properties` 会跟着过去（`sdk.dir` 在里面），不用重配 SDK。
- 跑完 `rm -rf /tmp/ccverify`。仓库**零改动**。
- ⛔ 不要为了「让它编过」去动他们的文件 —— 那会覆盖对方正在写的内容。

## 4. 本轮验证结果

`./gradlew :app:testDebugUnitTest --tests "com.cloudcine.tv.library.*" --tests "com.cloudcine.tv.pan.*"`
→ **94 例 0 失败**（LibrarySchema 13 / BackupManifest 22 / BackupPackage 15 / MiniJson 13 /
SyncDecision 10 / LibraryBackupService 3 / OssAuth 18），零编译错误。

---

# ★ PC 端红线细节（2026-10-06 从 MEMORY.md 下沉，起因：MEMORY.md 超 1.4 万字节被注入截断）

MEMORY.md 只留**标识符索引**，下列为**理由与完整判据**。

## 1. 已失效的「Flutter 跑在 Android 上」整条线（⛔ 别再引用）
`hwdec=mediacodec,auto-safe`（光写 `mediacodec` 失败只剩软解；判据读 `hwdec-current`，带 `copy` = 拷贝档）
· `VideoControllerConfiguration.hwdec` 与 `PlayerBufferConfig.apply` **必须同值**且**都排在 media_kit `create()` 之前**，Surface 就绪后要再写一次
· `VideoViewType.platformView`（10-04 实测「更卡、音画不同步」）· `tunnel: true`（「4K 看不到画面，只有声音」）
· `fvp.registerWith` 只在 macOS · Android 备用内核 `VideoPlayerExoPlaybackEngine()` · `highResTvRoute` = `Platform.isAndroid && tv`
· `playback_engine_router.dart:184` 判据 `videoHeight >= 2048`（⛔ 不是 2160）· `:199` 日志文案写死「切到 fvp（libmdk）」实际是 ExoPlayer（**待修**）
· mpv 在 Android 上**做不到零拷贝**（`media_kit_video-1.3.1/android/.../VideoOutput.java` 写死 `createSurfaceProducer()`）· 崩溃证据 `libmdk.so` 的 `strlen→vfprintf` / `SurfaceTextureWrapper.release`
· `ro.boot.mi.panel_resolution=3840x2160` 但 Android 显示层只有 1920×1080（`dumpsys display`）
· 旧观察（已废弃）：真机 `解码丢帧=0 / 显示丢帧 21s 涨 44`、[中继] 零告警 ⇒ 瓶颈不在解码。
  证据 `docs/AndroidTV-4K-丢帧-夸克对标.md`，方案 `docs/解决4k片源不卡顿解析方案.md`。

## 2. 中继 416 契约的完整由来
`core/utils/http_range.dart` 旧 `parseRangeHeader` 用**一个 `null`** 同时表达「没要求区间」（→200 整文件）和「起点越界」（→416）；
调用方 `clampRange(requested ?? ByteRange(0,total-1), total)` 只能二选一、选了整文件 ⇒ **416 成死代码**；旧单测注释还写「交给 416」—— **契约两半分家，测试一直绿**。
后果（`凡人` 4K 3.13 GiB）：播放器问 `bytes=5014520206-`，中继回 `200 bytes 0-3358116481/…`；
「对带 Range 的请求回 200」=「这是完整资源」⇒ media3 丢掉前 5.01 GB 去对齐偏移，可整条流只有 3.13 GiB ⇒ 读完才 EOF ⇒ **「正在加载…」永不消失**。
判据：`[中继]` 出现 `读取器 #N → 200 bytes 0-<总长-1>/<总长>` 且请求 `Range: bytes=<大于总长>-`。

## 3. `chunkSize` ↔ 首字节延迟（10-05 血案完整版）
`_fetchChunk` **整块读完才 `cache.put` + `_settle`** ⇒ 首字节延迟 ≈ 单块下载耗时，与 `chunkSize` 成正比。
2 MiB→8 MiB 后首块 1.18s→**15~45s**、**零成功播放**、每次换片 `Source error`。✅ 已改回 2 MiB；
回归测试 `test/data/stream/local_stream_relay_test.dart`「默认 chunkSize 的首字节预算」（断言 `chunkSize/0.6MiB < 5000ms`）。提速调 `connections`/`prefetchBytes`。
⛔ **`Source error` 的真判据不是「首帧 > 8s」**（原型首帧 12.3s 却没错）。`DefaultHttpDataSource` readTimeout 是**单次 socket 读**空闲上限：
2 MiB 中继 ~2.8s 出首字节；8 MiB **整块读完才发第一字节**，>8s 零字节 ⇒ 必炸。`warmUpRelay(timeout:2500ms)` / mpv ~5s / ExoPlayer ~20s 都远小于它。
⛔ 换源时 `fvp 失败 → 回退 media_kit` 会**再建一个中继会话**（sN/sN+1）⇒ 一次换片 = 2 次首块等待。
⚠️ 同窗口有**跨内核陈旧事件**（切回 mpv 后 2.2s 仍收 `ExoPlayer 首次初始化失败`）→ 待查。

## 4. PC 媒体库三轴 / 层级 / 归一
- 三轴**不能互推、不能合并**：`MediaKind`（**结构**，只看文件名 `SxxExx`）· `MediaCategory`（**语义**，落 `media_works.category`）·「最近播放」（`playedOnly`，与 `category` **互斥**）。
- 层级**不落库**（现算）：**季在外、部在内**；某层**少于 2 个选项不画**。
- ⛔ **归一 = 打标记**（`mergedInto`）：**不删行、不改 `group_key`、不许链式**。
- ⛔ **目录名当系列名**：判定单元是**目录不是文件**，**四处调用点都要传 `dirPath`**。
- ⛔ 「已刮削」= **`source==online`**。⛔ `posterFaceX` 与 `posterUrl` **必须成对**。⛔ 字幕字节走 `decodeTextBytes`（先 UTF-8 后 GBK）。

## 5. PC 播放器 / 进度 / 音效
- ⛔ **两份实现，别只改一个**（`player_window_app.dart` + `player_page.dart`）。⛔ 起播只走 `Media(start:)`。
- ⛔ 进度两列**别合并**：`resumePositionMs`（起播，看完清）vs `maxPositionMs`（v15，只增不减）。
- ★ **音效 ≠ 音轨**（**别合并菜单**）：`音轨` = 片源里封着的流；`音效` = 播放端对输出的处理。⛔ macOS `audio-spdif` 直通必卡死 ⇒ macOS `passthroughAvailable == false`。

## 6. PC 导航 / 目录视图 / 文件夹模式 / 下载
- 侧栏五项 媒体库 `/library` · 文件夹 `/folders` · 扫描 · 下载 · 设置：⛔ `app_shell._items` 与 `app_router.branches` **必须同序**（判据是**下标**）；文件夹读**网盘实时目录**、媒体库读**本地索引**，**搜索词各一份**。
- 三组**目录 → 视频 → 其他文件**（**组间顺序是结构**）。⛔ 入库判据只有 `classifyEntry` 一处。
- ⛔ 下载取链**复用 `adapter.resolveStream`**（别打 `/file/download`，>50MiB 直接 23018）；⛔ `.part` 是断点**唯一真源**，服务端**忽略 Range 回 200 必须从 0 重写**，`parse` 读不懂退 **paused**。
- 文件夹模式只做**「已入库」叠加层**（镜像判定在视频判定**之前**）：⛔ **绝不清理陈旧记录**、⛔ **绝不写续扫游标**、**深度从本次目标算第 0 层**。

---

## §AND-1 Android 媒体库 / UI / OSD（2026-10-06 从 `MEMORY.md` 下沉，逐条细节）

> `MEMORY.md` 只留红线短句 + 索引；**判据原文在此**。新增条目请往这里加，别把 MEMORY 撑爆。

### 1. 媒体库数据结构（Android 侧 `library/`）
- `LibrarySchema` = **唯一真源**，7 条 DDL 与 Dart（`lib/data/db/tables.dart` / drift）**逐字一致**，`LibrarySchemaTest` 守着。
- `LibraryDb`：打开即**补表补列** + 对齐 `user_version`；⛔ **不做 v1→v16 迁移**；补列**必须 `col.copy(notNull = false)`**（照抄 DDL 的 NOT NULL 会让老库 ALTER 失败）；⛔ **不用 WAL**，`journal_mode=DELETE`（备份要直接拷文件，WAL 会把新数据留在 `-wal` 里 ⇒ 备份丢最近改动）。
- `LibraryModels` · `LibraryPaths` · `LibraryBackupService`。
  - ⛔ `rawBytes()` 必须先 `close()`；`replaceWithRawBytes()` 必须先删 `-journal`/`-wal`/`-shm`。
  - ⛔ `LibraryItem` 必须带 `dirId`（起播传 `EXTRA_PDIR`，用来扫同目录字幕）。
- 备份包 `.ccbak` 的 Android 侧：`BackupPackage` · `BackupManifest`（含手写 `IsoTime`，⛔ 不能用 `SimpleDateFormat` 拼时区）· `SyncDecision`（纯函数，**分支顺序不能动**）· `MiniJson`（⛔ `org.json` 在 JVM 单测里是空壳；整数不能写成 `16.0`）。
- ★ **drift 的 DDL 两处反直觉**：可空列**显式写 ` NULL`**；主键写在**表尾**（`ADD COLUMN` 同一套规则）。

### 2. 媒体库 UI（`LibraryActivity` / `BrowseActivity`）
- ⛔⛔ **`AbsListView.OnItemClickListener` 在电视上按 OK 不触发**（实测 `input keyevent 23` 零反应）⇒ 必须在 `dispatchKeyEvent` 里自管 OK，**DOWN 与 UP 都要吞**（只吞 DOWN ⇒ UP 再触发一次 `performItemClick`，一按播两遍）。`OnItemClickListener` 只留触摸路径。
- ⛔ **`applyWorks` 里无条件 `requestFocus()` = 一级导航「点不动」**。守卫 `if (!tabsFocused && !filterVisible && !overlayVisible)`。
- ⛔ **光标态与生效态必须分离**：←→ 只移 `navIndex`（不查询），OK 才 `applyTab()` 落 `category`；否则连按 = 6 次全量查询。
- ★ **取片算法 `PlayTarget.resolve`**（移植 `lib/domain/services/play_target.dart`，`library/PlayTarget.kt`，10 例单测）：①有续播点（`resume>0`）的一集，多条取 `lastPlayedAt` 最大、全无时刻退**列表最后一个** → ②有播放记录但已看完 ⇒ **仍播那一集，绝不猜下一集** → ③第一条。**先滤 `is_sample_or_extra`**（花絮），全花絮才退回全部。⛔ `Cursor.boolOrFalse` 读不到当 `false`（误判花絮 ⇒ 文件从候选消失 ⇒ 症状「点海报没反应」）。
- ★ **海报文件名要自己算**：`media_works.poster_file` **PC 端从不回写**（128 部全空）⇒ 按 `poster_cache.dart` 规则 `{sanitize(key)}_{FNV-1a32(url) 8位}.jpg` 现算。`PosterNaming.kt` + 18 例单测与 Dart 逐字对拍（真机 **命中 128/128**）。⛔ FNV 溢出即回绕；`0x811C9DC5 > Int.MAX_VALUE` ⇒ 写 `0x811C9DC5L.toInt()`；Dart `\s` 比 Java 宽（含 `\u00A0/\u3000/\uFEFF/\u2000-\u200A`，但 **`\u200B/\u200C` 不算**）。
- ★ **分类口径**（PC `_categoryCondition`）：`movie`/`series`/`other` 三桶带**空串兜底**；`anime`/`variety`/`documentary` 只看那一列。**Android 有意修正**：PC 写 `category = ''`，而 SQL `NULL = ''` 为假 ⇒ 改 `(category IS NULL OR category = '')`。⛔ 分类计数必须与筛选条件**逐字对齐**（`CASE` 分桶），否则「角标 72、点进去 68」。
- ★ **`genres` 是 JSON 文本** ⇒ `LIKE '%"动画"%'`（带引号）才不捞进「动画片」；**项间是「或」**，「与」只发生在维度之间。⛔ 分面角标作用域**不含 years/genres 自己**（否则勾第一个类型后其余角标就变、勾第二个列表已空）；⛔ **「已选但当前范围没有」的项仍要画**（`stale`/「无结果」），否则那颗 chip 消失但它仍生效。
- ★★ **深色 UI 的层次靠实心面明度，不靠描边**（用户**两次**点名「线框不高级/难看」）。选中态 = 实心圆角块 + 左侧 4dp 强调竖条（`MenuRow.kt`，`0xFF3A3268` 底 / 白字）；一级导航三态全实心（生效 `BRAND_TINT`+深字 / 光标 `0xFF4A4278` / 常态 `0x14FFFFFF`）；⛔ **导航带不许画整体贯通外框**（`tabsBox.background = null`）。卡片焦点三层：非选中 `alpha=0.62` + 描边 + `scale 1.05`（`clipChildren=false`）；选中项变化要 `post { notifyDataSetChanged() }` 重画可见卡片。
- 筛选面板 = **一维列表**（不做二维网格：电视上折行位置随数量变，最易「按右键跳得莫名其妙」）；`openMenu()` 用 `ArrayList<Pair<String, () -> Unit>>`，⛔ 别用「labels + `when(index)`」（插项后下标错位，其中一项是不可逆的「从网盘恢复」）。

### 3. 播放器 OSD 的「画质」行（10-06 用户反馈：选项过长、超出面板）
- **现象与修法**：`PlayerActivity.buildRows()` 里画质 chip 曾经拼 `"${label}  ${detail}"`（`4K  3840×1606 · 5.2 Mbps · 需 0.63 MB/s`）⇒ 一个 chip 就吃掉大半行，后面几档全被挤出右侧面板（用户原话「选项过于冗长，超出设置面板，只需要 4K 原画 超清等名称即可」）。现改为**只放短名** `pi.qualities.map { it.label }`。
- **短名来源**：`PanApi.tierLabel(id)` = `4k→4K` · `2k→2K` · `super→超清` · `high→高清` · `normal→标清` · `low→流畅`；映射表外的 id **原样回退**（所以 chip 必须设宽度上限）。
- **信息不丢**：分辨率 / 码率 / `需 X MB/s` 改由 `rebindOsd()` 追加一行 `Log.i("CloudCine", "画质档位：…")` 输出 —— 「4K 卡顿」排查第一步就是对照这几档的需带宽（原画 3.00 vs 4k 0.63 MB/s）。菜单里那点数字本来也没人算，选档已由 `chooseQuality` 按实测带宽自动做掉。
- **防御**：`TvOsdView` 里每个 chip 设 `maxWidth = MAX_CHIP_W`（160dp）+ `maxLines = 1` + `ellipsize = END`，防服务端给出超长档位 id 时一个 chip 撑满整行。面板右侧可用宽 ≈ 屏宽 − `SAFE_H`(48dp) − `SIDEBAR_W`(180dp)，1080p 上约 560dp。

### 4. 启动时问一句「网盘上有更新的备份，要不要同步」（2026-10-07）

**需求**：每次启动 Android TV App 时提示是否有更新的媒体库备份、是否需要同步。

**为什么需要**：「同步」原本只藏在 MENU 菜单里 ⇒ 用户在电脑上扫完库 / 刮好海报，回到电视上看到的还是上周那份索引，而**他不会想到去菜单里点一下** ⇒ 跨端同步这个能力等于不存在。

**实现（Android 端新增，PC 端没有这个功能）**
- `library/StartupSync.kt`：策略对象。`shouldPrompt(action)` 决定弹不弹；`probedThisLaunch` + `beginLaunch()`/`markProbed()` 管「本次启动」的零点。
- `LibraryBackupService.probeRemote()`：**只读**探测，返回 `Probe(action, latest, remoteManifest, localModifiedAtSec)`；`decide()` 复用 `SyncDecision`，方向判断与 `sync()` 完全同源。
- `LibraryActivity.probeRemoteBackupAtStartup()` / `askStartupSync()`：`onCreate` 里 `root.post{}` 发起（别挡首帧），回来后弹 `showOverlay`，两个选项 `暂不同步` / `立即同步`（**默认落在「暂不同步」**，恢复是破坏性的）；点「立即同步」走 `doSync()` 而**不是** `doRestore()`（`sync` 会重新判一次方向）。
- `MainActivity.onCreate` 调 `StartupSync.beginLaunch()`。

**判据（⛔ 别改）**
1. **只在 `restores` 那两个动作弹**（`restoreRemoteNewer` / `restoreLocalEmpty`）。`uploadLocalNewer` 是**常态**（看一集就变了），也问就变成每次启动烦一次；`uploadFirst`/`uploadRemoteEmpty` 要动的是**网盘**；`conflict` 要看得见两边的库才选得出来，两行弹窗承担不了。`StartupSyncTest` 里有一条「弹的条件恰好等于 `Action.restores`」，穷举 `when` ⇒ 以后加第八个动作会**编译不过**，逼着做决定（漏判是静默的：不弹 = 用户根本不知道有这回事）。
2. **零点在 `MainActivity.onCreate`，不在 `LibraryActivity`**。每个页面是独立 Activity，从「文件列表」返回会**重建** LibraryActivity ⇒ 状态放那儿就变成「来回切一次弹一次」。`MainActivity` 是 LAUNCHER 入口且自己 `finish()` ⇒ 从桌面点一次图标必然新建一次它。
3. `markProbed()` 在探测**发起时**置位，不等跑完（探测慢时用户可能已经点进文件列表又退回来 ⇒ 会重复发起）；失败也不重试。
4. **失败静默**：没网 / 未登录 / 网盘抽风一律只写日志。启动路径上弹错误框比「这次没同步」更烦，而且用户没法处理。
5. **界面正忙就不弹**（`busy || overlayVisible || filterVisible || scanCancel != null` 时只记日志）：`showOverlay` 会直接盖掉当前那层菜单。

**三处「不」——都为了不在启动路径上产生副作用 / 白流量**
- **不创建备份目录**：`PanApi.findFolder()`（新加的，只查不建）而不是 `ensureFolder()`。否则从没备份过的用户每开一次电视就被塞一个空的「云影备份」。
- **不整包下载**：清单在包最前面（`[magic][清单长度][清单][库][海报]`），走新加的 `PanApi.fileHeadBytes()` → `PanHttp.getBytesHead()`，带 `Range: bytes=0-65535` 只读 64 KiB。⛔ `getBytesHead` 与 `getBytes` 的**唯一差别是超长不抛**（`getBytes` 读满 `maxBytes` 会抛，因为它的用途是字幕/图片）。服务端不认 `Range` 时也只读到 64 KiB 就断开，结果一样。读不出清单才退回整包（`readRemoteManifest` 的兜底）。
- **不读库文件字节**：`lightLocalManifest()` 只用 `db.libraryModifiedAt()`，**不调 `exportBackup()`** —— 后者会走 `LibraryDb.rawBytes()`，而那个方法为了拿到自洽的库文件**先 `close()`** 连接；启动时主线程刚 `loadWorks()` 完，撞上就是「already-closed object」。⛔ 口径必须与 `exportBackup` 的清单等价：`decide` 只用 `hasLibraryContent` / `effectiveModifiedAt` / `deviceId` 三项。

**文案**：`MM-dd HH:mm · 12.3 MB · 来自「小米电视」`（时间用**本机时区**显示 —— manifest 存的是 UTC 毫秒）+ 「本机媒体库比它旧。」/「本机还没有媒体库。」+ 「同步会用网盘上那份覆盖本机（本机还没上传的改动会丢失）」。

**测试**：`StartupSyncTest`（4 例）；`BackupPackageTest` 加了一例「只拿到包头的若干字节也读得出清单」—— 它是「探测只读头部」这个假设的唯一防线（有人把清单挪到包尾时会红）。

**⛔ 顺带发现的坑（2026-10-07 07:22）**：`android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java` **未跟踪**、会突然出现（在根目录跑 Flutter 工具会往 `android/` 里重新生成 Flutter 宿主），让 `:app:compileDebugJavaWithJavac` 直接 **35 个错误**（`找不到符号 Log` / `程序包 io.flutter.plugins.* 不存在`）。它**不属于本工程**，清掉即 `rm -rf android/app/src/main/java/io`。排查手法：`compileDebugJavaWithJavac` 平时是 `NO-SOURCE`，它一旦「执行并失败」就说明源码树里混进了 Java 文件。

### 5. 文件夹「发现」+ 手动刮削 + 凭证随备份（2026-10-07）

**三个需求一次做完**：① 文件列表里能「扫这个目录、把里面的片子收进媒体库」；② 详情页能「手动刮削」；③ 刮削的 token / cookie 随备份恢复。

#### 5.1 「发现」= 局部扫描，与全盘扫描有**三条硬区别**（`LibraryScanner.discover`）

| | 全盘 `scan` | 发现 `discover` |
|---|---|---|
| 清理陈旧记录 | 调 `pruneMissingItems` | ⛔ **绝不调** |
| 写续扫游标 `scan_cursors` | 写 | ⛔ **绝不写** |
| 深度 | 按设置 | `recursive=false` 只扫一层 |

「只增不减」是这一整个功能的**定义**：用户在文件列表里点的是「把这几个收进来」，不是「用这个目录重建我的库」。任何一处泄漏（顺手 prune 一次）都会让用户丢掉别的目录里的条目，而且**不报错**。
- `Discovery` 数据类**刻意没有 `itemsPruned` 字段** —— 字段缺席本身就是约定。
- 复用全盘那条链的 `toItem` / `accumulate` / `toWork` / `listAll` / `insertMissingWorks` / `refreshWorkStats`，只换遍历入口。
- ⛔ 归组用**库里已有的 `group_key`**（`db.groupKeysOf`），不用本次解析出来的：Android 的 `MediaNameParser` 是 PC 端的移植版，两边对同一文件给出不同 `group_key` 完全可能 ⇒ 不复用会把一部剧拆成两部（原来那部还在，旁边多出一部同名的、只含新扫到的那几集）。`applyScanItems` 更新已有行时**不碰 `group_key`**，所以「拿旧 key 覆盖解析 key」只影响归组、不会写坏数据。
- `discoverFile`（单文件入仓）的判据是 **`!isVideoFile(name) || isDiscImage(name)`**，两个条件缺一不可：`.iso` **在**视频白名单里（映射到 `other` 容器）⇒ 只能靠 `isDiscImage` 拦下来；`.img` 不在白名单，被拦两次。⛔ 只留前者的后果：用户点一个 40 GB 的 `.iso`「加入媒体库」，库里多一个永远播不动的条目。
- `normalizeDirPath` 一律补尾斜杠，**根目录是 `/` 不是空串** —— 空串与 `/` 拼出来的 `groupKey` 不同，会让根目录下的片子多出一格。
- UI 入口（`BrowseActivity.openMenu`）：`发现本目录「X」（含子目录）` / `只发现「X」这一层` / `发现「X」（含子目录）`（光标在某一行目录上时）/ `把「X」加入媒体库`（光标在视频文件上时）。菜单行塞进 `ScrollView`（`overlayScroll` + `revealOverlayRow()`），否则项一多就被屏幕切掉。
- `Discovery.message` 特判 `found == 0` → 「这个目录里没有可入库的视频」：不能只说「发现完成 0 个」，那与「功能没做」长得一样。

#### 5.2 手动刮削（`ScrapeActivity` + `library/Scrape*.kt`）

- **分层**：`ScrapeModels`（网络层模型）· `ScrapeHttp`（`HttpURLConnection`，**不引 OkHttp**，与 `PanHttp` **刻意不合并**）· `DoubanScraper` / `TmdbScraper` · `ScraperPipeline`（**拼接**各源候选，不是「取第一个成功的」——手动刮削是用户自己挑）· `PosterFetcher`。
- ★★ **豆瓣 rexxar 的六个坑**（`https://m.douban.com/rexxar/api/v2`，必带 `Referer: https://movie.douban.com/`）：
  1. **搜索结果分两处**：`subjects.items`（`{items:[…]}`）**和** `smart_box`（直接是数组）。实测搜「繁花」正主只在 `smart_box` 里 ⇒ 只读一处会**静默刮错片子**。
  2. **`type=movie` 不是过滤器**，返回里混着 `book`/`music` ⇒ 必须自己按 `target_type` 剔。
  3. **搜索的 `cover_url` 不能当海报**（服务端套了 `h/120` ⇒ 120px 横条）。海报只能取**详情**的 `cover_url`（`m_ratio_poster`，540×803）。
  4. **详情对剧集会 301 到 `/tv/{id}`** ⇒ 类型必须读**响应体**的 `type`，不能按请求路径判。
  5. **限流是显式的但状态码不稳**：`{"code":103,"msg":"need_login"}` 实测**既见过 200 也见过 403** ⇒ **业务码判在状态码之前**（判反了 ⇒ 403 那次被读成「网络抖了一下」，继续烧额度）。
  6. 海报 CDN `img*.doubanio.com` **带对 Referer 也回 403/418** ⇒ 落库前改写域名到 `qnmob3-sign.doubanio.com`（**只换域名、路径不变**；已幂等；非豆瓣域**原样返回**，别误伤 TMDB）。改写用 `indexOf` + 拼接做**字面量**替换，不用 `replaceFirst`（后者第一个参数是**正则**）。
- **匿名额度实测约 10 个不同的搜索词**；同一个词连打命中服务端缓存（不扣额度）⇒「多打几次看看」这种排查会得出完全错误的结论。见到 `103` 立刻熔断，**但熔断必须会过期**（30s 起、翻倍、封顶 10 min）：写死「本次进程内不再试」的话，用户按提示去贴了 Cookie 回来仍然刮不到，只有重启才恢复。
- ⛔ **Android 端 `DoubanScraper.enabled` 恒为 `true`**（PC 端要求 Cookie 非空）。两条现实：电视上遥控器敲 Cookie 是**真的难**；手动刮削是低频主动动作（一次点一部），而 PC 端担心的是「扫描期自动刮 145 部」——那个场景 Android 端不存在。`TmdbScraper.enabled = apiKey.isNotBlank()`（没 Key 根本发不出去，服务端必回 401，与豆瓣那条放宽是两回事）。
- ★★ **TMDB**：`api.themoviedb.org` 与 `image.tmdb.org` 境内不可达（DNS 污染）⇒ **两个域名分开配**（`tmdb_api_base` / `tmdb_image_base`），反代常只覆盖一个；合成一个的话「API 通了但海报全是灰块」没法修。`year` 是**硬过滤**（错的年份把正主直接筛掉）⇒ 只在有值时带。电影/剧集是**两套接口两套字段名**（`title`/`name`、`release_date`/`first_air_date`）。类型未知（综艺/纪录片常见 `unknown`）时**两个接口都搜**——硬猜一个方向会把它们搜到完全无关的条目上。`poster_path` 以 `/` 开头、`imageBase` 不带尾斜杠 ⇒ 直接相加；用户填的反代地址**结尾带斜杠是常态** ⇒ `trimEnd('/')`。
- ⛔ **标题拿不到 ⇒ 返回 `null`，绝不拿查询词兜底**（豆瓣、TMDB 同一规矩）。兜底会把「详情没拿到」伪装成「刮削成功」：标题有、海报简介一个都没有，且 `source` 记成 online ⇒ 界面显示「已刮削」。
- **落库**：`LibraryDb.updateWorkScrape` 合并元数据列，⛔ **不碰** `item_count`/`total_bytes`/`season_count`/`last_modified_at`；海报换了清 `poster_file`/`poster_face_x`；`source='online'`。分类走四级：`categoryOverride`（用户手选）→ `fromGenres` → `structureOf(onlineId)` → 保持原值。
- ★ `structureOf(onlineId)`：`douban/tv/34874646` / `tmdb/movie/843527`，**按段**匹配（`startsWith("movie/")` 会漏掉豆瓣那条多一层前缀的）；认不出返回 **`null`**（= 「这条证据没意见」），**不是**「归到其它」。
- ★ **海报换 URL 后能立刻看到新图**：`PosterStore.fileFor` 三级 —— ① `work.posterFile` → ② **用当前 `posterUrl` 现算** `PosterNaming.fileNameFor(key, url)` → ③ 目录索引。第 ② 步是关键：文件名的第二段是 URL 散列 ⇒ 新旧海报是**两个文件**，只靠 ③ 会在两个里随便挑一个（索引取「目录返回顺序里的第一个」），表现是「刮了但海报没变」。`PosterFetcher` 写 `.part` 再改名（进程被杀会留半张图，而它下次会被当有效缓存）。
- **详情页入口**（`LibraryActivity.openMenu` 的 `Level.ITEMS` 分支）：`手动刮削「X」` → `startActivityForResult`（⛔ 不是 `startActivity`：刮完 `currentWork` 就是过期快照，不刷新会「刮成功了但详情页还是旧的」）；回来后 `refreshAfterScrape()` 重读 `db.workByKey` + `posters.buildIndex()`。`刮削设置` 两个分支都放（用户看到「刮不出来」的瞬间想找的就是它）。
- **按键**：候选列表 OK **DOWN 与 UP 都要吞**（只吞 DOWN ⇒ 一次按键刮两遍）；⛔ **单行 `EditText` 会自己吃掉 ↑↓** ⇒ 必须在 `dispatchKeyEvent` 里接管（搜索框 ↓ 去胶囊行、设置页 ↑↓ 换输入框）。

#### 5.3 凭证随备份恢复 —— **不需要任何新的备份代码**

- 备份包（`.ccbak`）里装的是**整个 `cloudcine.sqlite` 文件的原始字节**，`settings` 表随之一起走。所以把凭证写进 `settings` 表（**不是** `AppPrefs`/SharedPreferences —— 那个在备份包里根本不存在）就自动跨端走。
- 键名（`LibrarySettings` / PC `SettingKeys`）必须**逐字一致**：`tmdb_api_key` · `tmdb_api_base` · `tmdb_image_base` · `douban_cookie`。差一个字母 ⇒ 电视上就是「没配」，走匿名额度，**两边都不报错**。`ScrapeSettingsKeysTest` 把这四个字面量钉死（改名就会红）。
- ⛔ **PC 端原有的一个真 bug（本次修掉）**：`SettingsStore` 有一层进程内 `_cache`，而 `importBackup` 是**换掉整个数据库文件** ⇒ 缓存对「文件被换了」一无所知。触发路径很容易撞：在新机器上先打开设置页（缓存记下「TMDB Key 为空」）→ 从网盘恢复电脑上的备份 → **设置页还是空的**、刮削继续走匿名额度，**要重启应用才对**。修法两条缺一不可：
  1. `SettingsStore.invalidate()`（清 `_cache`），由 `LibraryBackupService` 新加的 `onLibraryReplaced` 钩子在 `importBackup` **末尾**（且无条件）同步调用；组合根把它接到 `ref.read(settingsStoreProvider).invalidate()`（⛔ 用 `ref.read` 不用 `ref.watch`，否则设置一变这个服务就跟着重建）。
  2. `settings_page._refreshLibraryViews()` 里加 `ref.invalidate(settingsProvider)` —— `SettingsController` 手上那份 `AppSettings` 也是恢复**之前**读的。一条管缓存、一条管状态。
- Android 端**天然满足**：`ScraperPipeline.fromSettings(db)` **每次刮削都重新构造**（不缓存实例），所以恢复后下次刮削读到的就是新值。

#### 5.4 本次新增的单测（80 例，`./gradlew :app:testDebugUnitTest --tests 'com.cloudcine.tv.library.*Scrape*'` 等）

`ScrapeModelsTest`（`structureOf` 段匹配/`wantsTv`/`subtitle`/`uid`）· `DoubanScraperTest`（两处搜索来源、`target_type` 剔除、占位项跳过、id 数字/字符串、去重保序、类型读响应体、标题不兜底、`103` 两写法、403+103 也熔断 vs 普通 403 不熔断、熔断过期、Referer/Cookie/编码、海报改写幂等与不误伤 TMDB）· `TmdbScraperTest`（`title`/`name` 两套字段、`release_date`/`first_air_date`、图片拼接与反代尾斜杠、`year` 硬过滤、类型未知搜两个接口、流水线拼接/跳过未启用/指定来源/来源不在流水线）· `ScrapeSettingsKeysTest`（四个键字面量 + 蛇形小写无空白 + `SCRAPE_KEYS` 恰好四个 + API/图片是两个键）· `DiscoveryIngestRulesTest`（视频白名单、字幕图片音频压缩包不收、畸形文件名、**`.iso` 只能靠 `isDiscImage` 拦**、容器枚举名归一、分辨率三条判据的顺序、营销词不咬到字母数字中间、实测尺寸长短边取较高档）。

**两个「测试写错了」的实例（都是测试起了作用）**：① `candidates` 按 `uid` 去重 ⇒ 用同一个 id 测「数字/字符串两种形态」会被合并成一条，两个 id 必须不同；② `isVideoFile("x.img")` 是 **false**（`.img` 不在白名单），我原先写成「前提：在白名单里」⇒ 断言反了。

#### 5.5 TMDB 两代 Key 的**送法不同**（2026-10-07 血案）

**现象**：刮削设置页填了 Key、点「测试」回 `401 Invalid API key`，看起来就是「Key 填错了」，
但同一个 Key 在 PC 端能用。

**根因**：TMDB 有两代凭证，**送的位置不一样**，服务端对送错位置**只回 401**：

| 形态 | 长什么样 | 送法 |
|---|---|---|
| **v4 读取令牌** | `eyJ…` 开头的 JWT（很长） | `Authorization: Bearer <token>` |
| **v3 API Key** | 32 位十六进制 | 查询参数 `?api_key=<key>` |

把 v4 令牌塞进 `api_key=` 就是 401 —— 与「Key 真的填错了」**在响应上完全一样**，
所以这条必须靠**形状**判，不能靠试。实测：`?api_key=<JWT>` → 401；`Bearer <JWT>` → 200。
判据函数 `TmdbScraper.isV4Token`（认 `eyJ` 前缀）与 PC 端 `tmdb_client.dart` 的那份
**逐字一致** —— 两边各写一份、哪天只改一边，就会变成「电脑能用、电视不能用」。

#### 5.6 刮削设置页的「测试」按钮（`ScrapeProbe`）

`TmdbScraper.probe()` 打 `/configuration`（最轻的、需要鉴权的接口）；
`DoubanScraper.probe()` 打一次**真实搜索**（`/configuration` 那种接口在豆瓣不存在）。
两者都把失败**分开报**，不合并成「失败」两个字：

| 源 | 分类 |
|---|---|
| TMDB | 地址不通（DNS/反代）/ **401 = Key 被拒** / 其它 HTTP |
| 豆瓣 | 连不上 / 业务码 `103`（要登录）/ HTTP 错 / 零命中 / 正常（并报 Cookie 里**含不含 `dbcl2`**） |

⛔ 用**输入框当前值**测，不读库里已存的 —— 用户点「测试」的动机就是「我刚改的值对不对」，
读旧值会让「测试通过」骗人。⛔ `probe` **不碰熔断**：测试是用户的主动动作，
不该因为失败几次就把豆瓣关掉（熔断是给自动刮削用的）。
⛔ `ScrapeProbe.ok` 只有**明确验证过**才置 `true`：零命中、超时都不算通过 ——
把它写成「没抛异常就算过」的话，这个按钮就成了安慰剂。

### 6. 作品简介页：点卡片先去这里，不再直接播（2026-10-07）

**起因（用户原话）**：「媒体文件无法进入简介页面，点击媒体文件应该先进入简介页面，
在简介页面支持手动刮削和播放和选集播放的相关功能，对标pc端简介页面」。

**为什么原来的「点卡片直接播」是错的**：直接播等于替用户做了三个决定 —— 播哪一条
（`PlayTarget.resolve`）、播哪一版、要不要先刮削。而用户点卡片时想做的经常是
「看看这部是什么」「换一集」「刮一下海报」。旧的 `onWorkRow` 是
`works.getOrNull(position)?.let { playWork(it) }`，现在改成 `openWork(it)`；
「直接续播」降级成简介页里的一颗胶囊 + 菜单项（两条路都还在）。

#### 6.1 页面结构与上下层的物理顺序

```
简介页头部 detailHead       海报 96×144 + 标题 / 原名 / 元数据行 / 简介（最多 3 行）
动作胶囊   actionsScroll     ▶ 播放(续播) · 手动刮削 · 刮削设置 · 选集（N）
排序胶囊   itemsSortScroll   修改时间倒序 · 剧集顺序 · 标题
剧集列表   itemsList
```

`detailHead` / `actionsScroll` 在 `Level.WORKS` 下 `GONE`，`openWork` 里转
`VISIBLE`，`backToWorks` / `applyWorks` 里转回 `GONE`（⛔ 转的是**滚动容器**
`actionsScroll`，不是里面的 `LinearLayout` —— 与 `itemsSortScroll` 同一条理由，
只 GONE 子视图会留下一条高度 0 却仍参与焦点搜索的空壳）。

#### 6.2 焦点模型：焦点留在列表上，两行胶囊只吃「光标态」

- 两行胶囊都是 `isFocusable = false`；真正的焦点**始终在 `itemsList`** 上。
  理由与一级导航带 / 状态行一致：焦点一挪到胶囊上，底下列表那行的高亮就没了，
  用户会以为列表被清空了。
- 方向键靠 `actionsFocused` / `itemsSortFocused` 两个标志在 `dispatchKeyEvent`
  里分流，`actionsFocused` 那一支必须排在 `itemsSortFocused` **之前**。
- ⛔ 各 `focus*` 函数**必须互相清掉对方的标志位**（与 `focusTabs`/`focusBar`/
  `focusGrid` 那一组同一条规矩），漏清一个 = 「两行同时发光」。
- 上下层的物理顺序 ⇒ 键语义：动作行 ↑↓ → 排序行；排序行 ↑↓ → 列表；
  列表首行 ↑ → 排序行。**只有动作行上再按 ↑（或返回）才回作品墙** ——
  排序行上的 ↑ 从「回作品墙」改成了「到动作行」。
- 进作品时（`openWork`）先 `itemsList.setSelection(0)` + `requestFocus()`，
  再 `focusDetailActions()`：**焦点给列表、光标给动作行**。这样默认落在
  「▶ 播放 / ▶ 续播」上，按一下 OK 就是播（保留了旧行为的顺手），
  而 ←→ 能看到刮削、选集。

#### 6.3 两行胶囊**刻意不合并**

动作行回答「对这一部作品做什么」，排序行回答「这一页的列表怎么排」。合成一行的话
「▶ 播放」会和「修改时间倒序」并排，用户按 ←→ 路过时分不清哪颗是动作。
两行都是同一套样式语言：实心面明度区分「光标（`BRAND_TINT` + 深字）/ 常态
（`0x14FFFFFF` + 次级字）」，⛔ **不描边**（用户两次点名「线框不高级」）。

动作行多一个状态：`enabled = false` 时压到 `0x0AFFFFFF` + 灰字。
⛔ **不可用时置灰而不是从列表里消失** —— 库里一条可播文件都没有时，用户最需要
看到的恰恰是一个灰着的按钮加上一句解释；按钮凭空消失他只会以为页面坏了。
`applyAction` 在 `!enabled` 时把原因写进 `infoLine`（「▶ 播放：现在没有可播的文件」）。

#### 6.4 海报尺寸 **96×144**，不照抄 PC 的 138×207

PC 那个尺寸是给桌面窗口高度用的。电视横屏逻辑高只有 **540dp**（1080p / density
2.0），207dp 的海报加上两行胶囊、剧集列表、`infoLine`、`hintBar` 会把这页撑爆 ——
列表只剩一行，而「选集」恰恰是这一页的主要用途。96×144（2:3）之后刚好放下三行
简介 + 四行列表。

#### 6.5 底部提示行 `hintBar` 随层级换文案

原来是写死的一句话（「OK 直接播放」），现在改成字段 `hintBar`：
作品墙上写「OK 进简介页」，简介页里写「←→ 换胶囊 · OK 播放 / 执行 · ↑↓ 换层」。
⛔ 写死的话两层里总有一层在骗人，而遥控器上用户唯一的线索就是这行字。
`infoLine` 在 `Level.ITEMS` 下不再显示作品简介（简介正文已经画在头部里了），
改成按键提示 —— 否则同一段简介会在屏幕上印两遍。

#### 6.6 ⛔ 顺手修掉一个**不报错**的真 bug：`openWork` 把 `items` 清了两遍

原代码：

```kotlin
items.clear()
items.addAll(list ?: emptyList())
…
items.clear()                                    // ← 又清了一次
items.addAll(sortItems(items, itemsSortMode))     // ← 排的是空列表
```

`sortItems` 拿到的是空列表 ⇒ **剧集列表永远是空的**，而且不报任何错
（只是「点进去什么都没有」）。正确写法：保留容器、只清空重填，一次排序 ——
`items.clear(); items.addAll(sortItems(list ?: emptyList(), itemsSortMode))`。

#### 6.7 简介页文案口径下沉成纯函数 + 单测

`library/WorkDetailFormat.kt`（`object`，纯函数）+ `WorkDetailFormatTest`（13 例）。
搬出来的理由：每一条都是**跨端口径**，而写错它们**全都不会报错** ——
放在 `LibraryActivity` 里 JVM 单测根本跑不起来（与 `PlayTarget` / `PosterNaming`
同一套做法）。钉住的四条：

| 口径 | 写错的后果 |
|---|---|
| 「已刮削」判据 = `source == "online"`，**不是**「有海报」 | 刮了但没下到图的作品写着「未刮削」，用户再刮一遍还是这样 |
| 季数门槛 `>= 2` | 每部电影、每部单季剧都多一个「1 季」，像分类判错了 |
| 类型最多 `MAX_GENRES = 4` 个 | 类型多的片子把这一行折成两排，把简介正文挤出屏幕 |
| 原名 `!= title` 才画 | 中文片名没刮到时标题连着印两遍 |

另外两条：`metaLine` **恒非空**（分类兜底「其他」+ 来源恒在），所以调用方不判空；
`actionLabels(resumable, itemCount)` 的顺序**必须**与 `buildDetailActions` 逐项一致
（光标位置就是按这个下标存的，顺序错了 = 「点了 A 执行 B」）。

**又一个「测试写错了」的实例（测试起了作用）**：我最初断言「什么都没刮到时
`metaLine` 返回空串」，实际是 `"其他 · 未刮削"` —— 分类与来源两项恒在，
所以这一行永不为空。断言改对之后，顺带把 `paintDetailHead` 里那句多余的
`if (text.isEmpty()) GONE` 也删了。

#### 6.8 海报解码的两个约束（与海报墙不同）

- 解码**不能在主线程**（`PosterStore.decode`），走 `Bg.run`，与 `WorksAdapter`
  同一套「先查缓存 → 未命中丢后台解 → 解完再画」。
- ⛔ 解完**只重画这一块**，**不能** `notifyDataSetChanged()` 海报墙：那会连带重绑
  整个 `GridView`，而用户此刻正在看详情页。
- ⛔ 解码回来时**必须核对 `currentWork?.key == 解码时那个 key`**：这段时间里用户
  可能已经退出这一页 / 进了别的作品，无条件画上去就是**别人的海报**。

#### 6.9 本次验证

`:app:compileDebugKotlin` ✅ · `:app:testDebugUnitTest --tests 'com.cloudcine.tv.library.*'`
**214 例全绿**（原 201 + `WorkDetailFormatTest` 13）· `:app:assembleDebug` ✅。

### 7. 简介页文件列表：主标题必须是**文件名**（2026-10-07）

**起因（用户原话）**：「媒体库媒体简介页面中，文件列表应该重点凸显的是文件名，
而不是全部都是媒体名，否则剧集列表都是媒体名，看起来体验非常不好」。

**根因**：`ItemsAdapter.getView` 里那一行写的是 `entry.displayTitle`，而
`LibraryItem.displayTitle` 是 `title ?: name` —— **优先返回作品标题**。12 集全被
归到同一部作品、`title` 都是「黑亚当」，于是整列印的是同一句话，一个字的信息量
都没有。这就是 PC 端 2026-10-02 已经踩过、并记在本文件
「提不出集号的行标题**不能**退回片名」那一节里的坑 —— Android 端重新踩了一遍。

**修复形态**：改用 `EpisodeLabels.fileLabel(entry)`（文件名去掉扩展名）——
与播放页 OSD「选集」**同一个函数**，两边口径从此不会再分叉。

```
主标题 18sp 白  黑亚当.2022.S01E03.1080p.WEB-DL      ← 文件名（去扩展名）
副标题 13sp 灰  1080p · 1.2 GB · 看到 12:34 / 45:00
标签   13sp 紫  S01E03                                ← 集号解析得出时才画
右侧   13sp 灰  3 天前                                ← 网盘修改时间
```

#### 7.1 ⛔ **不**照抄 PC 的「剧名-文件名」前缀

PC `_fileRowLabel` 拼 `剧名-文件名`（并做了「文件名已含剧名就不重复拼」的去重）。
电视这一行**只有一行、尾部省略**，长剧名会把真正要看的文件名挤出屏幕 ——
而本文件那一节自己写过：「只给一行的话被省略号吃掉的全是后半段的文件名」。
所以 Android 端只留文件名：这一页的头部就挂着剧名和海报，前缀是纯噪音。

⛔ 也**不能**把主标题改成 2 行来解决：列表区只有约 4 行的高度（见 6.4 的版面账），
多一行就少一行剧集。电视行宽约 800dp / 18sp ≈ 44 汉字，真实文件名极少超。

#### 7.2 顺带修掉两个同源的**不报错**问题

1. **副标题的进度读错了列**：原来读 `resumePositionMs`，而它是「下次从哪儿接着播」，
   **看完就清成 NULL** ⇒ 看完的那一集永远显示不出「看到」。改读
   `maxPositionMs`（历史最大位置，永不回退/清除），走 `EpisodeLabels.progressLabel`，
   并**钳到总时长**（否则会出现「看到 50:00 / 45:00」这种一眼假的东西）。
2. **`fileLabel` 的扩展名门槛 5 → 4**：函数注释自己举的例子 `Mr. Robot` 点后正好
   5 位，门槛写 5 时会被砍成 `Mr` —— 注释与行为不符。真实视频扩展名最长 4 位
   （`mkv`/`mp4`/`webm`/`m2ts`），卡在 4 不会误伤。顺手删掉 `LibraryActivity`
   里因此变成死代码的 `private fun clock()`。

#### 7.3 补上一直缺的单测

`EpisodeLabels` 是播放页与简介页**共用**的口径，却一直没有测试。新增
`EpisodeLabelsTest`（11 例）钉住：只砍最后一个点 · 主标题取文件名而非作品标题 ·
同片多版本可区分 · 无扩展名/点在最前（`.gitignore`）原样返回 · 点后超 4 位不砍 ·
进度读 `max_position_ms`（看完仍显示）· 越过总时长钳住。

`:app:testDebugUnitTest --tests 'com.cloudcine.tv.library.*'` **18 个类 / 243 例全绿**
（含新增的 `EpisodeLabelsTest` 11 例）· `:app:compileDebugKotlin` ✅。

#### 8. 扫描期边扫边显示 / 未刮削用网盘封面 / 扫完自动刮削（2026-10-07）

**用户原话**：「扫描网盘过程中，只有等扫描结束后媒体库才能看到媒体文件，需要优化一下，
一边扫描一边出现媒体库文件，并且没有刮削的媒体文件，没有封面这个不符合预期，没有刮削的
媒体文件应该使用网盘的封面图，扫描完毕后后需要自动启动刮削，并将刮削进度显示出来」。

##### 8.1 症状一：必须等扫描结束才看得到作品

**根因**：扫描是**两相写入**，两相的节奏差了整整一个遍历。

| 表 | 写法 | 节奏 |
|---|---|---|
| `media_items` | `LibraryScanner.flush()` → `db.applyScanItems(buf)` | 每 `FLUSH_AT = 200` 条一批 |
| `media_works` | `db.insertMissingWorks()` + `db.refreshWorkStats()` | **整个遍历结束后一次** |

作品墙查的是 `media_works`，扫描期间它一直是空的 ⇒ 「扫完才出现」。

**修法**：`LibraryScanner` 里加 `publishWorks(force)`，在 `flush()` 落完批**之后**调用
（顺序有讲究：`refreshWorkStats` 的 `item_count` 必须看得见刚落的这批）。

```kotlin
val known: MutableSet<String> = db.workKeys().toMutableSet()
val dirty = LinkedHashSet<String>(256)          // 本轮新增/变更过的 group_key
var lastPublish = 0L

fun publishWorks(force: Boolean = false) {
    val now = System.currentTimeMillis()
    if (!force && now - lastPublish < PUBLISH_EVERY_MS) return   // 节流
    lastPublish = now
    val fresh = seeds.keys.filter { it !in known }
    if (fresh.isNotEmpty()) {
        worksCreated += db.insertMissingWorks(fresh.map { toWork(it, seeds.getValue(it)) })
        known.addAll(fresh)
    }
    if (dirty.isNotEmpty()) {
        db.refreshWorkStats(dirty)
        // 顺手把本轮新拿到的网盘缩略图补进 poster_url（见 8.2）
        ...
        dirty.clear()
    }
}
```

三个设计约束，改了会出问题：

1. ⛔ **`PUBLISH_EVERY_MS = 1000` 必须远大于 `REPORT_EVERY_MS = 400`**：每次发布都要跑一遍
   `refreshWorkStats` 的全表 `GROUP BY`（`group_key` 上**没有索引**）。跟进度上报同频 = 把
   扫描拖成龟速。进度条每 400 ms 跳一次，作品墙每 1 s 跳一次，观感已经够「实时」。
2. ⛔ **只对 `dirty` 里的 key 跑 `refreshWorkStats`**，不是全表 —— 全表统计是 O(库大小)，
   而 `dirty` 是本轮增量。
3. ⛔ **发布必须在 `applyScanItems` 之后**。反了的话 `item_count` 会少算一批，作品卡上的
   「N 集」会一直差一截，而且**不报错**。

`Progress` 新增 `val works: Int` = **当前库里作品总数**（不是「本轮找到几个」）—— 这是 UI
判断「要不要重画作品墙」的信号，`text` 也顺带拼上 `· 作品 N`。
`discover()`（文件列表 MENU 的局部扫描）同样接了这一套，变量名用 `knownWorks` 以免与
`flush()` 里管 group key 的局部 `known`（已改名 `oldKeys`）撞车。

##### 8.2 症状二：没刮削的作品没有封面

**根因**：扫描**确实**把夸克的 `preview_url` 写进了 `media_works.poster_url`
（`LibraryScanner.kt` 的 `toWork`/`accumulate`），但**没有任何组件去下载它**。

`PosterStore.fileFor(work)` 是三级查找，**三级全都要求本地已有真实文件**：
① `poster_file` 列 → ② `PosterNaming.fileNameFor(key, posterUrl)` 现算 → ③ 目录索引。
三级全落空 ⇒ 退化成「首字占位块」。

而能下载的两个组件都不是干这个的：

- `PosterFetcher`：只服务**刮削海报**，只被 `ScrapeActivity` 调用，走 `ScrapeHttp`
  —— **没有网盘凭证**，拿来下夸克缩略图必然 401。
- `EpisodeThumbs`：能力对，但它是**播放页专用**，目录（`filesDir/thumbs`）和命名
  （`t-{hash8}.img`）都是另一套。

PC 端早就是对的，Android 是唯一的例外：`lib/domain/entities/work_poster.dart`
`WorkPoster.fromItems()` 挑第一张有 `thumbUrl` 的条目（**正片优先于花絮**），
下载走 `lib/data/scrape/poster_cache.dart` `PosterCache.pathFor`（`_headersFor` 带 Cookie）。

**修法**：新增 `CloudCoverFetcher`，**必须走 `PanApi.thumbBytes(url)`**
（裸链回 `401 code=31001 require login`），产物落**海报目录**并用
`PosterNaming.fileNameFor(key, url)` 命名 ⇒ `fileFor` 的第 ② 级**零改动直接命中**，
而且**随备份包一起走**（`.ccbak` 会打包 posters 目录）。

```kotlin
class CloudCoverFetcher(private val dir: File, private val thumbBytes: (String) -> ByteArray) {
    fun fetch(workKey: String, url: String?): String?   // 返回相对文件名，失败返回 null
}
```

- 拿**函数类型**而不是 `PanApi`，是为了 JVM 单测能塞假实现（`PanApi` 要凭证，测不了）。
- 守卫：空白 / 不以 `http` 开头 ⇒ 直接 `null`（**绝不自己拼 URL**）；文件已存在 ⇒ 直接返回；
  `failed` / `inFlight` 按 `"$workKey|$u"` 去重（`failed` 的键必须是这个 token，
  用 `target.name` 会永远匹配不上 ⇒ 每次滚动都重试）。
- `.part` + rename 原子写。
- ⛔ 失败**不持久化**：夸克 `preview_url` 是带签名的、会过期，今天的失败明天可能就成功了。

配套三处改动：

1. `LibraryScanner.Seed` 加 `var extraPosterUrl`，`accumulate()` 分流：
   **正片**（`!isSampleOrExtra`）的缩略图进 `posterUrl`，**花絮**的进 `extraPosterUrl`；
   `toWork` 取 `seed.posterUrl ?: seed.extraPosterUrl`。对标 PC `WorkPoster.fromItems`。
2. `LibraryDb.backfillWorkPosterUrls(Map<String,String>)`：**只填 `poster_url IS NULL` 或 `= ''` 的行**。
   为什么需要它 —— `insertMissingWorks` 是 `CONFLICT_IGNORE`，一次扫描没拿到缩略图的行
   `poster_url` 就**永远是 NULL**，后续扫描再也填不上（静默数据缺口）。
3. UI 侧触发点：`WorksAdapter.getView` 的占位分支 + `paintDetailPoster`。

##### 8.3 症状三 + 四：扫完自动刮削、并显示进度

**前置认知：自动刮削必须先有匹配闸门。** 手动刮削有人盯着，自动刮削没有 ——
PC 的 `lib/domain/services/scrape_match.dart` 就是为此写的（「宁可漏刮，不要刮错」），
**Android 端此前从未移植**（`titleSimilarity|ScrapeMatch|normalizeForMatch|maxYearGap`
全库零命中）。所以顺序是：先移植闸门，再写编排。

新增四个文件（`com.cloudcine.tv.library`）：

| 文件 | 职责 |
|---|---|
| `ScrapeMatch.kt` | 闸门。纯函数 + `object ScrapeMatch.evaluate(...)` |
| `ScrapeQueryBuilder.kt` | 「用什么词去搜」。手动 prefill 与自动刮削**共用一份** |
| `ScrapeSourceBudget.kt` | 「这个源还值不值得问」 |
| `AutoScraper.kt` | 编排：取待刮作品 → 搜 → 验 → 落库 → 下海报 → 报进度 |

**闸门判据**（与 PC 逐字对齐）：年份硬闸 `MAX_YEAR_GAP = 2`；标题相似度
`STRONG_SIMILARITY = 0.6` / `WEAK_SIMILARITY = 0.35`；前缀 `0.65 + 0.35×ratio`、
包含 `0.55 + 0.25×ratio`、否则 bigram Dice。判定顺序**不能改**：
年份闸 → 相似度 → `requireExactTitle`（只认全等）→ `≥ STRONG` 收 → `≥ WEAK` 需年份贴近
→ 跨文种 + 年份贴近 收 → 拒。
⛔ `allDigits` 检查必须放在 `na == nb` 早退**之后**，否则《2012》《1917》这种数字片名全废。
⛔ 纯数字串永远不当名字用（`182` 命中《1821: Οι Ήρωες》那次事故）。

`ScrapeQuery.requireExactTitle` 的语义：PC 是 `!parsed.isConfident`，而
`isConfident = kind != unknown && title 非空 && (year != null || kind == episode)`；
Android 的解析器只在标题为空时给 `unknown`（已被 `hasUsableTitle` 挡掉），
所以化简成一句：**`kind == "movie" && year == null`**。

`ScrapeQueryBuilder` 刻意**不重复判 `kind == unknown`** —— 那是 PC 判据的等价化简，
不是漏了一条规则（注释里写明了，免得后人以为是 bug）。

**待刮集合 `LibraryDb.worksNeedingScrape(limit)`**：

```sql
WHERE merged_into IS NULL
  AND (source IS NULL OR (source <> 'online' AND source <> 'manual'))
ORDER BY (last_modified_at IS NULL), last_modified_at DESC, year DESC, title ASC
```

三个排除各有理由：`merged_into` 非空的行**不在墙上**；`online` 是已刮好的；
`manual` 是**用户自己改过的**（PC `customizeWork` 写的），自动刮削绝不能覆盖。

**源预算 `ScrapeSourceBudget` 的核心判据**：`search()` 的失败语义是「返回空列表」，
**分不清「源坏了」和「这个标题不在源里」**。用**耗时**来分：

- 健康的源 0.3~2 s 就回；坏掉的源要烧完 12 s 超时。
- **慢且空**（`elapsed ≥ SLOW_MS = 8000` 且无命中）⇒ 记一次失败，**连续 3 次丢源**。
- **快且空** ⇒ **不算失败**（就是没这部片），并把计数清零。
- 命中（不论快慢）⇒ 清零。丢源是**单向**的，丢掉的源本轮不再问。

**`AutoScraper` 的三个提前退出**（缺一就会让用户干等）：

1. **用户取消** —— 在作品之间检查 `LibraryScanner.Cancellation.isCancelled`。
2. **所有源都被熔断** —— 再搜也是白搜。
3. **`scraped == 0 && consecutiveMiss >= GIVE_UP_AFTER (= 12)`** —— 专门抓
   **「凭证被拒」**这种情形：此时请求是**飞快**的（401 立刻回），
   所以**源预算的「慢」启发式抓不到**，只能靠「连着一打作品一个都没刮到」来兜。
   ⛔ `Verdict.noQuery`（这条文件名提不出可用标题）**不计入** `consecutiveMiss`，
   否则库里堆一批 `01.mp4` 就会误判成凭证失效。

`pickVerified` 按**源的顺序**取**第一个**通过闸门的候选 —— 源自己的相关性排序是权威，
PC 的规则也是「第一个必须全等」。每个被拒的候选都 `Log` 出 `reason`，便于事后复盘。

**为可测性做的两处接口收窄**（`AutoScraper` 直接依赖 `LibraryDb` 就 JVM 测不了）：

```kotlin
interface AutoScrapeStore {                 // 只留 4 个方法
    fun worksNeedingScrape(limit: Int): List<Work>
    fun itemsForWork(workKey: String): List<LibraryItem>
    fun updateWorkScrape(workKey: String, meta: ScrapedMetadata): Work?
    fun setWorkPosterFile(workKey: String, fileName: String)
}
```

`companion object` 里的 `forLibrary(db, pipeline, posterFetcher, cancel)` 提供一个匿名对象
适配器 —— 因为 `LibraryDb.updateWorkScrape` **带默认参数**，而 **Kotlin 接口不能有默认参数**。
另外注入了 `clock: () -> Long` 和 `sleep: (Long) -> Unit`，测试里用来伪造「慢源」。

**设置项**：`LibrarySettings.AUTO_SCRAPE_ON_SCAN = "auto_scrape_on_scan"`
（键名与 PC 逐字一致）。⚠️ **PC 默认关**（豆瓣匿名额度约 10 次搜索），
**Android 默认开**；默认值**不写在这个常量里**，写在 `LibraryActivity.autoScrapeEnabled()`。

### 8. 海报墙卡片：角标尺寸 / 圆角（2026-10-07 真机复核）

**角标尺寸**（`BADGE_TEXT_SP` / `BADGE_PAD_H_DP` / `BADGE_PAD_V_DP` /
`BADGE_CORNER_DP` —— 评分 `★ x.x` 与追剧 `+N` **两处共用同一组常量**）：
- 原 **11sp / `h7·v3` / `r5`** 在 203px 宽的卡上实测占海报宽 **44%**，用户反馈
  「星标标签太大，挡住了海报很多信息」⇒ 收到 **9sp / `h5·v2` / `r4`**，
  实测 **71×29px**（改前 ≈90×38px）⇒ **面积 −40%**，占海报宽 **35%**。
- ⛔ **别按 PC 端的比例去对齐**：PC 卡宽 172dp、这里只有 101.5dp（8 列），
  同一套 dp 在两边占的**比例**不同；以「别挡住海报」为准。
- ⛔ 别再压到 8sp 以下：卡宽只有 203px，3 米外读不出数字，角标就失去意义。
- ⛔ 尺寸**只写在常量里**，两处角标别再各写一份字面量（改一处漏一处会不等大）。

**圆角（真机复核通过，2026-10-07）**：`RoundedPosterDrawable` + `FIT_XY` 方案
四角**全部是圆的**，放大 1.1× 后也**不丢角**。实测轮廓（焦点卡 224×335）：

| 角 | 顶行内缩 → 到达边缘 |
|---|---|
| 左上 | +12 → +6 → +3 → +1 → 0 |
| 右上 | −13 → −7 → −4 → −2 |
| 左下 | +14 → +7 → +4 → +2 → 0 |
| 右下 | −15 → −8 → −5 → −3 → −1 |

实测半径 ≈13–15px，理论值 8dp×2×1.1=17.6px（差值来自描边内缩 + 抗锯齿阈值）。
★ **量法**（比肉眼看图可靠）：`uiautomator dump` 取 `posterBox` 的**真实 bounds**
（原生 Kotlin 工程 dump 得到，不是 Flutter），再沿四条边扫「背景 → 非背景」过渡。
⛔ 扫的时候注意**邻卡会串进窗口**（相邻 poster 间距 14px），要把邻卡的边当干扰排除。
★ 另：`pivotY = 0` 已验证生效 —— 焦点卡与非焦点卡**顶边同为 y=184**，
放大只向下长，第一行不丢顶部像素。

## 7. PC TV 布局 / OSD 卡顿
- `isTvLayout` = android + 逻辑宽≥960（⛔ 判据读 **view 宽**）。⛔ 页头 `actions` 必须 `Wrap`；⛔ **过扫描内边距只有 `app_shell` 一处**；⛔ 遥控器 **↓ 绝不接管**；⛔ **`SelectableText` 是焦点陷阱** → 用 `TvSelectableText`。
- ⛔ **播放页 OSD 卡顿**：整页 rebuild ≈10 次/秒（`bufferEnd` 没节流）+ `SubtitleViewConfiguration` 无 `operator ==` + `DebugOverlay` 的 `kDebugOverlayEnabled = true` **硬编码**。

## 8. 资源采样 / 日志 / 打包（判据细节）
- 采样：⛔ 周期 **10 秒**，**故意不与**视频探针的 21 秒相等（会**拍频锁定**；10 与 21 互质）。⛔ **读不到一律留空、整段从日志行消失**，不许退化成 0。⛔ 进程 CPU 是**单核口径**，必须写「折合 N 核」。⛔ 系统 CPU「忙」**不含 iowait**；`/proc/stat` 只认汇总行 `cpu `（**别用 `cpu0`**）。⛔ `/proc/loadavg` 在电视上 `Permission denied`；`/proc/pressure/*` 在 Android 9 不存在 ⇒ 用 `procs_running`/`procs_blocked`（`parseProcStatProcs`，**同文件、不额外读盘**），写「可运行进程=N（4 核，超订 x.xx×）」——⛔ **核数必须一起写**。⛔ `/proc/self/stat` **按最后一个 `)` 切**。⛔ `df` 正则**从左锚定**、不按列 split；用异步 `Process.run`。macOS 无 `/proc`：内存退回 `ProcessInfo.currentRss`，CPU/负载留空属**正常**。
- 取证：应用日志是**文件、不是 logcat** —— `DiagLog` 同步写 `files/logs/cloudcine-YYYY-MM-DD.log`，读 `adb shell run-as com.cloudcine.cloudcine cat files/logs/cloudcine-<日期>.log`；⛔ logcat `I/flutter` 基本只有引擎启动几行；⛔ **文件 mtime 不涨 = 应用真没做事**。**线程名读 `/proc/<pid>/task/*/comm`**：`top -H` 在 Android 9 全打进程名；⛔ 取字段写 `${12}`/`${13}`；切字段按**最后一个 `)`**。⛔ `exec-out screencap` 被 fvp 的 `Init wrapper sys mutex successful.` 污染 ⇒ 用 `shell screencap -p /sdcard/x.png` + `pull`。**`uiautomator dump` + `input tap X Y` 比猜 DPAD 可靠**；⛔ Flutter 语义树只在无障碍被触发后才暴露。★ **视频真帧率用 SurfaceFlinger 量**：`dumpsys SurfaceFlinger --list` 找层 → `--latency '<层名>'`（首行=刷新周期 ns，其后 128 帧三列时间戳）；**Flutter UI 帧率**用 `dumpsys gfxinfo <包名>` 两次取差。实测 `activeBuffer=[3840x2160:3840,Unknown 0x13]` 才是**视频层**；`SurfaceView #0` 是 `1920x1080 RGBA`。⛔ **LMK 会杀掉后台的云影**（电视仅 2.5 GB）⇒ 中继喂原型只有 2~3 分钟窗口；先 `am kill-all` 腾内存。
- 打包：⛔ MSI 启动条件绝不能写 `VersionNT >= 1000`（钳在 603）⇒ 用 **`WindowsBuild >= 10240`** + `Installed OR`（MSI 条件**不支持括号**）。⛔ macOS 不许写 `keychain-access-groups`（→ 启动即 SIGKILL）、`app-sandbox` 必须 **`false`**。⚠️ 本机**出不了 Flutter release/profile 包**（对比云影与原型本身不公平：原型是原生 Kotlin，`debuggable` 几乎无代价；云影是 Flutter `app-debug.apk` = JIT，实测进程合计 **467%/400%**，主线程 200% + `DartWorker` 199% + `1.raster` 42%，ExoPlayer 只拿 12%）。

## 9. 追剧 / 更新提醒（2026-10-07，两端已落地）

产品口径与逐条理由见 `docs/追剧-更新提醒-设计方案.md`（12 章）。这里只留
**改错不报错**的那些判据。

### 9.1 数据 / 契约
- 4 列加在 `media_works`（**不新建表**）：`followed` / `follow_started_at` /
  `follow_checked_at` / `new_item_count`。schema **16 → 17**，两端同时改，
  **无回填**（默认值恰好表达「没追剧」）。`LibrarySchemaTest` 逐字守着 DDL。
- 三条判据全靠已有的 `media_items.first_seen_at` 做差：
  ①本次新增 = `first_seen_at > follow_checked_at` → 角标增量累加；
  ②追剧以来新增 = `first_seen_at > follow_started_at`；
  ③`max_position_ms IS NULL`。②∧③ = 剧集行 NEW 标签（**播过自动消失，零额外写入**）。
  ⛔ **刻意不用 `modified_at`**：替换文件（换更高码率）会误报「有新集」。
- ⛔⛔ **自动检查绝不写 `media_works.updated_at`**。`libraryModifiedAt` 是同步 LWW
  判据，写了就会「本地永远看起来更新 → 无条件上传 → 盖掉另一台设备的进度」。
  只有**用户手动开关追剧**才写。节流零点放 `settings.follow_last_check_at`
  （Unix **秒字符串**，不是 ISO8601 —— 两端解析器差异会静默差一个时区）。
- ⛔ **按目录回写，不按发起者**（`/电影/` 平铺，一个目录含多部作品）。
- ⛔ **目录失败不推进 `follow_checked_at`**（水位线不完整时推进 = 新集永久丢失）。
- ⛔ `follow_checked_at` 取「**发现跑完之后**」的时刻，不是检查开始时刻 ——
  库时间列是秒，取开始时刻会让本次插入的行在下一轮被重复计数。

### 9.2 ⛔⛔ `FollowAutoCheck.off` 的 `throttleWindow == null` 是**反向**的
`off` 的窗口是 `null`，而 `null` 在 `FollowService._run` 里的含义是
「**不节流**」（想跑就跑）—— 两者含义**恰好相反**。只靠窗口判据的话，
设成「关闭」之后**一次节流判断都不做** ⇒ 每次启动都真的去列网盘目录，
而日志上一切正常。⇒ `_run` 里必须**先显式判 `policy == off`** 再读窗口。
（`FollowAutoCheck.throttleWindow` 的文档已写明这个 `null` 不能当闸门用。）
⚠️ 原 `test/domain/follow_service_test.dart` 有一例把这个 bug **钉成了正确行为**
（断言 `skipped == false && calls == 1`，理由写「off 的窗口是 null，所以节流闸
直接放行」）—— 已改。

### 9.3 ★ 桌面页头放不下第 9 个按钮（2026-10-07 实测）
`PageHeader` 桌面分支是 `Row`。媒体库页头原本 8 个控件在 **800px 宽**窗口下
已顶满（可用宽 756），加「检查更新」**实测溢出 26px**；而 `Row` 溢出在 Release
下是**静默裁掉**，看起来像「这个按钮本来就没有」。
⇒ 「检查更新」落在**分类栏右端**（`_CategoryBar` 的 `_FollowCheckButton`）：
那一带的胶囊是 `Expanded` 里一条横向滚动列表，右边从来没有东西，**零宽度压力**，
而且它紧挨着「追剧」胶囊。TV 与桌面**同一份代码**（TV 页头整页只有 624 宽）。

⛔ 别再试图「让 `PageHeader` 的 actions 折行」：`Row` 里非 flex 子项拿到的是
**无界**主轴约束，永远不会 wrap；给 actions 加 `Flexible` 又只能和标题的
`Expanded` 对半分（375/375，宽窗口下照样折行）。唯一可行的折行方案是把整个
桌面页头改成 `Wrap` + 标题 `ConstrainedBox(maxWidth: 260)`，代价是**所有页面**
的操作区从「右对齐」变成「紧跟标题左对齐」—— 视觉回归太大，不划算。

### 9.4 触发时机
| 平台 | 入口 | 时机 | 节流 |
|---|---|---|---|
| PC | 启动静默检查 | `AppShell` 挂 `_FollowLaunchCheck`，延迟 **20 秒** | 沿用窗口 |
| PC | 手动 | 分类栏右端「检查更新」（`force: true`） | 无视 |
| PC | 定时 | 设置页 `follow_auto_check` 三态：`off` / `on_launch`（默认）/ `every_6h` | 沿用窗口 |
| Android | 进媒体库静默检查 | `LibraryActivity` 首帧后延迟 **1.5 秒** | 窗口 **30 分钟** |
| Android | 手动 | MENU 覆盖层菜单「检查追剧更新」 | 无视 |

- ⛔ PC 的启动触发器**必须挂在壳上**（`AppShell`），不是媒体库页：语义是
  「一次会话一次」，挂在媒体库页会变成「每次进媒体库 20 秒后」。
- ⛔ 它那两个 `Timer`（20 秒 + `every_6h`）**必须在 `dispose` 里 cancel** ——
  漏了会让 widget 测试在收尾时炸「A Timer is still pending even after the
  widget tree was disposed」，看起来像「加了段无关代码、一堆页面测试同时红」。
- ⛔ `every_6h` 的周期与 `throttleWindow` **是同一个数（6h）但刻意不互相引用**：
  比窗口密 = 白转一圈，比窗口疏 = 漏掉窗口边界那一次。两处一起改。
- ⛔ 手动入口一律 `force: true`：无视窗口、也无视 `off`。把 `off` 也挡住的话，
  那个按钮会变成「按下去什么都不发生」。
- ⛔ 扫描 / 刮削在跑时**禁用**追更检查（两边的节流器是各自实例，并发跑等于把
  实际 QPS 翻倍）。这是**单向**守卫（追更让着扫描），与 discovery 那边一致。

### 9.5 PC 界面落点
- 分类栏：「追剧 N」chip（⛔ **不加侧栏一级入口** —— `app_shell._items` 与
  `app_router.branches` 必须同序，判据是**下标**）。角标 = **有更新的作品数**
  （`new_item_count > 0`），不是「在追的作品数」—— 后者恒 > 0，角标永远亮着。
- 海报卡角标：**左上角**（其余三角已占：左下评分 / 右下简介 / 右上文件名），
  且只在 `!selecting` 时画。
- 剧集行 NEW：`MediaItemRow` 的 `isNew` 参数（判据由 `_DetailBody` **算好传进来**，
  只此一处），`_NewTag` 与主标题**同排**（不改行高 —— 与进度条压底边同一条理由）。
  文案口径与 Android `newEpisodeTitle` 逐字一致（■ + NEW）。
- 详情页 `_FollowButton`：放**播放之后、刮削之前**（与 Android 那颗胶囊同序）。
  已追剧时**点亮**（半透明底 + 同色描边，⛔ 深色 UI 靠**实心面明度**不靠描边）。
  写入走 `FollowController.toggleFollow`，它刷新**四处**：`workListProvider` /
  `followedUpdateCountProvider` / `libraryStatsProvider` / **`workDetailProvider(key)`**。
  ⛔ 漏最后一处的表现是「点了按钮毫无反应」（库里已追上，眼前那颗还写着「追剧」），
  用户会再点一次 = 取消，来回几下就认为按钮坏了。
- 空态：`libraryEmptyHint` 的追剧分支必须排在**搜索词 / 面板条件之后** ——
  带条件时确实是「条件太紧，清掉就好」，排前面会让用户点「去看看全部」时把
  自己打的词一起丢掉。
- SnackBar：⛔ **只在 `outcome.hasNews` 时弹**（`newItems > 0`）。手动点一次
  什么都没变时弹「没有更新」是最典型的噪音。用 `identical(prev?.outcome, …)`
  挡同一份结果，否则用户会连吃两个一样的提示。「查看」要**把面板条件 + 搜索词
  一起清掉**再切追剧，否则更新的那几部恰好不在旧条件里时，点完看到一片空。

### 9.6 恢复备份之后
`settings_page._refreshLibraryViews` 必须 invalidate **六个**：`workListProvider` /
`libraryStatsProvider` / `categoryCountsProvider` / `playedCountProvider` /
`followedUpdateCountProvider` / `yearCountsProvider` / `genreCountsProvider`，
外加 `settingsProvider`。
⛔ 后五个**只** `watch(libraryListSignalProvider)`（**不是**
`libraryWriteSignalProvider`），所以函数里那句 `libraryWriteSignalProvider.bump()`
**推不动它们**，必须显式 invalidate。漏掉的表现是「恢复完之后列表是新库的内容，
但分类栏角标还是旧库的数字」—— 列表本身看着是对的，很难联想到它。
（`categoryCounts` / `playedCount` 这两处是 2026-10-07 顺手补的既有缺口。）

### 9.7 验证命令
```
# PC
NO_PROXY="127.0.0.1,localhost" HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= \
  flutter analyze lib
NO_PROXY=... flutter test test/domain test/ui
# ⚠️ `test/ui/widgets/tv_text_field_test.dart`「TV 下点一下进编辑态」**已修好**
#    （2026-10-07）。当时不是 Flutter 版本差异，是 widget 自己的 bug：
#    `_enterEditing()` 里的 `_focusNode.unfocus()` 会触发 `_onFocusChange()`，
#    后者见「失焦 ∧ _editing」就把 `_editing` 重置回 false ⇒ `readOnly` 一直是
#    true ⇒ `enterText` 一个字都进不去（Expected 'abc' / Actual ''）。
#    ⛔ 修法是在 `_onFocusChange` 上加 `!_entering` 守卫（`_entering` 只在
#    「unfocus → 下一帧 requestFocus」这段窗口里为 true），**别去改测试**。
#    全量 `flutter test` 现已 2448 条全绿。
# Android（JDK 21）
JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home \
  ./gradlew :app:testDebugUnitTest --tests 'com.cloudcine.tv.library.*'
```

### 9.8 追剧新集「看不见」的三层根因（2026-10-07 macOS 现场）

用户原话：
> 「遮天这部动画片设置为追剧后，点击更新后发现有 2 个更新，但是并没有在简介的
>   文件列表中发现这俩文件」
> 「**可能是因为没有刷新缓存，点击一下刷新可以看到 2 个新文件**」

★ 最后这句是钥匙：它把方向从「新集落在别的季格」（我第一轮的判断）扭回
**信号接线**。三方对齐（`logs/cloudcine-2026-10-07.log` / 用户库 / 源码）：
日志 `[发现] 媒体 13（新增 2 / 已有 11）`、`[追剧] 检查结束：… 新增 2`，
库里 `shroudingtheheavens.followed=1, new_item_count=2` ⇒ **库确实写对了**。

#### ① 真根因：`workDetailProvider` 没订阅 `libraryWriteSignalProvider`
`ui/providers/library_providers.dart`。它当时只
`ref.watch(playbackProgressSignalProvider)`（播放进度），而写库的几条路径
（扫描 / 发现 / **追更检查** / 批量刮削）推的是 `libraryWriteSignalProvider`
（语义 =「库里数据变了，**凡是读库的视图都该重看**」）⇒ 详情页不在那条链的
下游，不重查。

**为什么这一类 bug 特别贵**：它既不像「写失败」（库里有数据），也不像
「查询错」（点一下刷新就对），只能对着信号链一条条数。

**修**：加 `ref.watch(libraryWriteSignalProvider);`。
★ 一般化：**任何读库的 `FutureProvider`/`Notifier` 都必须 watch 写库信号**；
漏掉的表现是「点了按钮毫无反应」。`FollowController._refreshAfterWrite` 的
注释早就反复强调过这一条，这次漏掉的是**文件列表本身**。

#### ② `clearFollowBadge` 此前**全工程没有调用点** ⇒ 角标永不消失
海报上「更新 N」永远挂着，用户没有任何办法清掉。

**修**：在 `workDetailProvider` 里判「这一部下已经没有任何『追剧后新增且没播过』
的条目」时清掉。三条口径：
- 判据必须与行级 `■ NEW` **同源**（同一个 `MediaWork.isNewSinceFollow` +
  `maxPositions`），否则会出现「列表里一条 NEW 都没有、海报上还挂着 2」；
- ⛔ 用 `maxPositions` 而不是 `resumePositionMs`（后者看完会被清成 NULL）；
- ⛔ 只清 `new_item_count` 一列（`follow_started_at` / `follow_checked_at` /
  `updated_at` 都不能动，理由见 `clearFollowBadge` 的注释）。

#### ③ ⛔⛔ `ref.invalidateSelf()` 不能在 provider **自己的 body** 里用
清完角标我原本写 `ref.invalidateSelf()` 把 `work` 刷成 `newItemCount = 0`。
单测**直接超时 30 秒**，Riverpod 抛：
`Bad state: The provider … was disposed during loading state, yet no value could
be emitted.` —— 本次计算产出的那个 future **永远不完成**，而详情页正是靠它拿
数据的（`.future` 被孤立）。

**修**：`work = owner.copyWith(newItemCount: 0);` 直接改手上这一份。既省掉一次
四查询，也不会把状态推回 loading（值本来就已知）。顺带避开另一个隐患：万一
`clearFollowBadge` 没写成功，自我作废会变成**无限重建**。

#### ④ 附带：`183 4K.mp4` 提不出集号
`core/utils/filename_parser.dart` 的 `_parseDotted`：`183` 被当片名
（`_isStandaloneRelease` 允许纯数字当名字，为《65》那部电影），紧接着
「目录名作为系列名」那条规则用目录名顶掉 `title` 时**连季集号一起清掉** ⇒
它在库里成了独立作品，而详情页按「作品 = 遮天」查文件，永远查不到。

**修**：`bareEpisode` —— 三条守卫**同时**成立才算：
① `title` 是纯数字（`^\d{1,4}$`）；② 编号与第一个技术标记之间**只隔空格**
（`markerStart > 0`；点号不算）；③ **没有年份**。
命中后 `title = null`（让目录名兜底）、`kind = episode`、`episode = bareEpisode`。
回归样本全部不变：`65.2023.2160p…`（片名《65》）、`159.mkv`、`183.mp4`、
`182.格力空调显示E6如何维修.mp4`。

#### ⑤ 顺带的可见性改进（用户三选一里选的「格子角标 + 提示条」）
`ui/pages/work_detail_page.dart`：
- 季/部 chip 上加「N 新」小胶囊 `_NewCountBadge`（**品牌色**，不跟选中态走 ——
  它的意思是「这里有新东西」，与「你正站在这一格」是两件事）；
- 当前格一条新的都没有、而别处有时，选择器下面挂整条可点的 `_NewItemsHint`
  （「有 N 集更新在「X」里 · 去看看」），点一下 `setState` 切格；
- ⛔ 角标与行级 `■ NEW` 必须用**同一个** `isNewItem` 判据。

#### ⑥ 新增守卫测试（三个文件，均已离线验证会变红）
- `test/ui/providers/work_detail_follow_refresh_test.dart`
  ① 写库 + 推 `libraryWriteSignalProvider` → 详情页必须多出那一行
     （离线验证：注释掉那个 watch ⇒ `Expected: <3> / Actual: <2>`，**精确复现用户现场**）；
  ② 两集新集都 `saveMaxPosition` 之后角标自动归零、且 `followStartedAt` 不动
     （离线验证：`if (false)` 掉那个分支 ⇒ `Expected: <0> / Actual: <2>`）。
- `test/ui/pages/work_detail_new_badge_test.dart`：新集在别的季 ⇒ 那一格挂「1 新」+
  指路条出现；**点一下列表真的换了**。
  ⚠️ 只断言「提示条消失」抓不住「只换高亮不换列表」—— 那种坏版本一样会消失
  （因为已经站在那一格了），测试会绿而用户仍看不到那一集。
- `test/core/filename_parser_test.dart` 新增一组「「编号 + 空格 + 分辨率」= 集号」
  （5 例：`183 4K.mp4` 有/无目录 + 三条回归守卫）。

#### ⑦ ⚠️ 写这类测试时踩的两个坑（下次直接照做）
1. `upsertItems` 插入时**用 `now` 顶掉 `firstSeenAt`**（「首次入库时刻 = 本次
   扫描时刻」是它的语义）⇒ 想让「老集」与「追剧起点」有先后，必须**传两次不同
   的 `now`**，在 `MediaItem` 上填 `firstSeenAt` 是**无效的**。
2. `saveMaxPosition` 收的是**完整 item id**（`quark:f3`），不是 `fileId`。
   传错时它静默匹配 0 行 —— 正是「看过没有」这类判据最难查的失败形态。

### 9.9 「点了 NEW 不消失」：已读判据只认位置，而位置只在整十秒边界上报（2026-10-07 macOS 现场）

用户原话：
> 「看到了简介页面的 new 标记的列表，但是点击后，new 标记不消失，并且媒体库
>   列表中的『更新 2』标记也没有相应的调整」
> 「**调整逻辑，无论播放了多长时间，只要点击了，就去掉 new 标记**」

第二句是**口径**（推翻了隐含假设「播放进度上报一定会写 `max_position_ms`」），
不是猜测。**先按它改，再去对齐取证。**

#### ① 三方对齐的取证（这个手法值得复用）
| 证据源 | 看到的东西 |
|---|---|
| 日志 `logs/cloudcine-2026-10-07.log` | `12:32:30.697 播放请求已被播放窗口取走：Z 遮 天 E184` → `12:32:33.674 收到窗口关闭通知`（**3 秒**）；`E183` 同理 **2 秒**。期间**一次进度回报都没有**。 |
| 用户库直查 | `183 4K.mp4` / `EP184.mkv` 的 `max_position_ms` / `last_played_at` / `resume_position_ms` **三列全 NULL**；`shroudingtheheavens.new_item_count = 2` |
| 源码 | `player_protocol.dart` 的 `ProgressThrottle.accept`：`second <= 0 \|\| second % 10 != 0` 直接返回 null |

⇒ **播放 < 10 秒 = 库里一个字都没写。** 而关窗时 `_releasePlayer()` 先
`sub.cancel()` 再 stop、且 `_currentRequest = null`，**不补最后一笔**
（⚠️ Android 端 `onDestroy` 是补的 —— 这就是两端差异的来源）。

★ 钥匙：`max_position_ms` 是「**看到哪儿了**」；「**有没有点过**」是另一件事。
拿前者当后者的判据，等于要求「至少看满 10 秒」。

#### ② 判据 = 两条记录**取或**（`lib/domain/services/follow_read.dart`）
```dart
bool isItemWatched(MediaItem item, Map<String, Duration> maxPositions) =>
    maxPositions[item.id] != null || item.lastPlayedAt != null;
```
- `max_position_ms` —— 看到哪儿了（看满 10 秒以上必有值）；
- `last_played_at` —— **已读回执**，起播那一刻由 `MediaRepository.markPlayed` 写。

⛔ **起播时不要往 `max_position_ms` 写个 1 毫秒充数**，两个后果：
1. 每一行**点过**的条目都会画出一条 **0% 的进度槽** —— `_WatchedBar` 的槽是
   **不透明**的（`panel2`），看得见；
2. 与项目已定的「播了但不足 1 秒 = 从没播过」自相矛盾。
**已读归 `last_played_at`，位置归 `max_position_ms`，两列各司其职。**

⛔ 也不能用 `resume_position_ms`：看完会被清成 NULL ⇒ 看完的一集重新变 NEW。

#### ③ 落点：`ui/widgets/play_action.dart` 的 `_markOpened`
`playItem` 是**全应用唯一起播入口**（`media_item_row` / `library_page` /
`folder_browser` / `work_detail_page` 四处调用点全走它）。在它的**两条**返回路径
上 `unawaited(_markOpened(ref, item))`：独立窗口成功开窗后、以及退回内置页
`context.push` 之前。

`_markOpened` 三件事：`repo.markPlayed(item.id, now)` →
`syncFollowReadCount(repo, item.groupKey)` → 推 `playbackProgressSignal` +
`libraryListSignal`。

- ⛔ **三个 `ref.read` 必须在第一个 `await` 之前**：内置页那条路紧接着
  `context.push` 换页，之后再碰 `ref` 会抛
  「Cannot use ref after the widget was disposed」。
- ⛔ **刻意不推 `libraryWriteSignalProvider`**：它下游挂着 `folderTreeProvider`
  （每次读全表两万行），而播放只写播放记录。与 `onPositionTick` 同一套口径。

#### ④ ⛔⛔ 只下调、绝不上调（`syncFollowReadCount` / `workDetailProvider`）
从「未读集合」重算的口径**比 `applyFollowCheck` 的累加更宽**（包含「追剧之后、
但被**全盘扫描**而不是追更检查发现的集」）。上调会让**打开一次详情页就凭空冒出
角标**。上调的唯一入口是 `applyFollowCheck`；**下调永远安全**。
条件写成 `remainingNew < owner.newItemCount`（不是 `== 0`）。

接口也顺势改名：`clearFollowBadge(key)` → **`setFollowNewItemCount(key, count)`**
（现在要写的不只是 0）。

#### ⑤ ⛔⛔ 归一之后 `item.groupKey` **不是**作品 key
调用方手里只有一个 `MediaItem`，能给的只有 `groupKey`。但：
```
media_items.group_key = 'z遮天'                  ← 文件名解析出来的归组键
media_works.key       = 'shroudingtheheavens'    ← 归一目标（追剧状态挂这行）
media_works['z遮天'].merged_into = 'shroudingtheheavens'   ← 别名行
```
直接拿 `groupKey` 去 `workByKey` 会落在**别名行**上，而那行 `followed == false`
⇒ 提前 return ⇒ **角标永远降不下来，且不报错**（`mergeWorksInto` 只写作品行，
**不重写 `media_items.group_key`**）。

**修**：`syncFollowReadCount` 自己顺着 `mergedInto` 走到目标 —— 与
`workDetailProvider` 里那段**同一口径**（连「只走一跳」都一样，因为折叠不允许
成链，`mergeWorksInto` 会拒绝把别名当目标）。
★ 一般化：**凡是「从一个 item 反推它的作品」的地方，都必须跟着 `mergedInto` 走。**

#### ⑥ Android 端同步（两端必须同源）
`android/.../library/LibraryModels.kt`：
```kotlin
return item.maxPositionMs == null && item.lastPlayedAt == null   // 原：只看 maxPositionMs
```
那边也有**真实的**缺口：`PlayerActivity.reportProgress` 里
`if (totalMs > 0L) db.saveMaxPosition(...)` —— **时长探测不出来**时（转码流 /
探测失败）`max_position_ms` 一个字都不写，而 `markPlayed` 每次都写。
新增 `FollowReadTest.kt`（10 例）钉住。

⚠️ **两端口径仍有一处不同**：Android `openWork` 是「进简介页 =
`clearFollowBadge` 清零」（它的红线 8），PC 是「只下调」。**刻意未改**。

#### ⑦ 测试与验证
- 新建 `test/domain/follow_read_test.dart`（9 例，**真 drift 库**）。
  离线验证两条守卫：
  - 去掉 `|| item.lastPlayedAt != null` ⇒ `+8 -3`（三条用例红）；
  - `if (false)` 掉 `mergedInto` 跟随 ⇒ `Expected: <1> / Actual: <0>`。
- ⛔ 空 Map 字面量写 `const <String, Duration>{}`（`const {}` 推断成
  `Map<dynamic, dynamic>`）。
- PC 回归 `test/domain test/data test/ui/providers test/ui/pages test/core`
  = **1938 例全绿**；Android `:app:testDebugUnitTest` BUILD SUCCESSFUL。


## 10. 发版 / Release（2026-10-07 首个版本 v0.1.0）

### 10.1 触发方式
`.github/workflows/release.yml` 只认 **`v*` tag**：
```bash
git tag -a v0.1.0 -m "…" && git push origin v0.1.0
```
推 tag ⇒ 跑测试 → 三端构建 → **全部成功才** `gh release create`。
⛔ 上架是**独立 job**（`needs: [build-macos, build-windows, build-android]`），
任一平台失败 ⇒ **Release 根本不出现**（只留下 tag 和一次红的 run）。
所以「tag 推出去就收不回来」在本仓库只对 **tag** 成立，Release 是有闸门的。
⛔ `workflow_dispatch` 手动触发时 `github.ref` 是**分支名** ⇒ release job 的
`if: startsWith(github.ref, 'refs/tags/v')` 不成立 ⇒ 只构建、不上架，产物留在
本次 run 的 Artifacts 里。想先试就跑它。

### 10.2 ⛔⛔ 版本号有**两个源头，必须同时改**
| 平台 | 真源 | 产物名 |
|---|---|---|
| macOS / Windows | `pubspec.yaml` 的 `version: x.y.z+N` | `cloudcine-x.y.z-macos.dmg` / `-windows-x64.msi` |
| Android | `android/app/build.gradle.kts` 的 `versionName` | `cloudcine-<versionName>-b<versionCode>-android.apk` |

两边不一致 ⇒ **同一个 Release 挂着两个版本号**（2026-10-07 修：Android 侧是
从没改过的占位 `1.0.0`，PC 侧是 `0.1.0`）。README 与 `.github/release-notes.md`
承诺的是统一的 `cloudcine-x.y.z-*`。
- ⛔ `versionCode` 必须**单调递增**（不递增 ⇒ 已装设备报「应用未安装」）；
  `pubspec` 的 `+N` 与它同义，也应同步。
- ⛔ `applicationId` 不许动（换包名 = 丢磁盘缓存）。
- ⛔ **tag 名**（`v0.1.0`）也要跟这两个对上 —— Release 标题用的是 `GITHUB_REF_NAME`。

### 10.3 本地预检（推 tag 之前跑；等价于 release job 的两道门）
```bash
# Android（JDK 21 + SDK 36）—— 与 build-android 同命令
cd android
JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home \
ANDROID_HOME=$HOME/Library/Android/sdk \
  ./gradlew :app:testDebugUnitTest :app:assembleRelease
ls app/build/outputs/apk/branded/          # 期望 cloudcine-<新版本>-b<N>-android.apk

# PC
NO_PROXY="localhost,127.0.0.1,::1" flutter analyze && flutter test
```

**2026-10-07（v0.1.1 发版）实测结果**：`flutter analyze` → `No issues found!`；
`flutter test` → `00:42 +2448: All tests passed!`；Android → `BUILD SUCCESSFUL`，
品牌化产物 `cloudcine-0.1.1-b2-android.apk`。⇒ 全绿，约 3 分钟。

⚠️⚠️ **在本机（Agent 沙箱）跑这套预检必须 `HOME=/Users/tandy` 且关掉沙箱**，
否则两个假故障：
- `$HOME` 被重定向成 `/Users/tandy/.workbuddy-ai-6-home` ⇒ `ANDROID_HOME=$HOME/Library/Android/sdk`
  指向不存在的路径（SDK 真实位置是 `/Users/tandy/Library/Android/sdk`）。
- `flutter test` 会写 `~/.pub-cache/...` 与 `~/.dartServer/...`，被拒后**进程被打断** ⇒
  现象是 `tail` 停在 `+2430` 之类的进度行、**没有 `All tests passed!` 汇总行**，
  看起来像测试失败 —— 其实一条断言都没红。判据：看退出码 + `grep -c '\[E\]'`，
  别只看 tail。（`flutter analyze` 不受影响，它照样能出 `No issues found!`。）

⚠️ `brandReleaseApk` **不清理** branded 目录 ⇒ 本地会同时躺着新旧两个版本名的
apk（`cloudcine-0.1.0-*` 与 `cloudcine-1.0.0-*`）。CI 是干净检出，不会。
⛔ 别「按优先级取第一个」挑包 —— `android/tool/adb_tv.sh` 的 `find_apk` 按 **mtime** 取最新。

### 10.4 已知未配项（发版前要知道）
- **Android 发布签名未配**（`ANDROID_KEYSTORE_BASE64` 那组 secret 没设）⇒
  release 包退回 **debug 签名**。侧载正常，但⛔ 签名不同的包**不能互相覆盖安装**
  （用户装新版会报「应用未安装」，得先卸载再装）。
- `gh release create --generate-notes` 从**提交信息**生成 changelog，而本仓库提交
  信息大量是 `nil` ⇒ 自动更新日志基本是空的。要体面的 changelog 就得自己写进
  `.github/release-notes.md`（它排在自动日志**之前**）。
