import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';

import '../../data/db/settings_store.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/entities/quality_option.dart';
import '../../domain/entities/subtitle_track.dart';
import '../../domain/services/playback_controller.dart';
import '../../domain/services/playback_exit_policy.dart';
import '../providers/app_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/anchored_menu.dart';
import '../widgets/buffered_slider.dart';
import '../widgets/common_widgets.dart';

/// 遥控器 / 键盘上某个键，在当前上下文里该触发什么。
///
/// 抽成**纯函数**是为了可单测 —— 这套路由最典型的故障是「键名写错」：
/// Android TV 遥控器的中心 OK 键键码是 23，映射到
/// `LogicalKeyboardKey.select`，**不是 `enter`、也不是 `space`**。
/// 写错的后果是「按了没反应」，既不报错也不崩溃，只有断言能钉住它。
enum RemoteKeyAction {
  playPause,
  seekBack,
  seekForward,

  /// 沉浸模式下：把控制栏叫回来。
  ///
  /// TV 上**没有 Esc**，不补这条的话沉浸模式就是一间单向门。
  showControls,

  /// 非沉浸模式下按 Esc：退出播放页。
  pop,

  /// 放行给焦点系统（移动焦点、激活按钮）。
  ignored,
}

/// 遥控器上「我们认识的」键。
///
/// ⚠️ 只能是 `final` 不能是 `const`：`LogicalKeyboardKey` 重写了 `==`，
/// 而常量集合的元素要求原生相等（`const_set_element_not_primitive_equality`）。
final Set<LogicalKeyboardKey> _remoteKeys = {
  LogicalKeyboardKey.select,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.space,
  LogicalKeyboardKey.escape,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.mediaPlayPause,
  LogicalKeyboardKey.mediaRewind,
  LogicalKeyboardKey.mediaFastForward,
};

/// 决定一个按键该干什么。
///
/// [stageFocused] = 焦点是否**真的落在画面上**（而不是某个按钮 / 菜单 / 遮罩上）。
/// 这个参数是整套 TV 交互的关键：
///   * 焦点在画面上 → OK = 播放/暂停、←/→ = 快退/快进；
///   * 焦点在按钮上 → 这三个键必须 `ignored`，交回焦点系统去「激活按钮 / 换焦点」。
/// 不区分的话，OK 会**既暂停又点按钮**，而 ←/→ 会**既快退又不换焦点**。
RemoteKeyAction resolveRemoteKey({
  required LogicalKeyboardKey key,
  required bool immersive,
  required bool stageFocused,
}) {
  // 沉浸模式优先：任何认识的键，第一下都用来把控制栏叫回来。
  if (immersive && _remoteKeys.contains(key)) {
    return RemoteKeyAction.showControls;
  }

  // 这几个不挑焦点在哪：遥控器 / 键盘上的专用键，在任何位置都该生效。
  switch (key) {
    case LogicalKeyboardKey.mediaPlayPause || LogicalKeyboardKey.space:
      return RemoteKeyAction.playPause;
    case LogicalKeyboardKey.mediaRewind:
      return RemoteKeyAction.seekBack;
    case LogicalKeyboardKey.mediaFastForward:
      return RemoteKeyAction.seekForward;
    case LogicalKeyboardKey.escape:
      return RemoteKeyAction.pop;
  }

  // 焦点不在画面上时，OK 与方向键都属于焦点系统。
  if (!stageFocused) return RemoteKeyAction.ignored;

  switch (key) {
    case LogicalKeyboardKey.select || LogicalKeyboardKey.enter:
      return RemoteKeyAction.playPause;
    case LogicalKeyboardKey.arrowLeft:
      return RemoteKeyAction.seekBack;
    case LogicalKeyboardKey.arrowRight:
      return RemoteKeyAction.seekForward;
  }

  // ↑/↓ 一律放行：「从画面往下走到控制栏」靠的就是焦点遍历本身。
  return RemoteKeyAction.ignored;
}

