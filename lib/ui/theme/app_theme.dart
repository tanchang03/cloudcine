import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../core/utils/video_formats.dart';

/// 设计令牌。
///
/// 色值沿用参考项目（夸克音乐播放器）的深色原型，做到两套应用观感一致。
/// **页面里不写死颜色** —— 换肤与统一口径只改这一个文件。
class AppTheme {
  const AppTheme._();

  /// 字体：与设计稿一致。
  ///
  /// macOS / iOS 上 `PingFang SC` 一定存在；其它平台由 Flutter 回退到
  /// 系统默认中文字体，不会出现方框。
  static const String fontFamily = 'PingFang SC';

  // ---- 背景与容器 ----
  static const Color bg = Color(0xFF0B0D12);
  static const Color panel = Color(0xFF141821);
  static const Color panel2 = Color(0xFF1B2130);
  static const Color panel3 = Color(0xFF232B3D);
  static const Color line = Color(0xFF2A3244);

  // ---- 文字 ----
  static const Color text = Color(0xFFE9EDF6);
  static const Color muted = Color(0xFF8B95AC);
  static const Color dim = Color(0xFF5D6780);

  // ---- 强调色（主渐变 #5b8cff → #a45cff）----
  static const Color accent = Color(0xFF5B8CFF);
  static const Color accent2 = Color(0xFFA45CFF);

