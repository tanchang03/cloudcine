import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// TV 播放器底部菜单上的一行。
///
/// 枚举顺序**就是**菜单上从上到下的顺序，也**就是**遥控器 ↑ / ↓ 的遍历顺序。
/// 「选集」放第一行：电视上看剧时最常动的就是它；「片头」几乎不用，放最后。
/// 顺序本身就是在替用户省按键。
///
/// ## ⚠️ 这里曾经还有一行「全屏（收起控制栏）」，已经删掉
///
/// 它原本的作用是给用户一条「调完设置回到干净画面」的路 —— 那时面板一开就
/// 退出沉浸，不补一行的话只剩「等 30 秒自动收起」和「按返回键退出播放」两条路。
/// 现在的菜单本身就是一条路：**菜单键 / 返回键关掉菜单 = 回到干净画面**
/// （`_PlayerPageState._closeTvPanel` 会同时进入沉浸）。功能没丢，少了一行。
enum PlayerTvRow {
  episode('选集', Icons.smart_display_rounded),
  quality('画质', Icons.high_quality_rounded),
  subtitle('字幕', Icons.subtitles_rounded),
  audioTrack('音轨', Icons.speaker_rounded),
  audioEffect('音效', Icons.graphic_eq_rounded),
  rate('倍速', Icons.speed_rounded),

  /// 片头。低频动作（一部片最多用一次），而上面六项是「边看边调」的。
  ///
  /// ⚠️ 这一项在 TV 上**只能跳、不能标**。手标片头要把播放头定位到某一秒，
  /// 遥控器做不了（长按方向键最快也要几十秒），所以菜单里只给「跳到片头」。
  /// 标记那一路留在桌面控制栏 —— 那里有鼠标拖进度条。
  intro('片头', Icons.skip_next_rounded);