/// 控制栏是否该在无操作超时后自动收起（进入沉浸）。
///
/// 抽成**纯函数**是为了可单测 —— 「什么时候藏」一旦散在定时器回调里，
/// 就会随按钮越来越多而漂移，且无法断言。判据（TV 遥控器通行约定）：
///   * 已经沉浸（控制栏已藏）→ 不用再藏；
///   * **暂停**时用户多半是停下来读字幕 / 调设置 → 藏了等于把正看的东西
///     盖掉，宁可不藏；
///   * 焦点不在画面上（进了控制栏按钮 / 字幕菜单）→ 用户正在操作，藏了
///     等于把控件从手底下抽走。
///
/// 注意它只看「能不能藏」，不看「过了多少秒」—— 超时由调用方的定时器负责。
bool shouldAutoHideControls({
  required bool immersive,
  required bool playing,
  required bool stageFocused,
}) =>
    !immersive && playing && stageFocused;

/// 播放页。
///
/// ## 为什么播放页要自己把数据装一遍
///
/// 它接收的是 **itemId 而不是 `MediaItem` 对象**。看起来多绕一步，换来两件事：
///   1. 深链接 / 热重载后页面能自己恢复（对象传参会丢）；
///   2. 「播放」这件事的**全部前置条件**（字幕引用、默认清晰度、音量倍速、
///      是否自动加载字幕）都从库里现读，不会因为调用方忘了传某个参数
///      而静默用默认值。
///
/// ## 控制栏为什么是自绘的
///
/// `media_kit_video` 自带一套 `AdaptiveVideoControls`，但它**不认识清晰度** ——
/// 网盘的清晰度是服务端转码梯度，mpv 侧只是换了一条 URL，对播放器来说
/// 就是「同一个文件」。清晰度菜单、字幕来源标注（网盘/内嵌）、
/// 音轨语言名这些都必须我们自己画。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key, required this.itemId, this.qualityId});

  final String itemId;

  /// 指定要播的清晰度档位（从详情页点某一档进来时用）。`null` = 用设置里的默认。
  final String? qualityId;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  MediaItem? _item;
  String? _loadError;
  bool _ready = false;

  /// 在 `initState` 就抓住控制器，而不是等到 `dispose` 再 `ref.read`。
  ///
  /// 页面销毁时再去读 provider 属于「已经要走的人还回头翻抽屉」：
  /// provider 可能已经被销毁，行为不确定。
  late final PlaybackController _controller;

  /// 沉浸模式：隐藏顶栏与控制栏，只剩画面。
  bool _immersive = false;

  /// 画面区的焦点节点 —— 遥控器适配的核心判据。
  ///
  /// `hasPrimaryFocus` 回答的是「遥控器现在指的是画面，还是指某个按钮」。
  /// 只有焦点真的落在画面上时，OK 键才该是「播放/暂停」、←/→ 才该是「快退/快进」；
  /// 焦点一旦进到控制栏的按钮上，这两个键必须**放行**给焦点系统 ——
  /// 否则 OK 会既暂停又点按钮，←/→ 会既快退又不换焦点。
  final FocusNode _stageNode = FocusNode(debugLabel: 'player-stage');

  /// 无操作收起控制栏（进入沉浸）的定时器。
  ///
  /// TV 通行约定是「遥控器静置一会儿就只剩画面」；但**每次按键都重置它** ——
  /// 用户正找按钮时把控件藏起来是最糟的时机。真机上这条行为肉眼可见，所以
  /// 它的判据抽成了 [shouldAutoHideControls]，定时器只负责倒计时。
  Timer? _idleHideTimer;

  /// 控制栏无操作后收起的时间。30 秒是 TV 的主流约定（足够读完一行字幕，
  /// 又不会让用户觉得「按了没反应」—— 因为唤回只要任意一键）。
  static const Duration _controlsIdleTimeout = Duration(seconds: 30);

  /// 拖动进度条时的临时值。拖动过程中不能让 `position` 流把滑块拽回去。
  double? _dragFraction;

  /// 当前音轨 id。页面自己记：mpv 的 `tracks` 流只给列表，不给「当前选中」。
  String? _audioId;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(playbackControllerProvider);
    // 播放状态一变就重算收起倒计时（见 [_onPlayStateChanged]）。
    _controller.addListener(_onPlayStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  /// 播放状态一变就重算收起倒计时：开始播 → 挂上；暂停 / 停止 → 撤掉
  /// （暂停时用户多半在读数 / 调设置，藏控制栏会把正看的东西盖掉）。
  void _onPlayStateChanged() {
    if (_controller.isPlaying) {
      _scheduleControlsHide();
    } else {
      _cancelIdleHide();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onPlayStateChanged);
    //   - 桌面：保留播放（可以一边浏览一边听）；
    //   - Android / Android TV：停止并释放解码器 —— 页面都走了，不该还占着
    //     4K 解码器与网络连接，而那边也没有通知栏控件能停它。
    //
    // 挂在 `dispose` 而不是「返回按钮」上：返回按钮、系统返回键、手势返回、
    // 以及从播放页跳到别的路由，全都经过这里 —— 只有一个入口，
    // 不会漏掉某条退出路径。
    if (PlaybackExitBehavior.forPlatform(defaultTargetPlatform) ==
        PlaybackExitBehavior.stopAndRelease) {
      unawaited(_controller.stop());
    }
    _cancelIdleHide();
    _stageNode.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final repo = ref.read(mediaRepositoryProvider);

    final item = await repo.itemById(widget.itemId);
    if (!mounted) return;
    if (item == null) {
      setState(() => _loadError = '找不到这个媒体项。可能它已被重新扫描移除，'
          '或链接是从旧版本的应用里带过来的。');
      return;
    }

    // 字幕引用（扫描期建的，不含正文）与设置一起读。
    final subtitles = await repo.subtitlesForItem(item.id);
    final settings = ref.read(settingsStoreProvider);
    final values = await settings.readAll(const [
      SettingKeys.defaultQuality,
      SettingKeys.autoLoadSubtitles,
      SettingKeys.playerVolume,
      SettingKeys.playerRate,
    ]);
    if (!mounted) return;

    final preferred =
        widget.qualityId ?? _nonEmpty(values[SettingKeys.defaultQuality]);
    // 默认 **true**：绝大多数片子都有中文字幕，默认加载省一次点击；
    // 没有字幕时 `_autoLoadSubtitle` 会安静地什么都不做。
    final autoSub = values[SettingKeys.autoLoadSubtitles] != 'false';
    final volume = double.tryParse(values[SettingKeys.playerVolume] ?? '') ?? 100;
    final rate = double.tryParse(values[SettingKeys.playerRate] ?? '') ?? 1.0;

    final controller = _controller;
    await controller.setVolume(volume);
    await controller.setRate(rate);

    setState(() {
      _item = item;
      _ready = true;
    });

    await controller.open(
      item,
      subtitles: subtitles,
      preferredQualityId: preferred,
      autoLoadSubtitles: autoSub,
    );
  }

  static String? _nonEmpty(String? v) =>
      (v == null || v.trim().isEmpty) ? null : v.trim();

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(playbackControllerProvider);

    return Scaffold(
      backgroundColor: AppTheme.cinema,
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => Focus(
          // 这一层**只为收按键**存在，自己不参与焦点遍历。
          // 放在最外层，是为了让焦点无论在画面还是在控制栏，按键都能冒泡到这里。
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _onRemoteKey,
          child: Column(
            children: [
              // 顶栏保持 `ExcludeFocus`：它那两个按钮遥控器都不需要 ——
              // 返回有遥控器自己的 BACK 键（由 Activity 处理，不走 Flutter 的按键通道），
              // 沉浸模式是桌面鼠标的用法，TV 上不该让焦点先停在这里。
              if (!_immersive) ExcludeFocus(child: _buildTopBar(controller)),
              Expanded(
                child: Focus(
                  focusNode: _stageNode,
                  autofocus: true,
                  child: _buildStage(controller),
                ),
              ),
              if (!_immersive) _remoteReachable(_buildControlBar(controller)),
            ],
          ),
        ),
      ),
    );
  }

  /// 控制栏在 TV 上必须能被遥控器走到；桌面上维持「纯鼠标控件」。
  ///
  /// 桌面端继续 `ExcludeFocus` 是有实测理由的，见 [_buildControlBar] 里
  /// 进度条滑块那处注释：焦点一旦落到滑块上，←/→ 就被滑块吃掉，
  /// 用户只要点过一次进度条就再也跳不了 10 秒。**只在 Android 上放开。**
  Widget _remoteReachable(Widget child) =>
      defaultTargetPlatform == TargetPlatform.android
          ? child
          : ExcludeFocus(child: child);

  /// 遥控器 / 键盘按键 → 播放动作。
  ///
  /// 路由判断本身在 [resolveRemoteKey]（纯函数，可单测），这里只负责执行。
  ///
  /// ## 为什么不用 `CallbackShortcuts`
  ///
  /// 它命中就一律报 `handled`。于是「焦点在控制栏里按 ←/→」会被它抢走，
  /// 焦点**永远**在按钮之间挪不动 —— 而 TV 上挪不动焦点就等于选不了字幕和清晰度。
  /// `Focus.onKeyEvent` 能返回 `ignored` 把按键交还给焦点系统，
  /// 这是「同一个键，在画面上是快退、在控制栏里是移动焦点」唯一能落地的写法。
  KeyEventResult _onRemoteKey(FocusNode node, KeyEvent event) {
    // 长按要能连续快退/快进，所以 `KeyRepeatEvent` 也要处理。
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    // 任意一次按键都算「用户还在」—— 重置收起倒计时。放在路由判断之前，
    // 这样连「放行给焦点系统」的方向键（↑/↓）也会重置，而不是只有播放 /
    // 快退才重置（否则用户在控制栏里找按钮时，倒计时照样到点把控件藏掉）。
    _scheduleControlsHide();

    final action = resolveRemoteKey(
      key: event.logicalKey,
      immersive: _immersive,
      stageFocused: _stageNode.hasPrimaryFocus,
    );

    switch (action) {
      case RemoteKeyAction.playPause:
        _controller.playOrPause();
      case RemoteKeyAction.seekBack:
        _controller.seekRelative(const Duration(seconds: -10));
      case RemoteKeyAction.seekForward:
        _controller.seekRelative(const Duration(seconds: 10));
      case RemoteKeyAction.showControls:
        // 唤回控制栏：倒计时从头算，给用户足够时间看清再决定下一步。
        setState(() => _immersive = false);
        _scheduleControlsHide();
      case RemoteKeyAction.pop:
        context.pop();
      case RemoteKeyAction.ignored:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// 看过 30 秒无操作就收起控制栏（进入沉浸）。
  ///
  /// 超时那一刻再判一次 [shouldAutoHideControls]：倒计时期间用户可能把焦点
  /// 挪进了控制栏按钮或字幕菜单，这时藏掉等于把控件从手底下抽走；
  /// 也可能按了暂停正读字幕 —— 两种都不该藏。
  void _scheduleControlsHide() {
    // 桌面 / 手机上「控制栏一直可见」是更让人安心的默认 —— 这条只服务于
    // TV 遥控器「静置即只剩画面」的约定，所以非 TV 一律不挂定时器。
    if (!AppTheme.isTvLayout(context)) return;

    _idleHideTimer?.cancel();
    _idleHideTimer = Timer(_controlsIdleTimeout, () {
      // 窗口可能已经在倒计时里关了。
      if (!mounted) return;
      if (shouldAutoHideControls(
        immersive: _immersive,
        playing: _controller.isPlaying,
        stageFocused: _stageNode.hasPrimaryFocus,
      )) {
        setState(() => _immersive = true);
      }
    });
  }

  void _cancelIdleHide() {
    _idleHideTimer?.cancel();
    _idleHideTimer = null;
  }

  // -------------------------------------------------------------------
  // 顶栏
  // -------------------------------------------------------------------

  Widget _buildTopBar(PlaybackController controller) {
    final item = _item;
    return Container(
      height: 48,
      color: AppTheme.cinema,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => context.pop(),
            iconSize: 18,
            tooltip: '返回',
            icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.text),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item?.displayTitle ?? '加载中…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.text,
                  ),
                ),
                if (item != null)
                  Text(
                    item.technicalSummary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10.5, color: AppTheme.dim),
                  ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _immersive = true),
            iconSize: 17,
            tooltip: '沉浸模式（Esc 退出）',
            icon: const Icon(Icons.fullscreen_rounded, color: AppTheme.muted),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------
  // 画面
  // -------------------------------------------------------------------

  Widget _buildStage(PlaybackController controller) {
    final loadError = _loadError;
    if (loadError != null) {
      return EmptyState(
        icon: Icons.link_off_rounded,
        danger: true,
        title: '打不开这个视频',
        body: loadError,
        actionLabel: '返回',
        onAction: () => context.pop(),
      );
    }

    final error = controller.error;
    final notice = controller.notice;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (_ready)
          Video(
            controller: controller.videoController,
            // 自绘控制栏（见类文档）。
            controls: (_) => const SizedBox.shrink(),
            fill: AppTheme.cinema,
            subtitleViewConfiguration: const SubtitleViewConfiguration(
              style: TextStyle(
                fontSize: 30,
                height: 1.35,
                color: Colors.white,
                fontWeight: FontWeight.w500,
                backgroundColor: Color(0x99000000),
              ),
              padding: EdgeInsets.fromLTRB(24, 0, 24, 44),
            ),
          )
        else
          const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),

        if (controller.isBuffering && error == null)
          const Center(
            child: SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),

        if (error != null)
          _ErrorOverlay(
            message: error,
            onRetry: controller.retry,
            onBack: () => context.pop(),
          ),

        // 非致命提示：**贴顶的小条，不盖画面**。
        // 「这条字幕没挂上」「这一档服务端没给地址」都不该让用户看不到视频。
        if (notice != null && error == null)
          Positioned(
            top: 14,
            left: 0,
            right: 0,
            child: Center(
              child: _NoticePill(
                message: notice,
                onDismiss: controller.clearNotice,
              ),
            ),
          ),

        // 沉浸模式下点画面任意处切回普通模式 —— 否则用户会「进去出不来」。
        if (_immersive)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                setState(() => _immersive = false);
                _scheduleControlsHide();
              },
            ),
          ),
      ],
    );
  }

  // -------------------------------------------------------------------
  // 控制栏
  // -------------------------------------------------------------------

  /// 控制栏。
  ///
  /// ⚠️ **两条滑块必须 `ExcludeFocus`**，这不是装饰。滑块自带方向键处理 ——
  /// 实测（Flutter 3.29）把焦点给一个 `value: 0.5` 的滑块再按 →，
  /// 它的值会变成 `0.55`：方向键根本轮不到播放器。用户只要点过一次进度条，
  /// ← / → 就再也不是「跳 10 秒」了。
  ///
  /// 为什么不是**整条控制栏** `ExcludeFocus`（原来的写法）：那样遥控器就
  /// **够不到任何控件**，TV 上等于没有暂停、没有清晰度、没有字幕。
  /// 精确地把滑块摘出焦点链、按钮留给遥控器，两边才都满足。
  /// 关掉聚焦**不影响鼠标**：点击与拖拽走手势层，不经过焦点。
  Widget _buildControlBar(PlaybackController controller) {
    final duration = controller.duration;
    final position = controller.position;
    final fraction = _dragFraction ??
        (duration.inMilliseconds <= 0
            ? 0.0
            : (position.inMilliseconds / duration.inMilliseconds)
                .clamp(0.0, 1.0));

    return Container(
      height: AppTheme.playerBarHeight,
      color: AppTheme.cinema,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Text(
                _fmt(position),
                style: AppTheme.mono.copyWith(color: AppTheme.muted),
              ),
              Expanded(
                child: ExcludeFocus(
                  child: BufferedSlider(
                    value: fraction,
                    // 「已经缓存到这儿了」那一层。时长未知时是 null（不画）。
                    //
                    // ⚠️ 用的是**真实播放头**，不是 [_dragFraction]：拖拽只是预览，
                    // mpv 的缓存并不会跟着预览值走，按预览算会画出一段假的缓冲。
                    buffered: controller.bufferedFraction,
                    onChangeStart: (v) => setState(() => _dragFraction = v),
                    onChanged: (v) => setState(() => _dragFraction = v),
                    onChangeEnd: (v) {
                      setState(() => _dragFraction = null);
                      unawaited(controller.seekToFraction(v));
                    },
                  ),
                ),
              ),
              Text(
                _fmt(duration),
                style: AppTheme.mono.copyWith(color: AppTheme.dim),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                onPressed: controller.playOrPause,
                iconSize: 22,
                tooltip: controller.isPlaying ? '暂停（空格）' : '播放（空格）',
                icon: Icon(
                  controller.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: AppTheme.text,
                ),
              ),
              IconButton(
                onPressed: () =>
                    controller.seekRelative(const Duration(seconds: -10)),
                iconSize: 17,
                tooltip: '后退 10 秒（←）',
                icon: const Icon(Icons.replay_10_rounded, color: AppTheme.muted),
              ),
              IconButton(
                onPressed: () =>
                    controller.seekRelative(const Duration(seconds: 10)),
                iconSize: 17,
                tooltip: '前进 10 秒（→）',
                icon: const Icon(
                  Icons.forward_10_rounded,
                  color: AppTheme.muted,
                ),
              ),
              const SizedBox(width: 6),

              // 音量
              IconButton(
                onPressed: () => unawaited(
                  controller.setVolume(controller.volume > 0 ? 0 : 100),
                ),
                iconSize: 16,
                tooltip: controller.volume > 0 ? '静音' : '取消静音',
                icon: Icon(
                  controller.volume <= 0
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                  color: AppTheme.muted,
                ),
              ),
              // 音量滑块同样 `ExcludeFocus`（理由见方法头）。TV 上音量交给
              // 电视自己的音量键，遥控器只需要那个静音按钮。
              SizedBox(
                width: 84,
                child: ExcludeFocus(
                  child: Slider(
                    value: controller.volume.clamp(0, 100),
                    max: 100,
                    onChanged: (v) => unawaited(controller.setVolume(v)),
                  ),
                ),
              ),

              const Spacer(),

              _QualityMenu(controller: controller),
              _SubtitleMenu(controller: controller),
              _AudioMenu(
                controller: controller,
                activeId: _audioId,
                onSelected: (id) => setState(() => _audioId = id),
              ),
              _RateMenu(controller: controller),
            ],
          ),
        ],
      ),
    );
  }

  /// `1:02:03` / `02:03`
  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

