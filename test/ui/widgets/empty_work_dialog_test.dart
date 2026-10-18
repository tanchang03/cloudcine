import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/empty_work_removal.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/library_providers.dart';
import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/empty_work_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 空壳作品的确认弹窗与完整移除流程。
///
/// ## 为什么这一层要单独测
///
/// 它是 2026-10-17 那条报障的落点：用户点《仙逆剧场版：弑仙之战》拿到一句
/// 没有出口的提示。要钉的是「这条路上现在到底有什么」：
///
///   - 正文说清了两种原因 + 「网盘文件不动、重新扫描能找回」；
///   - 无副作用的按钮排在前面；
///   - 点确认 → 作品行真的没了 + 出结果提示；
///   - 点暂不移除 → 库里一动不动。
void main() {
  final now = DateTime(2026, 10, 17);

  MediaWork work(String key, String title) => MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: title,
        updatedAt: now,
      );

  /// 弹出对话框并把它的 Future 交出来，供测试断言返回值。
  Future<Future<bool?>> open(
    WidgetTester tester,
    EmptyWorkRemovalPlan plan,
  ) async {
    late Future<bool?> pending;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  pending = EmptyWorkDialog.show(context, plan);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return pending;
  }

  testWidgets('正文说清两种原因与「只清索引、网盘文件还在」', (tester) async {
    await open(
      tester,
      EmptyWorkRemovalPlan(work: work('弑仙之战', '仙逆剧场版：弑仙之战')),
    );

    expect(find.textContaining('仙逆剧场版：弑仙之战'), findsOneWidget);
    expect(find.textContaining('归到了别的作品名下'), findsOneWidget);
    expect(find.textContaining('网盘上的文件已经不在'), findsOneWidget);
    expect(find.textContaining('只清掉这台设备上的索引'), findsOneWidget);
    expect(find.textContaining('重新扫描'), findsOneWidget);
  });

  testWidgets('无副作用的按钮排在前，确认按钮是危险色那一个', (tester) async {
    await open(tester, EmptyWorkRemovalPlan(work: work('k', 'X')));

    expect(find.text('暂不移除'), findsOneWidget);
    expect(find.text('从媒体库移除'), findsOneWidget);
    // actions 数组的顺序就是视觉上的左右顺序：没副作用的那一个必须在左边，
    // 否则用户伸手就点到的是「移除」。
    final dismiss = tester.getTopLeft(find.text('暂不移除'));
    final confirm = tester.getTopLeft(find.text('从媒体库移除'));
    expect(dismiss.dx, lessThan(confirm.dx));
    final style = tester.widget<FilledButton>(find.byType(FilledButton)).style;
    expect(style?.backgroundColor?.resolve({}), AppTheme.danger);
  });

  testWidgets('点确认返回 true，点暂不移除返回 false', (tester) async {
    final plan = EmptyWorkRemovalPlan(work: work('k', 'X'));

    final pending = await open(tester, plan);
    await tester.tap(find.text('从媒体库移除'));
    await tester.pumpAndSettle();
    expect(await pending, isTrue);
    expect(find.byType(EmptyWorkDialog), findsNothing);

    final pending2 = await open(tester, plan);
    await tester.tap(find.text('暂不移除'));
    await tester.pumpAndSettle();
    expect(await pending2, isFalse);
  });

  testWidgets('完整流程：确认后空壳作品行被删掉并给出结果提示', (tester) async {
    final repo = InMemoryMediaRepository();
    // 一部**空壳**作品：作品行在，名下一条文件都没有（现场同款形状）。
    await repo.upsertWorks([work('弑仙之战', '仙逆剧场版：弑仙之战')]);
    final target = work('弑仙之战', '仙逆剧场版：弑仙之战');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [mediaRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => removeEmptyWork(context, ref, target),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从媒体库移除'));
    await tester.pumpAndSettle();

    expect(await repo.workByKey('弑仙之战'), isNull);
    expect(find.textContaining('已移除《仙逆剧场版：弑仙之战》'), findsOneWidget);
  });

  testWidgets('完整流程：用户选暂不移除时库一动不动', (tester) async {
    final repo = InMemoryMediaRepository();
    await repo.upsertWorks([work('弑仙之战', '仙逆剧场版：弑仙之战')]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [mediaRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () =>
                      removeEmptyWork(context, ref, work('弑仙之战', 'X')),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('暂不移除'));
    await tester.pumpAndSettle();

    expect(await repo.workByKey('弑仙之战'), isNotNull);
    expect(find.textContaining('已移除'), findsNothing);
  });
}
