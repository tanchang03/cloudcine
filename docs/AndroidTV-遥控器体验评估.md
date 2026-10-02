# Android TV 遥控器体验评估与改造方案

> 日期：2026-10-02
> 范围：Android TV —— 能不能装上、能不能**只用遥控器**走通每一个已实现功能
> 方法：源码通读 + 在 `flutter test`（默认平台是 `android`，走**真实 Android 键码表**）里跑行为探针 + 逐条比对官方 TV 规范
> 探针文件：`test/ui/tv_remote_probe_test.dart`（8 例，全绿）
>
> ⚠️ **快照说明**：本文按 **2026-10-02 12:55 的工作区**评估。评估期间仓库正在被编辑
> （`work_detail_page.dart` 由 576 行变 707 行、新增 `customize_work_dialog.dart` 与
> `genre_edit_dialog.dart`），已把这三个也纳入 §5.4。
>
> ✅ **§0–§5 描述的是「改造前」的状态，原样保留作为基线。**
> P0 四项、P1-2、P1-4 已实施完毕，实施记录、验收数据、「实施中改了主意的三处」
> 与「P1-4 的三个更正」见 **§6.0**。

---

## 0. 结论速览

一句话：**当前版本在 Android TV 上「装不上、看不见焦点、播放页按不出任何控件」。**
不是细节没打磨，是三处结构性缺口；但**焦点遍历与 OK 键激活这两件最难的事，Flutter 默认就给对了**，所以工作量比想象的小。

| 层 | 判定 | 依据 |
|---|---|---|
| 能不能装到 TV 上 | ❌ **装不上** | `AndroidManifest.xml` 没有 `LEANBACK_LAUNCHER`、没有 `touchscreen required=false`、没有 `banner` |
| 焦点能不能走 | ✅ 能走 | 探针：D-pad 在**懒加载** `GridView` 里从第 0 项一路走到第 55 项，滚动位置到 `maxScrollExtent` |
| OK 键能不能按 | ✅ 能按 | 探针：`select` 能激活 `InkWell` / `Switch` / `FilterChip` / `ExpansionTile` |
| 能不能**看见**焦点在哪 | ❌ 看不见 | 深色主题默认焦点色是**白色 12% 蒙层**（实测 alpha = 0.1216）；海报卡片更糟 —— ink 画在图片**下面** |
| 字够不够大 | ❌ 差一倍 | 正文 10.5–13；官方 TV 下限 **12sp**、默认 **18sp** |
| 播放页 | ❌ **不可用** | 控制栏整块 `ExcludeFocus`，键位表只绑了 `space` —— 而 TV 的 OK 键是 `select` |
| 浏览效率 | ⚠️ 偏低 | 960×540 逻辑屏上只看得到约 **1.5 行海报（4 张）** |
| 返回键 | ✅ 已正确 | `PlaybackExitBehavior` 已把 Android/TV 归到「返回即停播并释放解码器」 |

**三条最重要的发现**

1. **装不上不是"上架问题"，是"看不见"问题。** 官方文档写得很直白：缺 `CATEGORY_LEANBACK_LAUNCHER` 时，
   「用开发工具把应用装到 TV 设备上，它**不会出现在 TV 用户界面里**」—— 侧载都找不到图标。
   缺 `touchscreen required=false` 则「不会出现在 TV 设备的 Google Play 上」。
   这两条加一个 320×180 的 banner，是**唯一一件不做就什么都验不了**的事。
2. **「遥控器按不动」的根因不是焦点系统，是播放页自己把控件关掉了。**
   `player_page.dart` 用 `ExcludeFocus` 把顶栏+控制栏整块设成不可聚焦（这是为桌面鼠标刻意的设计，
   注释里有实测数据：焦点落在滑块上时 → 会把 0.5 改成 0.55），
   于是 TV 上**没有任何控件能被遥控器选中**；而唯一能用的键位表又只绑了 `space`，
   OK 键（`KEYCODE_DPAD_CENTER` → `LogicalKeyboardKey.select`）落不到它身上 —— 实测 `select` 命中次数 = 0。
   后果是：**能用遥控器开始播，但不能暂停、不能选清晰度、不能选字幕。**
3. **海报墙的焦点高亮是被"画在整页内容之下"吃掉的，不是颜色太淡那么简单。**
   `_WorkCard` 的 `InkWell` 是**全项目唯一一个没有自己 `Material` 包裹的卡片类点击区**
   （对比 `_NavTile` / `_FolderRow` / `MediaItemRow` / `_DetailButton` / `_ViewSegment` /
   `_CategoryChip` / `_Crumb` / `_FilterChip` 都包了）。
   最近的 `Material` 于是变成 `Scaffold` 那一层，而 `_RenderInkFeatures.paint` 是
   **先画 ink、再 `super.paint`（画子节点）**——
   所以高亮**只可能从卡片下半部那段透明底的文字区露出来**，海报本身把它整个盖住。
   而默认 alpha 只有 0.12（探针 5 实测 0.1216），露出来也看不见。
   **只调 `focusColor` 不改这一条，海报墙上照样等于没有焦点。**

---

## 1. 构建与运行：本机现在跑不起来（以及怎么跑起来）

### 1.1 实测环境（2026-10-02）

| 项 | 结果 |
|---|---|
| Flutter | 3.29.0 stable / Dart 3.7.0 ✅ |
| JDK | 17.0.2 ✅（Gradle 8.10.2 支持 8–22） |
| Android SDK | ❌ **不存在**。`android/local.properties` 指向 `~/Library/Android/sdk`，该目录不存在 |
| `flutter doctor` 报的 SDK 路径 | `/opt/homebrew/Caskroom/android-platform-tools/35.0.2` —— 这只是 homebrew 的 `adb` 包，不是 SDK |
| `cmdline-tools` | ❌ 缺（doctor 明确报 `cmdline-tools component is missing`） |
| `platforms;android-36` | ❌ 未安装（`build.gradle.kts` 里 `compileSdk = maxOf(flutter.compileSdkVersion, 36)` 要求它） |
| build-tools / NDK | ❌ 未安装 |
| `~/.gradle` | 0 字节 —— 没有任何依赖缓存 |
| Android 设备 / 模拟器 | ❌ 无（`flutter devices` 只有 macOS / Chrome） |
| `maven.google.com` | ❌ 代理 502 `CONNECT tunnel failed` |
| `download.flutter.io` | ❌ 000（带代理、不带代理都失败）—— **Flutter Android embedding 的 maven 源** |
| `dl.google.com/dl/android/maven2/` | ✅ 200（AGP 实际走这个，不是 maven.google.com） |
| `repo.maven.apache.org` / `services.gradle.org` / `plugins.gradle.org` | ✅ 200 |

**结论：本机现在既装不了 SDK，也拉不到 Flutter 的 Android 引擎产物，`flutter build apk` 会在依赖解析阶段失败。**
另外**没有任何 Android 设备或 TV 模拟器**，所以「运行」这一步也无从谈起。

### 1.2 要跑起来需要补的三步

