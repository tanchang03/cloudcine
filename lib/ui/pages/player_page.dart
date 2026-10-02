import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/seek_acceleration.dart';
import '../../data/db/settings_store.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/entities/media_work.dart';
import '../../domain/entities/quality_option.dart';
import '../../domain/entities/subtitle_track.dart';
import '../../domain/services/episode_queue.dart';
import '../../domain/services/playback_controller.dart';
import '../../domain/services/playback_exit_policy.dart';
import '../providers/app_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/anchored_menu.dart';
import '../widgets/buffered_slider.dart';
import '../widgets/common_widgets.dart';
import '../widgets/missing_media_dialog.dart';
import '../widgets/player_keys.dart';

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

  /// 数字键：跳到片子的 N%。
  ///
  /// 「是哪个数字」不在这里定 —— 这个枚举只回答「该干什么」，
  /// 具体百分比由 `player_keys.dart` 的 `seekFractionForKey` 从键本身读。
  /// 把比例塞进枚举会让它变成带载荷的密封类，而**两个播放器都要用它**
  /// （那个文件在 `ui/widgets/` 下，独立播放窗口也够得着）。
  seekPercent,

  /// 放行给焦点系统（移动焦点、激活按钮）。
  ignored,
}

/// 遥控器上「我们认识的」键。
///
/// ⚠️ 只能是 `final` 不能是 `const`：`LogicalKeyboardKey` 重写了 `==`，
/// 而常量集合的元素要求原生相等（`const_set_element_not_primitive_equality`）。
final Set<LogicalKeyboardKey> _remoteKeys = {
  // 数字键也要认。沉浸模式「第一下先把控制栏叫回来」的判据是「认不认得这个
  // 键」—— 漏掉数字键的话，用户按 5 只会换回控制栏，得按第二下才跳。
  ...seekDigitKeys.keys,
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

  // 数字键不挑焦点：它是**明确的意图**（「跳到 50%」），不像 OK / ←→ 那样
  // 在按钮上有别的含义。焦点停在控制栏里时按 5，用户要的仍然是跳转。
  if (isSeekDigit(key)) return RemoteKeyAction.seekPercent;

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

  /// 长按 / 连按 ←→ 的步长累加（10 秒 → 30 → 60 → 5 分钟）。
  ///
  /// 状态放在页面里而不是全局：它描述的是「用户手上这一串按键」，
  /// 退出播放页就该忘掉。独立播放窗口另有一份（不同引擎，共享不了）。
  final SeekRepeatTracker _seekRepeat = SeekRepeatTracker();

  /// 拖动进度条时的临时值。拖动过程中不能让 `position` 流把滑块拽回去。
  double? _dragFraction;

  /// 当前音轨 id。页面自己记：mpv 的 `tracks` 流只给列表，不给「当前选中」。
  String? _audioId;

  /// 当前作品（作品级数据：手标的片头区间在这里）。
  ///
  /// `_item` 是「这一集」，`_work` 是「这部剧」—— 片头区间是**作品级**的
  /// （见 `MediaWork.introStartMs` 的类文档：各集片头时长基本一致，
  /// 而逐集标记的代价高得没人会去标）。
  MediaWork? _work;

  /// 设置：一集播完是否自动接下一集。
  bool _autoPlayNext = true;

  /// 设置：有片头标识时是否自动跳过。
  bool _skipIntro = true;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(playbackControllerProvider);
    // 播放状态一变就重算收起倒计时（见 [_onPlayStateChanged]）。
    _controller.addListener(_onPlayStateChanged);
    // 自动连播。**在这里挂、在 dispose 摘**：控制器是 Provider 级的单例，
    // 不摘的话它会在页面销毁之后继续持有这个 State 的闭包（`_onCompleted`
    // 里要 `setState` / 读 provider），下一次播完会打到已销毁的页面上。
    _controller.onCompleted = _onCompleted;
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  /// 一集播完。自动接下一集（设置里关掉时什么都不做）。
  void _onCompleted() {
    if (!_autoPlayNext) return;
    unawaited(_playNextEpisode());
  }

  /// 找同一部作品里的下一集并打开它。
  ///
  /// 「下一集是哪一条」的规则本体在 [EpisodeQueue]（两个播放器共用）——
  /// 这里只负责取列表、把当前项交出去、然后把结果播起来。
  Future<void> _playNextEpisode() async {
    final current = _item;
    if (current == null) return;

    final repo = ref.read(mediaRepositoryProvider);
    // `itemsForWork` 取的是**并集**（含折叠过来的那些目录），与详情页
    // 剧集列表同一口径 —— 否则跨目录归一的剧集会「播到第 3 集就断了」。
    final siblings = await repo.itemsForWork(current.groupKey);
    final next = EpisodeQueue.nextAfter<MediaItem>(
      entries: siblings,
      idOf: (i) => i.id,
      currentId: current.id,
      isExtra: (i) => i.isSampleOrExtra,
    );

    if (next == null) {
      // 不是错误：最后一集播完就该停（见 `EpisodeQueue` 第 3 条 ——
      // 循环重播会让睡着的用户被整夜播放）。
      diag.info('播放', '没有下一集了：${current.displayTitle}');
      return;
    }
    if (!mounted) return;

    diag.info('播放', '自动连播 → ${next.displayTitle}');
    await _openItem(next);
  }

  /// 当前这一条**在网盘上已经没了** → 问用户要不要把它的索引删掉。
  ///
  /// 删掉之后顺手退出播放页：留在一个「索引已经不存在」的页面上没有
  /// 任何可做的事（重试必然再失败一次），而返回之后他能立刻看到已经
  /// 更新过的媒体库 —— 那正是他刚做的那件事的结果。
  Future<void> _removeCurrent() async {
    final item = _item;
    if (item == null) return;
    final removed = await removeMissingMedia(context, ref, item);
    if (!mounted || !removed) return;
    context.pop();
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
    // 摘掉自动连播回调：它是**全局唯一**的那个（控制器是单例），
    // 留着会让下一次播完打到这个已经销毁的 State 上。
    if (_controller.onCompleted == _onCompleted) {
      _controller.onCompleted = null;
    }
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

    // 设置一次性读齐：清晰度 / 字幕 / 音量 / 倍速 / **连播 / 跳片头**。
    // 连播与跳片头这两项在切集时不会重读 —— 它们描述的是「这一轮观看」
    // 的偏好，中途去设置页改的极端情况不值得为它每次切集多打一次库。
    final settings = ref.read(settingsStoreProvider);
    final values = await settings.readAll(const [
      SettingKeys.defaultQuality,
      SettingKeys.autoLoadSubtitles,
      SettingKeys.playerVolume,
      SettingKeys.playerRate,
      SettingKeys.autoPlayNext,
      SettingKeys.skipIntro,
    ]);
    if (!mounted) return;

    final volume = double.tryParse(values[SettingKeys.playerVolume] ?? '') ?? 100;
    final rate = double.tryParse(values[SettingKeys.playerRate] ?? '') ?? 1.0;

    setState(() {
      _autoPlayNext = values[SettingKeys.autoPlayNext] != 'false';
      _skipIntro = values[SettingKeys.skipIntro] != 'false';
    });

    final controller = _controller;
    await controller.setVolume(volume);
    await controller.setRate(rate);

    await _openItem(item);
  }

  /// 打开一集（首次进入与自动连播走的是**同一条路**）。
  ///
  /// 抽出来而不是让自动连播另写一份：两份必然会漂移，而漂移的表现是
  /// 「自动切过去的那一集字幕没加载 / 清晰度不对 / 不跳片头」——
  /// 用户完全不会想到这与「第一集」走的是不同代码。
  Future<void> _openItem(MediaItem item) async {
    final repo = ref.read(mediaRepositoryProvider);

    // 字幕引用（扫描期建的，不含正文）与作品级数据一起读。
    final subtitles = await repo.subtitlesForItem(item.id);
    final work = await repo.workByKey(item.groupKey);
    final settings = ref.read(settingsStoreProvider);
    final values = await settings.readAll(const [
      SettingKeys.defaultQuality,
      SettingKeys.autoLoadSubtitles,
    ]);
    if (!mounted) return;

    final preferred =
        widget.qualityId ?? _nonEmpty(values[SettingKeys.defaultQuality]);
    // 默认 **true**：绝大多数片子都有中文字幕，默认加载省一次点击；
    // 没有字幕时 `_autoLoadSubtitle` 会安静地什么都不做。
    final autoSub = values[SettingKeys.autoLoadSubtitles] != 'false';

    setState(() {
      _item = item;
      _work = work;
      _ready = true;
      // 音轨选中态是**逐文件**的：上一集的音轨号在新文件里可能根本不存在，
      // 留着会让音轨菜单高亮一个不存在的轨。
      _audioId = null;
      // 拖拽预览值同理：它属于上一集的进度条。
      _dragFraction = null;
    });

    await _controller.open(
      item,
      subtitles: subtitles,
      preferredQualityId: preferred,
      autoLoadSubtitles: autoSub,
      // 手标区间（兜底）。文件章节那份由控制器自己探测，且优先级更高。
      introMarker: work?.introRange,
      skipIntro: _skipIntro,
    );
  }

  // -------------------------------------------------------------------
  // 片头标记（手标那一半）
  // -------------------------------------------------------------------

  /// 把「当前位置」记成片头起点 / 终点，或清除整个标记。
  ///
  /// ## 为什么三个动作都写库、且写完**从库里重读**
  ///
  /// 仓储那三个方法是**分开的**（`setWorkIntroStart` / `setWorkIntroEnd` /
  /// `clearWorkIntroRange`），而不是一个带可空参数的 —— 因为 `copyWith`
  /// 的 `??` 把 `null` 当成「不改」，用一个方法表达不了「清除」。
  ///
  /// 本地这份同样不能用 `copyWith` 造：`copyWith(introStartMs: null)` 清不掉
  /// 字段。重读一次既绕开了它，又保证界面显示的就是库里真正存着的东西 ——
  /// 代价是一次 `SELECT`，而标片头是极低频动作。
  Future<void> _markIntro(_IntroAction action) async {
    final work = _work;
    if (work == null) return;

    // 「跳到片头」不写库，先单独处理掉。
    if (action == _IntroAction.jump) {
      final marker = _controller.introMarker;
      if (marker != null) await _controller.seek(marker.start);
      return;
    }

    final repo = ref.read(mediaRepositoryProvider);
    final ms = _controller.position.inMilliseconds;
    final String message;

    switch (action) {
      case _IntroAction.setStart:
        if (ms <= 0) {
          _toast('现在的位置是 0，先让画面播起来再标起点');
          return;
        }
        await repo.setWorkIntroStart(work.key, ms);
        message = '片头起点已记为 ${_fmt(Duration(milliseconds: ms))}';

      case _IntroAction.setEnd:
        if (ms <= 0) {
          _toast('现在的位置是 0，先让画面播起来再标终点');
          return;
        }
        await repo.setWorkIntroEnd(work.key, ms);
        message = '片头终点已记为 ${_fmt(Duration(milliseconds: ms))}';

      case _IntroAction.clear:
        await repo.clearWorkIntroRange(work.key);
        message = '已清除片头标记';

      case _IntroAction.jump:
        return; // 上面已经处理过。
    }

    final fresh = await repo.workByKey(work.key);
    if (!mounted) return;
    if (fresh != null) _applyWork(fresh);

    // 标完之后区间还不成立（只标了一半 / 起终点反了）必须**说一声**：
    // 否则用户看到的是「两个点都标了，可是还是不跳」。
    final incomplete =
        action != _IntroAction.clear && _controller.introMarker == null;
    _toast(
      incomplete
          ? '$message。片头要同时有起点和终点、且起点在终点之前，'
              '现在这样不会自动跳过'
          : message,
    );
  }

  void _applyWork(MediaWork work) {
    if (!mounted) return;
    setState(() => _work = work);
    _controller.applyManualIntro(work.introRange);
  }

  /// 一条轻提示。用 SnackBar 而不是播放器里那个 `notice` 药丸：
  /// 药丸是「播放状态的一部分」（控制器持有、会自动消失），而这几句是
  /// 用户点按钮的**即时反馈**，生命周期属于这个页面。
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
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
    // 松手 = 这一串快退/快进结束，下一串重新从 10 秒起步。
    //
    // 这里能显式收到 key-up（`Focus.onKeyEvent` 的待遇），比独立播放窗口那边
    // 靠「间隔超时」判断开要准 —— 那边走 `CallbackShortcuts`，压根收不到 up。
    if (event is KeyUpEvent) {
      _seekRepeat.reset();
      return KeyEventResult.ignored;
    }

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
        _seekRepeat.reset();
        _controller.playOrPause();
      case RemoteKeyAction.seekBack:
        // 步长由「这一串已经连了几下」决定：按一下 10 秒，长按住会涨到 5 分钟。
        _controller.seekRelative(-_seekRepeat.step(-1));
      case RemoteKeyAction.seekForward:
        _controller.seekRelative(_seekRepeat.step(1));
      case RemoteKeyAction.seekPercent:
        // 数字键是**一步到位**的跳转，与「连按累加」是两回事，别把两者混起来。
        _seekRepeat.reset();
        final fraction = seekFractionForKey(event.logicalKey);
        if (fraction != null) _controller.seekToFraction(fraction);
      case RemoteKeyAction.showControls:
        // 唤回控制栏：倒计时从头算，给用户足够时间看清再决定下一步。
        _seekRepeat.reset();
        setState(() => _immersive = false);
        _scheduleControlsHide();
      case RemoteKeyAction.pop:
        _seekRepeat.reset();
        context.pop();
      case RemoteKeyAction.ignored:
        // 走到这儿的是「放行给焦点系统」的键（↑/↓、焦点不在画面上时的 OK 与
        // ←→）。它们与快退/快进不是同一件事，所以把这一串断掉 ——
        // 否则「← ↓ ←」会被当成连按两下 ←。
        _seekRepeat.reset();
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
            // 只有「网盘上已经没有这个文件」才给这个出口。登录失效、断网、
            // 限流都是「这次没取到」—— 那些情况下文件还在，拿它们去问
            // 用户要不要删片是最糟的一类误报。
            onRemove: controller.isFileMissing ? _removeCurrent : null,
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
              // 片头标记入口。`_work` 为空（这一条没进过库）时不显示 ——
              // 标记要写到作品行上，没有那一行就无处可写。
              if (_work case final work?)
                _IntroMenu(
                  controller: controller,
                  work: work,
                  onAction: (a) => unawaited(_markIntro(a)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// `1:02:03` / `02:03`
  static String _fmt(Duration d) => _fmtClock(d);
}

/// `1:02:03` / `02:03`。
///
/// 提到顶层是因为**片头菜单也要用**（它是个独立的 `StatelessWidget`，
/// 够不到 `_PlayerPageState` 的静态方法）。留两份的话，进度条上写着
/// `1:30`、片头菜单里写着 `01:30`，同一段时间两个样子。
String _fmtClock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// 片头菜单能触发的四个动作。
enum _IntroAction {
  /// 把当前位置记为片头起点。
  setStart,

  /// 把当前位置记为片头终点。
  setEnd,

  /// 清掉手标的那一份（文件章节不受影响）。
  clear,

  /// 跳到片头起点。
  jump,
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

/// 片头菜单：看当前片头区间、跳过去、手动标记 / 清除。
///
/// ## 为什么这个入口必须存在
///
/// 「有片头标识就自动跳过」里的「标识」有两路来源：文件内章节（`Opening` /
/// `片头` 这类章节名）与用户手标的区间。而**网盘上的剧集绝大多数没有章节**
/// —— 压制时没人写。只有章节这一路的话，这个功能对大部分用户等于不存在。
///
/// ## 为什么标在「作品」而不是「这一集」
///
/// 同一部剧每集的片头位置几乎一样，让用户给 24 集各标一次是不可接受的。
/// 代价是各集片长略有差异时会有偏差 —— 这个取舍见 `MediaWork.introStartMs`。
class _IntroMenu extends StatelessWidget {
  const _IntroMenu({
    required this.controller,
    required this.work,
    required this.onAction,
  });

  final PlaybackController controller;
  final MediaWork work;
  final ValueChanged<_IntroAction> onAction;

  @override
  Widget build(BuildContext context) {
    final marker = controller.introMarker;
    final manual = work.introRange;
    final fromChapters = controller.introFromChapters;

    // 状态说明。三种情形对用户是**三件不同的事**，文案不能混：
    //   - 有章节：这是发布者给的准确信息，用户不需要做任何事；
    //   - 只有手标：告诉他这一份是「整部剧共用」的；
    //   - 都没有：告诉他可以自己标一次 —— 否则他不会想到这个功能还能用。
    final String status;
    if (fromChapters) {
      status = '来自文件章节（压制时写进去的），比手标更准';
    } else if (manual != null) {
      status = '来自你手动标记的区间，这部作品下的每一集共用';
    } else {
      status = '文件里没有章节标记。可以在这儿手动标一次，'
          '这部作品下的每一集都会用';
    }

    final now = _fmtClock(controller.position);

    return Builder(
      builder: (buttonContext) => _MenuButton(
        tooltip: '片头',
        onTap: () => unawaited(_openAnchoredMenu<_IntroAction>(
          buttonContext: buttonContext,
          title: '片头',
          maxWidth: 330,
          onSelected: onAction,
          rows: (context, select) => [
            _MenuTile(
              child: _MenuRow(
                label: marker == null
                    ? '还没有片头标识'
                    : '片头 ${_fmtClock(marker.start)} → '
                        '${_fmtClock(marker.end)}（${marker.length.inSeconds} 秒）',
                detail: status,
                dim: marker == null,
              ),
            ),
            if (marker != null)
              _MenuTile(
                onTap: () => select(_IntroAction.jump),
                child: _MenuRow(
                  label: '跳到片头',
                  detail: '回到 ${_fmtClock(marker.start)}',
                ),
              ),
            _MenuTile(
              onTap: () => select(_IntroAction.setStart),
              child: _MenuRow(
                label: '把当前位置标为片头起点',
                detail: '当前位置 $now',
              ),
            ),
            _MenuTile(
              onTap: () => select(_IntroAction.setEnd),
              child: _MenuRow(
                label: '把当前位置标为片头终点',
                detail: '当前位置 $now',
              ),
            ),
            // 「清除」只在真的手标过时才给 —— 章节那份清不掉（它在文件里），
            // 给一个点了没反应的按钮比不给更让人困惑。
            if (manual != null)
              _MenuTile(
                onTap: () => select(_IntroAction.clear),
                child: _MenuRow(
                  label: '清除手动标记',
                  detail: fromChapters
                      ? '清掉之后仍会用文件里的章节'
                      : '清掉之后这一部不再自动跳过片头',
                ),
              ),
          ],
        )),
        child: _BarButton(
          icon: Icons.content_cut_rounded,
          label: '片头',
          active: marker != null,
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
    this.onRemove,
  });

  final String message;
  final Future<void> Function() onRetry;
  final VoidCallback onBack;

  /// 「从媒体库移除」的出口。**`null` 表示不给这个出口** —— 只有确认
  /// 「网盘上已经没有这个文件」时才传（`PlaybackController.isFileMissing`）。
  final VoidCallback? onRemove;

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
              // `Wrap` 而不是 `Row`：多出「从媒体库移除」那一个按钮之后，
              // 三个按钮在窄窗口（TV 上尤其）会挤成一行溢出。
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 8,
                children: [
                  OutlinedButton(onPressed: onBack, child: const Text('返回')),
                  FilledButton(
                    onPressed: () => unawaited(onRetry()),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accent,
                    ),
                    child: const Text('重新取链'),
                  ),
                  if (onRemove != null)
                    TextButton(
                      onPressed: onRemove,
                      child: const Text(
                        '从媒体库移除…',
                        style: TextStyle(color: AppTheme.warn),
                      ),
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
