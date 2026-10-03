import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/player_audio_effect.dart';
import '../../core/utils/seek_acceleration.dart';
import '../../core/utils/track_labels.dart';
import '../../data/db/settings_store.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/entities/media_work.dart';
import '../../domain/entities/playback_preference.dart';
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
import '../widgets/player_tv_overlay.dart';

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

/// TV 设置面板相关的按键该干什么。
///
/// ## 为什么要跟 [RemoteKeyAction] 分开，而且必须先判
///
/// 面板的开关**不是播放动作**，并且它必须在 [resolveRemoteKey] **之前**判：
/// 那里面「沉浸模式下任何认识的键 → `showControls`」这一条会把菜单键吃掉，
/// 于是沉浸状态下按菜单键只会把控制栏叫回来、面板永远打不开 ——
/// 而菜单键恰恰是这条需求点名要用的键。
enum TvPanelKeyAction {
  /// 与面板无关，交给 [resolveRemoteKey] 继续判。
  none,

  /// 唤出面板。
  open,

  /// 收起面板（菜单键再按一次）。
  close,
}

/// 决定一个按键要不要动 TV 设置面板。
///
/// ## 为什么 ↑ 只在「焦点真在画面上」时才接管
///
/// 电视的通行约定是画面里按 ↑ 唤出设置（YouTube / Netflix 都这样），而 ↑ 在
/// 画面上本来就是**空闲**的 —— 顶栏整块 `ExcludeFocus`，焦点挪不上去。
/// 但焦点一旦进了控制栏，↑ 就属于焦点遍历（用户要从下面走回去），
/// 这时接管会把「走回上一行」变成「弹出面板」。
///
/// ⚠️ 反过来说 **↓ 必须继续放行**：从画面往下走到控制栏（去够「设置」按钮）
/// 靠的就是它。所以这里只认 ↑，绝不认 ↓。
TvPanelKeyAction resolveTvPanelKey({
  required LogicalKeyboardKey key,
  required bool panelOpen,
  required bool stageFocused,
}) {
  // 菜单键（Android `KEYCODE_MENU` = 82 → `contextMenu`）。同一个键开 / 关。
  // 不挑焦点：它上面没有别的含义，任何位置按下去都该是「开设置」。
  if (key == LogicalKeyboardKey.contextMenu) {
    return panelOpen ? TvPanelKeyAction.close : TvPanelKeyAction.open;
  }
  if (key == LogicalKeyboardKey.arrowUp && !panelOpen && stageFocused) {
    return TvPanelKeyAction.open;
  }
  return TvPanelKeyAction.none;
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

/// 画面上该不该显示「正在切换…」这一层。
///
/// 抽成**纯函数**是为了可单测（与 [shouldAutoHideControls] 同理）——
/// 「什么时候算换档」一旦散在 `build` 里，就会随状态字段增减而漂移。
///
/// ## 判据
///
/// `isLoading` 同时被 `open()`（首次开播 / 换集 / 重试）与 `switchQuality`
/// 置位，光看它分不出「换档」和「首次载入」。所以用 `duration` 区分：
///
///   * `open()` 会把时长归零 —— 它换的是**另一个文件**，旧的时长没有意义；
///   * `switchQuality` **不走** `open()`（见 `PlaybackController._loadIntoPlayer`），
///     时长还在 —— 它换的是同一部片子的另一条转码流。
///
/// 于是「时长还在 + 正在加载」== 换档。首次载入时时长为零，不会误报。
///
/// ⚠️ **不要**把它改成页面自己的布尔标志位：那种锁存状态一旦有某条提前返回
/// 的分支忘了清，指示就会永远挂在画面上（「永远不收」比「早收」糟得多）。
/// 这里是从 `isLoading` 推导的，`switchQuality` 的 `try/finally` 保证它
/// 一定会落回 false。
bool shouldShowSwitchVeil({
  required bool isLoading,
  required Duration duration,
}) =>
    isLoading && duration > Duration.zero;

/// 进播放页要播的那一条：**调用方直接给的优先**，没给才按 id 查库。
///
/// ## 为什么这条规则要单独抽出来
///
/// 写反了（永远查库）的表现是：目录视图里点一个**还没入库**的视频，弹出来
/// 一句「找不到这个媒体项。可能它已被重新扫描移除」—— 而用户点的那部片子
/// 就在网盘上，只是还没进库。播放页本身太重（media_kit + 跨引擎通道），
/// 整页测不划算，所以判据抽成这个函数、由用例钉死。
///
/// [lookup] 由调用方传进来（而不是在这里 `ref.read`）：这样用例能验
/// 「给了对象时**一次都没查库**」，而那正是这条规则的要害 —— 库里没有
/// 那一行，查一次只会白跑一趟并拿到 `null`。
@visibleForTesting
Future<MediaItem?> resolvePlayItem({
  required String itemId,
  required MediaItem? item,
  required Future<MediaItem?> Function(String itemId) lookup,
}) async =>
    item ?? await lookup(itemId);

/// 播放页。
///
/// ## 为什么**默认**只收 itemId，而 [PlayerPage.item] 是例外
///
/// 常规路径传的是 **itemId 而不是 `MediaItem` 对象**。看起来多绕一步，
/// 换来两件事：
///   1. 深链接 / 热重载后页面能自己恢复（对象传参会丢）；
///   2. 「播放」这件事的**全部前置条件**（字幕引用、默认清晰度、音量倍速、
///      是否自动加载字幕）都从库里现读，不会因为调用方忘了传某个参数
///      而静默用默认值。
///
/// 唯一的例外是 [PlayerPage.item]：目录视图允许**不先入库就直接播**，那一条
/// 库里根本没有，按 id 查必然查不到 —— 所以那种情况下调用方把对象一起带
/// 过来（见 [resolvePlayItem] 的规则），而**只有**那种情况才会用到它。
///
/// ## 控制栏为什么是自绘的
///
/// `media_kit_video` 自带一套 `AdaptiveVideoControls`，但它**不认识清晰度** ——
/// 网盘的清晰度是服务端转码梯度，mpv 侧只是换了一条 URL，对播放器来说
/// 就是「同一个文件」。清晰度菜单、字幕来源标注（网盘/内嵌）、
/// 音轨语言名这些都必须我们自己画。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key, required this.itemId, this.qualityId, this.item});

  final String itemId;

  /// 指定要播的清晰度档位（从详情页点某一档进来时用）。`null` = 用设置里的默认。
  final String? qualityId;

  /// 要播的媒体项**对象**。`null` = 去库里按 [itemId] 查。
  ///
  /// ## 为什么除了 id 还要能直接给对象
  ///
  /// 目录视图允许**不先入库就直接播**（`playDriveEntry`）：那条路手里有一个
  /// 现造的 `MediaItem`，而库里**没有这一行** —— 只给 id 的话，[PlayerPage]
  /// 查库查不到，只能报「找不到这个媒体项」，而用户点的那部片子就在网盘上。
  ///
  /// 走导航参数（go_router 的 `extra`）而不是在这里查一个旁路缓存：谁导航
  /// 过来、带的是哪一条，在调用点上一眼看得到。已经入库的条目也会带上它
  /// （同一个对象，省一次点查），所以这里**不区分**两种来源。
  final MediaItem? item;

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

  /// 这一条**当前生效的播放偏好**（画质 / 音轨 / 字幕 / 字幕开关 / 音效）。
  ///
  /// ## 为什么在页面里留一份，而不是每次写库时现读
  ///
  /// 用户改一项时要写回去的是**完整的偏好**（仓储是整条覆盖写）。现读一次
  /// 当然也行，但那会多一次数据库往返 + 一次 JSON 解析，而这一份本来就
  /// 已经读出来过（`_openItem` 里），只是原先没地方放。
  ///
  /// ⚠️ 它必须**跟着当前这一集走**：`_openItem` 每次都会用新一集读到的值
  /// 覆盖它。漏了覆盖的话，「切到下一集 → 改字幕」会把上一集的偏好写进
  /// 下一集的行里 —— 而用户只看到「设置记住了错的」。
  PlaybackPreference _pref = const PlaybackPreference();

  /// 音效是否已经应用过。**进播放页后只应用一次**（切集不重来）。
  ///
  /// 与连播 / 跳片头同一待遇：音效描述的是**这台设备怎么接音箱**，与播
  /// 哪一集无关。切集时重下发会让 mpv 重配音频输出 —— 听感上是一次极短的
  /// 断音，而用户什么都没改。
  bool _audioEffectApplied = false;

  /// 设置：一集播完是否自动接下一集。
  bool _autoPlayNext = true;

  /// 设置：有片头标识时是否自动跳过。
  bool _skipIntro = true;

  /// TV 右侧设置面板是否打开。
  ///
  /// 它**不是**路由、也不是 `showModalBottomSheet` —— 面板只是画面 `Stack`
  /// 里的一层。走路由的话，「返回键是先关面板还是先退出播放」会变成两个地方
  /// 各自的决定，而电视上返回键是唯一的退出手段，分错一次就是「按了没反应」。
  bool _tvPanelOpen = false;

  /// 同一部作品下的全部条目（「选集」用）。
  ///
  /// 与 `_playNextEpisode` 取的是**同一份**（`itemsForWork` 的并集）——
  /// 在这里缓存是为了让面板一开就能列出集数，而不是让用户盯着「—」等一次
  /// 数据库往返。空列表表示这一条不在库里（从「文件夹」直接播了没入库的
  /// 文件），那时面板里「选集」那一行不可调。
  List<MediaItem> _siblings = const [];

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

  /// 改一项偏好并**立刻写库**。
  ///
  /// 顺序是「先更新本地、再写库」：本地那份是 UI 立刻要用的（菜单打勾、
  /// 按钮状态），而写库只决定「下次还记不记得」。反过来等一次数据库往返，
  /// 用户会觉得点了没反应。
  ///
  /// 写库失败**不影响本次播放**，只留一条 warn —— 但必须留痕，否则用户
  /// 下次打开发现设置又变回去了，而日志里一条线索都没有。
  Future<void> _savePref(
    PlaybackPreference Function(PlaybackPreference current) update,
  ) async {
    final next = update(_pref);
    // 值没变就不写：菜单里点中当前那一项是常事，白跑一次写库（以及一次
    // `setState`）没有意义。
    if (next == _pref) return;
    setState(() => _pref = next);

    final item = _item;
    if (item == null) return;
    try {
      await ref
          .read(mediaRepositoryProvider)
          .savePlaybackPreference(item.id, item.groupKey, next);
    } catch (e) {
      diag.warn('播放', '播放偏好没能存下来（本次播放已生效）：$e');
    }
  }

  /// 切换「音效」预设：**先应用、再落库**。
  ///
  /// 顺序是有意的：应用是用户按下菜单那一刻要听到的结果，落库是「下次还记得」。
  /// 反过来先等一次数据库写，用户会觉得点了没反应。
  ///
  /// 落库**写两处**，它们语义不同：
  ///   - 全局设置 = 「这台设备怎么接音箱」，其它片子跟着用；
  ///   - 这条偏好 = 「这部片上的覆盖」，下次播它时优先。
  ///
  /// 只写全局的话，「这部片要直通、别的片立体声」就做不到；只写偏好则会让
  /// 用户在设置页看到的音效永远停在旧值。
  Future<void> _setAudioEffect(AudioEffectPreset preset) async {
    await _controller.setAudioEffect(preset);
    await _savePref((p) => p.withAudioEffect(preset.value));
    try {
      await ref
          .read(settingsStoreProvider)
          .write(SettingKeys.playerAudioEffect, preset.value);
    } catch (e) {
      diag.warn('音效', '音效设置没能存下来（本次播放已生效）：$e');
    }
  }

  /// 换清晰度：切档 + 记住。
  ///
  /// ⚠️ **失败时不记**：`switchQuality` 在「这一档服务端没给地址」时只设一条
  /// `_notice` 就返回，`activeQualityId` 不会变。记下来的话，下次打开会去选
  /// 一个取不到地址的档位 —— 表现是「一进播放页就报错」，而用户上次只是
  /// 随手点了一下。
  Future<void> _changeQuality(String id) async {
    await _controller.switchQuality(id);
    if (_controller.activeQualityId != id) return;
    await _savePref((p) => p.withQuality(id));
  }

  /// 换字幕（`null` = 关闭字幕）：加载 + 记住。
  ///
  /// ⚠️ 同样**只在真的挂上了之后才记**。`selectSubtitle` 失败时（网盘字幕
  /// 取不下来、内嵌轨没有轨道号）只设 `_notice`，`activeSubtitleId` 不变 ——
  /// 那时若已经写成「选中这一条」，下次打开会**再失败一次**，而用户完全
  /// 不知道为什么这部片的字幕总是加载不上。
  Future<void> _changeSubtitle(SubtitleTrack? track) async {
    await _controller.selectSubtitle(track);
    if (track != null && _controller.activeSubtitleId != track.id) return;

    // ⛔ 本地字幕**不记**：它的 id 是 `local#<微秒时间戳>`（见
    // `PlaybackController.addLocalSubtitle`），每挑一次文件都会变，记下来
    // 永远匹配不回去；而只剩「序号兜底」那一级时，它会把偏好记成**另一条
    // 完全不相干的轨**。何况本地字幕本来就是「只对本次播放有效」的临时选择
    // （见那个方法的文档），记进库等于偷偷改变了它的语义。
    //
    // 不记的代价是「下次打开回到上一条记住的字幕」，这是刻意接受的取舍 ——
    // 与独立播放窗口那边同一条规则。
    if (track != null && track.origin == SubtitleOrigin.localFile) return;

    // 序号取「在**当前字幕列表**里的位置」—— 与 `_autoLoadSubtitle` 的匹配
    // 口径一致（那边也是按 `allSubtitles` 的下标比的）。
    var index = 0;
    if (track != null) {
      final all = _controller.allSubtitles;
      for (var i = 0; i < all.length; i++) {
        if (all[i].id == track.id) {
          index = i;
          break;
        }
      }
    }
    await _savePref(
      (p) => p.withSubtitle(
        track == null ? null : TrackPreference.ofSubtitle(track, index: index),
      ),
    );
  }

  /// 记住用户选的音轨。**切轨本身由菜单自己做**（它手里就有 `AudioTrack`）。
  ///
  /// [index] 是这条轨在**真实音轨列表**里的位置，由菜单一并给出 —— 在
  /// 「语言标记一个都没写」的片源里，它是唯一可用的匹配依据
  /// （见 `TrackPreference`）。
  Future<void> _rememberAudio(mk.AudioTrack track, int index) => _savePref(
        (p) => p.withAudio(
          TrackPreference(
            trackId: track.id,
            language: track.language,
            title: track.title,
            index: index,
          ),
        ),
      );

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

    final item = await resolvePlayItem(
      itemId: widget.itemId,
      item: widget.item,
      lookup: repo.itemById,
    );
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
    // 音量与倍速是**全局**的（不按片记）：它们描述的是这台设备 / 这个人的
    // 观看习惯，与播哪一部片无关 —— 半夜把音量调小，不该只对一部片生效。
    await controller.setVolume(volume);
    await controller.setRate(rate);
    // 音效**不在这里**应用：它现在也按片记（见 `PlaybackPreference`），而
    // 偏好是 `_openItem` 里读的。挪过去统一处理，省得同一个值读两遍、
    // 也省得「先按全局设一次、再按偏好设一次」白跑一次音频输出重配。
    await _openItem(item);
  }

  /// 打开一集（首次进入与自动连播走的是**同一条路**）。
  ///
  /// 抽出来而不是让自动连播另写一份：两份必然会漂移，而漂移的表现是
  /// 「自动切过去的那一集字幕没加载 / 清晰度不对 / 不跳片头」——
  /// 用户完全不会想到这与「第一集」走的是不同代码。
  Future<void> _openItem(MediaItem item) async {
    final repo = ref.read(mediaRepositoryProvider);

    // 字幕引用（扫描期建的，不含正文）、作品级数据、这一条的播放偏好
    // 一起读 —— 三样合起来才是「打开这一集需要的全部前置条件」。
    final subtitles = await repo.subtitlesForItem(item.id);
    final work = await repo.workByKey(item.groupKey);
    // 兄弟集（TV 面板的「选集」用）。与自动连播取的是**同一份**并集，
    // 口径必须一致 —— 否则跨目录归一的剧集会出现「面板里 24 集、播完第 3
    // 集就断」，而两处都看不出错。
    final siblings = await repo.itemsForWork(item.groupKey);
    final pref = await repo.playbackPreferenceFor(
      item.id,
      groupKey: item.groupKey,
    );
    final settings = ref.read(settingsStoreProvider);
    final values = await settings.readAll(const [
      SettingKeys.defaultQuality,
      SettingKeys.autoLoadSubtitles,
      SettingKeys.playerAudioEffect,
    ]);
    if (!mounted) return;

    // 选档优先级：**进页面时指定的那一档 > 这部片上次选的 > 全局默认**。
    // 第一项是「从详情页点了某一档进来」，那是比偏好更明确的意图。
    final preferred = widget.qualityId ??
        _nonEmpty(pref?.qualityId) ??
        _nonEmpty(values[SettingKeys.defaultQuality]);
    // 字幕开关：偏好优先（用户上次在这部片上开着 / 关着），没记过才用全局
    // 设置。默认 **true**：绝大多数片子都有中文字幕，默认加载省一次点击；
    // 没有字幕时 `_autoLoadSubtitle` 会安静地什么都不做。
    final autoSub = pref?.subtitlesEnabled ??
        (values[SettingKeys.autoLoadSubtitles] != 'false');

    setState(() {
      _item = item;
      _work = work;
      // ⚠️ 偏好**必须跟着这一集换掉**：留着上一集的，用户在新一集上改任何
      // 一项，写回去的都是上一集的值（见 [_pref] 的文档）。
      _pref = pref ?? const PlaybackPreference();
      _ready = true;
      // 音轨选中态是**逐文件**的：上一集的音轨号在新文件里可能根本不存在，
      // 留着会让音轨菜单高亮一个不存在的轨。
      _audioId = null;
      // 兄弟集跟着这一部走。不清的话，切到下一集后面板里列的还是上一部
      // 的集数，而「选集」那一格看起来完全正常。
      _siblings = siblings;
      // 拖拽预览值同理：它属于上一集的进度条。
      _dragFraction = null;
    });

    // 音效只应用**一次**（进播放页时），切集不重来：它描述的是这台设备怎么
    // 接音箱，重下发会让 mpv 重配音频输出（听感上是一次极短的断音），
    // 而用户什么都没改。
    //
    // 这一项也按片记（用户可能给某部片单独选了直通），所以取值优先级是
    // 「这条偏好 > 全局默认」。
    if (!_audioEffectApplied) {
      _audioEffectApplied = true;
      await _controller.setAudioEffect(
        PlayerAudioEffect.parse(
          _pref.audioEffect ?? values[SettingKeys.playerAudioEffect],
        ),
      );
    }

    await _controller.open(
      item,
      subtitles: subtitles,
      preferredQualityId: preferred,
      autoLoadSubtitles: autoSub,
      // 手标区间（兜底）。文件章节那份由控制器自己探测，且优先级更高。
      introMarker: work?.introRange,
      skipIntro: _skipIntro,
      // 音轨 / 字幕的还原。控制器按**特征**匹配（内嵌轨号逐文件不同），
      // 匹配不上就退回默认 —— 见 `TrackPreference`。
      preference: _pref,
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
      body: PopScope(
        // 面板开着时，返回键**先关面板**，而不是退出播放。
        //
        // 电视上返回键既是唯一的退出手段，也是唯一的「取消」手段 —— 不拦的话，
        // 用户想取消一次误开的面板，结果整部片退出了、还得重新找进度。
        canPop: !_tvPanelOpen,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _tvPanelOpen) _closeTvPanel();
        },
        child: ListenableBuilder(
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

    // TV：菜单键与「画面上按 ↑」唤出右侧设置面板（见 [_handleTvPanelKey]）。
    if (_isTv && _handleTvPanelKey(event.logicalKey)) {
      return KeyEventResult.handled;
    }

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
  // TV 右侧设置面板
  // -------------------------------------------------------------------

  bool get _isTv => AppTheme.isTvLayout(context);

  /// 唤出 / 收起 TV 设置面板的键。**返回 true 表示这个键已被吃掉。**
  ///
  /// ⚠️ 面板**开着**且握着焦点时，菜单键由面板自己处理（它在焦点链更靠下的
  /// 位置，会先收到事件并报 `handled`）—— 那时 [resolveTvPanelKey] 的
  /// `close` 分支其实走不到。留着它是因为还有另一种情形：面板开着、焦点却被
  /// 挪到了控制栏上，这时菜单键会冒泡到这里，按下去应当是「收起面板」而不是
  /// 「再开一个」。
  ///
  /// 这不是巧合，正是我们想要的层级：越靠下的 UI 越先决定。
  bool _handleTvPanelKey(LogicalKeyboardKey key) {
    // 路由判断在 [resolveTvPanelKey]（纯函数，可单测），这里只负责执行 ——
    // 与 [_onRemoteKey] 对 [resolveRemoteKey] 的分工完全一致。
    switch (resolveTvPanelKey(
      key: key,
      panelOpen: _tvPanelOpen,
      stageFocused: _stageNode.hasPrimaryFocus,
    )) {
      case TvPanelKeyAction.none:
        return false;
      case TvPanelKeyAction.open:
        _openTvPanel();
      case TvPanelKeyAction.close:
        _closeTvPanel();
    }
    return true;
  }

  void _openTvPanel() {
    if (_tvPanelOpen) return;
    setState(() {
      _tvPanelOpen = true;
      // 面板显示时控制栏也要在：TV 上它们是同一套 OSD 的两半，只出一半
      // 会被读成「控制栏没了」。
      _immersive = false;
    });
    _scheduleControlsHide();
  }

  void _closeTvPanel() {
    if (!_tvPanelOpen) return;
    setState(() => _tvPanelOpen = false);
    // 焦点必须交回画面。面板的 `Focus(autofocus: true)` 拿走焦点之后不主动
    // 还回去的话，↑ / ↓ 会继续被面板吃掉、OK 也不再是播放/暂停 ——
    // 而画面上没有任何东西提示「焦点现在在别处」，用户只会以为播放器卡了。
    _stageNode.requestFocus();
    _scheduleControlsHide();
  }

  // -------------------------------------------------------------------
  // 顶栏
  // -------------------------------------------------------------------

  Widget _buildTopBar(PlaybackController controller) {
    final item = _item;
    // 顶栏要避让过扫描带：那个返回键原本起于 x=8，而电视会把最左 48px 裁掉 ——
    // 整个按钮（8~46）都落在被切掉的那一圈里。
    // ⚠️ 高度跟着 `safe.top` 一起加，否则内容会被挤在一条更矮的条里。
    final safe = AppTheme.safeAreaInsets(context);
    return Container(
      height: 48 + safe.top,
      color: AppTheme.cinema,
      padding: EdgeInsets.fromLTRB(8 + safe.left, safe.top, 8 + safe.right, 0),
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

    // 「同一部片换一档清晰度」——**用户自己刚点的操作**，不该只丢一个转圈让
    // 他猜是卡住了还是点了没反应。独立窗口那边有 `_switching`（半透明
    // 「正在切换…」），这里对齐它。判据与理由见 [shouldShowSwitchVeil]。
    final switching = shouldShowSwitchVeil(
      isLoading: controller.isLoading,
      duration: controller.duration,
    );

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

        // 换档走这一支：半透明罩 + 文案，**不盖掉上一帧**（用户视线里的位置
        // 一点没变）。它与下面那个通用缓冲圈互斥 —— 否则同一处会叠两个圈。
        if (switching && error == null)
          const _SwitchVeil()
        else if (controller.isBuffering && error == null)
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

        // TV 右侧设置面板。**浮在画面之上**，不占布局空间 —— 用 `Column`
        // 挤窄画面的话，调一次字幕就要让视频重新布局一次（画面会明显抖一下），
        // 而用户只是想看字幕有没有乱码。
        if (_tvPanelOpen)
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            child: PlayerTvOverlay(
              controller: controller,
              item: _item,
              siblings: _siblings,
              activeAudioId: _audioId,
              onPickQuality: _changeQuality,
              onPickSubtitle: _changeSubtitle,
              onPickAudioTrack: (track, index) {
                setState(() => _audioId = track.id);
                unawaited(controller.selectAudioTrack(track));
                unawaited(_rememberAudio(track, index));
              },
              onPickAudioEffect: _setAudioEffect,
              onPickRate: controller.setRate,
              onPickEpisode: _openItem,
              onJumpIntro: () async {
                final marker = controller.introMarker;
                if (marker == null) return;
                await controller.seek(marker.start);
              },
              onClose: _closeTvPanel,
              onActivity: _scheduleControlsHide,
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

    // ⛔ 控制栏贴着屏幕最下面，自身只有 6px 底内边距，而电视会把最下 27px
    // 裁掉 —— 那 6px 远不够，按钮那排的下半截会落进被切掉的一圈里
    // （TV 上图标放大到 34px，切掉一截很明显）。
    // ⚠️ 高度跟着 `safe.bottom` 一起加：只加内边距会把内容挤扁，反而更糟。
    //
    // ⚠️ 这一处与上面顶栏那处**是按几何推的，没有自动化用例**：播放页在
    // `flutter test` 里起不来（`PlaybackController` 的 `Player` 是字段初始化器，
    // 一构造就启 libmpv）。真机上请顺带看一眼控制栏有没有被切。
    final safe = AppTheme.safeAreaInsets(context);
    return Container(
      height: AppTheme.playerBarHeight + safe.bottom,
      color: AppTheme.cinema,
      padding: EdgeInsets.fromLTRB(
        12 + safe.left,
        0,
        12 + safe.right,
        6 + safe.bottom,
      ),
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
                // TV 上放大：22px 的图标隔着三米连「是暂停还是播放」都看不出来。
                iconSize: _isTv ? 34 : 22,
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
                iconSize: _isTv ? 26 : 17,
                tooltip: '后退 10 秒（←）',
                icon: const Icon(Icons.replay_10_rounded, color: AppTheme.muted),
              ),
              IconButton(
                onPressed: () =>
                    controller.seekRelative(const Duration(seconds: 10)),
                iconSize: _isTv ? 26 : 17,
                tooltip: '前进 10 秒（→）',
                icon: const Icon(
                  Icons.forward_10_rounded,
                  color: AppTheme.muted,
                ),
              ),
              SizedBox(width: _isTv ? 14 : 6),

              // 音量
              IconButton(
                onPressed: () => unawaited(
                  controller.setVolume(controller.volume > 0 ? 0 : 100),
                ),
                iconSize: _isTv ? 24 : 16,
                tooltip: controller.volume > 0 ? '静音' : '取消静音',
                icon: Icon(
                  controller.volume <= 0
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                  color: AppTheme.muted,
                ),
              ),
              // 音量滑块同样 `ExcludeFocus`（理由见方法头）。
              //
              // TV 上**干脆不画**它：遥控器的音量键走 CEC 到电视 / 功放，
              // 应用内这个滑块在电视上是个无效控件；而它占着 84px，会把下面
              // 那个「设置」入口往右推得更远。
              if (!_isTv)
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

              // TV 上给一个**可以点**的「设置」入口。
              //
              // 菜单键不是每台遥控器都有 —— 大量电视盒子只有方向键 + OK +
              // 返回。而右侧面板是这个版本里调画质 / 字幕 / 音轨 / 音效的
              // **唯一**入口，没有可点的入口，那些功能在那些设备上等于不存在。
              if (_isTv) _TvSettingsButton(onTap: _openTvPanel),

              // TV 上**不渲染这几组菜单按钮**。
              //
              // 它们是为鼠标排的：六个按钮横在一条 64 高的栏里，点两下就到。
              // 遥控器没有指针，要够到最右边那个得先按 ↓ 进这一栏、再按 → 一路
              // 挪过去，中途还会停在静音键和音量滑块上 —— 换个字幕要按七八下。
              // 于是「全都看得见、但要花很久才够得到」，这是电视上最难受的一类
              // 交互。全部并进右侧面板（一个键唤出、↑↓ 选、←→ 改），桌面
              // 那套原样保留 —— 鼠标用户并没有这个问题。
              if (!_isTv) ...[
                _QualityMenu(
                  controller: controller,
                  onSelected: (id) => unawaited(_changeQuality(id)),
                ),
                _SubtitleMenu(
                  controller: controller,
                  onSelected: (t) => unawaited(_changeSubtitle(t)),
                ),
                _AudioMenu(
                  controller: controller,
                  activeId: _audioId,
                  onSelected: (id) => setState(() => _audioId = id),
                  // 切轨由菜单自己做（它手里就有 `AudioTrack`），页面只负责
                  // 把「用户选了哪条」记进偏好。
                  onTrackSelected: (t, i) => unawaited(_rememberAudio(t, i)),
                ),
                // 「音效」紧跟「音轨」——它们解决的是同一个听感问题的两半，
                // 但**不是同一件事**，见 `_AudioEffectMenu` 的类文档。
                _AudioEffectMenu(
                  controller: controller,
                  onSelected: (p) => unawaited(_setAudioEffect(p)),
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
            ],
          ),
        ],
      ),
    );
  }

  /// `1:02:03` / `02:03`
  static String _fmt(Duration d) => _fmtClock(d);
}

