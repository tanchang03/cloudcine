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
/// ⚠️ 这是聚焦菜单里**标题行**的高度（只显示当前分类那一行，不是七行列表）。
const double _kRowHeight = 44;

/// 选项条 / 说明条那一格的高度。**恒定**，与有没有选项无关。
const double _kStripHeight = 50;

/// 菜单内容的上下内边距。
const double _kSheetPadding = 10;

/// 卡片顶部那条描边有多粗。
const double _kCardBorderWidth = 0.8;

/// 聚焦式菜单内容（标题行 + 选项条 + 上下内边距）需要的高度。
const double _kSheetContentHeight =
    _kRowHeight + _kStripHeight + _kSheetPadding * 2;

/// 底部菜单的总高。
///
/// ## 这个数是怎么来的
///
/// 2026-10-05 起菜单从「七行纵排 + 选中行下方选项条」改为**聚焦式 XY 交叉
/// 菜单**：每次只显示**当前一个分类**（Y）及其选项条（X）。原因是 TV 上
/// 4K 播放时（CPU 169%）每次按键重建全部七行（每行还带 140ms 动画）+ 大阴影
/// 卡片会明显掉帧；聚焦后屏幕上永远只有 1 个分类 + 一组选项。
///
/// 内容 = 标题行 [_kRowHeight] + 选项条 [_kStripHeight] + 上下内边距
///       = 44 + 50 + 10 × 2 = 114，再加上 [_kCardBorderWidth]。
///
/// ⚠️ **末尾那 0.8 不能省。** `Container` 会把 `decoration` 上那条描边算成
/// **内容的内边距**（`decoration.padding`），于是内容实得的高度比 `height`
/// 少 0.8px。少了它，标题行会溢出 0.8px —— Flutter 会把溢出画成黄黑斜纹，
/// 而电视上没有滚动条，用户看到的是内容被削掉一条边。
const double kPlayerTvSheetHeight = _kSheetContentHeight + _kCardBorderWidth;

/// 选集网格二级页的高度。
///
/// 网格页需要比行菜单高得多（要放得下好几行集数格子），所以它**显式传**
/// 自己的高度，而不是沿用聚焦菜单的 [kPlayerTvSheetHeight]。
const double kPlayerTvEpisodeGridHeight = 420;

/// 选项条里一颗 chip 的高度。
const double _kChipHeight = 34;

/// 底部菜单的卡片本体：底色、描边、阴影、圆角（夸克式毛玻璃）。
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
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        // 夸克式：顶部稍亮的 success 玻璃，下缘渐深。比纯色多一层浮起感，
        // 末端留一点透明度，菜单只占下半屏，不把画面压死。
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF262E42).withValues(alpha: 0.98),
            const Color(0xFF141824).withValues(alpha: 0.96),
          ],
        ),
        // ⚠️ 只能用单边 uniform 边框：`Border` 四边颜色不一致时不能配
        // `borderRadius`（框架直接抛 FlutterError）。侧边那圈用阴影补。
        border: Border(
          top: BorderSide(
            color: Colors.white.withValues(alpha: 0.14),
            width: _kCardBorderWidth,
          ),
        ),
        boxShadow: const [
          // ⚠️ blur 从 44/60 收到 26/34：Mali GPU 上大 blur 阴影每帧重绘很贵，
          // 而聚焦菜单比原七行版矮了 2/3，阴影面积本来就小。视觉上仍是
          // 「浮在画面上的卡片」，只是不再为「更柔的边」付每一帧的 GPU。
          BoxShadow(
            color: Color(0xE0202738),
            blurRadius: 26,
            spreadRadius: 2,
            offset: Offset(0, -10),
          ),
          BoxShadow(
            color: Color(0x1A5B8CFF),
            blurRadius: 34,
            offset: Offset(0, -4),
          ),
        ],
      ),
      child: Stack(
        children: [
          child,
          // 顶部小横条（夸克式把手）：纯装饰，不占高度预算，浮在内容上。
          Positioned(
            top: 6,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ],
      ),
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
    // 夸克式：整行坐在半透明 pill 上，浮在卡片右下角更整体。
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.08), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < hints.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            _KeyCap(hints[i].$1),
            const SizedBox(width: 5),
            Text(
              hints[i].$2,
              style: TextStyle(
                  fontSize: 11.5, color: Colors.white.withValues(alpha: 0.55)),
            ),
          ],
        ],
      ),
    );
  }
}