// ---------------------------------------------------------------------------
// 菜单
// ---------------------------------------------------------------------------

/// 打开一个「贴着 [buttonContext] 正上方划出」的菜单。
///
/// 摆位与动画都在 [showAnchoredMenu] 里；这里只负责「量按钮坐标 → 推浮层 →
/// 把选中的值交给 [onSelected]」这套重复了四遍（画质 / 字幕 / 音轨 / 倍速）的活。
///
/// 不用 `PopupMenuButton`：位置由它自己挑，而我们要的是**固定贴着按钮正上方**
/// 划出来 —— 跟独立窗口播放器（`player_window_app.dart`）一套观感。
Future<void> _openAnchoredMenu<T>({
  required BuildContext buttonContext,
  required String title,
  required List<Widget> Function(
    BuildContext context,
    void Function(T value) select,
  ) rows,
  required ValueChanged<T> onSelected,
  double maxWidth = 280,
}) async {
  if (!buttonContext.mounted) return;
  final navigator = Navigator.of(buttonContext, rootNavigator: true);
  final anchor = globalRectOf(buttonContext);
  if (anchor == null) return;

  final picked = await showAnchoredMenu<T>(
    navigator: navigator,
    anchor: anchor,
    builder: (context) => AnchoredMenuPanel(
      title: title,
      maxWidth: maxWidth,
      children: rows(context, (value) => Navigator.of(context).pop(value)),
    ),
  );
  if (picked == null) return;
  onSelected(picked);
}

