import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'tv_focus.dart';

/// TV 播放器右侧纵向面板上的一行。
///
/// 枚举顺序**就是**面板上从上到下的顺序，也**就是**遥控器 ↑ / ↓ 的遍历顺序。
/// 「选集」放第一行：电视上看剧时最常动的就是它；「倍速」几乎不用，放最后。
/// 顺序本身就是在替用户省按键。
enum PlayerTvRow {
  episode('选集', Icons.smart_display_rounded),
  quality('画质', Icons.high_quality_rounded),
  subtitle('字幕', Icons.subtitles_rounded),
  audioTrack('音轨', Icons.speaker_rounded),
  audioEffect('音效', Icons.graphic_eq_rounded),
  rate('倍速', Icons.speed_rounded),

  /// 片头。放最后：它是**低频**动作（一部片最多用一次），而上面六项
  /// 是「边看边调」的。
  ///
  /// ⚠️ 这一项在 TV 上**只能跳、不能标**。手标片头要把播放头定位到某一秒，
  /// 遥控器做不了（长按方向键最快也要几十秒），所以面板里只给「跳到片头」。
  /// 标记那一路留在桌面控制栏 —— 那里有鼠标拖进度条。
  intro('片头', Icons.skip_next_rounded);

  const PlayerTvRow(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// 一行的当前状态。
class PlayerTvRowValue {
  const PlayerTvRowValue({
    required this.row,
    required this.value,
    this.adjustable = true,
  });

  final PlayerTvRow row;

  /// 当前值。空串表示这一项目前没有可用选项（行上显示「—」并灰掉）。
  ///
  /// 例如：服务端只给了原画一档时画质写着「原画」但不可调；这一集没有
  /// 任何字幕轨道时字幕是空串。
  final String value;

  /// ← / → 能不能改它。只有**一个**可选项时为 `false`。
  ///
  /// ⚠️ 这个标志必须真的把箭头画成灰的：用户按了没反应，唯一的结论是
  /// 「遥控器坏了」或者「这个应用卡了」，而不是「这一项只有一档」。
  /// 电视上没有任何 hover 提示能替我们把这句话说出来。
  final bool adjustable;
}

/// ↑ / ↓ 之后选中行落到哪一行。
///
/// **循环**：最后一行按 ↓ 回到第一行。
///
/// 为什么循环而不是撞墙：六行的列表在电视上循环远比「走到头就停」好用 ——
/// 从「倍速」回到「选集」只要按一下，而不是连按五次 ↑。而在**只有六行**的
/// 列表里循环不会让人迷失（不像几百项的海报墙，那里循环会让人以为翻页了）。
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
// 视觉令牌（面板这一块专用）
//
// 这块面板是**唯一**长得不像应用其余部分的地方：它是浮在视频上的一层，
// 底色、圆角、阴影都要按「叠在画面上」来定，不能直接套页面那套 `panel` 平面。
// 收在这里是为了让「改一个数字」只改一处 —— 七个行、两页共用。
// ---------------------------------------------------------------------------

/// 面板卡片的宽度。
const double _kPanelWidth = 400;

/// 卡片与屏幕上下缘的距离。**必须 ≥ 过扫描的 27**，否则卡片上下两条圆角
/// 在真机上会被切平（电视会把最外一圈裁掉）。
const double _kPanelMarginY = 28;

/// 卡片圆角。
const double _kCardRadius = 20;

/// 一行的高度。
///
/// ⚠️ 这是**高度预算**里最大的一块，改之前先看 [TvPanelShell] 的文档：
/// 7 行 × 52 + 表头 54 + 底部提示 40 ≈ 458，而卡片只有
/// 540 − 28×2 = **484** —— 余量 26px。
const double _kRowHeight = 52;

/// 面板卡片本体：底色、描边、阴影、圆角。
///
/// 两页（行列表 / 集数网格）共用一份 —— 各写一份的话，切到「选集」时
/// 卡片的圆角与阴影会跳一下，而那种差异没人会当成 bug 去报。
class TvPanelCard extends StatelessWidget {
  const TvPanelCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      // ⛔ `clipBehavior` 不能省：里面的行高亮是圆角矩形，不裁的话
      // 选中行会盖住卡片的圆角，看着像卡片被啃掉一个角。
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_kCardRadius),
        // 上深下浅的一点点渐变，比纯色多一层「这是一块浮起来的玻璃」的暗示。
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppTheme.panel2.withValues(alpha: 0.97),
            AppTheme.panel.withValues(alpha: 0.97),
          ],
        ),
        border: Border.all(
          color: AppTheme.line.withValues(alpha: 0.9),
          width: 0.8,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0xCC000000),
            blurRadius: 32,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// 面板右侧那一列的容器：**宽度、卡片外观、焦点、键盘回退**。