```bash
# 1) 装 SDK 组件（走 dl.google.com，本机可达）
#    需要一份 cmdline-tools；装好后：
sdkmanager --install "platform-tools" "platforms;android-36" \
                     "build-tools;36.0.0" "ndk;<flutter.ndkVersion>"
# 2) 让 local.properties 指向真实 SDK
#    android/local.properties: sdk.dir=/绝对路径/android-sdk
# 3) TV 模拟器（Apple Silicon 用 arm64 镜像）
sdkmanager --install "system-images;android-34;android-tv;arm64-v8a"
avdmanager create avd -n tv34 -k "system-images;android-34;android-tv;arm64-v8a" -d "tv_1080p"
emulator -avd tv34
```

`download.flutter.io` 若仍不通，需要在代理里放行该域名（否则 Flutter 的 `io.flutter:*` 依赖解析不了）。

### 1.3 遥控器怎么验（上了模拟器之后）

TV 模拟器可以**完全用 `adb` 模拟遥控器**，不需要真机：

```bash
adb shell input keyevent 19   # DPAD_UP
adb shell input keyevent 20   # DPAD_DOWN
adb shell input keyevent 21   # DPAD_LEFT
adb shell input keyevent 22   # DPAD_RIGHT
adb shell input keyevent 23   # DPAD_CENTER  ← 就是 OK 键
adb shell input keyevent 4    # BACK
adb shell input keyevent 85   # MEDIA_PLAY_PAUSE
adb shell input keyevent 89   # MEDIA_REWIND
adb shell input keyevent 90   # MEDIA_FAST_FORWARD
```

---

## 2. 遥控器到底是个什么输入设备

它**不是**「没有触摸的鼠标」，而是一个**只有 7 个键、且没有任何"位置信息"的离散输入设备**：

| 键 | Android 键码 | Flutter 逻辑键（实测，`keyboard_maps.g.dart`） |
|---|---|---|
| 上 / 下 / 左 / 右 | 19 / 20 / 21 / 22 | `arrowUp` / `arrowDown` / `arrowLeft` / `arrowRight` |
| **OK（中心）** | **23** | **`select`** ← 注意**不是** `enter`、**不是** `space` |
| 返回 | 4 | 由 Activity 走 `popRoute`，**不作为按键事件**送进 Flutter |
| 播放 / 暂停 | 85 | `mediaPlayPause` |
| 快退 / 快进 | 89 / 90 | `mediaRewind` / `mediaFastForward` |
| 首页 | 3 | `goHome`（系统吃掉） |

`WidgetsApp` 的默认键位表（非 web 平台）已经把这些接好了：

```
select / enter / numpadEnter / space / gameButtonA  →  ActivateIntent
四个方向键                                          →  DirectionalFocusIntent
escape                                              →  DismissIntent
```

由此推出 5 条**连带后果**，它们解释了本文后面一半的问题：

1. **没有 hover。** 所有「悬停才出现 / 悬停才说清」的东西在 TV 上等于不存在。
   本项目里这类有：海报卡片的播放图标与暗罩（`_WorkCard._hovered`）、
   所有 `Tooltip`（`_ScrapeButton` 的「去设置里打开刮削」、`_FolderRow` 的「只发现这一层」、
   `CopyTextButton` 的按钮名、`_WorkCard` 的「文件名」说明）。
2. **没有 Esc。** 只有 BACK，而 BACK 走的是「弹路由」，**不是** `DismissIntent`。
   于是**不是路由的浮层关不掉** —— `MenuAnchor`（媒体库的「筛选」面板）源码里是
   `OverlayPortal` + `OverlayPortalController`，关闭动作绑在 `escape: DismissIntent()` 上（`menu_anchor.dart:69`）。
   `PopupMenuButton`（排序 / 清晰度 / 字幕 / 音轨 / 倍速 / 下拉）走 `showMenu`，是**路由**，BACK 能关 —— 两者行为不同，必须分开对待。
3. **没有「划选」。** `SelectableText`（诊断页日志与路径、`KeyValueRow`、二维码页的 JSON 块）在 TV 上无法选择。
4. **没有「粘贴目的地」。** 全部 `CopyTextButton`（详情页路径/文件 ID、目录视图路径、诊断页日志）
   在 TV 上点了只会弹一句「已复制」，而用户没有任何地方可以粘贴。
5. **数字键与长按是可用资源。** 遥控器有 0–9（跳转到 N%）与长按（硬件重复 keydown）。

---

## 3. 探针实测结果

`test/ui/tv_remote_probe_test.dart`，`flutter test` 下 `defaultTargetPlatform == android`，
所以 `tester.sendKeyEvent` 走的是**真实 Android 键码**，不是 macOS 那条路。

| # | 探针 | 实测结果 | 意义 |
|---|---|---|---|
| 1 | D-pad 在**懒加载** `GridView.builder` 里能走多远 | `[0,5,10,15,20,25,30,35,40,45,50,55]`，滚动 `2576.4 / 2576.4` | ✅ **能走到底**。Flutter 的 `defaultTraversalRequestFocusCallback` 会 `Scrollable.ensureVisible`，边滚边补建 —— 「海报墙翻不到第二屏」这个担心**不成立** |
| 2 | OK 键（`select`）能激活 `InkWell` 吗 | 命中 1 次 | ✅ 「按 OK 打开详情/开始播」可用 |
| 3 | 设置页那批控件能被 OK 键操作吗 | `Switch` ✅ / `FilterChip` ✅ / `ExpansionTile` ✅；`Slider` 值**不变**（0.5） | 开关、多选 chip、折叠说明都能用遥控器；**滑块不能**（要靠方向键） |
| 4 | 焦点落在 `Slider` 上时方向键归谁 | 0.5 → **0.55** | 实证了播放页 `ExcludeFocus` 那条注释：焦点一旦落在滑块上，← / → 就不再是「快进 10 秒」 |
| 5 | `AppTheme.dark().focusColor` 的实际值 | `Color(alpha: 0.1216, white)` | 深色主题默认焦点色 = **白色 12% 蒙层**。3 米外看不见 |
| 6 | `CallbackShortcuts` 只绑 `space` 时，OK 键会命中吗 | `select` 命中 **0**，`space` 命中 1 | ❌ **这就是「遥控器按不出暂停」的机制** |
| 7 | 筛选浮层（`MenuAnchor`）遥控器能不能进出 | 能打开 ✅、下+OK 命中 chip ✅、Esc 能关 ✅ | 面板本身没问题；**问题是 TV 上没有 Esc**，只能走回「筛选」按钮再按一次 OK 关掉 |

---

## 4. 与官方 TV 规范逐条比对

官方（`developer.android.com/design/ui/tv`）给的是硬数字，逐条对：

