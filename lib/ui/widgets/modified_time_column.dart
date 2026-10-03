import 'package:flutter/material.dart';

import '../../core/utils/format.dart';
import '../theme/app_theme.dart';

/// 「修改时间」这一列。**目录视图与作品详情页共用同一份**。
///
/// ## 为什么要单列，而不是拼在下面那行元信息里
///
/// 原先的写法是 `体积 · 时长 · 分辨率 · 时间` 拼成一句。时间是**最后一段**，
/// 于是它的左边缘随前面每一段的宽度浮动 —— 同一层里十几行的时间参差不齐，
/// 而这个列表最常见的用法恰恰是**竖着扫**「哪几个是刚传的」。单列 + 右对齐
/// 之后所有时间戳对齐在同一条竖线上，扫一眼就能看出哪一批是新的。
///
/// 顺带把文件名那一行让了出来：时间从元信息里挪走之后，`1.2 GB · 1080p`
/// 这一行不再因为多了 5 个字而被挤掉后半截。
///
/// ## 为什么显示相对时间（`3 天前`）而不是完整时刻
///
/// 全应用同一套措辞（`formatRelativeTime`，海报墙也在用）：这个列表要回答的
/// 是「新不新」，不是「精确到分是哪一刻」。完整时刻放在 **tooltip** 里 ——
/// 桌面鼠标一悬停就有；而把它印在列里，宽度会从 60px 涨到 130px 以上，
/// 比很多文件名还宽，那一列会喧宾夺主。
///
/// ## 为什么两份列表共用这一个 widget 而不是各写一份
///
/// 详情页的文件列表与目录视图的条目列表是**两套数据结构**（`MediaItem` /
/// `DriveEntry`），行布局也刻意不共用（见 `folder_browser.dart` 里那段说明）。
/// 但「时间该怎么显示」不是布局问题：一处写成 `3 天前`、另一处写成
/// `2026-10-03 16:41`，用户会以为是两个不同的字段。所以只抽这一列。
class ModifiedTimeColumn extends StatelessWidget {
  const ModifiedTimeColumn({super.key, required this.modifiedAt});

  final DateTime? modifiedAt;

  /// 列宽。**必须固定**：这一列右边是按钮、左边是 `Expanded` 里的文件名，
  /// 宽度随内容伸缩的话，整层名字的左边缘不会变，但时间会各占各的位置，
  /// 又退回「对不齐」的老样子。
  ///
  /// 90 是实测能放下最长的相对时间（`29 天前`）与完整日期（`2026-09-01`）
  /// 的宽度，再宽就白占文件名的地方。
  static const double width = 90;

  @override
  Widget build(BuildContext context) {
    final t = modifiedAt;
    // 网盘对少数条目不给 `modified`。显示 `—` 而不是留空：留空看起来像
    // 这一行坏了，而 `—` 是「网盘没给」这个事实的诚实写法。
    final text = t == null ? '—' : formatRelativeTime(t);

    return SizedBox(
      width: width,
      child: Tooltip(
        message: t == null ? '网盘没有给出这一条的修改时间' : formatDateTimeMinute(t),
        child: Text(
          text,
          textAlign: TextAlign.right,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            color: t == null ? AppTheme.dim : AppTheme.muted,
          ),
        ),
      ),
    );
  }
}
