---
name: player-window-capability
description: 在本项目（cloudcine / 网盘媒体库播放器）里给「独立播放窗口」增加或修改一条能力时使用。独立播放窗口跑在第二个 Flutter 引擎里，碰不到主窗口的 Riverpod 容器，任何新能力都要走跨引擎通道 + 主窗口回调这条五段链路。触发词：播放窗口、独立窗口、跨引擎、跨窗口通道、播放器加功能、字幕、音轨、PlayerWindowApp、player_bridge_host、player_window_bridge、player_protocol、desktop_multi_window。
agent_created: true
---

# 给独立播放窗口加一条能力

## 何时用

要动 `lib/ui/windows/` 下这几个文件里**任何**一个的时候：

| 文件 | 角色 | 跑在哪个引擎 |
| --- | --- | --- |
| `player_window_app.dart` | 播放窗口的全部 UI 与播放器操作 | **子窗口引擎** |
| `player_window_bridge.dart` | 通道名 / 方法名 / 两侧的 handler | 两侧共用（纯 Dart） |
| `player_protocol.dart` | 跨引擎传输的数据结构 | 两侧共用（纯 Dart） |
| `player_bridge_host.dart` | 主窗口侧的「服务台」，装回调 | 主窗口引擎 |

也包括：给播放窗口加菜单、加设置项、加需要凭证/仓储/HTTP 的操作、加新的原生插件。

## 心智模型：两个引擎，两种能力

```
主窗口引擎                          子窗口引擎
├─ Riverpod 容器                     ├─ 没有容器，没有 ref
├─ 仓储 / 适配器 / 凭证 / HTTP        ├─ 有 Player（media_kit）
├─ 设置库（异步读）                   ├─ 有 UI、有 Focus、有窗口尺寸
└─ 通道 handler（服务台）      ⇄      └─ 通道 handler（只处理协议层方法）
```

**判断一条能力放哪边**：需要**凭证、仓储、HTTP 客户端、设置库**的 → 主窗口；需要**播放器实例、UI 状态**的 → 子窗口。绝大多数能力是**两边都要**，这正是下面五段链路存在的原因。

⚠️ 子窗口**刻意不背** `fast_gbk` / drift / 夸克适配器这些依赖。不要为了图省事把主窗口的依赖搬进播放窗口 —— 那会让子窗口引擎的启动变慢、依赖面变大，而且沙箱与插件注册的坑会翻倍。

## 五段链路（照顺序改，缺一段就是「功能没做」）

### 第 1 段 · `player_protocol.dart` —— 定义数据形状

- 数据类一律 `@immutable`，带 `toJson()` 和 `static fromJson(Object?)`。
- **`fromJson` 必须容错**：解不开时返回 `null`（或一个 `isEmpty` 的空对象），**不许抛**。跨引擎传过来的东西不保证是你想的那形状，抛出去只会变成一个没头没尾的 `PlatformException`。参考 `SubtitleSearchRequest.fromJson`。
- **空 vs 失败要能区分**：`List` 返回 `[]` 表示「确实没有」，`null` 或抛异常表示「这次没成」。这两者混了以后用户会把「Key 没配对」读成「这部片没字幕」，排查方向完全相反。
- 传**文本**不传字节：解码要在有 `fast_gbk` 的那一侧做（主窗口）。

### 第 2 段 · `player_window_bridge.dart` —— 通道名、方法名、全局回调

- 方法名加到 `PlayerBridgeMethod`（`abstract final class`，全是 `static const String`）。**主窗口和播放窗口各写一份字符串是这个文件要消灭的东西。**
- 回调声明成**可空的顶层全局变量**，形如：

  ```dart
  Future<String?> Function(String fileId)? onFetchSubtitleText;
  ```

  必须是可空的：这个文件在 `main()` 阶段就被用到，那时还没有 Riverpod 容器。填回调是第 4 段的事。

- 在 `handlePlayerWindowCall` 里加 `case`。骨架固定是：

  ```dart
  case PlayerBridgeMethod.xxx:
    final arg = XxxRequest.fromJson(call.arguments);
    if (arg == null) { diag.warn('窗口', '收到解不开的 xxx 请求，忽略'); return null; }
    final handler = onXxx;
    if (handler == null) { diag.warn('窗口', '播放窗口要 xxx，但没有装上回调'); return null; }
    return await handler(arg);
  ```