class _KeyCap extends StatelessWidget {
  const _KeyCap(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(7),
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.14), width: 0.5),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          height: 1.15,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// 底部菜单：**聚焦式 XY 交叉菜单**。
///
/// ## 交互（照夸克播放器的「每次只显示一个分类的选项」）
///
///   * ↑ / ↓ —— **切换分类**（Y 轴），标题行换成本分类名 + 当前值 + 位置
///     （如「画质 · 超清  2/7」）。每次只渲染**当前这一个分类**的选项条；
///   * ← / → —— 在当前分类的选项条里走（X 轴）；这一行没有选项时交给
///     [onAdjust]（「选集」用它直接换集）；
///   * OK —— 应用选中的那一颗（「片头」这种一次动作行则直接执行）；
///   * 菜单 / Esc —— 收起菜单。
///
/// ## 为什么从「七行全显示」改成「聚焦单分类」
///
/// 原版把七个分类全部竖排，选中行下方再铺选项条。在 TV 上播放 4K 时
/// （CPU 169–232%），每次按键都要重建七行（每行带 140ms `AnimatedContainer`
/// 动画）+ 整块大阴影卡片，Mali GPU 上明显掉帧。
///
/// 聚焦后屏幕上永远只有 **1 个标题行 + 1 组选项 chip**，每次按键 rebuild 的
/// 子树从「整张七行表」缩成「一个分类」，动画 / 阴影面积也一并大幅减小。
/// 代价是用户看不到其它分类 —— 用标题行上的「N/7」位置指示补上定位感。
///
/// ## 为什么不要「焦点在按钮之间横移」
///
/// 桌面那套控制栏把画质 / 字幕 / 音轨 / 音效 / 倍速排成一行按钮，鼠标点两下
/// 就到。遥控器没有指针：要够到最右边那个按钮，得先按 ↓ 进控制栏、再按 →
/// 一路挪过去。于是「换个字幕」变成一件要按七八下的事 —— 全都看得见，但
/// 要花很久才够得到。聚焦式里「换分类」只要按一下 ↑/↓。
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

  /// 选中分类变了（↑ / ↓）。
  final ValueChanged<int> onSelectedChanged;

  /// ← / → 落在**没有选项条**的分类上时回调（目前只有「选集」）。
  /// `delta` 为 -1（←）或 +1（→）。
  final void Function(PlayerTvRow row, int delta) onAdjust;

  /// OK 落在某个分类上。
  ///
  /// `optionIndex` 是选项条里被选中的那颗的下标；这一分类没有选项条时为 -1。
  final void Function(PlayerTvRow row, int optionIndex) onActivate;

  final VoidCallback onClose;
  final VoidCallback onActivity;
  final FocusNode? focusNode;

  @override
  State<PlayerTvSheet> createState() => _PlayerTvSheetState();
}

class _PlayerTvSheetState extends State<PlayerTvSheet> {
  /// 选项条里光标的位置。**归菜单自己管**：它纯是界面状态。
  int _chip = 0;

