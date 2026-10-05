import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'tv_text.dart';
import 'tv_text_field.dart';

/// 页面标题栏。
///
/// 统一「大标题 + 副标题 + 右侧操作」的版式：三个一级页面各写一份的话，
/// 字号/间距会各自漂移，切页时能看出「跳」。
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    // TV 上**操作区独占一行**，不再挤在标题右侧。
    //
    // 桌面那排版（标题在左、六个操作挤在右边一行）是为鼠标定的：一眼扫过去，
    // 鼠标直接点目标。遥控器下它的代价极高 —— 960 的屏去掉 96 过扫描和 240
    // 侧栏只剩 624，六个控件挤在里面，焦点从海报墙按 ↑ 上来会落在**最右边**
    // 那个，用户要连按 ← 才能到最左边；而且每个只有 17px 图标，隔三米看不出
    // 是什么。
    //
    // 竖排之后：操作区有整行 624 可用，且「从海报墙上按一次 ↑」就到 ——
    // 那正是遥控器唯一能做的事。
    if (AppTheme.isTvLayout(context)) {
      return Padding(
        // 上下各 10/8：TV 上垂直空间比水平更宝贵 —— 页头每省下 10px，
        // 海报墙就多露出 10px 的封面（实测见下面 `Wrap` 那段）。
        padding: const EdgeInsets.fromLTRB(22, 10, 22, 8),
        child: Wrap(
          // ⚠️ **`Wrap`，不能是 `Row`** —— 这一处实测溢出 145px。
          //
          // 媒体库页头有八个控件（刮削 / 重扫 / 视图切换 / 搜索框 / 排序 /
          // 筛选 / 选择 / 刷新）。桌面版把它们横排在标题右侧，因为总宽度够；
          // 电视上页面只拿到 624（960 − 过扫描 96 − 侧栏 240），页头自己再吃掉
          // 44 的内边距 → **580**。`Row` 在 580 里塞不下这八个，会溢出
          // 145px：Debug 下是一块黄黑斜纹，Release 下溢出部分**直接被裁掉**，
          // 看起来就像「筛选和刷新这两个按钮本来就没有」—— 而它们其实还在
          // 焦点链里，遥控器按得到、屏幕上却看不见，用户只会以为遥控器坏了。
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // ⚠️ **标题块是 `Wrap` 的第一项**，不是另起一行的 `Column`。
            //
            // 两种排法的实测差距（960×540、页面实得 624×486）：
            //   * 标题独占一行 + 操作区折行 → 页头 **284px**（原来就是这样）；
            //   * 标题当作第一个可折行的块   → 页头 **122px**。
            // 省下的 162px 全归海报墙 —— 卡片高 166，原来一屏连**一行都露不全**。
            //
            // 折行的结果是：第一行「标题 · 刮削 · 重扫 · 封面/列表」，
            // 第二行「搜索 · 排序 · 筛选 · 选择 · 刷新」—— 分组也正好合理。
            ConstrainedBox(
              // ⛔ 必须夹宽度：`Wrap` 给子项的约束是**无界**的，不夹的话
              // 文件夹页那条长路径副标题会把整个页头撑出屏幕，而且
              // `Wrap` 不像 `Row` 那样会报溢出 —— 它只是**静静地画到屏幕外**。
              constraints: const BoxConstraints(maxWidth: 260),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: AppTheme.tvHeaderTitle,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.text,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: AppTheme.tvHeaderSubtitle,
                        color: AppTheme.dim,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            ...actions,
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.text,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.dim,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // 间距由这里统一给，调用方**不要**再往 `actions` 里塞
          // `SizedBox(width: …)` 当间隔 —— TV 那一支是 `Wrap`，自带 `spacing`，
          // 那些占位盒子会变成一个个「可以单独折到下一行」的 8px 宽小块，
          // 折行位置因此变得不可预测（表现为页头忽高忽低）。
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            actions[i],
          ],
        ],
      ),
    );
  }
}

