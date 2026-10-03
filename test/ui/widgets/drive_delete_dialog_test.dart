import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/services/drive_cleanup.dart';
import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/drive_delete_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 批量删除的二次确认弹窗。
///
/// ## 为什么这一层要单独测
///
/// 它是**不可逆操作**前的唯一一道闸。这个弹窗上任何一句话缺失，用户的
/// 后果都是真的丢掉网盘上的文件（不是「显示得不好看」）。所以要钉的是
/// 「正文里到底有没有说」：
///
///   - 说清删的是什么（名字摊开）；
///   - 说清能腾出多少（未知时必须写「未知」，不能是 `0 B`）；
///   - 说清不可撤销；
///   - 勾了目录时额外说一句「里面的文件一起删」。
void main() {
  DriveEntry file(String id) =>
      DriveEntry(id: id, name: '$id.mkv', isDirectory: false, sizeBytes: 1024);
  DriveEntry dir(String id) =>
      DriveEntry(id: id, name: id, isDirectory: true);

  /// 弹出对话框并把它的 Future 交出来，供测试断言返回值。
  Future<Future<bool?>> open(WidgetTester tester, DriveDeletePlan plan) async {
    late Future<bool?> pending;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  pending = DriveDeleteDialog.show(context, plan);
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

  testWidgets('正文摊开要删的名字 —— 用户要能确认「这就是我勾的那几个」',
      (tester) async {
    await open(
      tester,
      DriveDeletePlan(entries: [file('a'), file('b'), dir('电影')]),
    );

    expect(find.text('要删除这 3 项吗？'), findsOneWidget);
    expect(find.text('a.mkv'), findsOneWidget);
    expect(find.text('b.mkv'), findsOneWidget);
    expect(find.text('电影'), findsOneWidget);
    expect(find.text('删除 3 项'), findsOneWidget);
  });

  testWidgets('超过预览上限时折成「…等共 N 项」，而不是把按钮顶出屏幕',
      (tester) async {
    final entries = [for (var i = 0; i < 12; i++) file('f$i')];
    await open(tester, DriveDeletePlan(entries: entries));

    // 只摊开前 8 个。
    for (var i = 0; i < DriveDeleteDialog.previewLimit; i++) {
      expect(find.text('f$i.mkv'), findsOneWidget);
    }
    expect(find.text('f11.mkv'), findsNothing);
    expect(find.text('…等共 12 项'), findsOneWidget,
        reason: '折起来的那几个必须给一个总数，否则用户会以为总共只删 8 个。');
  });

  testWidgets('不可撤销警告必须在正文里（不能只靠颜色暗示）', (tester) async {
    await open(tester, DriveDeletePlan(entries: [file('a')]));

    expect(find.textContaining('不可撤销'), findsOneWidget);
    expect(find.textContaining('无法恢复'), findsOneWidget);
  });

  testWidgets('勾了目录时额外说一句「里面的文件一起删」', (tester) async {
    await open(tester, DriveDeletePlan(entries: [file('a'), dir('电影')]));

    expect(find.textContaining('1 个目录'), findsOneWidget);
    expect(find.textContaining('全部文件'), findsOneWidget);
  });

  testWidgets('全是文件时不说目录那句（说了就是噪音）', (tester) async {
    await open(tester, DriveDeletePlan(entries: [file('a'), file('b')]));

    expect(find.textContaining('个目录'), findsNothing);
  });

  testWidgets('体积未知时写「未知」，绝不写 0 B', (tester) async {
    await open(tester, DriveDeletePlan(entries: [dir('电影'), dir('剧集')]));

    expect(find.textContaining('未知'), findsOneWidget);
    expect(find.textContaining('0 B'), findsNothing,
        reason: '「释放 0 B」会被读成「删了也腾不出空间」，用户就不删了 —— '
            '而事实正好相反。');
  });

  testWidgets('取消返回 false（「取消」是唯一没有副作用的选择）',
      (tester) async {
    final pending = await open(
      tester,
      DriveDeletePlan(entries: [file('a')]),
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(await pending, isFalse);
  });

  testWidgets('确认返回 true', (tester) async {
    final pending = await open(
      tester,
      DriveDeletePlan(entries: [file('a'), file('b')]),
    );

    await tester.tap(find.text('删除 2 项'));
    await tester.pumpAndSettle();

    expect(await pending, isTrue);
  });
}