  const PlayerTvRow(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// 一行里的一项可选值。
///
/// ## 为什么是「列表」而不是「当前值 + ←→ 循环」
///
/// 原来这一行只带一个**当前值字符串**，改值靠 ← / → 逐档循环。用户看不到
/// 有哪些档、也不知道下一档是什么 —— 换字幕时他得按一下、看一眼、再按一下。
/// 这是「全都看不见，还要花很久才够得到」，与电视上最难受的那类交互正好
/// 是同一种。
///
/// 现在每一项都摊开成一颗 chip（见 [PlayerTvOption] 的渲染处），用户一眼
/// 看全，← / → 只是在**已经看得见的**几颗之间挪。
class PlayerTvOption {
  const PlayerTvOption(this.label, {this.enabled = true});

  final String label;

  /// 能不能选。`false` 的那一颗仍然**画出来**（灰掉），只是 ← / → 会跳过它。
  ///
  /// ⚠️ 灰掉但保留，是为了回答「为什么没有 4K 这一档」：直接不画的话，用户
  /// 只会以为这个应用不支持 4K。而 ← / → 跳过它，是为了不让用户按了 OK
  /// 才弹一条「这一档服务端没给地址」—— 那时他已经按了两下才知道自己那下
  /// 没生效。
  final bool enabled;
}

/// 一行的当前状态。
class PlayerTvRowValue {
  const PlayerTvRowValue({
    required this.row,
    required this.value,
    this.adjustable = true,
    this.options = const <PlayerTvOption>[],
    this.selectedOption = 0,
    this.hint,
  });

  final PlayerTvRow row;

  /// 当前值。空串表示这一项目前没有可用选项（行上显示「—」）。
  ///
  /// 例如：服务端只给了原画一档时画质写着「原画」但不可调；这一集没有
  /// 任何字幕轨道时字幕是空串。
  final String value;

  /// 这一行能不能用 ← / → 动。
  ///
  /// ⚠️ 这个标志必须真的把箭头画成灰的：用户按了没反应，唯一的结论是
  /// 「遥控器坏了」或者「这个应用卡了」，而不是「这一项只有一档」。
  /// 电视上没有任何 hover 提示能替我们把这句话说出来。
  final bool adjustable;

  /// 这一行的全部可选项。**空 = 不画选项条**。
  ///
  /// 空的两种情形：一次动作（「片头」），或者选项太多不适合铺成一条
  /// （「选集」走二级页，见 [PlayerTvEpisodeGrid]）。那时选项条的位置改画
  /// [hint] 那一句话 —— 保持菜单高度恒定，焦点上下走的时候整块不会跳。
  final List<PlayerTvOption> options;

  /// 当前生效项在 [options] 里的下标。`options` 非空时它必须落在范围内
  /// （没有精确对应项时退回 0，例如字幕「关闭」就占着第 0 颗）。
  final int selectedOption;

  /// `options` 为空时，选项条那一格里写的一句说明。
  ///
  /// 写法与「片头」那一行的值同一套：写的是**按 OK 会发生什么**，
  /// 而不是当前状态。
  final String? hint;
}

/// ↑ / ↓ 之后选中行落到哪一行。
///
/// **循环**：最后一行按 ↓ 回到第一行。
///
/// 为什么循环而不是撞墙：七行的列表在电视上循环远比「走到头就停」好用 ——
/// 从最后一行「片头」回到第一行「选集」只要按一下，而不是连按六次 ↑。
/// 而在**只有七八行**的列表里循环不会让人迷失（不像几百项的海报墙，
/// 那里循环会让人以为翻页了）。
///
/// 抽成纯函数是因为「取模方向写反」是这类代码最典型的错：写成加完再 clamp
/// 的话，边界那一下永远不动，而它既不报错也不崩溃 —— 只有断言能钉住。
int nextTvRowIndex({
  required int current,
  required int delta,
  required int total,
}) {
  if (total <= 0) return 0;
  // Dart 的 `%` 是欧几里得取模：`(-1) % 6 == 5`。所以 current + delta 为负
  // 时不必先补 total，结果天然落在 [0, total)。
  return (current + delta) % total;
}

// ---------------------------------------------------------------------------
// 视觉令牌（底部菜单这一块专用）
//
// 这块菜单是**唯一**长得不像应用其余部分的地方：它是浮在视频上的一层，
// 底色、圆角、阴影都要按「叠在画面上」来定，不能直接套页面那套 `panel` 平面。
// 收在这里是为了让「改一个数字」只改一处 —— 两个页面共用。
// ---------------------------------------------------------------------------

/// 一行的高度。
///
/// ⚠️ 这是**高度预算**里最大的一块，改之前先看 [kPlayerTvSheetHeight]。
const double _kRowHeight = 40;

/// 选项条 / 说明条那一格的高度。**恒定**，与有没有选项无关 ——
/// 变高变矮的话，焦点上下走的时候整块菜单会跟着跳。
const double _kStripHeight = 50;

/// 菜单内容的上下内边距。
const double _kSheetPadding = 8;

/// 卡片顶部那条描边有多粗。
const double _kCardBorderWidth = 0.8;

/// 菜单内容（七行 + 选项条 + 上下内边距）需要的高度。
const double _kSheetContentHeight =
    7 * _kRowHeight + _kStripHeight + _kSheetPadding * 2;

/// 底部菜单的总高。
///
/// ## 这个数是怎么来的
///
/// 内容 = 七行 × [_kRowHeight] + 选项条 [_kStripHeight] + 上下内边距
///       = 7 × 40 + 50 + 8 × 2 = 330，再加上 [_kCardBorderWidth]。
///
/// ⚠️ **末尾那 0.8 不能省。** `Container` 会把 `decoration` 上那条描边算成
/// **内容的内边距**（`decoration.padding`），于是内容实得的高度比 `height`
/// 少 0.8px。少了它，七行会溢出 0.8px —— Flutter 会把溢出画成黄黑斜纹，
/// 而电视上没有滚动条，用户看到的是最下面一行被削掉一条边。
/// 这不是理论：**这一条是被单测抓出来的**（`RenderFlex overflowed by 0.8
/// pixels`），当时只是把行高从 46 收到 40，肉眼完全看不出来。
///
/// 菜单**不留滚动**：电视上没有滚动条，滚出去的行等于不存在（用户不会知道
/// 下面还有「音效 / 倍速 / 片头」）。所以这个常量是「内容必须装得下」的
/// 硬预算 —— 加一行、或把行高改大之前，先算一遍。
///
/// ## 屏幕还剩多少给画面
///
/// 960×540 上菜单贴着下缘、再避让 27 的过扫描带，于是顶边落在
/// 540 − 27 − 346.8 ≈ **166**。画面仍然铺满整屏，只是下面这段被菜单盖住 ——
/// 换字幕 / 换画质时看的就是上面那 166px。
///
/// ⚠️ 这也是字幕要**抬高**的原因：字幕原本贴在画面底部（距下缘 44），
/// 正好在菜单后面。播放页在菜单打开时把字幕的内边距加大（见
/// `_PlayerPageState._subtitleBottomPadding`），与夸克播放器的做法一致
/// （它的字幕区固定在 y 215–315，菜单在它下面）。
const double kPlayerTvSheetHeight = _kSheetContentHeight + _kCardBorderWidth;

/// 选项条里一颗 chip 的高度。
const double _kChipHeight = 34;

/// 底部菜单的卡片本体：底色、描边、阴影、圆角。
///
/// 两个页面（行菜单 / 选集网格）共用一份 —— 各写一份的话，切到「选集」时
/// 卡片的圆角与阴影会跳一下，而那种差异没人会当成 bug 去报。
///
/// ⚠️ 只有**上**面两个角是圆的：它贴着屏幕下缘，下面两个角本来就看不见，
/// 画了反而会在避让过扫描带时露出一截圆弧。
class TvSheetCard extends StatelessWidget {
  const TvSheetCard({super.key, required this.child, this.height});

  final Widget child;
  final double? height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      // ⛔ `clipBehavior` 不能省：里面的行高亮是圆角矩形，不裁的话
      // 选中行会盖住卡片的圆角，看着像卡片被啃掉一个角。
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        // 上深下浅的一点点渐变，比纯色多一层「这是一块浮起来的玻璃」的暗示。
        // 末端留一点透明度：菜单只占下半屏，完全压死会让画面看起来被切断了。
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppTheme.panel2.withValues(alpha: 0.97),
            AppTheme.panel.withValues(alpha: 0.94),
          ],
        ),
        border: Border(
          top: BorderSide(
            color: AppTheme.line.withValues(alpha: 0.9),
            width: _kCardBorderWidth,
          ),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0xCC000000),
            blurRadius: 28,
            offset: Offset(0, -8),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// 底部菜单的容器：**高度、卡片外观、焦点、键盘回退**。
///
/// 抽出来是因为它有两页共用（行菜单 / 选集网格），两页的键盘语义不同，
/// 但「贴底、拿焦点、吃掉没认出来的键」完全一样。
///
/// ## ⛔ 焦点必须由调用方给（[focusNode]）
///
/// 这里虽然留着 `autofocus: true`，但它**只在所在 scope 还没有焦点时**才
/// 生效 —— 而播放页的画面节点早就占着焦点了。所以菜单能不能收到按键，
/// 取决于调用方在打开之后有没有 `requestFocus` 到这个节点上。
/// 不做的后果是用户报的那句：「菜单键能弹出 OSD，但上下键按不动」。
class TvSheetShell extends StatelessWidget {
  const TvSheetShell({
    super.key,
    required this.child,
    required this.onActivity,
    required this.onUnhandledKey,
    this.focusNode,
    this.height = kPlayerTvSheetHeight,
  });