- **`handler == null` 的分支一定要有，而且日志级别要想清楚**：正常运行时它**不该出现**（第 4 段一定会装上），出现即说明启动路径被改坏了 → 用 `diag.warn`。但如果是高频回调（如每 10 秒一次的进度回报），用 `diag.warn` 会刷屏 → 用 `diag.debug`。
- **要不要 `catch`？看语义**：
  - 「失败 = 没有」的（取字幕正文、刷新直链）→ **不要抛**，在 host 里 `catch` 掉返回 `null`，主窗口日志写清原因。抛出去对面只能看到一句没头没尾的异常。
  - 「失败 = 用户需要知道为什么」的（在线搜索）→ **不要 catch，原样穿出去**，但必须按下面第 3 段转成 `PlatformException`。
- 别忘了 `ref.onDispose` 里把新回调置 `null`（第 4 段）。

### 第 3 段 · 错误形状 —— 跨引擎通道只认识 `PlatformException`

**这是最容易踩、症状最误导人的一条。**

链路：Dart A 抛异常 → 框架按 `code`/`message`/`details` 三段编码 → 原生转成 `FlutterError` → 引擎 B 抛 `PlatformException` → `desktop_multi_window` 包成 `WindowChannelException`。

**别的异常形状到了对面会退化成 `code='error'` + `message=<整段 toString>`**，于是用户看到的提示是：

```
OpenSubtitlesException(notConfigured, 还没填 OpenSubtitles 的 Api-Key…)
```

一句本该很干净的话被包了一层内部类型名。所以主窗口侧必须**显式翻译**：

```dart
PlatformException _asChannelError(OpenSubtitlesException e) => PlatformException(
      code: 'opensubtitles/${e.failure.name}',  // 机器可读，只进日志
      message: e.message,                        // 能直接显示给用户的中文
      details: e.statusCode,
    );
```

拆分口径：`code` 给日志（`opensubtitles/badApiKey` 这种），`message` 给人看。子窗口拿到 `WindowChannelException` 后把 `message` 直接显示出来。

### 第 4 段 · `player_bridge_host.dart` —— 在主窗口把回调装上

- 新回调写进 `playerBridgeHostProvider`，并在 `ref.onDispose` 里置 `null`。
- **依赖现造现用，别做成 Provider**：如果这条能力依赖设置库里的配置（如 Api-Key），而读库是异步的，做成同步 Provider 就得在启动阶段阻塞读一次、设置改了还不同步。低频操作（用户手动点一次）每次读一遍设置没有代价。参考 `openSubtitlesOf(ref)`。
- 回调的**返回值语义要在 doc 注释里写死**，尤其是 `null` 的含义（是「取不到」还是「成功但为空」）。
- **这里不 catch 那类「要显示原因」的异常** —— 见第 3 段。但同时要在 host 里补一条 `diag.warn`，否则日志里查不到。

### 第 5 段 · `player_window_app.dart` —— 播放窗口侧的 UI 与状态

- 状态字段加 `_xxx`，`List` 类的一律 `const []` 初始化。
- **清空时机按 `itemId` 变化判，不是「又来了一条请求」**：

  ```dart
  if (_currentRequest?.itemId != request.itemId) {
    _xxx = const [];
    _activeXxxId = null;
  }
  ```

  ⚠️ 这个坑踩过：直链刷新也会走到 `_adoptRequest`，按「又来了一条请求」清空会让用户点一次「重试」就把选好的字幕丢掉。

- 用 `while` 循环 + 抽出来的 `_promptXxxChoice()` 处理「打开菜单 → 用户选了某个动作 → 动作完成后重开菜单」这类交互。**不要**在 `while` 循环体里 `await` 之后再用 `dialogContext` —— 会撞 `use_build_context_synchronously`。把弹菜单抽成独立方法、循环体只 `await` 它的返回值就没这问题。
- `switch` 处理用户选择时**穷举所有枚举值，不写 `default`** —— 将来加一个来源时编译器会提醒你。
- 播放器订阅用 `_ensurePlayer()` 里那两条：`player.stream.tracks`（有哪些轨）和 `player.stream.track`（**哪条是选中态 —— 这是唯一真相**）。UI 上画勾要靠后者，不要靠自己的状态变量。