| 规范项 | 官方要求 | 本项目现状 | 差距 |
|---|---|---|---|
| 设计尺寸 | **960×540 dp**（MDPI，1px = 1dp） | 按桌面窗口设计（`sidebarWidth = 196`） | 196dp 占掉 960 的 **20%** |
| 安全边距（overscan） | 左右 **48dp**、上下 **27dp** | `PageHeader` 左 22 / 海报墙 22 / 侧栏顶部 18、底部 10 | ❌ 全部落在不安全区 |
| 正文字号 | 最小 **12sp**，默认 **18sp** | 10.5 / 11 / 11.5 / 12 / 12.5 / 13 | ❌ 一半在 12 以下，且没有一处到 18 |
| 卡片标题 | **16sp** | 12.5 | ❌ 差 28% |
| 卡片副标题 | **12sp** | 11 | ❌ |
| 浏览页大标题 | **44sp** | 17 | ❌ 差 2.6 倍 |
| 详情页内容标题 | **34sp** | 20 | ❌ |
| 栅格 | 12 列 × 52dp，间距 20dp | `maxCrossAxisExtent: 172`，间距 14/18 | ⚠️ 算下来 4 列、卡片 169.5dp（官方 4 卡布局是 196dp）—— **列数碰巧对，边距不对** |
| 焦点指示 | 三态（default / focused / pressed）；**scale 1.025 / 1.05 / 1.1**，或 glow 2–32dp，或 outline | 只有一层 12% 白蒙层，无缩放、无描边 | ❌ |
| 导航位置 | 放**左或右**侧，纵向留给内容 | 左侧栏 ✅ | ✅ 方向对 |
| 深色主题 | 避免大面积纯白；避免过暗/浑浊色 | `#0B0D12` 底 + `#E9EDF6` 字 | ✅ 基本合规 |
| 字体 | 避免细/light 字重（TV 锐化会让它锯齿） | `w300`（`_Placeholder` 的首字 34sp） | ⚠️ 个别处 |

另外一条官方**明确要求**：TV 界面是 **16:9 固定横屏**，`android:screenOrientation` 应锁 `landscape`（当前 Manifest 未声明，虽然 TV 设备本来就是横屏，但声明它能让部分盒子/投影不出意外）。

---

## 5. 逐功能点评估

判定口径：
**✅ 可用** = 遥控器能完整操作；**⚠️ 勉强** = 能操作但别扭/信息丢失；**❌ 不可用** = 遥控器到不了或看不见。

### 5.1 外壳与导航

| # | 功能点 | 遥控器判定 | 问题 |
|---|---|---|---|
| 1 | 启动页（`splash_page`） | ✅ | 纯展示 + 一个「重试」`TextButton`，无输入 |
| 2 | 授权入口页（`auth_page`） | ✅ | 只有一个 `FilledButton`，OK 键直接可用 |
| 3 | 二维码登录页（`auth_qr_login`） | ⚠️ | 二维码 208×208 在 TV 上偏小（远距离扫不到），官方建议这类内容显著放大；「刷新二维码」「复制二维码内容」「显示原始值」都是 `TextButton`，可聚焦 ✅；但「复制二维码内容」在 TV 上无意义 |
| 4 | 侧栏一级导航（媒体库/扫描/设置） | ✅ 能走 ⚠️ 看不见 | `_NavTile` 包了 `Material`，高亮**画得出来**，但只有 12% 白蒙层 —— TV 上等于没有。字号 13 偏小 |
| 5 | 侧栏账号块 + 退出登录 | ⚠️ | 「退出登录」是 `IconButton`（只有 tooltip「退出登录」，TV 上无 hover → 图标语义靠猜）。它还是**唯一一个点一下就直接退登的入口**（设置页那个走确认对话框）—— 遥控器上误触代价大 |
| 6 | 侧栏「诊断日志」入口 | ✅ | 同 `_NavTile` |
| 7 | 深色主题 / 背景光晕 | ✅ | 符合 TV 深色规范 |
| 8 | `visualDensity: VisualDensity.compact` | ❌ | 全局压缩控件高度，与 TV「大间距、少内容」的要求相反 |
| 9 | `splashFactory: NoSplash` | ⚠️ | 涟漪被关掉（桌面刻意的），TV 上「按下去了没有」只剩一层很淡的 `highlightColor` —— 而 TV 规范要求 pressed 态明确可见 |
| 10 | 顶部安全边距（`WindowChrome`） | ✅ 正确 | 只在 macOS 加 `titleBarHeight`，Android 不加 —— 对。但 Android TV 需要的是**overscan 边距**，目前没有 |

### 5.2 媒体库（海报墙）

| # | 功能点 | 遥控器判定 | 问题 |
|---|---|---|---|
| 11 | 视图切换（海报墙 / 文件夹） | ✅ | `_ViewSegment` 包了 `Material`，OK 可切。字号 12 偏小 |
| 12 | 分类栏（全部/最近播放/电影/剧集/动漫/综艺/纪录片/其他 + 角标） | ✅ 能走 ⚠️ 看不见 | `_CategoryChip` 包了 `Material` ✅；但整条是**横向 `ListView`**，TV 上左右穿行 8 个 chip 才能到头，且高亮太弱 |
| 13 | 搜索框（防抖 250ms） | ⚠️ **最大的体验坑** | 能聚焦（`TextField` 是可聚焦的），但会拉起系统 IME。TV 上打中文要么用 Leanback 网格键盘（极慢），要么放弃。而**按片名找片子正是遥控器场景下最自然的需求**。另外它在页头那一行里，横向要穿过 5 个控件才够得到 |
| 14 | 排序菜单（`PopupMenuButton`） | ✅ | `showMenu` 是路由，BACK 能关 |
| 15 | 筛选面板（年代 / 类型多选，`MenuAnchor`） | ⚠️ | 探针证明：OK 能开、D-pad 能进、OK 能选 ✅。**但 TV 上没有 Esc**，只能走回「筛选」按钮再按一次 OK 关掉（`MenuAnchor` 不是路由，BACK 关不掉） |
| 16 | 刷新按钮 | ⚠️ | 只有图标 + tooltip，TV 上认不出 |
| 17 | 海报卡片：点卡片直接开播 | ⚠️ 能按 ❌ 看不见 | 探针 2 证明 OK 键能激活 ✅；但（a）焦点高亮被图片盖住（见 §0 发现 3），（b）「点卡片会直接播」这件事**只靠 hover 显示播放图标**来说，TV 上永远看不到 |
| 18 | 海报卡片：右下角「简介」按钮 | ⚠️ | 是卡片内**嵌套的第二个焦点目标**，D-pad 下/右会落到它上面（这是好事，否则详情页无路可进）；但它只有 12px 图标 + 10.5px 文字 |
| 19 | 海报卡片：评分角标 / 「文件名」角标 | ⚠️ | 「文件名」的含义只写在 `Tooltip` 里（「这些信息来自文件名解析，未联网刮削」）→ TV 上信息丢失 |
| 20 | 海报墙空态（3 种 + 行动按钮） | ✅ | `EmptyState` 的行动按钮是 `FilledButton`，OK 可用 ✅。文案偏小（11.5） |
| 21 | 加载 / 错误态 | ✅ | 「重试」按钮可聚焦 |
| 22 | 一屏能看到几张海报 | ⚠️ | 960×540 下：页头 ≈70 + 分类栏 ≈40，剩 430；行高 = 卡片 254 + 间距 18 = 272 → **只有 1.58 行**，即 4 张海报 + 半行。官方栅格建议一屏能看到更多 |

### 5.3 文件夹视图