  final Widget child;

  /// 菜单的焦点节点，**由播放页持有**（理由见类文档）。`null` 时自建一个 ——
  /// 单测里就是这么用的。
  final FocusNode? focusNode;

  /// 任意一次按键。**必须**回调它：菜单自己吃掉按键后，外层那个
  /// 「无操作 30 秒收起控制栏」的倒计时收不到事件，会当着正在调字幕的
  /// 用户把菜单收掉。
  final VoidCallback onActivity;

  /// 这一页没认出来的键（数字键、媒体键…）交给这里决定。
  /// 返回 `true` 表示已处理，菜单会报 `handled` 阻止它继续冒泡。
  final bool Function(LogicalKeyboardKey key) onUnhandledKey;

  final double height;

  @override
  Widget build(BuildContext context) {
    // 电视上这块菜单贴着下缘，而屏幕最下 27px 是过扫描带 —— 厂商电视会把
    // 那一圈裁掉。只缩**内容**（卡片），外框仍然贴到屏幕边缘。
    final safe = AppTheme.safeAreaInsets(context);

    return Focus(
      focusNode: focusNode,
      // 单测 / 单页预览里没有别人抢焦点，`autofocus` 让键盘直接可用；
      // 真机上由播放页显式 `requestFocus`（见类文档）。
      autofocus: true,
      onKeyEvent: (node, event) {
        // 长按要能连着改（倍速从 1.0 调到 2.0 要按好几下），所以 repeat 也处理。
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        onActivity();
        if (onUnhandledKey(event.logicalKey)) return KeyEventResult.handled;
        return KeyEventResult.ignored;
      },
      child: Padding(
        padding: EdgeInsets.only(
          left: safe.left,
          right: safe.right,
          bottom: safe.bottom,
        ),
        child: TvSheetCard(
          height: height,
          child: SizedBox(width: double.infinity, child: child),
        ),
      ),
    );
  }
}

/// 底部菜单右下角那行「按键说明」。**浮在卡片上**，不占高度预算。
///
/// 用键帽而不是一整句「↑↓ 选项目 · ←→ 改 · 菜单键关闭」：电视上那句话
/// 折成两行、挤成一片小字，读起来像免责声明；而键帽把「哪个键」与
/// 「干什么」分开了，扫一眼就够。
///
/// ⚠️ 这套导航是**新**的（原来只有 ↑↓ + ←→ 逐档循环），用户第一次见到的
/// 时候没有任何线索 —— 所以这行提示不能省。
class TvSheetKeyHints extends StatelessWidget {
  const TvSheetKeyHints({super.key, required this.hints});