/// TV 控制栏上的「设置」按钮 —— 打开右侧面板。
///
/// ## 为什么必须带文字
///
/// 纯图标按钮在电视上是个谜：没有 hover，用户按下去之前不可能知道会发生
/// 什么（项目里所有 tooltip 在 TV 上都等于不存在，理由见 `tv_affordance.dart`）。
/// 而这是**进入全部播放设置的唯一可点入口** —— 认不出来就等于没有。
///
/// ## 为什么写「设置」而不是「菜单」
///
/// 「菜单」在电视上容易和「系统菜单 / 遥控器菜单键」混起来。它打开的是画质 /
/// 字幕 / 音轨那一组，写「设置」更贴近它实际做的事。
class _TvSettingsButton extends StatelessWidget {
  const _TvSettingsButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.panel2,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          // 高度取 `tvActionHeight`（48）而不是由内边距撑出来：这个按钮是
          // **没有菜单键的遥控器上唯一一条进设置面板的路**，焦点框必须够大。
          // 按原来的 `vertical: 9` 撑出来只有 38 —— 隔三米按不中，而按不中的
          // 后果不是「少用一个功能」，是「选集 / 画质 / 字幕全都打不开」。
          child: SizedBox(
            height: AppTheme.tvActionHeight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.tune_rounded, size: 20, color: AppTheme.text),
                const SizedBox(width: 8),
                Text(
                  '设置',
                  style: const TextStyle(
                    fontSize: AppTheme.tvActionLabel,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.text,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
  const _QualityMenu({required this.controller, required this.onSelected});

  final PlaybackController controller;

  /// 选中某一档清晰度。**切档与「记进偏好」都由页面做**：只有切档真的
  /// 成功了才值得记（见 `_PlayerPageState._changeQuality`），菜单自己切完
  /// 就写库会记下一个其实没生效的档位。
  final ValueChanged<String> onSelected;

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
          onSelected: onSelected,
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
  const _SubtitleMenu({required this.controller, required this.onSelected});

  final PlaybackController controller;

  /// 选中某条字幕；**传 `null` 表示关闭字幕**。加载与记账都交给页面
  /// （见 `_PlayerPageState._changeSubtitle`）—— 只有真挂上了才记，
  /// 否则会记下一条下次打开同样加载失败的轨。
  final ValueChanged<SubtitleTrack?> onSelected;

  static const String _offValue = '__off__';

  @override
  Widget build(BuildContext context) {
    final tracks = controller.allSubtitles;
    final active = controller.activeSubtitleId;

    return Builder(
      builder: (buttonContext) => _MenuButton(
        tooltip: '字幕',
        onTap: () {
          // 菜单一打开就在后台预取**网盘字幕**正文：用户浏览菜单这几秒通常
          // 足够取完，等他真点下去就是瞬时挂上，而不是「点了没反应」。
          // 在线字幕不在预取范围（按次计费），理由见
          // `PlaybackController.prefetchCloudSubtitles`。
          controller.prefetchCloudSubtitles();
          unawaited(_openAnchoredMenu<String>(
            buttonContext: buttonContext,
            title: '字幕',
            onSelected: (value) {
              if (value == _offValue) {
                onSelected(null);
                return;
              }
              for (final t in tracks) {
                if (t.id == value) {
                  onSelected(t);
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
          ));
        },
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
    required this.onTrackSelected,
  });

  final PlaybackController controller;
  final String? activeId;
  final ValueChanged<String> onSelected;

  /// 用户切到了哪条音轨，**连同它在真实音轨列表里的下标**。
  ///
  /// 切轨由菜单自己完成（`AudioTrack` 就在它手里），页面只借这个回调
  /// **记账**（见 `_PlayerPageState._rememberAudio`）。
  final void Function(mk.AudioTrack track, int index) onTrackSelected;

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
            for (var i = 0; i < tracks.length; i++) {
              if (tracks[i].id == id) {
                onSelected(id);
                unawaited(controller.selectAudioTrack(tracks[i]));
                // 下标与轨道一起给出：语言标记一个都没写的片源里，
                // 「第几条」是唯一能跨集对上号的依据。
                onTrackSelected(tracks[i], i);
                return;
              }
            }
          },
          rows: (context, select) => [
            for (var i = 0; i < tracks.length; i++)
              _MenuTile(
                onTap: () => select(tracks[i].id),
                child: _MenuRow(
                  // 文案走 TrackLabels，**不要在这里自己拼**：独立播放窗口
                  // 用的是同一份（`player_window_app.dart` 的 `audioTitle`），
                  // 各写一份的代价是「同一个语言标记在两边显示得不一样」，
                  // 而两个播放器不会同时出现在同一块屏上，没人会发现。
                  label: TrackLabels.audioTitle(tracks[i]),
                  detail: TrackLabels.audioDetail(tracks[i]),
                  selected: tracks[i].id == activeId,
                ),
              ),
          ],
        )),
        child: const _BarButton(icon: Icons.graphic_eq_rounded, label: '音轨'),
      ),
    );
  }
}

