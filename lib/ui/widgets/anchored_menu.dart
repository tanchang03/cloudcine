import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 取 [context] 对应控件在**屏幕坐标系**里的矩形。
///
/// 专门用来给「贴着按钮正上方划出来」的菜单算锚点。拿不到（控件还没上树 /
/// 已经拆掉 / 尺寸还是 0）时返回 `null` —— 调用方应当**放弃弹菜单**，而不是
/// 拿一个假坐标去弹：一个弹在屏幕角落的菜单比不弹更难解释。
///
/// ⚠️ 调用前确认 `context.mounted`：元素已经失效时 `findRenderObject()` 在
/// debug 下会直接断言失败，那不是「拿不到坐标」，是崩。
Rect? globalRectOf(BuildContext context) {
  final object = context.findRenderObject();
  if (object is! RenderBox || !object.hasSize) return null;
  final size = object.size;
  if (size.isEmpty) return null;
  return object.localToGlobal(Offset.zero) & size;
}

/// 在 [anchor] 正上方划出一个菜单，返回用户选中的值。
///
/// 点菜单以外任意处、或按 Esc 关掉，都返回 `null`。
///
/// 收 [NavigatorState] 而不是 `BuildContext`：调用方常要在**跨 `await` 之后**
/// 再弹一次菜单（字幕菜单搜完在线字幕会重开），那时手里只该有一个不依赖
/// 元素生命周期的 navigator，而不是一个可能已经失效的 context。
///
/// ## 为什么不是 `showDialog` / `AlertDialog`
///
/// 那会把菜单摆在**屏幕正中**：盖住画面，而且离用户刚点的那个按钮很远 ——
/// 用户点的是「音轨」，眼睛却要去屏幕中间找菜单。主流播放器都不这么做。
///
/// ## 为什么不是 `CompositedTransformFollower`
///
/// 早先画质菜单用过它（`LayerLink` + `CompositedTransformFollower`），
/// 那条路靠**图层树**里的 leader 与 follower 配对。在「按钮在路由里、
/// 浮层插在 Overlay 顶层」这种跨层组合下并不稳，实测退化成把菜单摆在
/// **屏幕左上角**（follower 找不到 leader 时的兜底位置）。
/// 现在改成自己算坐标：拿按钮的全局矩形，用 [CustomSingleChildLayout] 摆到它
/// 正上方。没有任何跨层依赖，算出来是什么就是什么。
///
/// ## 为什么不是 `PopupMenuButton`
///
/// 它的每一项高度固定，塞不下「清晰度」那种两行（主标题 + `1920×1080 · 4.2 Mbps`）
/// 的项；动画与定位风格也跟播放器其它浮层对不上。
Future<T?> showAnchoredMenu<T>({
  required NavigatorState navigator,
  required Rect anchor,
  required WidgetBuilder builder,
  double gap = 8,
  double edgePadding = 8,
}) {
  return navigator.push<T>(
    _AnchoredMenuRoute<T>(
      anchor: anchor,
      builder: builder,
      gap: gap,
      edgePadding: edgePadding,
    ),
  );
}

/// 菜单路由本体。
///
/// 用 [PopupRoute] 而不是自己插 `OverlayEntry`：遮罩、点外部关闭、Esc 关闭、
/// 返回键与无障碍语义全都由它兜住，我们只需要负责「摆到哪儿」和「怎么动」。
class _AnchoredMenuRoute<T> extends PopupRoute<T> {
  _AnchoredMenuRoute({
    required this.anchor,
    required this.builder,
    required this.gap,
    required this.edgePadding,
  });

  /// 按钮的全局矩形。菜单会贴着它的**上边**划出来。
  final Rect anchor;

  final WidgetBuilder builder;

  /// 菜单与按钮之间的空隙。
  final double gap;

  /// 菜单离屏幕边缘至少留这么多，避免贴边或被裁。
  final double edgePadding;

  // 不要压暗整个画面：这是「下拉框」式的轻量浮层，不是模态对话框。
  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => '关闭菜单';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 170);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _AnchoredMenuLayout(
      anchor: anchor,
      gap: gap,
      edgePadding: edgePadding,
      animation: animation,
      child: builder(context),
    );
  }
}

/// 把菜单摆到锚点正上方，并做「上划 + 淡入」。
class _AnchoredMenuLayout extends StatelessWidget {
  const _AnchoredMenuLayout({
    required this.anchor,
    required this.gap,
    required this.edgePadding,
    required this.animation,
    required this.child,
  });