  final List<(String key, String action)> hints;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < hints.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          _KeyCap(hints[i].$1),
          const SizedBox(width: 5),
          Text(
            hints[i].$2,
            style: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
          ),
        ],
      ],
    );
  }
}

class _KeyCap extends StatelessWidget {
  const _KeyCap(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.panel3.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.line, width: 0.5),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          height: 1.15,
          fontWeight: FontWeight.w600,
          color: AppTheme.muted,
        ),
      ),
    );
  }
}

/// 底部菜单第一页：**纵向七行 + 选中行的横向选项条**。
///
/// ## 交互（照夸克播放器）
///
///   * ↑ / ↓ —— 在七行之间走（循环）；
///   * ← / → —— 在**选中那一行**的选项条里走；那一行没有选项时交给
///     [onAdjust]（目前只有「选集」用它来上一集 / 下一集）；
///   * OK —— 应用选中的那一颗（「片头」这种一次动作行则直接执行）；
///   * 菜单 / Esc —— 收起菜单。
///
/// ## 为什么不要「焦点在按钮之间横移」
///
/// 桌面那套控制栏把画质 / 字幕 / 音轨 / 音效 / 倍速排成一行按钮，鼠标点两下
/// 就到。遥控器没有指针：要够到最右边那个按钮，得先按 ↓ 进控制栏、再按 →
/// 一路挪过去，中途还会停在静音按钮和音量滑块上（而滑块**吃方向键**）。
/// 于是「换个字幕」变成一件要按七八下的事 —— **全都看得见，但要花很久才
/// 够得到**，这正是电视上最难受的一类交互。
///
/// ## 与「右侧竖排面板」那一版的区别
///
/// 那一版把选项收在「当前值」一个字符串里，改值只能逐档循环、看不到全貌。
/// 这一版把选项**摊开**成一条 chip（照夸克），并且整块挪到了底部横排 ——
/// 电视是 16:9 的，纵向挤七行会让每一行的可用宽度变得很窄。
class PlayerTvSheet extends StatefulWidget {
  const PlayerTvSheet({
    super.key,
    required this.rows,
    required this.selectedIndex,
    required this.onSelectedChanged,
    required this.onAdjust,
    required this.onActivate,
    required this.onClose,
    required this.onActivity,
    this.focusNode,
  });

