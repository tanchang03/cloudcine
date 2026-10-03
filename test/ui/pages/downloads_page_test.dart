import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/domain/entities/download_task.dart';
import 'package:cloudcine/ui/pages/downloads_page.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/download_providers.dart';
import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 下载记录页：**分组顺序、角标口径、按钮接线**。
///
/// ## 这里守的是什么
///
/// 队列本身的调度逻辑在 `test/domain/download_queue_test.dart` 里测过了。
/// 这一页测的是**它有没有真的接上**：
///
///   - 侧栏角标的数字与页面顶部那个「进行中」是不是同一个口径 ——
///     两处各算一遍的话，「角标说 2、进去看到 0」会变成一个没人能复现的
///     显示 bug；
///   - 分组顺序：正在动的必须在最上面（用户点进来 90% 是为了看它们）；
///   - 每行的按钮有没有调到**对应**的那个方法 —— 调错了不会报错，
///     只会表现为「点了暂停没反应」或者更糟：「点了取消，文件被暂停」。
///
/// ## 用替身而不是真的队列
///
/// 真队列会去建 SQLite、读适配器注册表，而这一页要验的只是「接线」。
/// 替身把状态直接喂进来、把动作调用记下来，于是断言可以精确到「点了哪个
/// 按钮、传了哪个 id」。
class _RecordingQueue extends DownloadQueueController {
  _RecordingQueue(this._tasks);

  final List<DownloadTask> _tasks;
  final List<String> calls = [];

  @override
  List<DownloadTask> build() => _tasks;

  @override
  Future<void> pause(String id) async => calls.add('pause:$id');

  @override
  Future<void> resume(String id) async => calls.add('resume:$id');

  @override
  Future<void> remove(String id) async => calls.add('remove:$id');

  @override
  Future<void> pauseAll() async => calls.add('pauseAll');

  @override
  Future<void> resumeAll() async => calls.add('resumeAll');

  @override
  Future<void> clearCompleted() async => calls.add('clearCompleted');
}

DownloadTask _task(
  String fileId,
  DownloadStatus status, {
  String? error,
  int receivedBytes = 0,
  int? sizeBytes = 1000,
  DateTime? at,
}) =>
    DownloadTask(
      id: 'quark:$fileId',
      provider: 'quark',
      fileId: fileId,
      name: '$fileId.bin',
      dirPath: '/电影',
      savePath: '/tmp/cloudcine_dl_test/$fileId.bin',
      status: status,
      error: error,
      receivedBytes: receivedBytes,
      sizeBytes: sizeBytes,
      createdAt: at ?? DateTime(2026, 10, 3, 12),
      updatedAt: at ?? DateTime(2026, 10, 3, 12),
    );

/// 定位到**某一行**里的按钮。
///
/// 列表里每一行都有「取消下载」，只按 tooltip 找会同时命中好几行。
/// 先按文件名找到那一行（最近的 `Container` 祖先就是行容器），再在行内找按钮。
Finder _inRowOf(String name, String tooltip) => find.descendant(
      of: find
          .ancestor(of: find.text(name), matching: find.byType(Container))
          .first,
      matching: find.byTooltip(tooltip),
    );