class _RateMenu extends StatelessWidget {
  const _RateMenu({required this.controller});

  final PlaybackController controller;

  // 与 TV 右侧面板**同一张表**（理由见 `kPlaybackRates` 的文档）：这里再写
  // 一份的话，「电视上能选 2.0x、桌面上只有 1.5x」这种偏差不会有人发现 ——
  // 没人会开着两个平台对着数档位。
  static const List<double> _rates = kPlaybackRates;

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

/// 「音效」菜单 —— 输出的声道 / 直通模式。
///
/// ## ⛔ 与左边那个「音轨」菜单是两件完全不同的事
///
/// 两个入口在控制栏里挨着，名字也只差一个字，但它们的数据来源毫无关系：
///
///   - 「音轨」列的是**片源里封着的流**（`stream.tracks`）。一部 MKV 里有几条
///     完全由发布组决定，换一集就换一批，可能一条中文都没有。
///   - 「音效」是**播放端对输出的处理方式**，与片源封了什么无关 ——
///     同一部片子谁都能选立体声或直通。
///
/// 夸克播放器也是这么分的：帮助中心把「多语言音轨」写在**「语言」**入口下，
/// 「环绕音效」写在**「音效」**入口下，两者并列。所以**别把它们合并成一个菜单**
/// （合并后的第一个后果是：用户会以为「音效」里那一列就是能选的音轨，
/// 于是找不到粤语时来报「音轨丢了」）。
///
/// ## 为什么选项只有四个
///
/// 当前内置的 libmpv 里没有任何可用的音频 DSP 滤镜（EQ / 人声增强 /
/// 虚拟环绕都做不出来）。完整证据与「怎么才能解锁」写在
/// `core/utils/player_audio_effect.dart` 的类文档里 —— 加新预设之前先读它。
class _AudioEffectMenu extends StatelessWidget {
  const _AudioEffectMenu({required this.controller, required this.onSelected});