## 键盘快捷键：两个播放器各有一份键位表

`player_page.dart`（内置播放页）和 `player_window_app.dart`（独立窗口）**各有一份**。macOS 上点播放走的是**后者**。只改一个 = 用户看到「功能没做」。

硬规则（改键位表前先看）：
- `Focus(autofocus: true)` 必须有，否则收不到键。
- 控制栏整块 `ExcludeFocus`，否则按钮会抢走空格/方向键。
- 诊断页要换一张只含 Esc 的表（那里不该有播放快捷键）。
- 跳转一律过 `clampSeekTarget`。

## 原生侧（只在需要新插件或新权限时）

1. **`pubspec.yaml`** 加依赖。选插件时优先 `flutter/packages` 下的官方包（如 `file_selector` 而不是 `file_picker`）。
2. **两份 entitlements 都要改**（`macos/Runner/DebugProfile.entitlements` 和 `Release.entitlements`）。macOS 沙箱下权限缺失的表现是「功能静默失效」或「报错完全不指向权限」。
   - 发网络请求 → `com.apple.security.network.client`
   - 读用户选中的文件 → `com.apple.security.files.user-selected.read-only`
   - ⚠️ 沙箱下拿到的路径**不是**持久 bookmark，下次启动就失效。要跨启动保留路径得自己做 security-scoped bookmark。
3. **`pod install` 在本机必须先设 locale**（项目路径含中文）：

   ```bash
   cd macos && LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pod install
   ```

   不设的话崩在 `Unicode Normalization not appropriate for ASCII-8BIT (Encoding::CompatibilityError)`，栈顶是 `cocoapods/config.rb` 的 `installation_root`。看着像 CocoaPods 坏了，其实只是 locale。

4. **加了新原生插件 → 必须重启 `flutter run`**。`r` 热重载不够，插件注册只在引擎启动时做一次。改完告诉用户重启。

## 测试配方

跨引擎通道**可以在单测里测**（纯 Dart，不需要真起两个引擎）：

1. **协议编解码** → `test/ui/windows/player_protocol_test.dart`。重点测：正常往返、**解不开时返回 null/空对象而不抛**、空 vs 失败的区分。
2. **两侧 handler** → `test/ui/windows/player_window_bridge_test.dart`。直接 `await handlePlayerWindowCall(MethodCall(...))`。重点测：参数缺失、回调没装、失败时的形状（该抛的抛、该返回 null 的返回 null）。**`_resetGlobals` 里要把新回调也清掉**，否则测试之间互相污染。
3. **纯函数**（文案、查询条件拼装）→ 单独文件。`track_labels.dart` 这类「文案生成」也要测，因为它是用户唯一能看到的东西。
4. **菜单 / 对话框 UI 层能测**，但要先开一个口子 → `test/ui/windows/player_track_menus_test.dart`。
   见下一节。

## 测菜单 / 对话框：先开 `@visibleForTesting` 入口

`Player()` 在 `flutter test` 里**建不出来**（`Cannot find Mpv.framework … in the Frameworks folder`，
测试跑在宿主 Dart VM 上，libmpv 不在 rpath 里）。于是控制栏上那两个入口
（`_player == null ? null : …`）**永远是禁用的** —— 弹菜单那条路径在测试里不可达，
不管怎么 pump 都点不开。

做法：在 `player_window_app.dart` 里为每个私有菜单类开一个 `@visibleForTesting` 的
构造入口，直接 new 出来渲染。

```dart
@visibleForTesting
Widget buildSubtitleMenuForTest({ /* 每个字段一个具名参数，都给默认值 */ }) =>
    _SubtitleDialog(/* … */);
```

然后测试里把它挂进一个**真的 Navigator** 再渲染（菜单每一行都以
`Navigator.of(context).pop(…)` 收尾，没有 Navigator 就会在点下去那一刻抛）：

```dart
await tester.pumpWidget(MaterialApp(
  key: UniqueKey(),          // ← 见下面的坑
  theme: AppTheme.dark(),
  home: Builder(builder: (context) => Scaffold(body: TextButton(
    onPressed: () async { popped = await Navigator.of(context).push<Object>(
      DialogRoute<Object>(context: context, builder: (_) => menu)); },
    child: const Text('打开'),
  ))),
));
```

