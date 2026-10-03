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

/// 面板右侧那一列的容器：**宽度、底色、焦点、键盘回退**。
///
/// 抽出来是因为它有两页共用（行列表 / 集数网格），两页的键盘语义不同，
/// 但「贴右、不铺满、拿焦点、吃掉没认出来的键」完全一样。
/// ⚠️ **不铺满整屏**：调字幕和调画质时必须看得见画面，那是唯一的反馈
/// （字幕有没有乱码、换档之后清不清楚），盖住画面就没法调了。
class TvPanelShell extends StatelessWidget {
  const TvPanelShell({
    super.key,
    required this.child,
    required this.onActivity,
    required this.onUnhandledKey,
    this.width = 344,
  });

  final Widget child;

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
    // ⚠️ 实测（960 宽、面板 `right: 0`）：行里最右那个箭头量到 x=914.25，
    // 安全线在 912 —— **只探进去约 2px**。所以这不是「字被切了一半」那种醒目
    // 毛病，只是擦着边：行值本身在箭头左边约 30px，离安全线还有余量。
    // 仍然避让的两个理由：① 这点余量会随面板宽度 / 行内边距变动，擦线很容易
    // 变成真切；② 全项目其它页面都按 48 留白，播放器不该是唯一的例外。
    // （⛔ 只避让右边；上下为什么不避让，见下面那处 `Padding` 的实测数字。）
    final safe = AppTheme.safeAreaInsets(context);

    return Focus(
      // 面板一开就把焦点拿过来：否则 ↑ / ↓ 还落在画面上（画面会拿它去快进），
      // 而本面板的 `onKeyEvent` 根本收不到事件。
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
      child: Container(
        width: width,
        decoration: BoxDecoration(
          color: AppTheme.panel.withValues(alpha: 0.96),
          border: Border(left: BorderSide(color: AppTheme.line, width: 0.5)),
          boxShadow: const [
            BoxShadow(color: Color(0x99000000), blurRadius: 24),
          ],
        ),
        // ⛔ 只缩**内容**，不缩 `Container` 本身。面板底色与左边那条描边要
        // 一直铺到屏幕边缘（贴右是这个面板的设计）；把整个面板往里挪 48px
        // 会变成一块浮在画面中间的卡片，右边留一条露出视频的缝。
        //
        // ⛔ **只避让右边，不避让上下** —— 这是量出来的取舍，不是漏了。
        // 实测（960×540）：
        //   表头 56 + 分隔线 0.5 + 底部提示 60 = 116.5（提示那行会折成两行）
        //   7 行 × 60 = 420
        //   面板高 540 − 116.5 = 423.5 → 只剩 **3.5px** 余量
        // 也就是面板是**按 7 行正好塞满**做的。上下各加 27 之后视口掉到 369.5，
        // 溢出 50.5px → 第 7 行「片头」被推到屏幕外，而**电视上没有滚动条**，
        // 用户不会知道下面还有一行。
        // 两者相权：标题上沿被切掉几像素，比整个设置项消失轻得多。
        // ⚠️ 想两全的话得改设计（行高 60→52、或把底部提示压成一行）——
        // 那是产品决定，留给人来定；`maxScrollExtent == 0` 的用例会钉住这条线。
        child: Padding(
          padding: EdgeInsets.only(right: safe.right),
          child: child,
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

  @override
  Widget build(BuildContext context) {
    return TvPanelShell(
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
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Text(
              '播放设置',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppTheme.text,
              ),
            ),
          ),
          const Divider(height: 0.5, color: AppTheme.line),
          Expanded(
            child: ListView.builder(
              // 行高在 TV 上放大到 60，六行加起来可能超过面板高度 ——
              // 用 `ListView` 而不是 `Column`，多出来的部分才滚得动
              // （遥控器 ↑↓ 会自动滚到可视区，见评估文档探针 1）。
              itemCount: rows.length,
              itemBuilder: (context, i) => _PanelRow(
                value: rows[i],
                selected: i == selectedIndex,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
            child: Text(
              '↑↓ 选项目 · ←→ 改 · 菜单键关闭',
              style: TextStyle(fontSize: 12.5, color: AppTheme.dim),
            ),
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

    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: selected ? AppTheme.panel3 : Colors.transparent,
        // 选中行左侧那一条竖线：光靠背景色差在电视上不够醒目 —— 面板底色
        // 本来就是深色，30% 的提亮在 3 米外几乎看不出来。
        border: Border(
          left: BorderSide(
            color: selected ? AppTheme.accent : Colors.transparent,
            width: 3,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(row.icon, size: 20, color: color),
          const SizedBox(width: 14),
          Text(
            row.label,
            style: TextStyle(
              fontSize: 16,
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
                fontSize: 15,
                color: value.value.isEmpty ? AppTheme.dim : AppTheme.text,
              ),
            ),
          ),
          const SizedBox(width: 10),
          // 箭头灰掉 = 「这一项改不了」。见 [PlayerTvRowValue.adjustable]。
          Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: value.adjustable ? AppTheme.muted : AppTheme.line,
          ),
        ],
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
  });

  final int count;

  /// 当前集的下标；-1 表示当前这条不在剧集列表里。
  final int currentIndex;

  final String Function(int index) labelOf;

  final ValueChanged<int> onPick;

  /// 菜单键 / Esc：回到行列表（不是关闭整个面板 —— 那一层由播放页决定）。
  final VoidCallback onClose;

  final VoidCallback onActivity;

  @override
  Widget build(BuildContext context) {
    return TvPanelShell(
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
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Row(
              children: [
                const Icon(
                  Icons.smart_display_rounded,
                  size: 20,
                  color: AppTheme.muted,
                ),
                const SizedBox(width: 12),
                Text(
                  '选集（$count）',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.text,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 0.5, color: AppTheme.line),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
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
      borderRadius: BorderRadius.circular(10),
      child: Material(
        color: current ? AppTheme.accent : AppTheme.panel2,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
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
    );
  }
}
