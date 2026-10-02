import 'package:cloudcine/ui/widgets/anchored_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 菜单浮层的**摆位规则**。
///
/// ## 为什么这条规则必须单独钉住
///
/// 「贴着按钮正上方划出来」是这次改动的全部意义。摆错了**不会抛异常** ——
/// 菜单照样弹出来，只是弹在错的地方：盖住按钮、飘到屏幕外、或者干脆又回到
/// 屏幕正中。用户看到的只是「这个菜单怪怪的」，而这类回归靠人眼极难发现，
/// 因为「摆错了」和「本来就这么摆」长得一模一样。
///
/// 所以把「算坐标」抽成纯函数 [anchoredMenuOffset]，在这里逐条比对数字。
void main() {
  // 一个 800×600 的窗口，按钮在右下角（控制栏上那排按钮的典型位置）。
  const screen = Size(800, 600);
  const button = Rect.fromLTWH(700, 540, 60, 32);
  const menu = Size(300, 200);

  test('菜单底边落在按钮顶边之上 gap 处 —— 这就是「从按钮上方划出来」', () {
    final offset = anchoredMenuOffset(
      anchor: button,
      screen: screen,
      menu: menu,
      gap: 8,
    );

    expect(
      offset.dy + menu.height,
      button.top - 8,
      reason: '底边离按钮顶边正好一个 gap —— 贴太近会像压在按钮上，'
          '离太远就看不出这个菜单是从哪个按钮弹出来的',
    );
  });

  test('菜单右沿对齐按钮右沿 —— 看起来是挂在按钮上的，而不是飘在屏幕某处', () {
    final offset = anchoredMenuOffset(
      anchor: button,
      screen: screen,
      menu: menu,
    );

    expect(offset.dx + menu.width, button.right);
  });

  test('按钮贴着屏幕右缘时，菜单被整体夹进屏幕而不是伸出去', () {
    // 右沿对齐会让菜单往左伸；按钮本来就在最右边时，夹紧那一步算错就会让
    // 菜单有一截留在屏幕外 —— 那一截里的选项点不到。
    const wideMenu = Size(760, 200);
    final offset = anchoredMenuOffset(
      anchor: const Rect.fromLTWH(760, 540, 40, 32),
      screen: screen,
      menu: wideMenu,
      edgePadding: 8,
    );

    expect(
      offset.dx + wideMenu.width,
      screen.width - 8,
      reason: '右沿顶到「屏幕右缘留一个 edgePadding」的位置，一像素都不许伸出去',
    );
    expect(offset.dx, greaterThanOrEqualTo(8));
  });

  test('按钮上方放不下整块菜单时翻到按钮下方', () {
    // 按钮靠近屏幕顶部、菜单又很高：上方那点空间塞不下。
    // 这时要翻到下面去，而不是让菜单被屏幕顶边裁掉半截。
    const anchor = Rect.fromLTWH(700, 40, 60, 32);
    final offset = anchoredMenuOffset(
      anchor: anchor,
      screen: screen,
      menu: const Size(300, 400),
      gap: 8,
    );

    expect(
      offset.dy,
      anchor.bottom + 8,
      reason: '翻到下方时同样要留一个 gap —— 贴着按钮会像压在按钮上',
    );
  });

  test('翻到下方也放不下时，只夹到 edgePadding，绝不出现负坐标', () {
    // 窗口被压成一条（播放器窗口可以很小），字幕菜单十几行根本放不下。
    // 负坐标等于菜单有一截在屏幕外 —— 那一截里的选项点不到。
    final offset = anchoredMenuOffset(
      anchor: const Rect.fromLTWH(700, 380, 60, 32),
      screen: const Size(800, 420),
      menu: const Size(300, 500),
      gap: 8,
    );

    expect(offset.dy, 8);
  });

  test('菜单比屏幕还高时不出现负坐标，只夹到 edgePadding', () {
    final offset = anchoredMenuOffset(
      anchor: button,
      screen: screen,
      menu: const Size(900, 900),
    );

    expect(offset.dx, 8);
    expect(offset.dy, 8);
  });

  test('按钮在左下角时，右沿对齐也不会把菜单推到屏幕左边外面', () {
    final offset = anchoredMenuOffset(
      anchor: const Rect.fromLTWH(0, 540, 40, 32),
      screen: screen,
      menu: menu,
    );

    expect(
      offset.dx,
      8,
      reason: '左沿对齐按钮左沿会算出一个负的 left，必须被夹回 edgePadding',
    );
  });
}