三个实测踩到的坑：

- ⚠️ **同一个用例里第二次 `pumpWidget` 必须换根 key。** `pumpWidget` 遇到**同类型**的根组件是
  「原地更新」而不是重建，Navigator 连同栈上那条还没关掉的 `DialogRoute` 会留下来 ——
  表现是「打开」按钮被上一个菜单盖住，`tap()` 报
  `derived an Offset … that would not hit test`。`key: UniqueKey()` 一行解决。
- ⚠️ **窗口要开大**（`tester.view.physicalSize = const Size(900, 1600)`）。字幕菜单满配 14 行，
  默认 800×600 会让 `AlertDialog` 内容溢出，而溢出在测试里是**报错**，直接把用例带崩。
- ⚠️ **读文案要限定在 `AlertDialog` 里**（`find.descendant(of: find.byType(AlertDialog), …)`），
  否则会把测试脚手架自己那个「打开」按钮也读进来。

菜单 pop 出来的是**私有类型**（`_SubtitleChoice`），测试库写不出它的名字。但它的**成员名是公开的**
（`kind` / `fileId` / `trackId` / `localPath`），所以 `(choice as dynamic).kind` 取得到 ——
只读、不构造，既能钉住「pop 了什么」又不用为测试把类型公开。

值得钉住的断言（都是**改错不报错**的规则）：

- 有外挂字幕挂着时**内嵌轨一律不打勾**（mpv 认不出后挂的是哪一条，轨号可能正好撞上）。
- 「关闭字幕」永远第一项；`_nothingActive` 要四个来源一起判（漏判 `activeLocalPath`
  → 本地字幕在生效、勾却打在「关闭字幕」上）。
- 每个来源各点一次，核对 pop 回去的 `kind` + 关键字段（漏一种来源 = 「点了没反应」）。
- 搜索中：文案变「搜索中…」且 `onTap == null`（连点会把额度连着花掉）。

断言要写**「为什么这条规则重要」**，不要只写「返回了 X」：

```dart
test('解不开的 JSON 返回 null 而不是抛 —— 抛出去会变成一句没头没尾的 PlatformException', () { … });
test('搜索失败抛异常、搜不到返回空列表 —— 混了以后用户会把「Key 没配对」读成「这部片没字幕」', () { … });
```

## 验证（每次改完都跑）

```bash
cd /Users/tandy/workbuddy-ai/网盘媒体库播放器

# ⚠️ NO_PROXY 必须带，否则报 Unable to connect to flutter_tester process
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost flutter test

flutter analyze
```

⚠️ 改 `lib/data/db/tables.dart` 的列之后，先跑 `flutter pub run build_runner build` 再测。
⚠️ 看不懂的编译错误先**重跑一次** —— 这个项目常有并发编辑，第二次就没了。别动手「修」一个不存在的错误。
⚠️ Bash 里 `grep` 中文关键词不可靠（在本项目实测返回空但实际有 46 处）。搜中文用 Grep 工具，别用 `grep` 命令。

## 反例清单（这些做法都是错的）

- ❌ 在 `player_window_app.dart` 里直接 `ref.read(...)` —— 子窗口没有容器，编译就过不去。
- ❌ 让子窗口自己去请求夸克直链 —— 缺 Cookie 一律 412，且凭证不该出现在子窗口。
- ❌ 用 `controller.invokeMethod` 推播放请求 —— 那是**单向**通道，要求子窗口先 `setWindowMethodHandler`。用 `playerWindowChannel`（bidirectional）。
- ❌ 用 `unidirectional` 通道模式 —— 那会让任何第三个窗口都能打进来。`bidirectional` 的「最多两个引擎」限制正好是「主窗口 + 一个播放窗口」的形状。
- ❌ 抛自定义异常类型过通道 —— 到对面只剩 `code='error'` + 一整段 `toString`。
- ❌ 按「又来了一条请求」清空 UI 状态 —— 直链刷新也走那条路，会把用户选好的东西丢掉。
- ❌ 只改一个播放器的键位表 —— macOS 上点播放走的是独立窗口那份。