///
/// 抽出来是因为它有两页共用（行列表 / 集数网格），两页的键盘语义不同，
/// 但「贴右、不铺满、拿焦点、吃掉没认出来的键」完全一样。
///
/// ## ⛔ 焦点必须由调用方给（[focusNode]）
///
/// 这里虽然留着 `autofocus: true`，但它**只在所在 scope 还没有焦点时**才
/// 生效 —— 而播放页的画面节点早就占着焦点了。所以面板能不能收到按键，
/// 取决于调用方在打开之后有没有 `requestFocus` 到这个节点上。
/// 不做的后果是用户报的那句：「菜单键能弹出 OSD，但上下键按不动」。
///
/// ## ⚠️ 不铺满整屏，但**纵向要铺满**
///
/// 横向只占右边一条：调字幕和调画质时必须看得见画面，那是唯一的反馈
/// （字幕有没有乱码、换档之后清不清楚），盖住画面就没法调了。
///
/// 纵向则相反 —— 它必须拿到**整屏高度**。播放页原来把它放进画面那一块
/// （`Stack` 在 `Expanded` 里），而面板一开控制栏也要显示，于是可用高
/// 只剩 540 − 75 − 91 = **374**：七行 × 52 装不下，第 5 行往后要滚动才
/// 看得见，而**电视上没有滚动条**。所以它现在挂在页面最外层的 `Stack` 上，
/// 高度是整屏，再靠 [_kPanelMarginY] 避让上下过扫描带。
class TvPanelShell extends StatelessWidget {
  const TvPanelShell({
    super.key,
    required this.child,
    required this.onActivity,
    required this.onUnhandledKey,
    this.focusNode,
    this.width = _kPanelWidth,
  });

  final Widget child;

  /// 面板的焦点节点，**由播放页持有**（理由见类文档）。`null` 时自建一个 ——
  /// 单测里就是这么用的。
  final FocusNode? focusNode;

  /// 任意一次按键。**必须**回调它：面板自己吃掉按键后，外层那个
  /// 「无操作 30 秒收起控制栏」的倒计时收不到事件，会当着正在调字幕的
  /// 用户把面板收掉。
  final VoidCallback onActivity;

  /// 这一页没认出来的键（数字键、媒体键…）交给这里决定。
  /// 返回 `true` 表示已处理，面板会报 `handled` 阻止它继续冒泡。
  final bool Function(LogicalKeyboardKey key) onUnhandledKey;

  final double width;

  @override
  Widget build(BuildContext context) {
    // 电视上这块面板是**贴右**的，而屏幕最右 48px 是过扫描带 ——
    // 厂商电视会把那一圈裁掉。
    //
    // ⛔ 只缩**内容**（卡片），不缩外层 `SizedBox`：面板的右缘要一直贴到
    // 屏幕边缘（贴右是这个面板的设计）；把整块往里挪 48px 会在右边留一条
    // 露出视频的缝，看起来像没对齐。
    //
    // ⚠️ 上下也避让（[_kPanelMarginY]）—— 面板现在纵向铺满整屏，
    // 不避让的话卡片上下两条圆角会落进过扫描带里被切平。
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
      child: SizedBox(
        width: width,
        child: Padding(
          padding: EdgeInsets.only(
            right: safe.right,
            top: _kPanelMarginY,
            bottom: _kPanelMarginY,
          ),
          child: TvPanelCard(child: child),
        ),
      ),
    );
  }
}

/// 面板顶部那一行「图标 + 标题」。
class TvPanelHeader extends StatelessWidget {
  const TvPanelHeader({super.key, required this.title, this.icon});

  final String title;

