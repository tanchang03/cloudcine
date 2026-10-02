import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';

/// 海报墙卡片两种宽高比。
///
/// 为什么这两个值得钉住：它们直接决定 TV 上一屏能看到几张海报，而「看几张」
/// 是 TV 遥控器体验里最关键的一档（方向键翻墙靠的就是密度）。两个值各管
/// 一个平台，绝不能混：
///   * 桌面 = 标准 2:3 海报比例，真海报正好铺满；
///   * TV = 0.8，故意比 2:3 矮，才多挤出一排。
/// 谁手滑把 `tvPosterAspect` 改回 2/3，TV 就退回「一屏一行半」；改得比 0.8
/// 还宽，海报会被压成缩略图。
void main() {
  test('桌面沿用标准海报比例 2:3', () {
    expect(
      AppTheme.posterAspect,
      2 / 3,
      reason: '2:3 是电影海报的标准比例，`PosterImage` 用 BoxFit.contain，'
          '这个比例下 TMDB 真海报正好铺满、看不到模糊底',
    );
  });

  test('TV 比桌面更矮（0.8 > 2/3）—— 才能多挤一排', () {
    expect(
      AppTheme.tvPosterAspect,
      0.8,
      reason: '960×540 那块屏用 2/3 只有一行半；压到 0.8 行高从 ~258 降到 ~215，'
          '一屏能放下 2 行。再宽（0.9+）海报剩得太扁、更像缩略图，所以停在 0.8',
    );
  });

  test('TV 比桌面矮，所以一屏能多放', () {
    // 同一列宽下，宽高比越大 → 卡片越矮 → 同屏行数越多。
    expect(
      AppTheme.tvPosterAspect,
      greaterThan(AppTheme.posterAspect),
      reason: '这是 P1-3 全部逻辑的前提：TV 上更矮的卡片才换来「多看出几部」',
    );
  });
}