class _QualityMenu extends StatelessWidget {
  const _QualityMenu({required this.controller});

  final PlaybackController controller;

  @override
  Widget build(BuildContext context) {
    final qualities = controller.qualities;

    // 服务端没给转码梯度时不显示入口 —— 一个只有一项的下拉框
    // 只会让用户以为「清晰度切换坏了」。
    if (qualities.length <= 1) return const SizedBox.shrink();

    final active = controller.activeQualityId;

    return Builder(
      builder: (buttonContext) => _MenuButton(
        tooltip: '清晰度',
        onTap: () => unawaited(_openAnchoredMenu<String>(
          buttonContext: buttonContext,
          title: '清晰度',
          onSelected: (id) => unawaited(controller.switchQuality(id)),
          rows: (context, select) => [
            for (final q in qualities)
              _MenuTile(
                onTap: q.isAvailable ? () => select(q.id) : null,
                child: _MenuRow(
                  label: q.label,
                  detail: q.displayDetail,
                  selected: q.id == active,
                  dim: !q.isAvailable,
                ),
              ),
          ],
        )),
        child: _BarButton(
          icon: Icons.high_quality_rounded,
          label: _activeLabel(qualities, active),
          active: true,
        ),
      ),
    );
  }

  static String _activeLabel(List<QualityOption> all, String? active) {
    for (final q in all) {
      if (q.id == active) return q.label;
    }
    return '清晰度';
  }
}

