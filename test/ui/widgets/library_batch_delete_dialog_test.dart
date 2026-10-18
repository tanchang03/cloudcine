import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/library_batch_delete.dart';
import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/library_batch_delete_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 批量移除的二次确认弹窗。
///
/// ## 为什么这一层要单独测
///
/// 用户对「移除」的预期是「文件也没了」，而这个按钮实际删的是本地索引。
/// 弹窗上任何一句话缺失，后果分两种：该说的没说（白吓一场 / 不知道续播
/// 进度会没）。所以要钉的是「正文里到底有没有说」：
///
///   - 网盘文件保留 + 能重新扫描找回（说在最前）；
///   - 续播进度 / 播放偏好 / 片头片尾会一起走；
///   - 摊开要移除的名字；
///   - 确认按钮带数量。
void main() {
  final now = DateTime(2026, 10, 17);

  MediaWork work(String key, String title, {String? mergedInto}) => MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: title,
        mergedInto: mergedInto,
        updatedAt: now,
      );

  /// 弹出对话框并把它的 Future 交出来，供测试断言返回值。
  Future<Future<bool?>> open(WidgetTester tester, LibraryBatchDeletePlan plan) async {
    late Future<bool?> pending;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  pending = LibraryBatchDeleteDialog.show(context, plan);
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

  testWidgets('正文说清「只移除索引、网盘文件还在、能扫回来」', (tester) async {
    await open(
      tester,
      LibraryBatchDeletePlan(works: [work('a', '进击的巨人')]),
    );

    expect(find.text('要从媒体库移除这 1 部吗？'), findsOneWidget);
    expect(find.textContaining('网盘上的文件原样保留'), findsOneWidget);
    expect(find.textContaining('重新扫描'), findsOneWidget);
  });

  testWidgets('本地数据会跟着走这件事也写在正文里', (tester) async {
    await open(
      tester,
      LibraryBatchDeletePlan(works: [work('a', '进击的巨人')]),
    );

    expect(find.textContaining('续播'), findsOneWidget);
    expect(find.textContaining('片头/片尾'), findsOneWidget);
  });

  testWidgets('摊开要移除的名字，超过上限折起来', (tester) async {
    await open(
      tester,
      LibraryBatchDeletePlan(
        works: [for (var i = 0; i < 12; i++) work('k$i', '剧$i')],
      ),
    );

    expect(find.text('剧0'), findsOneWidget);
    expect(find.text('剧7'), findsOneWidget);
    expect(find.text('剧8'), findsNothing);
    expect(find.text('…等共 12 部'), findsOneWidget);
  });

  testWidgets('勾选里有别名行时出现合并警告', (tester) async {
    await open(
      tester,
      LibraryBatchDeletePlan(
        works: [work('a', '遮天', mergedInto: 'shrouding'), work('s', '遮天全集')],
      ),
    );

    expect(find.textContaining('别名行'), findsOneWidget);
  });

  testWidgets('点确认返回 true，点取消返回 false', (tester) async {
    final plan = LibraryBatchDeletePlan(works: [work('a', '剧A')]);

    final pending = await open(tester, plan);
    await tester.tap(find.text('移除 1 部'));
    await tester.pumpAndSettle();
    expect(await pending, isTrue);
    expect(find.byType(LibraryBatchDeleteDialog), findsNothing);

    final pending2 = await open(tester, plan);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await pending2, isFalse);
  });
}