void main() {
  /// 一个只喂状态、只记动作的容器。
  ({ProviderContainer container, _RecordingQueue queue}) harness(
    List<DownloadTask> tasks,
  ) {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final queue = _RecordingQueue(tasks);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        downloadQueueProvider.overrideWith(() => queue),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, queue: queue);
  }

  Future<_RecordingQueue> pumpPage(
    WidgetTester tester,
    List<DownloadTask> tasks,
  ) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final h = harness(tasks);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: DownloadsPage()),
        ),
      ),
    );
    // ⚠️ 用 `pump` 而不是 `pumpAndSettle`：总长未知时进度条是**不确定态**
    // （`value: null`），它的动画永远不结束 —— `pumpAndSettle` 会直接超时，
    // 而那看起来像「页面卡死了」。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return h.queue;
  }

  test('角标口径：只数「排队 + 下载中」，不含已暂停 / 失败 / 已完成', () {
    final h = harness([
      _task('a', DownloadStatus.downloading),
      _task('b', DownloadStatus.queued),
      _task('c', DownloadStatus.paused),
      _task('d', DownloadStatus.failed),
      _task('e', DownloadStatus.completed),
    ]);

    expect(h.container.read(downloadActiveCountProvider), 2,
        reason: '角标的意义是「有东西正在动，你可能想看」。把用户早就放弃的'
            '暂停任务也算进去的话，角标会永远挂着，点进去却发现什么都没在下 —— '
            '那时它就不再是可信的信号了');
  });

  test('分组顺序：下载中 → 排队 → 已暂停 → 失败 → 已完成', () {
    final h = harness([
      _task('a', DownloadStatus.completed),
      _task('b', DownloadStatus.failed, error: '网络中断了'),
      _task('c', DownloadStatus.paused),
      _task('d', DownloadStatus.queued),
      _task('e', DownloadStatus.downloading),
    ]);

    final groups = h.container.read(downloadGroupsProvider);
    expect(
      groups.map((g) => g.status).toList(),
      [
        DownloadStatus.downloading,
        DownloadStatus.queued,
        DownloadStatus.paused,
        DownloadStatus.failed,
        DownloadStatus.completed,
      ],
      reason: '正在动的排最上面（用户点进来就是为了看它们），已完成的垫底'
          '（它们是历史，不需要一直占着视线）',
    );
    // 空分组不该画出来 —— 一排「失败 0」的标题只会让人以为出了问题。
    expect(h.container.read(downloadGroupsProvider).every((g) => g.count > 0),
        isTrue);
  });

  testWidgets('没有任何任务时给出空状态与去处', (tester) async {
    final queue = await pumpPage(tester, const []);

    expect(find.text('还没有下载任务'), findsWidgets);
    expect(queue.calls, isEmpty);
    // 没有东西可暂停 / 可继续时那两个按钮不该出现：一排永远是灰的按钮
    // 比没有按钮更让人困惑。
    expect(find.text('全部暂停'), findsNothing);
    expect(find.text('全部继续'), findsNothing);
    expect(find.text('清空已完成'), findsNothing);
  });

  testWidgets('点「暂停 / 继续 / 取消」分别调到对应的方法、带对的 id', (tester) async {
    final queue = await pumpPage(tester, [
      _task('run', DownloadStatus.downloading, receivedBytes: 400),
      _task('hold', DownloadStatus.paused, receivedBytes: 100),
    ]);

    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
    expect(queue.calls, ['pause:quark:run'],
        reason: '调成 cancel / remove 的话文件会被删掉 —— 而用户点的是「暂停一下」');

    await tester.tap(find.byTooltip('继续'));
    await tester.pumpAndSettle();
    expect(queue.calls.last, 'resume:quark:hold');

    // 两行都有「取消下载」（只要没下完就有），必须指明是**哪一行**的 ——
    // 只按 tooltip 找会同时命中两个，`tap()` 直接报 ambiguous。
    await tester.tap(_inRowOf('run.bin', '取消下载'));
    await tester.pumpAndSettle();
    expect(queue.calls.last, 'remove:quark:run');
  });

  testWidgets('工具条：有进行中的才给「全部暂停」，有可继续的才给「全部继续」', (tester) async {
    final queue = await pumpPage(tester, [
      _task('run', DownloadStatus.downloading),
      _task('hold', DownloadStatus.paused),
    ]);

    expect(find.text('全部暂停'), findsOneWidget);
    expect(find.text('全部继续'), findsOneWidget);
    expect(find.text('清空已完成'), findsNothing,
        reason: '没有已完成的记录时不该出现「清空已完成」');

    await tester.tap(find.text('全部暂停'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部继续'));
    await tester.pumpAndSettle();
    expect(queue.calls, ['pauseAll', 'resumeAll']);
  });

  testWidgets('失败的那一行把原因说出来（不是异常字符串）', (tester) async {
    await pumpPage(tester, [
      _task('bad', DownloadStatus.failed, error: '网络中断了。已经下好的部分还在，点「继续」接着下'),
    ]);

    expect(find.textContaining('点「继续」接着下'), findsOneWidget,
        reason: '用户要看到的是「下一步做什么」，而不是一个内部错误码');
  });

  testWidgets('总长未知时只说已下多少，不编一个百分比', (tester) async {
    await pumpPage(tester, [
      _task('run', DownloadStatus.downloading, receivedBytes: 400, sizeBytes: null),
    ]);

    expect(find.textContaining('已下载'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing,
        reason: '总长未知时拿已下字节编一个百分比是**假装知道** —— '
            '进度条要的是不确定态');
  });
}