class _SubtitleMenu extends StatelessWidget {
  const _SubtitleMenu({required this.controller});

  final PlaybackController controller;

  static const String _offValue = '__off__';

  @override
  Widget build(BuildContext context) {
    final tracks = controller.allSubtitles;
    final active = controller.activeSubtitleId;

    return Builder(
      builder: (buttonContext) => _MenuButton(
        tooltip: '字幕',
        onTap: () => unawaited(_openAnchoredMenu<String>(
          buttonContext: buttonContext,
          title: '字幕',
          onSelected: (value) {
            if (value == _offValue) {
              unawaited(controller.selectSubtitle(null));
              return;
            }
            for (final t in tracks) {
              if (t.id == value) {
                unawaited(controller.selectSubtitle(t));
                return;
              }
            }
          },
          rows: (context, select) => [
            _MenuTile(
              onTap: () => select(_offValue),
              child: const _MenuRow(label: '关闭字幕', detail: ''),
            ),
            if (tracks.isNotEmpty)
              const Divider(height: 1, thickness: 1, color: Colors.white12),
            for (final t in tracks)
              _MenuTile(
                onTap: () => select(t.id),
                child: _MenuRow(
                  label: t.displayLabel,
                  detail: _originLabel(t),
                  selected: t.id == active,
                ),
              ),
          ],
        )),
        child: _BarButton(
          icon: Icons.subtitles_rounded,
          label: active == null ? '字幕' : '字幕 · 开',
          active: active != null,
        ),
      ),
    );
  }