| # | 功能点 | 遥控器判定 | 问题 |
|---|---|---|---|
| 23 | 面包屑（可点、自动滚到末尾） | ✅ 能走 ⚠️ 目标小 | `_Crumb` 包了 `Material` ✅；但字号 12 + 上下 padding 4 |
| 24 | 面包屑「上一级」按钮 | ⚠️ | `constraints: BoxConstraints.tightFor(width: 28, height: 28)` —— **28dp 的焦点目标**，TV 上偏小（Material 最小 48dp），且无 hover 提示 |
| 25 | 「复制当前目录路径」 | ❌ 无意义 | TV 上无处可粘 |
| 26 | 发现栏：「仅本层」/「发现本目录」/「停止」 | ✅ | `TextButton` / `FilledButton` / `TextButton`，OK 都能用 ✅。说明文字 11 偏小 |
| 27 | 目录行：点整行进目录 | ✅ | `_FolderRow` 包了 `Material` ✅ |
| 28 | 目录行右侧「只发现这一层」按钮 | ⚠️ | 30×30 的 `IconButton`，且含义只在 `Tooltip` 里 → TV 上「一个不知道是什么的小图标」 |
| 29 | 文件行：「加入媒体库」/「播放」 | ✅ | `FilledButton.tonal` / `IconButton`，可聚焦 ✅ |
| 30 | 空态（3 种） | ✅ | 与海报墙同 |
| 31 | 搜索框筛当前层 | ⚠️ | 同 #13（IME 问题） |

### 5.4 作品详情 / 刮削

| # | 功能点 | 遥控器判定 | 问题 |
|---|---|---|---|
| 32 | 返回 / 刷新 | ⚠️ | 两个 `IconButton`，只有 tooltip |
| 33 | 海报 + 标题 + 标签 + 简介 | ✅ | 纯展示。标题 20（官方详情页 34）；简介 `maxLines: 5` 且 12sp，TV 上读起来吃力 |
| 33a | 「编辑类型」chip（`_EditGenresChip`） | ⚠️ **目标极小** | 是个 `InkWell` ✅ 可聚焦，但 padding 只有 `6×2.5`、字号 **10**、图标 10 —— TV 上几乎看不见焦点；而「类型标签已被你手动锁定」这层含义只写在 `Tooltip` 里 |
| 34 | 「播放」按钮 | ✅ | `FilledButton.icon`，OK 直接可用 —— **这是 TV 上最顺的一条路** |
| 35 | 「刮削」按钮 | ⚠️ | 可用，但**禁用原因只写在 tooltip 里**（「还没有可用的在线刮削源。到『设置 → 刮削』打开开关…」）→ TV 上用户看到一个灰按钮，不知道为什么 |
| 36 | 「手动」按钮 + 手动刮削对话框 | ⚠️ **勉强可用** | 对话框本身没问题（`Dialog` + `TextField` + `DropdownButton` + `FilterChip` + 候选 `ListTile`，都可聚焦；`barrierDismissible: false`，BACK 能关）。但**要敲中文片名** —— TV 上等于把「救不回来的片子」变成「救不了」 |
| 36a | 「自定义」按钮 + `CustomizeWorkDialog` | ⚠️ **TV 上基本做不了** | `OutlinedButton.icon` 可点开 ✅；对话框里是**多个 `TextField`**（片名 / 原名 / 年份 / 简介）+ 一个 `DropdownButton<MediaCategory>`。下拉能用遥控器选，但四个输入框在 TV 上等于做不了 |
| 36b | `GenreEditDialog`（加 / 删类型标签） | ⚠️ 一半可用 | **删**标签是 `_RemovableChip`（`InkWell`）→ 遥控器能点 ✅；**加**标签是 `_AddChip`（`InkWell`，从已有类型里选）→ 也能点 ✅；但要**凭空新增一个类型**就得敲字 → ❌。底栏「取消 / 保存」是 `TextButton`/`FilledButton` ✅ |
| 37 | 文件列表 `MediaItemRow`：点整行播放 | ✅ | 包了 `Material` ✅，探针证明 OK 可激活 |
| 38 | 文件行：分辨率角标 | ✅ | 展示 |
| 39 | 文件行：「复制路径」/「定位所在目录」 | ❌ 无意义 / ⚠️ | 复制无意义；`my_location` 图标按钮无文字标签，含义只在 tooltip |
| 40 | 花絮 / 样片 | ✅ | 同 37 |
| 41 | 网盘位置卡（路径 / 文件 ID / 两个复制按钮） | ❌ 两个复制按钮无意义 | 路径文本本身是 `Text`（不可选），在 TV 上**既不能复制也不能选** → 这块信息在 TV 上彻底不可用 |

### 5.5 播放

**这一节是问题最集中的地方。**

| # | 功能点 | 遥控器判定 | 问题 |
|---|---|---|---|
| 42 | 播放页顶栏（返回 / 标题 / 沉浸模式） | ❌ 不可达 | 整块 `ExcludeFocus(child: _buildTopBar(...))` |
| 43 | 画面 / 缓冲指示 / 错误遮罩 | ✅ | `_ErrorOverlay` 的「返回」「重新取链」是 `OutlinedButton`/`FilledButton`，**但它们在 `ExcludeFocus` 之外**（`_buildStage` 没被包），所以**可聚焦** ✅ |
| 44 | 非致命提示条 `_NoticePill` | ⚠️ | 「知道了」按钮可聚焦 ✅，但 `_NoticePill` 里那个关闭按钮在 `_buildStage` 内，不在 `ExcludeFocus` 里 → 可用。位置贴顶 14px，落在 overscan 不安全区 |
| 45 | **播放 / 暂停** | ❌ **不可用** | 键位表只绑 `space`（探针 6：`select` 命中 0），按钮又在 `ExcludeFocus` 里 → **遥控器按不出暂停** |
| 46 | 后退 / 前进 10 秒 | ✅ | ← / → 已绑，遥控器方向键就是它们 ✅ |
| 47 | 音量静音 | ❌ 不可达 | 在 `ExcludeFocus` 里；且 TV 遥控器的音量键走 CEC 给电视/功放，**根本不到应用** |
| 48 | 音量滑块 | ❌ 不可达 + 无意义 | 同上 |
| 49 | 进度条（`BufferedSlider`） | ❌ 不可达 | 在 `ExcludeFocus` 里。即使放开，TV 上拖拽 = 长按方向键，mpv 会跟不上 |
| 50 | 清晰度菜单 | ❌ 不可达 | `PopupMenuButton` 在控制栏里 |
| 51 | 字幕菜单（内嵌 / 网盘 / 在线 / 本地四路） | ❌ 不可达 | 同上 —— **TV 上用户永远打不开字幕菜单** |
| 52 | 音轨菜单 | ❌ 不可达 | 同上 |
| 53 | 倍速菜单 | ❌ 不可达 | 同上 |
| 54 | 沉浸模式 | ❌ 不可达 + 无法退出 | 进入靠顶栏按钮（不可达）；退出靠「点画面任意处」（TV 无触摸）或 `escape`（TV 无 Esc）→ **一旦进入就出不来** |
| 55 | 返回键退出播放 | ✅ **正确** | `PlaybackExitBehavior.forPlatform(android) = stopAndRelease`，挂在 `dispose` 上，覆盖返回键/系统返回/手势/跳路由全部路径 |
| 56 | 续播位置 / 起播位置 | ✅ | 与输入设备无关 |
| 57 | 独立播放窗口（`desktop_multi_window`） | ✅ **正确降级** | `supportsMultiWindow` 已排除 Android，`playItem` 静默退回内置播放页 |
| 58 | 媒体键（⏯ / ⏪ / ⏩） | ❌ 未绑 | 键码 85/89/90 已能送进 Flutter（`keyboard_maps.g.dart`），但两张键位表都没有它们 —— **零成本的改进** |
| 59 | 屏幕常亮 | ⚠️ 待验 | 全项目没有 `SystemChrome`/wakelock。TV 上播放时通常系统不会休眠，但**必须真机确认**（否则看到一半黑屏） |