  /// 默认用「播放设置」那个滑杆图标；集数页换成「选集」的图标。
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              gradient: AppTheme.brandGradient,
            ),
            child: Icon(
              icon ?? Icons.tune_rounded,
              size: 17,
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
                fontSize: 17,
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

/// 底部那行「按键说明」。三个小键帽 + 三句话。
///
/// 用键帽而不是一整句「↑↓ 选项目 · ←→ 改 · 菜单键关闭」：电视上那句话
/// 折成两行、挤成一片小字，读起来像免责声明；而键帽把「哪个键」与
/// 「干什么」分开了，扫一眼就够。
class TvPanelKeyHints extends StatelessWidget {
  const TvPanelKeyHints({super.key, required this.hints});

  final List<(String key, String action)> hints;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: [
          for (var i = 0; i < hints.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            _KeyCap(hints[i].$1),
            const SizedBox(width: 5),
            Text(
              hints[i].$2,
              style: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
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

/// 面板第一页：纵向的设置行列表。
///
/// ## 为什么 TV 上不要「焦点在按钮菜单里横移」
///
/// 桌面那套控制栏把画质 / 字幕 / 音轨 / 音效 / 倍速排成一行按钮，鼠标点两下
/// 就到。遥控器没有指针：要够到最右边那个按钮，得先按 ↓ 进控制栏、再按 →
/// 一路挪过去，中途还会停在静音按钮和音量滑块上（而滑块**吃方向键**，见
/// `_buildControlBar` 的注释）。于是「换个字幕」变成一件要按七八下的事 ——
/// **全都看得见，但要花很久才够得到**，这正是电视上最难受的一类交互。
///
/// 改成：一个键唤出右侧纵向面板，↑ / ↓ 选类别，← / → 直接改值。
/// 任何一个设置都在三步之内（唤出 → 选行 → 改值），全程不需要指针。
class PlayerTvPanel extends StatelessWidget {
  const PlayerTvPanel({
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

  /// 改值。`delta` 为 -1（←）或 +1（→）。
  final void Function(PlayerTvRow row, int delta) onAdjust;

  /// OK 落在某一行上。
  ///
  /// 交给调用方决定，是因为不同行的 OK 语义**根本不同**：「选集」是进二级页
  /// （集数可能几十条，左右键挪不过来）、「片头」是一次跳转、其余各项则是
  /// 「换下一个」（与 → 同义）。把这些塞进面板里会让它变成一个什么都得知道
  /// 的组件，而它本该只管导航。
  final ValueChanged<PlayerTvRow> onActivate;

  final VoidCallback onClose;
  final VoidCallback onActivity;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return TvPanelShell(
      focusNode: focusNode,
      onActivity: onActivity,
      onUnhandledKey: (key) {
        switch (key) {
          case LogicalKeyboardKey.arrowUp:
            onSelectedChanged(
              nextTvRowIndex(
                current: selectedIndex,
                delta: -1,
                total: rows.length,
              ),
            );
          case LogicalKeyboardKey.arrowDown:
            onSelectedChanged(
              nextTvRowIndex(
                current: selectedIndex,
                delta: 1,
                total: rows.length,
              ),
            );
          case LogicalKeyboardKey.arrowLeft:
            onAdjust(rows[selectedIndex].row, -1);
          case LogicalKeyboardKey.arrowRight:
            onAdjust(rows[selectedIndex].row, 1);
          case LogicalKeyboardKey.select || LogicalKeyboardKey.enter:
            onActivate(rows[selectedIndex].row);
          case LogicalKeyboardKey.contextMenu || LogicalKeyboardKey.escape:
            onClose();
          case _:
            // 数字键、媒体键一律放行给外层：它们的语义（跳到 N%、播放/暂停）
            // 与焦点在哪无关，不该被面板吞掉。
            return false;
        }
        return true;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const TvPanelHeader(title: '播放设置'),
          const Divider(height: 0.5, color: AppTheme.line),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 6),
              // 行高在 TV 上放大到 52，七行加起来可能超过面板高度 ——
              // 用 `ListView` 而不是 `Column`，多出来的部分才滚得动
              // （遥控器 ↑↓ 会自动滚到可视区，见评估文档探针 1）。
              itemCount: rows.length,
              itemBuilder: (context, i) => _PanelRow(
                value: rows[i],
                selected: i == selectedIndex,
              ),
            ),
          ),
          const TvPanelKeyHints(
            hints: [
              ('↑↓', '选择'),
              ('←→', '调整'),
              ('菜单', '关闭'),
            ],
          ),
        ],
      ),
    );
  }
}

/// 面板里的一行。
class _PanelRow extends StatelessWidget {
  const _PanelRow({required this.value, required this.selected});

  final PlayerTvRowValue value;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final row = value.row;
    final color = selected ? AppTheme.text : AppTheme.muted;
    // 不可调的行：箭头与值一起压暗。判据只有 [PlayerTvRowValue.adjustable]
    // 一处 —— 不在这里另判「值是不是空」。
    final arrowColor = !value.adjustable
        ? AppTheme.line
        : (selected ? AppTheme.accent : AppTheme.muted);

    return Padding(
      // 上下各 2 + 左右各 8：选中态的圆角高亮**缩进**在行内，看着像一颗
      // 浮在卡片上的胶囊，而不是一条顶满两边的色带 —— 后者是原来那版
      // 「呆板」的来源之一。
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        height: _kRowHeight - 4,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.accent.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          // ⛔ 描边**常驻**、只换颜色。改成「选中才画」的话，边框会把内容
          // 挤进去 3px —— 按 ↑↓ 时整行会左右抖一下。
          border: Border.all(
            color: selected
                ? AppTheme.accent.withValues(alpha: 0.55)
                : Colors.transparent,
            width: 1.5,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: AppTheme.accent.withValues(alpha: 0.22),
                    blurRadius: 14,
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Icon(row.icon, size: 19, color: color),
            const SizedBox(width: 12),
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
            // 箭头灰掉 = 「这一项改不了」。见 [PlayerTvRowValue.adjustable]。
            Icon(Icons.chevron_right_rounded, size: 18, color: arrowColor),
          ],
        ),
      ),
    );
  }
}

