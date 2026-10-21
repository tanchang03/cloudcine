import 'package:cloudcine/domain/services/library_batch_delete.dart';
import 'package:cloudcine/ui/widgets/library_removal_progress_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 批量移除时盖在界面上那一层进度。
///
/// ## 为什么值得测
///
/// 这一层的存在意义只有一个：**在几十秒里给用户一个「还在动」的证据**，
/// 顺便吃掉所有点击。它做错的方式都很安静：
///
///   1. 不自动关 —— 任务早结束了，用户对着一根不动的进度条等到放弃；
///   2. 提前关 —— 网盘还在删，界面已经能再点一次「移除」；
///   3. 异常路径不关 —— 任务抛了，弹窗永远留在屏幕上，`await` 也永远不返回。
void main() {
  /// 一个带按钮的页面：按下之后跑 [body]，把结果 / 异常记进闭包。
  Widget host(Future<void> Function(BuildContext) body) => MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => body(context),
              child: const Text('go'),
            ),
          ),
        ),
      );

  testWidgets('删到第几个写在脸上，任务结束后自己关掉', (tester) async {
    int? result;
    await tester.pumpWidget(host((context) async {
      result = await showRemovalProgress<int>(
        context: context,
        task: (report) async {
          report(const RemovalProgress(
            phase: RemovalPhase.drive,
            done: 1,
            total: 3,
          ));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return 7;
        },
      );
    }));

    await tester.tap(find.text('go'));
    await tester.pump();

    expect(find.text('正在删除网盘文件 1/3…'), findsOneWidget,
        reason: '用户要看到「还剩多少」，而不是一个转圈');

    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpAndSettle();

    expect(find.text('正在删除网盘文件 1/3…'), findsNothing,
        reason: '任务结束了还留着一层进度条，用户会一直等');
    expect(result, 7, reason: '这一层只负责显示，结果要原样透传');
  });

  testWidgets('任务抛异常：弹窗照样关，异常照样抛给调用方', (tester) async {
    Object? error;
    await tester.pumpWidget(host((context) async {
      try {
        await showRemovalProgress<int>(
          context: context,
          task: (_) async => throw StateError('boom'),
        );
      } catch (e) {
        error = e;
      }
    }));

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing,
        reason: '异常路径不关窗的话，这个弹窗会一直压在界面上');
    expect(error, isA<StateError>());
  });

  testWidgets('点遮罩关不掉（中途退出只会失去唯一的进度来源）', (tester) async {
    await tester.pumpWidget(host((context) async {
      await showRemovalProgress<int>(
        context: context,
        task: (report) async {
          report(const RemovalProgress(phase: RemovalPhase.drive));
          await Future<void>.delayed(const Duration(seconds: 5));
          return 1;
        },
      );
    }));

    await tester.tap(find.text('go'));
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);

    // 左上角远在对话框之外 —— 那里是遮罩。
    await tester.tapAt(const Offset(2, 2));
    await tester.pump();

    expect(find.byType(AlertDialog), findsOneWidget,
        reason: '请求已经发出去了，关掉这一层取消不了任何东西');

    // 收尾：把那个 5 秒的任务放完，避免留下未完成的定时器。
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });
}