  static String _originLabel(SubtitleTrack t) => switch (t.origin) {
        SubtitleOrigin.cloudFile => '网盘字幕',
        SubtitleOrigin.embedded => '内嵌轨',
        SubtitleOrigin.localFile => '本地字幕',
      };
}

class _AudioMenu extends StatelessWidget {
  const _AudioMenu({
    required this.controller,
    required this.activeId,
    required this.onSelected,
  });

  final PlaybackController controller;
  final String? activeId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final tracks = controller.embeddedAudioTracks;
    // 只有一条音轨时菜单没有意义。
    if (tracks.length <= 1) return const SizedBox.shrink();

    return Builder(
      builder: (buttonContext) => _MenuButton(
        tooltip: '音轨',
        onTap: () => unawaited(_openAnchoredMenu<String>(
          buttonContext: buttonContext,
          title: '音轨',
          onSelected: (id) {
            for (final t in tracks) {
              if (t.id == id) {
                onSelected(id);
                unawaited(controller.selectAudioTrack(t));
                return;
              }
            }
          },
          rows: (context, select) => [
            for (var i = 0; i < tracks.length; i++)
              _MenuTile(
                onTap: () => select(tracks[i].id),
                child: _MenuRow(
                  label: tracks[i].title ??
                      _languageLabel(tracks[i].language) ??
                      '音轨 ${i + 1}',
                  detail: _trackDetail(tracks[i]),
                  selected: tracks[i].id == activeId,
                ),
              ),
          ],
        )),
        child: const _BarButton(icon: Icons.graphic_eq_rounded, label: '音轨'),
      ),
    );
  }

  static String _trackDetail(mk.AudioTrack t) => [
        if (t.codec != null) t.codec!,
        if (t.channels != null) t.channels!,
        if (t.bitrate != null) '${(t.bitrate! / 1000).round()} kbps',
      ].join(' · ');

  static String? _languageLabel(String? tag) {
    if (tag == null || tag.isEmpty) return null;
    const table = {
      'chi': '中文',
      'zho': '中文',
      'zh': '中文',
      'eng': '英文',
      'en': '英文',
      'jpn': '日文',
      'ja': '日文',
      'kor': '韩文',
      'ko': '韩文',
    };
    return table[tag.toLowerCase()] ?? tag;
  }
}

