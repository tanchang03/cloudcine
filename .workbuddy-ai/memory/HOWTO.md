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