/// 面板第二页：集数网格。
///
/// 敢用 `InkWell` 网格而不是自绘焦点遍历，是因为探针实测过：D-pad 在懒加载
/// `GridView.builder` 里能从第 0 项一路走到第 55 项、边走边补建
/// （见 `docs/AndroidTV-遥控器体验评估.md` §3 探针 1）。焦点遍历与 OK 激活
/// 这两件最难的事 Flutter 默认就给对了，自己写一遍只会更差。
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

  /// 菜单键 / Esc：回到行列表（不是关闭整个面板 —— 那一层由播放页决定）。
  final VoidCallback onClose;

  final VoidCallback onActivity;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return TvPanelShell(
      focusNode: focusNode,
      onActivity: onActivity,
      onUnhandledKey: (key) => switch (key) {
        // 菜单键在这里是「返回行列表」，与在行列表里是「关闭面板」不同 ——
        // 二级页的返回必须比关闭更先发生，否则用户想退回上一层却整个退出。
        LogicalKeyboardKey.contextMenu || LogicalKeyboardKey.escape => _close(),
        _ => false,
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TvPanelHeader(
            title: '选集（$count）',
            icon: Icons.smart_display_rounded,
          ),
          const Divider(height: 0.5, color: AppTheme.line),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.6,
              ),
              itemCount: count,
              itemBuilder: (context, i) => _EpisodeCell(
                label: labelOf(i),
                current: i == currentIndex,
                onTap: () => onPick(i),
              ),
            ),
          ),
          const TvPanelKeyHints(hints: [('菜单', '返回')]),
        ],
      ),
    );
  }

  bool _close() {
    onClose();
    return true;
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
    return TvFocusable(
      borderRadius: BorderRadius.circular(12),
      child: Material(
        color: current ? Colors.transparent : AppTheme.panel3,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          // 「当前这一集」用品牌渐变而不是纯强调色：整块网格里只有一格是
          // 渐变的，扫一眼就能定位到「我在哪」。
          decoration: BoxDecoration(
            gradient: current ? AppTheme.brandGradient : null,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: current
                  ? Colors.transparent
                  : AppTheme.line.withValues(alpha: 0.8),
              width: 0.8,
            ),
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
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: current ? Colors.white : AppTheme.text,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