class _RateMenu extends StatelessWidget {
  const _RateMenu({required this.controller});

  final PlaybackController controller;

  static const List<double> _rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    final rate = controller.rate;

    return Builder(
      builder: (buttonContext) => _MenuButton(
        tooltip: '播放速度',
        onTap: () => unawaited(_openAnchoredMenu<double>(
          buttonContext: buttonContext,
          title: '播放速度',
          onSelected: (v) => unawaited(controller.setRate(v)),
          rows: (context, select) => [
            for (final r in _rates)
              _MenuTile(
                onTap: () => select(r),
                child: _MenuRow(
                  label: r == 1.0 ? '正常速度' : '${r}x',
                  detail: '',
                  selected: (r - rate).abs() < 0.001,
                ),
              ),
          ],
        )),
        child: _BarButton(
          icon: Icons.speed_rounded,
          label: rate == 1.0 ? '倍速' : '${rate}x',
          active: rate != 1.0,
        ),
      ),
    );
  }
}

/// 控制栏上的菜单入口。
///
/// 用 `InkWell` 而不是 `PopupMenuButton`：菜单自己定位，但入口本身必须仍然
/// **可聚焦、可被遥控器 OK 激活** —— TV 上控制栏只走焦点链（见 `_remoteReachable`），
/// 换成一块不可聚焦的装饰就等于把这个入口从遥控器手里拿走了。
class _MenuButton extends StatelessWidget {
  const _MenuButton({
    required this.tooltip,
    required this.onTap,
    required this.child,
  });

