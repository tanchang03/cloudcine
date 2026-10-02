/// TV 上把「只有图标的东西」补上一句看得见的说明。
///
/// ## 为什么需要这个文件
///
/// `Tooltip` 的触发方式是 **hover** 或**长按**，而遥控器两样都没有 ——
/// 它只有一个「按下去」。于是桌面上鼠标一悬停就出来的那句话，在电视上
/// **等于不存在**：用户看到的只有一排含义不明的图标（↻ ↑ ⤒ ▶ ⧉），
/// 按下去之前不可能知道会发生什么。
///
/// 更糟的是**禁用态**。按钮变灰在桌面上是「悬停一下就知道为什么」，
/// 在电视上就只是「一个按不动的灰块」—— 用户唯一的结论是「这个应用坏了」。
///
/// 这个文件里两个组件分别对付这两种情况：图标按钮补文字（[TvIconLabel]），
/// 按不动的原因写成看得见的一行字（[TvNote]）。
///
/// ## 共同的设计约束：**只在 TV 上生效**
///
/// 桌面上有 hover，补出来的文字标签只会让页头挤成一团（媒体库页头那一行
/// 本来就有视图切换 + 搜索框 + 排序 + 筛选 + 刷新）。所以两个组件在非 TV 上
/// 都**原样返回 / 返回空**，桌面的排版与既有测试完全不受影响。
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 给「只有图标的按钮」补一个可见的文字标签。
///
/// ## 为什么是「包一层」而不是「自己拼一个带文字的按钮」
///
/// 这里只把原来的控件外面套一层 `Row` 加个 `Text`，控件本身**一点没动** ——
/// 焦点遍历、`select` 键激活、禁用态语义、`constraints` / `visualDensity`
/// 一个都不用重新实现。自己拿 `InkWell` 拼一个「带文字的图标按钮」看着更
/// 顺眼，代价是上面这些行为全要照着 `IconButton` 重做一遍，还得自己
/// 记住哪些参数该透传。
///
/// ## 标签文案怎么定
///
/// 取的是原来 `tooltip` 那句话的**短版**：tooltip 可以是一整段解释
/// （「这些信息来自文件名解析，未联网刮削」），标签只放得下两三个字
/// （「刷新」「上一级」「播放」）。两者不冲突 —— tooltip 在桌面继续生效，
/// 电视上由标签兜底。
class TvIconLabel extends StatelessWidget {
  const TvIconLabel({
    super.key,
    required this.label,
    required this.child,
    this.enabled = true,
    this.gap = 2,
    this.trailing = 6,
  });

  /// 这个按钮做什么。**不要**把整段 tooltip 抄进来 —— 那是给鼠标的。
  final String label;

  /// 原来的按钮。除了被放进一个 `Row`，它的构造参数一个都不该改。
  final Widget child;

  /// 按钮当前能不能按。禁用时标签一起变暗 —— 否则会出现「字是亮的、
  /// 按钮是灰的」这种自相矛盾的样子，用户会去点那个亮着的字。
  final bool enabled;

  /// 图标与标签之间的间距。图标按钮自带内边距，这里只需要一点点。
  final double gap;

  /// 标签右侧留的间距。让连续几个「图标 + 标签」之间不至于贴在一起。
  final double trailing;

  @override
  Widget build(BuildContext context) {
    // 桌面/手机上有 hover，原样返回 —— 连一层 `Row` 都不多包，
    // 保证既有页面的排版与 widget 测试的 `find` 结果完全不变。
    if (!AppTheme.isTvLayout(context)) return child;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        child,
        SizedBox(width: gap),
        Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            height: 1.2,
            color: enabled ? AppTheme.text : AppTheme.dim,
          ),
        ),
        SizedBox(width: trailing),
      ],
    );
  }
}

/// TV 上才显示的一行小字 —— 用来把「这个按钮为什么是灰的」写出来。
///
/// 用法是在**被禁用的那组按钮附近**放一条，而不是给每个灰按钮各挂一条：
/// 详情页的「刮削」和「手动」是同一条原因（没有在线源），各挂一条会把
/// 同一句话并排印两遍。
///
/// 非 TV 上返回空 —— 桌面上按钮的 tooltip 已经把原因说清楚了。
class TvNote extends StatelessWidget {
  const TvNote({
    super.key,
    required this.text,
    this.icon = Icons.info_outline_rounded,
    this.tone = AppTheme.warn,
  });

  /// 一句话说明。应当**自足**：电视上它旁边没有鼠标可以去问。
  final String text;

  final IconData icon;

  /// 文案颜色。默认用警示色 —— 这条信息存在的场合几乎都是「有东西按不动」。
  final Color tone;

  @override
  Widget build(BuildContext context) {
    if (!AppTheme.isTvLayout(context)) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1.5),
            child: Icon(icon, size: 14, color: tone),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: tone,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