  final List<PlayerTvRowValue> rows;
  final int selectedIndex;

  /// 选中行变了（↑ / ↓）。
  final ValueChanged<int> onSelectedChanged;

  /// ← / → 落在**没有选项条**的行上时回调（目前只有「选集」）。
  /// `delta` 为 -1（←）或 +1（→）。
  ///
  /// ⚠️ 有选项条的行**不走这里** —— 那几行的 ← / → 只是在挪光标，
  /// 真正生效要等 OK。理由：挪一下画质就重取一次流，连按 → 会连取五次，
  /// 而用户只是想看看有哪些档。
  final void Function(PlayerTvRow row, int delta) onAdjust;

  /// OK 落在某一行上。
  ///
  /// `optionIndex` 是选项条里被选中的那颗的下标；这一行没有选项条时为 -1。
  ///
  /// 交给调用方决定，是因为不同行的 OK 语义**根本不同**：「选集」是进二级页
  /// （集数可能几十条，横着挪不过来）、「片头」是一次跳转、其余各项则是
  /// 「应用选中的那一颗」。把这些塞进菜单里会让它变成一个什么都得知道的
  /// 组件，而它本该只管导航。
  final void Function(PlayerTvRow row, int optionIndex) onActivate;

  final VoidCallback onClose;
  final VoidCallback onActivity;
  final FocusNode? focusNode;

  @override
  State<PlayerTvSheet> createState() => _PlayerTvSheetState();
}

class _PlayerTvSheetState extends State<PlayerTvSheet> {
  /// 选项条里光标的位置。**归菜单自己管**：它纯是界面状态，播放页不需要
  /// 知道「用户正停在第三颗上」—— 只有按下 OK 的那一刻才有意义。
  int _chip = 0;

  /// 选项条横向滚动用。选项多到一行放不下（字幕轨多的时候）才用得上。
  final ScrollController _stripScroll = ScrollController();

  /// 每颗 chip 的 key —— 用来把新选中的那颗滚进视野。
  final Map<int, GlobalKey> _chipKeys = {};

  @override
  void initState() {
    super.initState();
    _chip = _currentOptionIndex();
  }

