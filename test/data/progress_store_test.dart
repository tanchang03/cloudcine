import 'dart:io';

import 'package:cloudcine/data/db/progress_store.dart';
import 'package:cloudcine/domain/services/playback_progress.dart';
import 'package:flutter_test/flutter_test.dart';

/// 进度文件的**落盘语义**。
///
/// 这一层的错法全是静默的，而且后果都是「用户的进度没了」：
/// 写之前不读 → 整个文件被覆盖成一条；不用原子替换 → 断电留下半个 JSON；
/// `maxMs` 允许倒退 → 进度条往回走。下面每一条都对着其中一种。
void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cloudcine_progress_test');
    path = '${dir.path}${Platform.pathSeparator}${ProgressStore.fileName}';
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  ProgressStore makeStore() => ProgressStore(
        filePath: path,
        // 防抖窗口拉到很长：测试里一律显式 `flush()`，避免定时器插进来
        // 让断言时序不确定。
        flushDelay: const Duration(hours: 1),
      );

  test('写 → 落盘 → 新实例读回来，内容一致', () async {
    final a = makeStore();
    await a.load();
    a.recordResume('quark:e1', 12_345);
    a.recordMax('quark:e1', 60_000);
    a.recordPlayed('quark:e1', DateTime.fromMillisecondsSinceEpoch(1000 * 1000));
    await a.flush();
    expect(File(path).existsSync(), isTrue);

    final b = makeStore();
    await b.load();
    expect(b.book.length, 1);
    expect(b.book['quark:e1']!.resumeMs, 12_345);
    expect(b.book['quark:e1']!.maxMs, 60_000);
    expect(b.book['quark:e1']!.playedAtSec, 1000);
  });

  test('⛔ 写之前一定先读 —— 否则整个文件被覆盖成「只有刚写的那一条」', () async {
    // 先造一个「磁盘上已经有两条」的现场。
    final seed = makeStore();
    await seed.load();
    seed.recordResume('quark:old1', 111);
    seed.recordResume('quark:old2', 222);
    await seed.flush();

    // 新实例**故意不先 load**，直接写一条 —— `flush` 内部必须先补上读。
    final fresh = makeStore();
    fresh.recordResume('quark:new', 333);
    await fresh.flush();

    final check = makeStore();
    await check.load();
    expect(
      check.book.length,
      3,
      reason: '磁盘上原有的两条必须还在（这是最容易写出的静默数据丢失）',
    );
    expect(check.book['quark:old1']!.resumeMs, 111);
    expect(check.book['quark:new']!.resumeMs, 333);
  });

  test('recordMax 只增不减', () async {
    final s = makeStore();
    await s.load();
    s.recordMax('x', 5000);
    expect(s.recordMax('x', 3000), isFalse, reason: '更小的位置是「什么都没改」');
    expect(s.book['x']!.maxMs, 5000);
    s.recordMax('x', 9000);
    expect(s.book['x']!.maxMs, 9000);
  });

  test('recordResume：`null` 与 `<= 0` 都记成「没有可续的点」', () async {
    final s = makeStore();
    await s.load();
    s.recordResume('x', 8000);
    expect(s.book['x']!.resumeMs, 8000);
    s.recordResume('x', null);
    expect(s.book['x']!.resumeMs, isNull, reason: '看完要清掉，不是写 0');
    s.recordResume('x', 4000);
    s.recordResume('x', 0);
    expect(s.book['x']!.resumeMs, isNull);
  });

  test('recordPlayed 只前进（时钟回拨不该让「最近播放」倒退）', () async {
    final s = makeStore();
    await s.load();
    s.recordPlayed('x', DateTime.fromMillisecondsSinceEpoch(9000 * 1000));
    expect(
      s.recordPlayed('x', DateTime.fromMillisecondsSinceEpoch(1000 * 1000)),
      isFalse,
    );
    expect(s.book['x']!.playedAtSec, 9000);
  });

  test('坏文件 / 空文件 → 从空开始，**不抛**', () async {
    File(path).writeAsStringSync('{"v":1,"items":{');
    final s = makeStore();
    await s.load();
    expect(s.book.isEmpty, isTrue);
    s.recordResume('x', 100);
    await s.flush();
    final again = makeStore();
    await again.load();
    expect(again.book['x']!.resumeMs, 100, reason: '坏文件应当被一份好的覆盖掉');
  });

  test('落盘之后不留 .tmp（原子替换的中间文件必须被 rename 走）', () async {
    final s = makeStore();
    await s.load();
    s.recordResume('x', 1);
    await s.flush();
    expect(File('$path.tmp').existsSync(), isFalse);
  });

  test('mergeFrom 把远程合进来并标脏', () async {
    final s = makeStore();
    await s.load();
    s.recordResume('mine', 100);

    final remote = ProgressBook({
      // ⛔ 时间戳必须**明显在现在之后**：`recordResume` 写的是「此刻」的
      //    Unix 秒，用一个 2001 年的值会输掉 LWW，测出来的就不是「远程赢」
      //    这条规则了。
      'mine': const ProgressEntry(resumeMs: 999, updatedAtSec: 4000000000),
      'theirs': const ProgressEntry(resumeMs: 200, updatedAtSec: 4000000000),
    });
    final changed = await s.mergeFrom(remote);
    expect(changed, 2, reason: '两条都变了：一条被更新的远程覆盖、一条是新增');
    expect(s.book['mine']!.resumeMs, 999, reason: '远程的 u 更大，它赢');
    expect(s.isDirty, isTrue);

    await s.flush();
    final again = makeStore();
    await again.load();
    expect(again.book.length, 2);
  });
}
