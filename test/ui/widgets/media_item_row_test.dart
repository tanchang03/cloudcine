import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/media_item_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 作品详情页「文件」列表里的**一行**，以及它底下那条进度条。
///
/// ## 为什么值得单独测
///
/// 进度条里全是**改错不报错**的规则：
///
///   - 时长未知时该**不画**，而不是画一条 0% 的空槽 —— 后者会把一条
///     「确实看过」的记录显示成「没看过」，两者在屏幕上一模一样；
///   - 位置超过时长要夹到 100%，不能画出一条出格的线；
///   - 进度条**不能改变行高** —— 一改，同一屏里看过的行就比没看过的行
///     高几像素，右侧那一列时间也跟着上下跳。
///
/// 三条错了都只会「看起来本来就这么设计的」。
void main() {
  final ts = DateTime(2026, 10, 3);

  MediaItem item({
    String fileId = 'f1',
    String name = 'The.Glory.S01E01.2160p.mkv',
    int? durationMs = 60 * 60 * 1000,
    bool showPath = true,
  }) =>
      MediaItem(
        provider: DriveProvider.quark,
        fileId: fileId,
        name: name,
        dirId: 'd1',
        dirPath: '/剧集/The.Glory/',
        groupKey: 'The.Glory',
        kind: MediaKind.episode,
        title: 'The Glory',
        season: 1,
        episode: 1,
        durationMs: durationMs,
        firstSeenAt: ts,
        updatedAt: ts,
      );

  Future<void> render(
    WidgetTester tester,
    MediaItem it, {
    Duration? watched,
  }) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: MediaItemRow(item: it, index: 0, watched: watched),
        ),
      ),
    ));
    await tester.pump();
  }

  group('itemProgressOf', () {
    test('没播过 → null（不画进度条）', () {
      expect(itemProgressOf(item(), null), isNull);
    });

    test('位置是 0 → null（「播了 0 秒」不是一次播放记录）', () {
      expect(itemProgressOf(item(), Duration.zero), isNull);
    });

    test('时长未知 → null，而不是 0', () {
      // 这一条是整段代码里最容易写错的地方：返回 0 的话，一条**确实看过**
      // 的记录会画成 0% 的空槽 —— 用户看到的是「白看了」，而它与「没看过」
      // 在屏幕上完全一样。返回 null 让调用方什么都不画，至少不撒谎。
      expect(
        itemProgressOf(
          item(durationMs: null),
          const Duration(minutes: 12),
        ),
        isNull,
      );
      expect(
        itemProgressOf(item(durationMs: 0), const Duration(minutes: 12)),
        isNull,
      );
    });

    test('播了一半 → 0.5', () {
      expect(
        itemProgressOf(item(), const Duration(minutes: 30)),
        closeTo(0.5, 0.001),
      );
    });

    test('位置超过时长时夹到 1（上报位置可能比时长还大）', () {
      expect(
        itemProgressOf(item(), const Duration(minutes: 90)),
        1.0,
      );
    });

    test('刚好播完 → 1.0（这一列看完也不清，所以会稳定停在满格）', () {
      expect(
        itemProgressOf(item(), const Duration(minutes: 60)),
        1.0,
      );
    });
  });

  testWidgets('看过一点才画进度条，且值就是看过多少', (tester) async {
    await render(tester, item(), watched: const Duration(minutes: 15));

    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.25, 0.001));
  });

  testWidgets('没播过就不画进度条', (tester) async {
    await render(tester, item());
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('看过但时长未知 → 不画（宁可没有，也不画一条 0%）', (tester) async {
    await render(
      tester,
      item(durationMs: null),
      watched: const Duration(minutes: 12),
    );
    expect(
      find.byType(LinearProgressIndicator),
      findsNothing,
      reason: '画一条 0% 的空槽等于告诉用户「这一集没看过」，而它其实看过 —— '
          '这一行唯一的信息就是「看到哪儿了」，报错了不如不报。',
    );
  });

  testWidgets('进度条**不改变行高** —— 看过的行与没看过的行一样高', (tester) async {
    await render(tester, item(), watched: const Duration(minutes: 30));
    final withBar = tester.getSize(find.byType(MediaItemRow)).height;

    await render(tester, item());
    final withoutBar = tester.getSize(find.byType(MediaItemRow)).height;

    expect(
      withBar,
      withoutBar,
      reason: '进度条压在面板底边（不参与布局）。塞进文字列的话，一屏几十行里'
          '看过的那些会高几像素，右侧的时间列也跟着上下跳 —— 而这个列表最常见的'
          '用法正是竖着扫时间。',
    );
  });
}