/// 页头右侧的搜索框（媒体库与文件夹共用）。
///
/// ## 为什么两处必须共用一份
///
/// 它坐在 `PageHeader` 的同一行、紧挨着图标按钮，任何一处改宽度 / 改圆角 /
/// 改提示色，切页时都能看出「跳」一下。而两处各写一份的话，这种漂移是慢慢
/// 发生的、不会有人报 bug。
///
/// ⚠️ 高度是**写死的 32**，故意不进 `tvTextScaler`：页头那一行（含搜索框）
/// 不能在 TV 上放大字号 —— 一个固定高度的输入框一旦被放大字号，里面的字会
/// 顶破 32 的框、触发 `RenderFlex` 溢出。要放大也得先让这个 `SizedBox`
/// 改吸收高度（海报网格那类没有固定高的容器才套了 `tvTextScaler`）。
class HeaderSearchBox extends StatelessWidget {
  const HeaderSearchBox({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.hint,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  /// 提示词必须说清**搜的是什么**：两处的搜索范围完全不同 ——
  /// 媒体库搜库里已入库的作品 / 文件，文件夹只筛**当前这一层**网盘目录。
  final String hint;

  @override
  Widget build(BuildContext context) {
    final tv = AppTheme.isTvLayout(context);
    return SizedBox(
      // TV 上缩窄：页头的操作区现在横排六个控件，624 的宽度要留得下。
      width: tv ? 180 : 220,
      // 高度仍然**写死**（理由见类文档：固定高的框才吃得住字号，不能套
      // `tvTextScaler`）。TV 上从 32 抬到 44 —— 15sp 的字在 32 高的框里会顶破。
      height: tv ? 44 : 32,
      // TV 下同样只有按 OK 才进编辑态（见 TvTextField）：搜索框坐在页头，
      // 遥控器 ↑ 下来路过它就弹键盘的话，用户永远到不了海报墙。
      child: TvTextField(
        controller: controller,
        onChanged: onChanged,
        cursorHeight: tv ? 18 : 14,
        style: TextStyle(
          fontSize: tv ? AppTheme.tvActionLabel : 12.5,
          color: AppTheme.text,
        ),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: TextStyle(fontSize: tv ? 14 : 12, color: AppTheme.dim),
          prefixIcon: Icon(Icons.search_rounded, size: tv ? 20 : 15),
          prefixIconConstraints: BoxConstraints(
            minWidth: tv ? 40 : 30,
            minHeight: tv ? 40 : 30,
          ),
          filled: true,
          fillColor: AppTheme.panel,
          contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppTheme.line, width: 0.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppTheme.line, width: 0.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppTheme.accent, width: 0.8),
          ),
        ),
      ),
    );
  }
}