  final PlaybackController controller;

  /// 由页面负责「应用 + 落库」两件事 —— 落库要拿 settings 仓储，
  /// 而这个 widget 是纯展示。
  final ValueChanged<AudioEffectPreset> onSelected;

  @override
  Widget build(BuildContext context) {
    final active = controller.audioEffect;

    return Builder(
      builder: (buttonContext) => _MenuButton(
        tooltip: '音效',
        onTap: () => unawaited(_openAnchoredMenu<AudioEffectPreset>(
          buttonContext: buttonContext,
          title: '音效',
          maxWidth: 300,
          onSelected: onSelected,
          rows: (context, select) => [
            // ⚠️ 用 `selectable` 而不是 `all`：macOS 上「直通」会把整部片
            // 卡死，列出来只会变成一条「点了没反应」的反馈。理由见
            // `PlayerAudioEffect.passthroughAvailable`。
            for (final p in PlayerAudioEffect.selectable)
              _MenuTile(
                onTap: () => select(p),
                child: _MenuRow(
                  label: PlayerAudioEffect.label(p),
                  // 每一项都要说清「什么时候它才有区别」：不写的话
                  // 「立体声」在笔记本上与「跟随片源」**完全一样**（设备本来
                  // 就是 2.0，`auto-safe` 已经下混过了），用户会以为功能坏了。
                  detail: PlayerAudioEffect.detail(p),
                  selected: p == active,
                ),
              ),
            const Divider(height: 1, thickness: 1, color: Colors.white12),
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 9, 14, 11),
              child: Text(
                '人声增强 / 低音增强 / 虚拟环绕需要音频滤镜，当前内置播放引擎未提供。',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white38,
                  height: 1.35,
                ),
              ),
            ),
          ],
        )),
        child: _BarButton(
          icon: Icons.graphic_eq_rounded,
          // 默认档不写全名（`跟随片源`），与隔壁「倍速」在 1.0x 时只写
          // 「倍速」同一套口径：控制栏只有那么宽，常态不该占地方。
          label: active == AudioEffectPreset.auto
              ? '音效'
              : PlayerAudioEffect.label(active),
          active: active != AudioEffectPreset.auto,
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
/// 换清晰度时压在画面上的那一层：半透明 + 「正在切换…」。
///
/// ## 为什么**不**盖成不透明
///
/// 换档时 mpv 的视频输出**还挂着上一帧**，用户视线里的位置一点没变 ——
/// 把整块画面盖死等于把那一帧也抹了，看起来就是「重新缓存了一遍」，正是
/// 这个改动要消掉的那个观感。所以只压一层 55% 的黑。
///
/// ## 为什么要 [IgnorePointer]
///
/// 这层只是告知，不该吃掉点击：用户照样要能点暂停、点返回。独立窗口的
/// 加载罩出于同样的理由也这么写。
///
/// ## 与通用缓冲圈的关系
///
/// 两者在 `_buildStage` 里是**互斥**的：换档时画这一层，真正的网络卡顿才画
/// 那个裸转圈。同一处叠两个圈会让「切档」和「网卡了」看起来一模一样。
class _SwitchVeil extends StatelessWidget {
  const _SwitchVeil();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.55),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white70,
                ),
              ),
              SizedBox(height: 12),
              Text(
                '正在切换…',
                style: TextStyle(fontSize: 13, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