  final String tooltip;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: child,
      ),
    );
  }
}

/// 菜单里的一行：可点，且能被遥控器 OK 激活。
class _MenuTile extends StatelessWidget {
  const _MenuTile({required this.child, this.onTap});

  final Widget child;

  /// `null` = 这一项不可点（比如服务端没给这一档转码）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: child,
      ),
    );
  }
}

/// 控制栏上的文字按钮（带图标）。
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.label,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppTheme.accent : AppTheme.muted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 11.5, color: color)),
        ],
      ),
    );
  }
}

/// 菜单里的一行：主标签 + 说明 + 选中勾。
///
/// 不自己定宽：宽度由 [AnchoredMenuPanel] 给（撑满面板），否则每行右边会空出
/// 一块、看着像没对齐。
class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.label,
    required this.detail,
    this.selected = false,
    this.dim = false,
  });

  final String label;
  final String detail;
  final bool selected;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: dim
                      ? AppTheme.dim
                      : (selected ? AppTheme.accent : AppTheme.text),
                ),
              ),
              if (detail.isNotEmpty)
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, color: AppTheme.dim),
                ),
            ],
          ),
        ),
        if (selected)
          const Padding(
            padding: EdgeInsets.only(left: 8),
            child: Icon(Icons.check_rounded, size: 14, color: AppTheme.accent),
          ),
      ],
    );
  }
}

/// 取链失败时的遮罩。
///
/// 必须给出**可行动的**说明：夸克取链失败的原因分好几类
/// （登录失效 / 文件被删 / 被所有路由拒绝），笼统写「播放失败」
/// 会让用户以为是播放器的问题而去重装应用。
/// 非致命提示条。
///
/// 刻意做成「贴顶的小药丸 + 可关闭」，而不是像 [_ErrorOverlay] 那样铺满画面：
/// 它要报告的事（这条字幕没挂上、这一档切不过去）**都不影响视频继续播放**，
/// 为此把画面挡住反而是更严重的故障 —— 实测就是这么翻的车。
class _NoticePill extends StatelessWidget {
  const _NoticePill({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppTheme.panel2.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppTheme.line),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 7, 4, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.info_outline_rounded,
                size: 15,
                color: AppTheme.warn,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: AppTheme.text,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              IconButton(
                onPressed: onDismiss,
                tooltip: '知道了',
                iconSize: 15,
                color: AppTheme.muted,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorOverlay extends StatelessWidget {
  const _ErrorOverlay({
    required this.message,
    required this.onRetry,
    required this.onBack,
  });

  final String message;
  final Future<void> Function() onRetry;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppTheme.cinema.withValues(alpha: 0.88),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 32,
                color: AppTheme.danger,
              ),
              const SizedBox(height: 14),
              const Text(
                '播放失败',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.text,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.7,
                  color: AppTheme.muted,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton(onPressed: onBack, child: const Text('返回')),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: () => unawaited(onRetry()),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accent,
                    ),
                    child: const Text('重新取链'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