/// 空态 / 错误态。
///
/// 刻意**必须给一个行动按钮**：只有文案的空态会让用户不知道下一步做什么，
/// 而这正是空态唯一的用途。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.actionLabel,
    this.onAction,
    this.actionFocusNode,
    this.danger = false,
  }) : assert(
          (actionLabel == null) == (onAction == null),
          'actionLabel 与 onAction 必须**成对**给：下面渲染按钮的判据是'
          '「两个都非空」，只给标签的话按钮根本不出现，屏幕上只剩一句'
          '「说了要去做点什么」的空话 —— 而它看起来完全正常，没人会去查。'
          '（`scan_page` 未登录那条就漏过一次，见评估文档 P2-7。）',
        );

  final IconData icon;
  final String title;
  final String? body;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 挂在行动按钮上的焦点节点（可选）。
  ///
  /// ## 为什么调用方会需要它
  ///
  /// TV 上「焦点自己走到这个按钮」是不成立的：空态通常铺在一个**同样铺满
  /// 屏幕的焦点节点里面**（播放页的画面节点就是），而方向键遍历要求候选节点
  /// 完全在当前节点之外 —— 于是往下按只会跳过按钮、落到屏幕外那一层。
  /// 那种情况下只有调用方显式 `requestFocus` 才够得着，节点就得从这里传进去。
  ///
  /// 桌面 / 手机不传，行为一点不变。
  final FocusNode? actionFocusNode;

  /// 用错误色渲染（失败态）。
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 34,
                color: danger ? AppTheme.danger : AppTheme.dim,
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: danger ? AppTheme.danger : AppTheme.text,
                ),
              ),
              if (body != null) ...[
                const SizedBox(height: 8),
                Text(
                  body!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11.5,
                    height: 1.7,
                    color: AppTheme.muted,
                  ),
                ),
              ],
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 18),
                FilledButton(
                  focusNode: actionFocusNode,
                  onPressed: onAction,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.accent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 11,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                  child: Text(
                    actionLabel!,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 分组卡片容器。
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    this.description,
    required this.child,
    this.trailing,
  });

  final String? title;
  final String? description;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.line, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Row(
              children: [
                Expanded(
                  child: Text(
                    title!,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.text,
                    ),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
          if (description != null) ...[
            const SizedBox(height: 6),
            Text(
              description!,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.7,
                color: AppTheme.muted,
              ),
            ),
          ],
          if (title != null || description != null) const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

/// 「标签：值」一行。设置页与诊断页共用。
class KeyValueRow extends StatelessWidget {
  const KeyValueRow({
    super.key,
    required this.label,
    required this.value,
    this.labelWidth = 92,
    this.valueColor,
  });

  final String label;
  final String value;
  final double labelWidth;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
            ),
          ),
          Expanded(
            child: TvSelectableText(
              value,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.6,
                color: valueColor ?? AppTheme.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 小圆角标签（分辨率 / 来源 / 状态）。
///
/// ⚠️ 刻意**不叫 `Chip`** —— Material 里已经有一个 `Chip`，
/// 同文件同时 import 本文件与 `material.dart` 时会产生名字歧义。
class TagChip extends StatelessWidget {
  const TagChip({
    super.key,
    required this.label,
    this.color,
    this.icon,
    this.filled = false,
  });

  final String label;
  final Color? color;
  final IconData? icon;

  /// 实心底色（用于海报上的角标，需要压过图片内容）。
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppTheme.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
      decoration: BoxDecoration(
        color: filled ? c.withValues(alpha: 0.92) : c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
        border: filled ? null : Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 10,
              color: filled ? AppTheme.bg : c,
            ),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              height: 1.3,
              color: filled ? AppTheme.bg : c,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「电视上没有键盘」的说明卡。**只在 TV 布局下渲染**，其余平台返回空盒子。
///
/// ## 为什么必须有这一块
///
/// 设置页有 6 个自由文本字段（TMDB API Key / API 地址 / 图片地址 /
/// 豆瓣 Cookie / OpenSubtitles Api-Key / API 地址）。在电脑上它们是
/// 「粘一段字符串」，在电视上却变成「拿遥控器在软键盘上按方向键逐格选字」——
/// 一段上百字符的豆瓣 Cookie 要按几百下，实际等于填不了。
///
/// 难处在于**用户看不出还有别的路**：他看到的就是一排能聚焦、点下去却几乎
/// 没法用的输入框。所以这块不是「温馨提示」，而是唯一一条可行操作路径的
/// 说明书 —— 没有它，这一节在电视上就是死路。
///
/// ## 为什么这句话不是画饼
///
/// 设置项存在 `cloudcine.sqlite` 的 `settings` 表里，而备份服务导出的是
/// **整个数据库文件**（`library_backup_service.dart` 的 `dbBytesToWrite`
/// 恒等于 `dbBytes`，不做裁剪），所以设置确实跟着备份走。新电视上本地库是
/// 空的，`sync()` 里 `!localManifest.hasLibraryContent` 那一条会无条件让
/// 远程赢 —— 正好就是「第一次同步就把配置拉下来」。
///
/// ⚠️ 唯一不跟着走的是**网盘凭证**（扫码登录那一步），所以顺序必须先登录
/// 再同步。正文里写明了这一点，否则用户会在「同步」上卡住却不知道原因。
///
/// ## 为什么不做成「TV 上禁用输入框」
///
/// 因为 Android TV 的软键盘是**能用**的，只是难用：插一个 USB 键盘、或用
/// 电视厂商手机遥控 App 里的键盘，体验与电脑上没差别。禁用会把这条路一起
/// 堵死 —— 而键盘不是我们的东西，不该替用户决定他用不用。
class TvTypingNotice extends StatelessWidget {
  const TvTypingNotice({super.key});

  @override
  Widget build(BuildContext context) {
    if (!AppTheme.isTvLayout(context)) return const SizedBox.shrink();

    // 这块是 TV 用户唯一的出路，必须读得清 —— 所以自己套一层文字放大，
    // 而不是跟着设置页其余部分的 11px 走（那是照着电脑屏幕定的）。
    // 容器高度由内容撑开，放大不会溢出。
    return AppTheme.tvTextScaler(
      context,
      Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
        decoration: BoxDecoration(
          color: AppTheme.accent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: AppTheme.accent.withValues(alpha: 0.35),
            width: 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.keyboard_alt_outlined,
                  size: 15,
                  color: AppTheme.accent,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    '电视上没有键盘 —— 这一节建议在电脑/手机上配好',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.text,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '用遥控器在软键盘上逐字选，一段 Cookie 要按几百下，等于填不了。\n'
              '正路：在电脑或手机上打开云影 → 把这里填好 → 点「上传备份」→ '
              '回到这台电视，在「备份与同步」里点「同步」，配置就跟着媒体库一起过来。\n'
              '也可以：给电视插一个 USB 键盘，或用电视厂商手机遥控 App 里的键盘 —— '
              '那样和电脑上一样好打。\n'
              '⚠️ 网盘登录（扫码）不在备份里，所以顺序是「先在电视上登录，再同步」。',
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.75,
                color: AppTheme.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