  /// 选项条横向滚动用。选项多到一行放不下才用得上。
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
      // 换分类：光标回到「新分类当前生效的那一颗」。
      _chip = _currentOptionIndex();
      _chipKeys.clear();
      if (_stripScroll.hasClients) _stripScroll.jumpTo(0);
      return;
    }
    // 没换分类但选项条变短了（例如字幕轨加载完、可用档位少了）：
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

  /// 光标该落在哪一颗：这一分类当前生效的那颗；没有精确对应项时退回第 0 颗。
  int _currentOptionIndex() {
    final total = _optionsOf(widget.selectedIndex).length;
    if (total == 0) return 0;
    final sel = widget.rows[widget.selectedIndex].selectedOption;
    return sel.clamp(0, total - 1);
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    if (rows.isEmpty) {
      // 数据还没到的那一帧：一个空卡片，别崩也别画错。
      return TvSheetShell(
        focusNode: widget.focusNode,
        onActivity: widget.onActivity,
        onUnhandledKey: _onKey,
        child: const SizedBox(height: _kRowHeight),
      );
    }
    final index = widget.selectedIndex.clamp(0, rows.length - 1);
    final value = rows[index];

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
              children: [
                _FocusRowHeader(
                  value: value,
                  positionLabel: '${index + 1}/${rows.length}',
                ),
                _buildStrip(value),
              ],
            ),
          ),
          // 按键说明浮在右下角，**不占高度预算**。
          Positioned(
            right: 18,
            bottom: 8,
            child: TvSheetKeyHints(
              hints: const [
                ('↑↓', '换项'),
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

  /// 选项条：有选项就画 chip，没有就写一句「按 OK 会怎样」。
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
        return false;
    }
    return true;
  }

  /// 在选项条里挪一格。**不循环**：撞到两端就停。
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

/// 聚焦菜单的标题行：图标 + 分类名 + 当前值 + 「N/M」位置指示。
///
/// 它取代原版七行列表里那一行 `_SheetRow`，但只渲染**当前分类**这一个。
/// 为了省 GPU：不用 `AnimatedContainer`（原版每行都有 140ms 动画，四行以上
/// 就开始掉帧），选中态靠图标底 / 色条即时切换。
class _FocusRowHeader extends StatelessWidget {
  const _FocusRowHeader({required this.value, required this.positionLabel});

  final PlayerTvRowValue value;
  final String positionLabel;

  @override
  Widget build(BuildContext context) {
    final row = value.row;
    return SizedBox(
      height: _kRowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            // 左侧强调色条（选中定位信号）。
            Container(
              width: 3,
              height: 18,
              decoration: BoxDecoration(
                color: AppTheme.accent,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
            const SizedBox(width: 10),
            // 图标放在圆角小方块里。
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: AppTheme.accent.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(row.icon, size: 17, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Text(
              row.label,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                value.value.isEmpty ? '—' : value.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.text,
                ),
              ),
            ),
            const Spacer(),
            // 位置指示：让用户知道这是第几个分类（聚焦模式看不到其它分类）。
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                positionLabel,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.55),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 选项条里的一颗（夸克式 pill）。
///
/// 三种状态**必须能一眼分开**（电视上没有 hover、没有指针）：
///   * 当前生效（[selected]）—— 白底 + 深色字 + 勾（夸克选中态）；
///   * 光标所在（[focused]）—— 放大 + 边框提亮 + 字变白；
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
    final Color border;
    if (!enabled) {
      text = AppTheme.dim.withValues(alpha: 0.7);
      fill = Colors.white.withValues(alpha: 0.04);
      border = Colors.white.withValues(alpha: 0.06);
    } else if (selected) {
      // 夸克式选中：白底 pill + 深色字，在一排深色 chip 里一眼定位。
      text = const Color(0xFF141824);
      fill = Colors.white;
      border = Colors.white;
    } else if (focused) {
      text = Colors.white;
      fill = Colors.white.withValues(alpha: 0.16);
      border = Colors.white.withValues(alpha: 0.38);
    } else {
      text = AppTheme.muted;
      fill = Colors.white.withValues(alpha: 0.07);
      border = Colors.white.withValues(alpha: 0.10);
    }

    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        // ⚠️ 1.05 是单测断言的值（见 player_tv_panel_test），别改。
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
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: border, width: 0.8),
            boxShadow: [
              if (selected)
                const BoxShadow(
                  color: Color(0x4DFFFFFF),
                  blurRadius: 12,
                  offset: Offset(0, 2),
                )
              else if (focused)
                const BoxShadow(
                  color: Color(0x40000000),
                  blurRadius: 10,
                  offset: Offset(0, 3),
                ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                Icon(Icons.check_rounded,
                    size: 15, color: text),
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
      height: kPlayerTvEpisodeGridHeight,
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
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              gradient: AppTheme.brandGradient,
              boxShadow: const [
                BoxShadow(
                  color: Color(0x405B8CFF),
                  blurRadius: 12,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            child: Icon(
              icon ?? Icons.tune_rounded,
              size: 16,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: Colors.white,
              ),
            ),
          ),
          Text(
            'OK 选择 · 菜单返回',
            style: TextStyle(
              fontSize: 11.5,
              color: Colors.white.withValues(alpha: 0.45),
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
      color: current ? Colors.transparent : Colors.white.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(12),
      child: Ink(
        // 「当前这一集」用品牌渐变而不是纯强调色：整块网格里只有一格是
        // 渐变的，扫一眼就能定位到「我在哪」。
        decoration: BoxDecoration(
          gradient: current ? AppTheme.brandGradient : null,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: current
                ? Colors.white.withValues(alpha: 0.35)
                : Colors.white.withValues(alpha: 0.10),
            width: 0.8,
          ),
          boxShadow: current
              ? const [
                  BoxShadow(
                    color: Color(0x505B8CFF),
                    blurRadius: 14,
                    offset: Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
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