### 5.6 扫描

| # | 功能点 | 遥控器判定 | 问题 |
|---|---|---|---|
| 60 | 「从上次中断处继续」「扫描后清理失效记录」开关 | ✅ | 探针 3 证明 `Switch` 认 OK 键 |
| 61 | 「开始扫描」/「停止」 | ✅ | `FilledButton` / `OutlinedButton` |
| 62 | 进度卡（6 个指标 + 当前目录） | ⚠️ | 纯展示。指标值 15sp 还行，标签 10.5 太小；当前目录用 `AppTheme.mono`（11.5，`Menlo` —— Android 上会回退到 monospace，观感可接受） |
| 63 | 结果卡 / 「去看媒体库」 | ✅ | `TextButton.icon` |
| 64 | 扫描失败 + 重试 | ✅ | `EmptyState` 行动按钮 |
| 65 | 未登录空态 | ⚠️ | **`ScanPage` 里这个 `EmptyState` 没有传 `onAction`** —— 「去登录」按钮不会渲染（`EmptyState` 要求 `actionLabel != null && onAction != null`）。鼠标用户也点不到，属于既有缺陷，与 TV 无关，但顺手记一笔 |

### 5.7 设置

| # | 功能点 | 遥控器判定 | 问题 |
|---|---|---|---|
| 66 | 账号卡 + 退出登录 | ✅ | `TextButton.icon`，有确认对话框，BACK 可关 |
| 67 | 扫描：请求间隔滑块 / 最大递归深度滑块 | ⚠️ | **滑块不能用 OK 键改**（探针 3），必须先把焦点放上去再按 ← / →。TV 上这是**不直观但可用**的操作（用户看到滑块被选中，会试方向键）。值文字 11.5 偏小 |
| 68 | 刮削：两个开关 | ✅ | 探针 3 |
| 69 | TMDB Key / API 地址 / 图片地址 + 「保存」 | ❌ **TV 上不可用** | 三个 `TextField`，都需要敲一长串 key/URL。**这是 TV 上最不可能完成的任务** |
| 70 | 「测试连接」×3（TMDB / 豆瓣 / OpenSubtitles） | ✅ | `OutlinedButton.icon`，结果是一行文字（11sp） |
| 71 | 豆瓣 Cookie 输入 | ❌ **TV 上不可用** | 要粘贴一段几百字符的 Cookie |
| 72 | 「怎么拿到 Cookie？」折叠说明 | ✅ | 探针 3 证明 `ExpansionTile` 认 OK 键；但里面要求「按 F12 → Network」—— TV 上做不到 |
| 73 | 默认清晰度下拉 | ✅ | `DropdownButton` 走路由，BACK 能关；`DropdownButton` 在 `dropdown.dart` 里绑了 `ActivateIntent` |
| 74 | 自动加载字幕 / 记住进度开关 | ✅ | 探针 3 |
| 75 | 在线字幕 Api-Key / API 地址 | ❌ **TV 上不可用** | 同 69 |
| 76 | 存储：统计 / 缓存目录 / 清理海报缓存 | ⚠️ | 缓存目录用 `SelectableText`，TV 上不可选；「清理海报缓存」是 `OutlinedButton.icon` ✅ |
| 77 | 「清空索引库」+ 确认对话框 | ✅ | `AlertDialog` + `TextButton`/`FilledButton`，BACK 可关 |
| 78 | 备份与同步：上传 / 同步 / 从网盘恢复 | ✅ | 三个 `OutlinedButton.icon` |
| 79 | 远程备份选择对话框 | ✅ | `AlertDialog` + `ListTile`（`ListTile` 可聚焦、OK 可点），BACK 可关 |
| 80 | 关于：版本 / 播放后端 / 「打开诊断日志」 | ✅ | `OutlinedButton.icon` |

**设置页的整体结论**：TV 上它基本是**只读**的 —— 开关能拨、按钮能按，但**所有需要输入文本的配置项（TMDB / 豆瓣 / OpenSubtitles）都无法完成**。
而这恰好是「新机器上手」必须走的一步。这不是 UI 问题，是**流程问题**（见 §6 P1-4）。

### 5.8 诊断日志

| # | 功能点 | 遥控器判定 | 问题 |
|---|---|---|---|
| 81 | 「只看问题」`FilterChip` | ✅ | 探针 3 |
| 82 | 「复制全部」/「清空缓冲」 | ❌ 无意义 / ✅ | 复制在 TV 上没出口 |
| 83 | 日志路径行（`SelectableText` + 复制路径） | ❌ | TV 上既不能选也不能用 |
| 84 | 日志列表（`SelectableText`，11sp） | ❌ 读不了 | 11sp 在 3 米外不可读，且 TV 上没法复制走 |
| 85 | 「播放器窗口」按钮（桌面专属） | ✅ 正确 | `supportsMultiWindow` 为假时弹「当前平台不支持独立播放窗口」 —— 文案已说清 |
| 86 | 日志「返回」 | ✅ | 也可用 BACK |

---

## 6. 改造方案

### 6.0 实施进度（2026-10-02 更新）

**P0 四项已全部落地；P1 已完成 P1-2、P1-4 两项。**
验收：`flutter analyze` → No issues found；
`flutter test` → **1171 例全过**（其中 26 例是本次为 TV 新增的）。

| 项 | 状态 | 改了哪些文件 | 怎么验的 |
|---|---|---|---|
| P0-1 manifest + banner | ✅ | `android/app/src/main/AndroidManifest.xml`、新增 `res/drawable-xhdpi/banner.png`、新增生成器 `tool/gen_tv_banner.py` | `xmllint` 通过；banner 实测 320×180 |
| P0-2 播放页遥控器化 | ✅ | `lib/ui/pages/player_page.dart` | 新增 13 例纯函数测试 + 1 例对照探针 |
| P0-3 焦点可见化 | ✅ | `lib/ui/theme/app_theme.dart`、`lib/ui/pages/library_page.dart`、新增 `lib/ui/widgets/tv_focus.dart` | 新增 3 例（含「环必须画在子节点之后」的结构断言） |
| P0-4 尺寸与安全边距 | ✅ | `lib/ui/theme/app_theme.dart`、`lib/ui/shell/app_shell.dart`、`lib/ui/pages/library_page.dart` | 新增 3 例（TV 判据的三条分支） |
| P1-2 筛选面板关得掉 | ✅ | `lib/ui/widgets/library_filter_panel.dart` | 新增 3 例（显式「关闭」按钮 / 系统返回键 / `PopScope.canPop`） |
| P1-4 文字配置逃生通道 | ✅ | `lib/ui/widgets/common_widgets.dart`（新增 `TvTypingNotice`）、`lib/ui/pages/settings_page.dart` | 新增 5 例（见下方「P1-4 的三个更正」） |