  final Rect anchor;
  final double gap;
  final double edgePadding;
  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      // 菜单内容与动画无关，只建一次；每帧重建纯属浪费。
      child: child,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(animation.value);
        return CustomSingleChildLayout(
          delegate: _AboveAnchorLayoutDelegate(
            anchor: anchor,
            gap: gap,
            edgePadding: edgePadding,
          ),
          child: Opacity(
            opacity: t,
            // 从下方 14px 处滑上来 —— 这就是「上划」那一下。
            // `Transform` 只改绘制、不改布局，所以锚点算的是最终位置。
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 14),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// 算「菜单该摆在哪儿」的纯函数。
///
/// 抽成纯函数是因为这条规则**改错不报错**：菜单照样会弹出来，只是弹在错的
/// 地方（盖住按钮、飘到屏幕外），用户只会觉得「这个菜单怪怪的」，不会看到
/// 任何异常。所以它必须能被单测钉住。
///
/// 规则：
///   1. 菜单**底边**落在按钮顶边之上 [gap] 处 —— 「从按钮上方划出来」；
///   2. 菜单**右沿**对齐按钮右沿 —— 看起来是挂在按钮上的，而不是飘着的；
///   3. 两边都夹进屏幕，至少留 [edgePadding]；
///   4. 按钮上方放不下整块菜单时翻到按钮**下方**（被裁掉半截比换方向更糟）。
@visibleForTesting
Offset anchoredMenuOffset({
  required Rect anchor,
  required Size screen,
  required Size menu,
  double gap = 8,
  double edgePadding = 8,
}) {
  final maxLeft = math.max(edgePadding, screen.width - menu.width - edgePadding);
  final left = math.min(
    math.max(anchor.right - menu.width, edgePadding),
    maxLeft,
  );

  var top = anchor.top - menu.height - gap;
  if (top < edgePadding) {
    final maxTop = math.max(
      edgePadding,
      screen.height - menu.height - edgePadding,
    );
    top = math.min(math.max(anchor.bottom + gap, edgePadding), maxTop);
  }
  return Offset(left, top);
}

/// 「菜单底边落在按钮顶边之上」的定位。
class _AboveAnchorLayoutDelegate extends SingleChildLayoutDelegate {
  const _AboveAnchorLayoutDelegate({
    required this.anchor,
    required this.gap,
    required this.edgePadding,
  });

  final Rect anchor;
  final double gap;
  final double edgePadding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    // 菜单不能超出屏幕（两边各留 edgePadding）。
    return BoxConstraints(
      maxWidth: math.max(0, constraints.maxWidth - edgePadding * 2),
      maxHeight: math.max(0, constraints.maxHeight - edgePadding * 2),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) => anchoredMenuOffset(
        anchor: anchor,
        screen: size,
        menu: childSize,
        gap: gap,
        edgePadding: edgePadding,
      );

  @override
  bool shouldRelayout(_AboveAnchorLayoutDelegate oldDelegate) =>
      oldDelegate.anchor != anchor ||
      oldDelegate.gap != gap ||
      oldDelegate.edgePadding != edgePadding;
}

/// 菜单本体：一块圆角深色面板，顶上一行标题（可选），下面是一列选项。
///
/// 抽成一个公共件是因为播放器里有**两个**播放界面（独立窗口 / 内置播放页）、
/// 一共七个菜单。各自手搓一份的话，「面板底色」「圆角」「打勾口径」这些
/// 只要有一处走样，两个播放器看起来就是两套东西。
class AnchoredMenuPanel extends StatelessWidget {
  const AnchoredMenuPanel({
    super.key,
    this.title,
    this.maxWidth = 320,
    required this.children,
  });

  /// 面板顶上的标题行。`null` = 不显示（菜单本身已经能自解释时）。
  final String? title;

  /// 面板最大宽度。内容再宽也只会撑到这个宽度，超出部分交给滚动。
  final double maxWidth;

  /// 一列选项。每一行自己负责点击行为（`InkWell` / `ListTile`）。
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.panel,
      elevation: 12,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: GestureDetector(
        // 吃掉落在面板空白处（标题行、行间留白）的点击。不挡的话它们会穿到
        // 下面的遮罩，表现成「点菜单自己反而把菜单关了」。
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 7),
                  child: Text(
                    title!,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Divider(height: 1, thickness: 1, color: Colors.white12),
              ],
              // 字幕菜单满配时有十几行、还可能比按钮上方的空间高。
              // 让它滚，而不是把面板撑出屏幕外。
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