  @override
  void didUpdateWidget(PlayerTvSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedIndex != oldWidget.selectedIndex) {
      // 换行：光标回到「这一行当前生效的那一颗」。
      //
      // ⚠️ 不重置的话，从「倍速」第 6 档按 ↑ 到「画质」会落在画质的第 6 档上
      // —— 而画质可能只有 4 档，`options[5]` 直接抛 RangeError。
      _chip = _currentOptionIndex();
      if (_stripScroll.hasClients) _stripScroll.jumpTo(0);
      return;
    }
    // 没换行但选项条变短了（例如字幕轨加载完、可用档位少了）：
    // 把光标夹回范围内，否则下面 `options[_chip]` 会越界。
    final total = _optionsOf(widget.selectedIndex).length;
    if (total > 0 && _chip >= total) _chip = total - 1;
  }

  @override
  void dispose() {
    _stripScroll.dispose();
    super.dispose();
  }

  List<PlayerTvOption> _optionsOf(int rowIndex) {
    if (rowIndex < 0 || rowIndex >= widget.rows.length) {
      return const <PlayerTvOption>[];
    }
    return widget.rows[rowIndex].options;
  }

  /// 光标该落在哪一颗：这一行当前生效的那颗；没有精确对应项时退回第 0 颗。
  int _currentOptionIndex() {
    final total = _optionsOf(widget.selectedIndex).length;
    if (total == 0) return 0;
    final sel = widget.rows[widget.selectedIndex].selectedOption;
    return sel.clamp(0, total - 1);
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final selected = widget.selectedIndex;

    // 七行 + 选中行下面那一格选项条。选项条**插在选中行之后**（照夸克），
    // 所以它的位置会随焦点上下走 —— 而总高度恒定（选项条那一格的高度与
    // 有没有选项无关），于是整块菜单的上下缘不会跟着跳。
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      children.add(
        _SheetRow(
          value: rows[i],
          selected: i == selected,
          onTap: () {
            if (i != selected) widget.onSelectedChanged(i);
          },
        ),
      );
      if (i == selected) children.add(_buildStrip(rows[i]));
    }

    return TvSheetShell(
      focusNode: widget.focusNode,
      onActivity: widget.onActivity,
      onUnhandledKey: _onKey,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: _kSheetPadding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
          // 按键说明浮在右下角，**不占高度预算**（占的话就要从七行里抠）。
          Positioned(
            right: 18,
            bottom: 6,
            child: TvSheetKeyHints(
              hints: const [
                ('↑↓', '换行'),
                ('←→', '选择'),
                ('OK', '确定'),
                ('菜单', '关闭'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 选中行下面那一格：有选项就画 chip，没有就写一句「按 OK 会怎样」。
  Widget _buildStrip(PlayerTvRowValue value) {
    final options = value.options;

    if (options.isEmpty) {
      return SizedBox(
        height: _kStripHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(56, 0, 18, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              value.hint ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5, color: AppTheme.dim),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: _kStripHeight,
      child: SingleChildScrollView(
        controller: _stripScroll,
        scrollDirection: Axis.horizontal,
        // 全部 chip 一次建出来（不是懒加载），`Scrollable.ensureVisible`
        // 才有东西可滚 —— 见 [_revealChip]。
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Row(
            children: [
              for (var i = 0; i < options.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                _SheetChip(
                  key: _chipKeys.putIfAbsent(i, GlobalKey.new),
                  label: options[i].label,
                  focused: i == _chip,
                  selected: i == value.selectedOption,
                  enabled: options[i].enabled,
                  onTap: () {
                    setState(() => _chip = i);
                    widget.onActivate(value.row, i);
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  bool _onKey(LogicalKeyboardKey key) {
    final rows = widget.rows;
    if (rows.isEmpty) return false;
    final index = widget.selectedIndex.clamp(0, rows.length - 1);
    final value = rows[index];
    final options = value.options;

    switch (key) {
      case LogicalKeyboardKey.arrowUp:
        widget.onSelectedChanged(
          nextTvRowIndex(current: index, delta: -1, total: rows.length),
        );
      case LogicalKeyboardKey.arrowDown:
        widget.onSelectedChanged(
          nextTvRowIndex(current: index, delta: 1, total: rows.length),
        );
      case LogicalKeyboardKey.arrowLeft:
        if (options.isEmpty) {
          widget.onAdjust(value.row, -1);
        } else {
          _moveChip(-1, options);
        }
      case LogicalKeyboardKey.arrowRight:
        if (options.isEmpty) {
          widget.onAdjust(value.row, 1);
        } else {
          _moveChip(1, options);
        }
      case LogicalKeyboardKey.select || LogicalKeyboardKey.enter:
        widget.onActivate(value.row, options.isEmpty ? -1 : _chip);
      case LogicalKeyboardKey.contextMenu || LogicalKeyboardKey.escape:
        widget.onClose();
      case _:
        // 数字键、媒体键一律放行给外层：它们的语义（跳到 N%、播放/暂停）
        // 与焦点在哪无关，不该被菜单吞掉。
        return false;
    }
    return true;
  }

  /// 在选项条里挪一格。**不循环**：撞到两端就停。
  ///
  /// 循环在这里是纯困惑 —— 选项条是**看得见**的一排，从最后一颗绕回第一颗
  /// 会让人觉得光标「跳」了，而不是「绕回来了」。
  void _moveChip(int delta, List<PlayerTvOption> options) {
    var i = _chip;
    while (true) {
      i += delta;
      if (i < 0 || i >= options.length) return; // 到头了
      if (options[i].enabled) break;
    }
    if (i == _chip) return;
    setState(() => _chip = i);
    _revealChip();
  }

  /// 把光标那一颗滚进视野（选项多到一行放不下时才会真的滚）。
  void _revealChip() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _chipKeys[_chip]?.currentContext;
      if (context == null) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
      );
    });
  }
}

/// 菜单里的一行：图标 + 名字 + 当前值 + 箭头。
class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final PlayerTvRowValue value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final row = value.row;
    final color = selected ? AppTheme.text : AppTheme.muted;
    // 不可调的行：箭头压暗。判据只有 [PlayerTvRowValue.adjustable] 一处 ——
    // 不在这里另判「值是不是空」。
    final arrowColor = !value.adjustable
        ? AppTheme.line
        : (selected ? AppTheme.accent : AppTheme.muted);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        height: _kRowHeight,
        // ⚠️ 只有**横向**留白，没有纵向 margin：纵向留白会算进高度预算，
        // 七行各多 2px 就是 14px —— 正好把 [kPlayerTvSheetHeight] 撑破。
        // 行与行之间不靠留白分开，靠选中行的圆角底色。
        margin: const EdgeInsets.symmetric(horizontal: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.accent.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          // ⛔ 这里**不画描边、也不发光**（原来是 1.5px 描边 + blurRadius 14
          // 的辉光）。理由与 [TvFocusable] 完全同一条：电视上「一圈亮边」在
          // 3 米外就是一团糊住内容的粗框 —— 实测截图里它比行内容还抢眼。
          //
          // 去掉不是「少了一个信号」：选中态本来就有两条更清楚的信号，
          // 就是下面注释里说的**背景 0.18 蒙层**与**字重 w600**。描边和辉光
          // 是叠在上面的冗余，去掉后与媒体库那边的「提亮罩」才是同一种语言。
          //
          // ⚠️ 0.18 这个数与 [TvFocusable] 的默认 `tint` 是同一个值，改一处
          // 就要想另一处 —— 两边视觉要一致。
        ),
        child: Row(
          children: [
            Icon(row.icon, size: 18, color: color),
            const SizedBox(width: 14),
            Text(
              row.label,
              style: TextStyle(
                fontSize: 15,
                // ⚠️ 字重是「焦点落在哪一行」的主要信号之一（另一条是背景）。
                // 单测直接断言它，别改成别的表达方式。
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: color,
              ),
            ),
            const Spacer(),
            Flexible(
              child: Text(
                value.value.isEmpty ? '—' : value.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                  color: value.value.isEmpty
                      ? AppTheme.dim
                      : (selected ? AppTheme.text : AppTheme.muted),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 箭头灰掉 = 「这一项动不了」。见 [PlayerTvRowValue.adjustable]。
            Icon(Icons.chevron_right_rounded, size: 18, color: arrowColor),
          ],
        ),
      ),
    );
  }
}

/// 选项条里的一颗。
///
/// 三种状态**必须能一眼分开**（电视上没有 hover、没有指针）：
///   * 当前生效（[selected]）—— 实心强调色 + 白字 + 勾；
///   * 光标所在（[focused]）—— 提亮罩 + 轻微放大；
///   * 不可选（`enabled == false`）—— 压暗、去色。
///
/// 「光标所在」与「当前生效」是**两件事**：用户挪到「4K」上但还没按 OK 时，
/// 画面仍是原画 —— 两态合一的话，用户会以为已经换了。
class _SheetChip extends StatelessWidget {
  const _SheetChip({
    super.key,
    required this.label,
    required this.focused,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool focused;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color text;
    final Color? fill;
    if (!enabled) {
      text = AppTheme.dim;
      fill = AppTheme.panel3.withValues(alpha: 0.6);
    } else if (selected) {
      text = Colors.white;
      fill = AppTheme.accent;
    } else {
      text = focused ? AppTheme.text : AppTheme.muted;
      fill = AppTheme.panel3;
    }

    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: focused ? 1.05 : 1,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          height: _kChipHeight,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? Colors.transparent
                  : AppTheme.line.withValues(alpha: 0.8),
              width: 0.8,
            ),
            boxShadow: focused && !selected
                ? const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 10,
                      offset: Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                const Icon(Icons.check_rounded, size: 15, color: Colors.white),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected || focused
                      ? FontWeight.w600
                      : FontWeight.w400,
                  color: text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 底部菜单第二页：选集网格。
///
/// 敢用 `InkWell` 网格而不是自绘焦点遍历，是因为探针实测过：D-pad 在懒加载
/// `GridView.builder` 里能从第 0 项一路走到第 55 项、边走边补建
/// （见 `docs/AndroidTV-遥控器体验评估.md` §3 探针 1）。焦点遍历与 OK 激活
/// 这两件最难的事 Flutter 默认就给对了，自己写一遍只会更差。
///
/// ⚠️ 与第一页不同，这一页**真的用 Flutter 焦点**（格子是 `InkWell`）——
/// 因为集数可能几十条，用 ↑↓←→ 自己算坐标比交给遍历更容易写错。
class PlayerTvEpisodeGrid extends StatelessWidget {
  const PlayerTvEpisodeGrid({
    super.key,
    required this.count,
    required this.currentIndex,
    required this.labelOf,
    required this.onPick,
    required this.onClose,
    required this.onActivity,
    this.focusNode,
  });

  final int count;

  /// 当前集的下标；-1 表示当前这条不在剧集列表里。
  final int currentIndex;

  final String Function(int index) labelOf;

  final ValueChanged<int> onPick;

  /// 菜单键 / Esc：回到行菜单（不是关闭整个菜单 —— 那一层由播放页决定）。
  final VoidCallback onClose;

  final VoidCallback onActivity;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return TvSheetShell(
      focusNode: focusNode,
      onActivity: onActivity,
      onUnhandledKey: (key) => switch (key) {
        // 菜单键在这里是「返回行菜单」，与在行菜单里是「关闭菜单」不同 ——
        // 二级页的返回必须比关闭更先发生，否则用户想退回上一层却整个退出。
        LogicalKeyboardKey.contextMenu || LogicalKeyboardKey.escape => _close(),
        _ => false,
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TvSheetHeader(title: '选集（$count）', icon: Icons.smart_display_rounded),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 6,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 2.2,
              ),
              itemCount: count,
              itemBuilder: (context, i) => _EpisodeCell(
                label: labelOf(i),
                current: i == currentIndex,
                onTap: () => onPick(i),
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _close() {
    onClose();
    return true;
  }
}

/// 底部菜单顶部那一行「图标 + 标题」。只有二级页用得上。
class TvSheetHeader extends StatelessWidget {
  const TvSheetHeader({super.key, required this.title, this.icon});

  final String title;

  /// 默认用「播放设置」那个滑杆图标；集数页换成「选集」的图标。
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              gradient: AppTheme.brandGradient,
            ),
            child: Icon(
              icon ?? Icons.tune_rounded,
              size: 15,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppTheme.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EpisodeCell extends StatelessWidget {
  const _EpisodeCell({
    required this.label,
    required this.current,
    required this.onTap,
  });

  final String label;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: current ? Colors.transparent : AppTheme.panel3,
      borderRadius: BorderRadius.circular(10),
      child: Ink(
        // 「当前这一集」用品牌渐变而不是纯强调色：整块网格里只有一格是
        // 渐变的，扫一眼就能定位到「我在哪」。
        decoration: BoxDecoration(
          gradient: current ? AppTheme.brandGradient : null,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: current
                ? Colors.transparent
                : AppTheme.line.withValues(alpha: 0.8),
            width: 0.8,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: current ? Colors.white : AppTheme.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