**实施过程中改了主意的三处**（原方案写错了，这里更正）：

1. **不用 `CallbackShortcuts`，改用 `Focus.onKeyEvent`。**
   原方案说「给键位表补上 `select`」就够了。实际不够：`CallbackShortcuts`
   命中就一律报 `handled`，于是**焦点一旦进到控制栏，←/→ 就再也挪不动焦点** ——
   而 TV 上挪不动焦点 = 选不了字幕和清晰度。
   `Focus.onKeyEvent` 能返回 `ignored` 把按键交还焦点系统，这是唯一能同时满足
   「画面上 ←/→ 快退」和「控制栏里 ←/→ 换焦点」的写法。

2. **控制栏不是「删掉 `ExcludeFocus`」，而是「只摘掉两条滑块」。**
   原来整块 `ExcludeFocus` 是**过度修复**：真正吃方向键的只有 `Slider`。
   精确地把两条滑块摘出焦点链后，按钮留给遥控器、方向键留给播放器，两边都满足。
   对照探针实测：整块排除时 OK 命中 **0** 次；只摘滑块后命中 **1** 次。

3. **焦点环不走 `focusColor` 那条路，也不走 `FocusableActionDetector`。**
   * 只调 `focusColor` 没用 —— ink 画在子节点**下面**，海报把它整个盖住；
   * `FocusableActionDetector` 在 `enabled: false` 时把「显示不显示高亮」交给
     `MediaQuery.navigationMode` 决定，而那个值在 Android TV 上**只能真机验**
     （见 §7）。把焦点可见性押在没验证过的平台取值上，代价太大。
   最终自建 `TvFocusable`：`Focus(canRequestFocus: false)` 观察焦点 +
   在子节点**之后**叠一层描边，并且只看 `FocusManager.instance.highlightMode`
   （Android 默认 `touch`，**收到第一个按键就翻成 `traditional`**）——
   这个行为在源码里是确定的，不依赖真机。

**P0-4 里刻意没做的两件事**（都是有意的，不是漏）：

* **没动海报墙的列数。** 实测 960×540 下 `maxCrossAxisExtent` 从 172 提到 240，
  列数会从 4 压到 3，可见张数从 **~7.7 掉到 ~4.3**。文字已经靠整体放大一档
  变得能读了，再为「卡片更大」放弃一半信息量不划算。
* **没有全局放大字号。** 页面里写死的字号有上百处，逐个改既容易漏又很难回退。
  改成 `AppTheme.tvTextScaler`（TV 上整体 ×1.25）**只用在能吸收高度的地方** ——
  目前只包了海报墙的网格（卡片里海报是 `Expanded`，文字长高只会让海报变矮）。
  给固定高度的控件（播放页顶栏 48 / 控制栏 64 / **媒体库搜索框 32**）套它会直接报
  RenderFlex 溢出，所以那几处仍待单独处理，见 P1。

#### P1-4 的三个更正（写代码之前先核对了原方案的假设）

**(1) 「在电脑上配好，再用『备份与同步』同步过来」这句话，实测成立。**
但**理由和原方案想的不一样**：`BackupManifest` 里**根本没有设置字段**
（只有 `deviceId` / `deviceName` / `createdAt` / `libraryModifiedAt` /
`schemaVersion` / `fileNames` / `note`）。设置能过去，是因为设置项就存在
`cloudcine.sqlite` 的 `settings` 表里，而备份导出的是**整个数据库文件的原始字节**
（`library_backup_service.dart` 的 `dbBytesToWrite` 恒等于 `dbBytes`）。
新电视上本地库是空的，`sync()` 的 `!localManifest.hasLibraryContent` 分支
会无条件让远程赢 —— 正好是「第一次同步就把配置拉下来」。
⚠️ 唯一不跟着走的是**网盘凭证**，所以顺序必须是「先在电视上扫码登录，再同步」，
这句写进了提示正文。

**(2) 顺带发现一个既有缺陷（已按「诚实标注」处理，未改行为）：
`includeSettings` / `restoreSettings` 是**只写清单的空开关**。**
导出恒写原始字节、导入恒覆盖整个库文件，所以传 `false` 的实际效果只有一行日志。
原代码注释还在承诺「导入时据此决定是否恢复设置表」「实际设置过滤交给导入后的
迁移步骤」—— 那个迁移步骤**不存在**。UI 三条通道（上传备份 / 同步 / 从网盘恢复）
全部传 `true`，所以这个分支当下**够不到**，属于死代码。
处理：把三处误导性注释改成如实说明（要真正做到「不带走设置」，得先把库
`VACUUM INTO` 一份副本、在副本上 `DELETE FROM settings`、再读副本的字节）。
**没有**去实现它 —— 够不到的路径，实现出来也无法验证。

**(3) 原方案里「把 `CustomizeWorkDialog` 的年份也做成候选下拉」是空谈 ——
那个对话框根本没有年份字段**（只有 `片名` + `DropdownButton<MediaCategory>`）。
于是重新做了一遍全量清点：`lib/` 里一共只有 **6 个 `TextField`**，
逐个判「TV 上够不够得着 + 有没有免打字路径」：

| # | 位置 | TV 上要不要打字 | 处理 |
|---|---|---|---|
| 1 | 设置页 6 个配置字段（`settings_page.dart:491` 的 `_savableField`） | ❌ **要，且无替代** | ✅ 加 `TvTypingNotice` |
| 2 | 媒体库搜索框（`library_page.dart:882`） | ⚠️ 要，但**由用户主动进入**，且没有别的实现方式 | 不动。但记下：它 `height: 32` 写死，所以 P1-3 放大字号时**不能**给媒体库头部套 `tvTextScaler` |
| 3 | `CustomizeWorkDialog` 片名 | ⚠️ 要 —— 但**敲片名正是这个对话框存在的理由**，且已预填当前值 | 不动 |
| 4 | `ManualScrapeDialog` 片名 + 年份 | ✅ 不用 —— 两者都按文件名预填，`类型` 已是下拉，TV 上直接按「搜索」即可 | 不动 |
| 5 | `GenreEditDialog` 添加类型 | ✅ 不用 —— 已有「**常用类型**」chip 行，点 chip 即可，只有真的要造新类型才需要打字 | 不动 |
| 6 | `player_window_app.dart:3076`（直链调试框） | ✅ 够不着 —— `WindowLaunch.main()` 的文档写明 Android 端没有多窗口，这个 TextField 只在 PC 独立窗口里 | 不动 |

结论：**真正「TV 上够得着、又完全没有免打字路径」的只有设置页那 6 个字段**，
`TvTypingNotice` 就加在承载它们的「刮削」与「在线字幕」两节里（两处），
并在「备份与同步」一节反向写明操作顺序。

**仍未做**：P1-1、P1-3、P1-5，P2 七项，以及 §7 里那 6 件只能真机定的事。
**另外两处覆盖缺口，别当成已验**：