  /// 品牌主渐变，用于按钮 / 播放键 / 无海报时的占位底。
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accent, accent2],
  );

  /// 播放器区域的纯黑。视频周围必须是黑的 —— 用 [bg] 会显得「灰底」。
  static const Color cinema = Color(0xFF000000);

  // ---- 语义色 ----
  static const Color ok = Color(0xFF3DDC97);
  static const Color warn = Color(0xFFFFB454);
  static const Color danger = Color(0xFFFF6B6B);

  // ---- 尺寸 ----
  static const double sidebarWidth = 196;
  static const double titleBarHeight = 32;

  /// 海报宽高比（2:3 是电影海报的标准比例）。
  static const double posterAspect = 2 / 3;

  /// TV 上海报墙的卡片宽高比。
  ///
  /// 比标准海报更**矮**（0.8 > 2/3）：卡片变矮，960×540 那块屏才能多挤出一排
  /// （行高 ~258 → ~215，一屏从 1 行半变成 2 行）。桌面绝不沾这条 ——
  /// 12sp 的标题在 0.8 的卡片里会被横向压扁，看着像「海报被剪了一刀」。
  /// 取 0.8 是实测折中：再宽（0.9+）海报剩得太扁、更像缩略图；再窄就退回 2:3 了。
  static const double tvPosterAspect = 0.8;

  /// 播放页底部控制栏高度。
  static const double playerBarHeight = 64;

  // -------------------------------------------------------------------
  // TV / 过扫描安全边距
  // -------------------------------------------------------------------

  /// 官方 TV 设计规范（960×540）里的过扫描安全边距：左右 48dp、上下 27dp。
  ///
  /// 电视会把画面边缘切掉一圈（overscan）。原来媒体库的页边距是 **22**，
  /// 不到安全线的一半 —— 真机上侧栏最左边的字**可能直接被切掉**。
  static const double tvSafeHorizontal = 48;
  static const double tvSafeVertical = 27;

  // -------------------------------------------------------------------
  // TV 专用尺寸
  //
  // 桌面那套（侧栏 196、正文 12.5、图标 17）是按「鼠标能精确点到很小的行」
  // 定的。电视上没有一个数字是够的：隔着三米，13sp 的字等于没有，
  // 而 17px 的图标连焦点环都画不下。这一组是 TV 分支的**唯一真源** ——
  // 页面里不要再写死第二份。
  // -------------------------------------------------------------------

  /// TV 上的侧栏宽度（桌面 / 非顶栏模式兜底用）。
  ///
  /// 240 占 960 的 25%，纵向仍留 75% 给内容（符合官方「导航放一侧、纵向
  /// 留给内容」）。加宽不是为了好看，是为了让 16sp 的标签 + 24px 的图标
  /// + 焦点环**放得进去**。
  ///
  /// ⚠️ TV 默认已改走顶部一级导航（见 `AppShell`），这个值只在桌面窗口
  /// 被拉到 TV 判据之外、以及旧测试里作为「真机常数」保留。
  static const double tvSidebarWidth = 240;

  /// TV 顶部一级导航的高度（参考夸克网盘 TV 版媒体库首页的顶栏）。
  ///
  /// 60 = 内容 44 + 上下各 8。44 与页头控件（视图切换 / 搜索框）同高，
  /// 遥控器上下走时视觉对齐；整栏只吃纵向 60，内容区宽度从 624 放到 864。
  static const double tvTopBarHeight = 60;

  /// TV 上一级导航条目的高度。
  ///
  /// 48 是 Material 的最小触摸/焦点目标，也是官方 TV 规范的下限。桌面那一行
  /// 只有 ~38 —— 遥控器上那意味着「两行挤在一起，看不出焦点落在哪一行」。
  static const double tvNavItemHeight = 56;

  /// TV 上的页头大标题。官方 TV 规范是浏览页大标题 44sp，但那是指「整个
  /// 浏览页的分区标题」；本应用侧栏已经承担了分区，这里 24 足够。
  static const double tvHeaderTitle = 24;

  /// TV 上的副标题（「12 个视频 · 3 部作品」这类）。
  static const double tvHeaderSubtitle = 14;

  /// TV 上一级导航的条目文字。桌面是 13 —— 那是「鼠标悬停一下就知道是哪一
  /// 项」的字号，电视上隔着三米完全读不了。
  static const double tvNavLabel = 16;

  /// TV 上按钮上的文字。桌面是 12.5，电视上必须 ≥ 15。
  static const double tvActionLabel = 15;

  /// TV 上一个**动作控件**应有的高度。
  ///
  /// 48 不是随手定的：它是官方 TV 规范里「焦点框最小边长」的值，也正是
  /// Material 的 `IconButton` 默认最小尺寸 —— 所以这里不是要放大什么，
  /// 而是**防止有人把它改小**（`folder_browser` 的行内按钮就显式压到了 28，
  /// 那是为了让列表行不被撑高，属于另一回事）。
  static const double tvActionHeight = 48;

  /// 「这台设备是电视」的判据。
  ///
  /// Flutter 没有暴露 Android 的 leanback 标志，只能靠尺寸推断：
  /// 官方 TV 设计稿是 **960×540**，而手机的逻辑宽度普遍只有 360–430，
  /// 取 960 当分界线既不误伤手机，也不会给平板套上一圈没必要的黑边。
  static bool isTvLayout(BuildContext context) =>
      defaultTargetPlatform == TargetPlatform.android &&
      MediaQuery.sizeOf(context).width >= 960;

  /// 页面内容要避开的过扫描区域。非 TV 上返回 `EdgeInsets.zero`。
  ///
  /// ## ⛔ 谁负责加它 —— 不是「加了壳就都有了」
  ///
  /// `AppShell` 在 `app_shell.dart` 里（`build` 的 `body:` 那一层）给**壳内**
  /// 那五个一级页面统一加了这一层。
  /// ⚠️ 这里刻意**不写行号**：那层 `Focus`/`Padding` 一改行号就飘，而这个引用
  /// 已经因为侧栏焦点兜底飘过一次了（`34` → `40`）。认「`AppShell.build` 的
  /// `body:`」这个结构，别认行号。
  /// 但 `/auth`、`/auth/qr`、`/work`、`/diagnostics` 都是
  /// `StatefulShellRoute` **之外**的一级路由（见 `app_router.dart`）——
  /// 它们把整个屏幕换掉，**拿不到壳那一层内边距**，必须自己加。
  ///
  /// 不加的后果有两层，第二层更难受：
  ///   1. 最左那列（返回键、页头文字）落进过扫描带里被切掉；
  ///   2. 电视上从媒体库点进详情页，内容会**整体左移 48px** ——
  ///      页头本来就该在同一个位置，跳一下会让人以为换了个应用。
  ///
  /// ⚠️ 两种页面**不需要**加，别顺手加上去：
  ///   - 内容本身**居中且有 maxWidth**（`AuthPage` 是 `maxWidth: 460`）——
  ///     它本来就落在安全区里，加了只是白白缩窄；
  ///   - **全屏视频**（`/play`）—— 加了会变成黑边。
  static EdgeInsets safeAreaInsets(BuildContext context) => isTvLayout(context)
      ? const EdgeInsets.symmetric(
          horizontal: tvSafeHorizontal,
          vertical: tvSafeVertical,
        )
      : EdgeInsets.zero;

  /// TV 上的文字放大倍数。
  ///
  /// 官方 TV 规范是「正文最小 12sp、默认 18sp」，而本项目页面里大量写着
  /// 10.5–13 —— 差近一倍，隔着三米基本读不了。
  /// 与其去改上百处写死的字号（既容易漏、又很难回退），不如在 TV 上整体放大一档。
  static const double tvTextScale = 1.25;

  /// 需要放大文字的地方拿它包一层；非 TV 上原样返回。
  ///
  /// ⚠️ **只能用在「高度能吸收」的地方**（例如海报墙的卡片：海报是
  /// `Expanded`，文字长高只会让海报变矮）。给固定高度的控件
  /// （播放页顶栏 48、控制栏 64）套这个会直接报 RenderFlex 溢出。
  static Widget tvTextScaler(BuildContext context, Widget child) =>
      isTvLayout(context)
          ? MediaQuery.withClampedTextScaling(
              minScaleFactor: tvTextScale,
              maxScaleFactor: tvTextScale,
              child: child,
            )
          : child;

  // -------------------------------------------------------------------
  // 语义化取色
  // -------------------------------------------------------------------

  /// 分辨率徽标色。
  ///
  /// **只在卡片/列表的角标上用**，不参与正文配色：4K 用金色是为了让
  /// 「这一堆里哪几个是 4K」在一眼扫过时就能分辨，而不是为了好看。
  static Color resolutionColor(VideoResolution? r) {
    if (r == null) return dim;
    return switch (r) {
      VideoResolution.uhd4320 ||
      VideoResolution.uhd2160 =>
        const Color(0xFFE5B567),
      VideoResolution.qhd1440 ||
      VideoResolution.fhd1080 =>
        const Color(0xFF6FA8FF),
      VideoResolution.hd720 => const Color(0xFF3DDC97),
      VideoResolution.sd480 => muted,
    };
  }

  /// 等宽字体样式（路径、诊断日志、时间码）。
  static const TextStyle mono = TextStyle(
    fontFamily: 'Menlo',
    fontFamilyFallback: ['Consolas', 'monospace'],
    fontSize: 11.5,
    height: 1.5,
    color: muted,
  );

  // -------------------------------------------------------------------
  // ThemeData
  // -------------------------------------------------------------------

  /// 深色主题。本应用**锁定深色**：媒体库的主体是海报墙与视频画面，
  /// 浅色背景会把画面衬得发灰，也会让海报的暗部细节被吃掉。
  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      primary: accent,
      onPrimary: Colors.white,
      secondary: accent2,
      onSecondary: Colors.white,
      surface: panel,
      onSurface: text,
      error: danger,
      onError: Colors.white,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: panel,
      fontFamily: fontFamily,
      // 媒体库是「点一下就播」的场景，涟漪动画只会让点击显得迟钝。
      splashFactory: NoSplash.splashFactory,
      // 桌面用 compact 是为了让信息密度高一点；TV 上反过来 ——
      // `compact` 会把控件压到低于官方建议的焦点目标尺寸，
      // 遥控器选起来更容易点错。手机上两种都行，跟着 TV 用 standard。
      visualDensity: defaultTargetPlatform == TargetPlatform.android
          ? VisualDensity.standard
          : VisualDensity.compact,
      // ---- 焦点必须一眼可见（TV / 遥控器）----
      //
      // 不设的话，深色主题下 `ThemeData` 的默认值是
      // `Colors.white.withValues(alpha: 0.12)` —— 实测 alpha 恰好 `0.1216`。
      // 隔三米看电视，12% 的白色蒙层**等于没有**，用户不知道遥控器正指着谁。
      //
      // ⛔ **不要用强调色**。上一版是 `accent @ 0.30`，真机反馈是
      // 「不需要背景蒙版色凸显，看起来有点多余，也不太美观」——
      // 带颜色的罩子把控件整体染蓝，看着像「选中」而不是「焦点」。
      // 现在统一走**中性提亮**：只抬亮度、不动色相，与 `TvFocusable` 的
      // `brighten` 是同一种语言。
      //
      // ⚠️ **只改这一行不够**：海报卡片的 `InkWell` 高亮是画在子节点**下面**的
      // （`_RenderInkFeatures.paint` 先画 ink、再 `super.paint` 画子节点），
      // 一整张海报会把它盖得干干净净 —— 调多亮都没用。
      // 卡片类点击区还要额外套一层 `TvFocusable`（见 `ui/widgets/tv_focus.dart`），
      // 由它的 `brighten` 兜底。
      focusColor: Colors.white.withValues(alpha: 0.18),
    );

    return base.copyWith(
      textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
      dividerTheme: const DividerThemeData(
        color: line,
        thickness: 0.5,
        space: 0.5,
      ),
      iconTheme: const IconThemeData(color: muted, size: 18),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: text,
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: panel3,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: line, width: 0.5),
        ),
        textStyle: const TextStyle(
          fontFamily: fontFamily,
          fontSize: 11.5,
          color: text,
        ),
        waitDuration: const Duration(milliseconds: 500),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: panel2,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: line, width: 0.5),
        ),
        textStyle: const TextStyle(
          fontFamily: fontFamily,
          fontSize: 12.5,
          color: text,
        ),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 3,
        activeTrackColor: accent,
        inactiveTrackColor: panel3,
        thumbColor: accent,
        overlayColor: accent.withValues(alpha: 0.12),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(6),
        radius: const Radius.circular(3),
        thumbColor: WidgetStateProperty.all(panel3),
        trackColor: WidgetStateProperty.all(Colors.transparent),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: panel3,
        contentTextStyle: const TextStyle(
          fontFamily: fontFamily,
          fontSize: 12.5,
          color: text,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: accent,
        linearTrackColor: panel3,
      ),
    );
  }
}

/// 叠在所有路由之下的背景光晕。
///
/// 原型在 body 上叠了两处径向渐变（左上蓝 / 右上紫）。挂在
/// `MaterialApp.builder` 上才能真正铺在所有页面之下 —— 挂在某个页面里
/// 就只在那一个页面生效，页面切换时背景会「跳」。
class DesignBackground extends StatelessWidget {
  const DesignBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppTheme.bg,
        gradient: RadialGradient(
          center: Alignment(-0.8, -1.0),
          radius: 1.4,
          colors: [Color(0x1A5B8CFF), Color(0x000B0D12)],
        ),
      ),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.9, -1.0),
            radius: 1.2,
            colors: [Color(0x14A45CFF), Color(0x000B0D12)],
          ),
        ),
        child: child,
      ),
    );
  }
}