* `TvTypingNotice` 这个**组件**有 5 例测试；但它被**接进设置页的两个调用点**
  只有读代码 + `flutter analyze` 保证，**没有测试** —— 要测整页得先造一套
  fake（`SettingsStore` 是真类不是接口、`PosterCache` 要一个 `HttpClientLike` 替身、
  还要 fake 掉 `AuthController` 与两个目录 provider），成本高于这两行接线本身。
  本项目现有页面测试的取向也是「测抽出来的部件」（如 `LogPathRow`）。
* `_SearchBox` 那个 `height: 32` 只是**读代码看到的**，没有测试钉住；
  P1-3 动手前请先补一条。

---

### P0 —— 不修就等于「这个版本在 TV 上不存在」

**P0-1 `AndroidManifest.xml` 补 TV 声明**（`android/app/src/main/AndroidManifest.xml`）

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />

    <!-- TV 没有触摸屏；不声明 required=false 就不会出现在 TV 的 Google Play 上 -->
    <uses-feature android:name="android.hardware.touchscreen" android:required="false" />
    <!-- 同时支持手机与 TV，所以是 false -->
    <uses-feature android:name="android.software.leanback" android:required="false" />

    <application
        android:label="云影 CloudCine"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher"
        android:banner="@drawable/banner">   <!-- 320×180 xhdpi，图上要带文字 -->
        <activity
            android:name=".MainActivity"
            ...
            android:screenOrientation="landscape">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
                <!-- 缺这一条：侧载后不会出现在 TV 桌面上 -->
                <category android:name="android.intent.category.LEANBACK_LAUNCHER"/>
            </intent-filter>
        </activity>
```

还要新增 `android/app/src/main/res/drawable-xhdpi/banner.png`（320×180，带应用名文字）。

**P0-2 播放页让遥控器按得动**（`lib/ui/pages/player_page.dart`）

最小改法（保留桌面设计意图，只加 TV 需要的键）：

```dart
bindings: {
  // 桌面：空格。TV：OK 键是 select，必须单独绑。
  const SingleActivator(LogicalKeyboardKey.space): controller.playOrPause,
  const SingleActivator(LogicalKeyboardKey.select): controller.playOrPause,
  const SingleActivator(LogicalKeyboardKey.enter): controller.playOrPause,
  // 遥控器上带 ⏯ ⏪ ⏩ 的机型（键码 85/89/90）
  const SingleActivator(LogicalKeyboardKey.mediaPlayPause): controller.playOrPause,
  const SingleActivator(LogicalKeyboardKey.mediaRewind):
      () => controller.seekRelative(const Duration(seconds: -10)),
  const SingleActivator(LogicalKeyboardKey.mediaFastForward):
      () => controller.seekRelative(const Duration(seconds: 10)),
  const SingleActivator(LogicalKeyboardKey.arrowLeft): () => controller.seekRelative(const Duration(seconds: -10)),
  const SingleActivator(LogicalKeyboardKey.arrowRight): () => controller.seekRelative(const Duration(seconds: 10)),
  const SingleActivator(LogicalKeyboardKey.escape): ...,
}
```

再加一个 **TV 专属的「控制栏可达」模式**，而不是简单地把 `ExcludeFocus` 拆掉（拆掉会让桌面端回到「滑块抢方向键」的老问题）：

- 新增 `bool get _isTv => defaultTargetPlatform == TargetPlatform.android && <设备是 TV>`；
- TV 上：`select` 的第一件事是**显示/隐藏控制栏**（TV 通行交互：OK 唤出 OSD），控制栏显示时**把焦点交给控制栏的第一个控件**，方向键在控制栏内走；
- 控制栏隐藏时，方向键 = 快进/快退，`select` = 播放/暂停。

TV 判定可用 `package:flutter/services.dart` 之外的方式：
`MediaQuery.navigationModeOf(context) == NavigationMode.directional` 是一个候选（引擎在 TV 上会报 `directional`），
但**必须真机确认**（见 §7-3）。更稳的是读 `MediaQuery.size` + `defaultTargetPlatform`，或由原生侧通过 method channel 报 `UiModeManager.getCurrentModeType() == UI_MODE_TYPE_TELEVISION`。

**P0-3 焦点必须看得见**（`lib/ui/theme/app_theme.dart` + `library_page.dart`）

1. 主题里把焦点色改成明确的强调色描边/发光，而不是默认的白色 12%：
   ```dart
   focusColor: AppTheme.accent.withValues(alpha: 0.28),
   ```
2. 给 `_WorkCard` 补一层 `Material`（它现在是全项目唯一一个漏了的卡片）：
   ```dart
   return Material(
     color: Colors.transparent,
     borderRadius: BorderRadius.circular(10),
     child: InkWell(...),
   );
   ```
   **只改 `focusColor` 不改这一条，海报墙上依然什么都看不见。**
3. 按官方规范做**焦点缩放 + 描边**（`scale: 1.05` + `outline 2dp`）。
   建议抽一个共用部件，例如 `lib/ui/widgets/tv_focus.dart` 的 `TvFocusable`：
   用 `Focus` 的 `onFocusChange` 驱动 `AnimatedScale` / `AnimatedContainer`，
   供海报卡、列表行、按钮复用。缩放 1.05 需要给元素留边距 ——
   海报墙 `crossAxisSpacing: 14 / mainAxisSpacing: 18` 够；**列表行现在只有 `bottom: 4`，要加到 ≥8**，否则放大后互相压。

**P0-4 尺寸与安全边距**（`app_theme.dart` + 各页 padding）

- 去掉 `visualDensity: VisualDensity.compact`（或在 TV 上改成 `standard`/`comfortable`）。
- 新增一组 TV 字号令牌，按官方规范：正文 ≥ 12（默认 18）、卡片标题 16、卡片副标题 12、页面大标题 44。
  最小可行做法：在 `AppTheme` 里加 `static bool tvMode`（由启动时探测），
  然后用一个 `AppTheme.fs(base)` 之类的缩放函数把现有字号整体乘 1.4–1.6 —— 
  **比逐个改 40 处字号安全**（不会漏，也不会把某个页面改崩）。
- 页面 padding 从 22 提到 48（左右）/ 27（上下）。

### P1 —— 可用，但难用

**P1-1 让 Tooltip 在 TV 上有出路。** TV 上没有 hover，而当前有 6 类信息只存在于 tooltip 里
（`_ScrapeButton` 的禁用原因、`_FolderRow` 的「只发现这一层」、`CopyTextButton` 的按钮名、
`_WorkCard` 的「文件名」说明、刷新/返回等图标按钮的语义）。
建议：TV 上对**图标按钮**一律补文字标签，对**禁用按钮**把原因渲染成按钮下方的可见小字。

**P1-2 补「没有 Esc」的替代路径。** ✅ **已完成。** `MenuAnchor`（筛选面板）在 TV 上只能靠「再按一次开关」关闭。
最省事的做法是在面板底部加一个显式的「关闭」按钮；或者在 TV 上给 `MenuAnchor` 补一条 `goBack` 的 `DismissIntent` 绑定。

> 两条都做了。原因：`MenuAnchor` 是个 `OverlayPortal` 而**不是路由**，它唯一的关闭绑定是
> `escape: DismissIntent()`（`menu_anchor.dart` 的 `_kMenuShortcuts`）—— 而 TV 上没有 Esc，
> 系统返回键会**穿过浮层直接退页**，于是用户带着一个还开着的面板离开了这一页。
> 所以「显式按钮」管的是「我知道怎么关」，「`PopScope`」管的是「用户按返回时别把面板丢下」，
> 两者不是二选一。⚠️ 另外 `MenuController` 是普通类**不是 `ChangeNotifier`**，
> 打开状态只能用 `MenuAnchor.onOpen` / `onClose` 同步出来。

**P1-3 一屏多看几行海报。** 现在 960×540 只有 1.58 行。把 `childAspectRatio` 从 `2/3` 改成约 `0.8`
（或把卡片文字块压到 1 行），行高从 272 降到约 220 → 能看到 2 行 8 张。

> ⚠️ 动手前先读 §6.0 里「没动海报墙的列数」那一条 —— 这里缩的是**卡片**不是列数，
> 但两者都会改变「一屏看到几张」，得一起算。另外 `_SearchBox` 写死了 `height: 32`，
> 所以放大字号**不能**顺手给媒体库头部套 `tvTextScaler`。

**P1-4 解决「TV 上配不了 / 改不了文字」这一类。** ✅ **已完成，走的是 (c)。**
受影响的有：设置页的 TMDB Key / API 地址 / 图片地址 / 豆瓣 Cookie / OpenSubtitles Api-Key（§5.7 #69/#71/#75）、
详情页的「手动刮削」（#36）、「自定义」（#36a）、「新增类型」（#36b）。
三条路，任选：

- (a) 支持**扫码 / 链接导入配置**：PC 上生成一段配置二维码，TV 扫码导入
  （与现有登录二维码同一套机制，成本最低，且一次能带过全部 key）；
- (b) TV 上把 `TextField` 换成一个「从剪贴板导入」按钮 —— 但 TV 没有剪贴板出口，行不通；
- (c) 承认 TV 不做文字配置，在设置页显式写明「请先在手机/电脑上配置好，再用『备份与同步』同步过来」
  —— 这正好复用已有的 `library_backup_service`。

> 选 (c)：新增 `TvTypingNotice`，只加在**真正需要打字**的两节（「刮削」「在线字幕」），
> 并在「备份与同步」反向写明操作顺序。**实测确认这句话成立**（设置确实跟着备份走），
> 但理由与原方案不同 —— 见 §6.0「P1-4 的三个更正」。
> 另外**全量清点后推翻了原方案对 #36a/#36b 的判断**：
> `CustomizeWorkDialog` 没有年份字段（原方案要改的那个东西不存在），
> `ManualScrapeDialog` 与 `GenreEditDialog` 都已经有免打字路径。
> `lib/` 里 6 个 `TextField` 中，真正无解的只有设置页那 6 个字段。

对 #36a/#36b 还多一条便宜的缓解：**让「下拉 / chip」这类不需要打字的路径覆盖掉大部分场景** ——
`CustomizeWorkDialog` 里已经有 `DropdownButton<MediaCategory>`，把「年份」也做成候选下拉、
「片名」预填现有值并允许只做「清空刮削结果」这一步，就能让 TV 完成「自动刮错了 → 我改回来」的主诉求。

> 更正：`CustomizeWorkDialog` 里**没有**年份输入（只有片名 + 分类下拉），
> 所以「把年份做成候选下拉」这条无对象；而 #36b（`GenreEditDialog`）本来就有一行
> 「常用类型」chip，点 chip 就能加，不必打字。真正该补的是设置页。

**P1-5 播放页的 OSD 交互**（与 P0-2 配套）：OK 键唤出/收起控制栏、控制栏内方向键导航、
30 秒无操作自动收起（TV 通行约定）。

### P2 —— 体验

- **P2-1** 绑数字键 0–9 做「跳转到 N%」。
- **P2-2** 长按 ← / → 加速快退/快进（现在硬件重复 keydown 会一次次跳 10 秒，可用但粗糙）。
- **P2-3** 播放时保持屏幕常亮（`SystemChrome` 或 wakelock），**先真机确认是否必要**。
- **P2-4** TV 上隐藏或改造无意义的东西：`CopyTextButton`（全部）、`SelectableText`（改用普通 `Text`）。
- **P2-5** `flutter_inappwebview` 与 `url_launcher` 在 `lib/` 里**没有任何使用点**（只有 pubspec 声明），
  TV 上更用不到 —— 可考虑移除，减 APK 体积。
- **P2-6** 二维码登录页的二维码从 208 放大到 ≥320（TV 远距离扫码）。
- **P2-7** `ScanPage` 未登录那个 `EmptyState` 没传 `onAction`，「去登录」按钮不渲染（既有缺陷）。

---

## 7. 只有真机能定的 6 件事

文档里凡是我**没能实测**的，都在下面列清楚，别当成已结论：

1. **Android TV 上报的 `MediaQuery.navigationMode` 是 `traditional` 还是 `directional`。**
   这决定 `InkWell._canRequestFocus` 走哪条分支（`ink_well.dart:1287`），也决定「TV 模式」该怎么探测。
2. **libmpv 在各家 TV 芯片上的硬解表现。** `media_kit_libs_android_video` 在 TV 盒子上不一定能走 `mediacodec`，
   可能出现「有声无画」或掉帧 —— 这是播放器层面的事，与 UI 无关，但决定这个版本能不能用。
3. **屏幕常亮 / 屏保。** 播放中 TV 会不会休眠。
4. **遥控器音量键到底到不到应用。** 若走 CEC，应用内音量滑块在 TV 上就是无效控件，应当隐藏。
5. **系统 IME 在 TV 上的实际可用性。** 中文输入到底能不能用、Leanback 键盘长什么样。
6. **焦点缩放到 1.05 后海报墙会不会互相压。** 现在是按 169.5dp 卡片 + 14/18dp 间距推算的，
   真机上要看渲染结果。

---

## 8. 附：本文所有"实测"的来源

| 结论 | 来源 |
|---|---|
| Android 键码 23 → `select`、85/89/90 → 媒体键 | `flutter/lib/src/services/keyboard_maps.g.dart` |
| 方向键 → `DirectionalFocusIntent`、`select/enter/space` → `ActivateIntent` | `flutter/lib/src/widgets/app.dart` `_defaultShortcuts` |
| 焦点遍历会自动滚动到可视区 | `flutter/lib/src/widgets/focus_traversal.dart` `defaultTraversalRequestFocusCallback` → `Scrollable.ensureVisible` |
| ink 特效画在子节点**下面** | `flutter/lib/src/material/material.dart` `_RenderInkFeatures.paint`（先 `inkFeature._paint`，后 `super.paint`） |
| 焦点色默认白色 12% | `flutter/lib/src/material/theme_data.dart:442` + 探针 5 实测 |
| `MenuAnchor` 不是路由、靠 Esc 关 | `flutter/lib/src/material/menu_anchor.dart:69, 330, 411` |
| `Slider` 抢方向键 | 探针 4（0.5 → 0.55） |
| TV 字号/安全边距/焦点指示规范 | `developer.android.com/design/ui/tv`（Typography / Layouts / Focus system） |
| TV Manifest 要求 | `developer.android.com/training/tv/start/start` |
