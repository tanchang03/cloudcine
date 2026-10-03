import 'dart:async';
import 'dart:io';

import 'package:cloudcine/core/error/drive_error.dart';
import 'package:cloudcine/domain/adapters/cloud_drive_adapter.dart';
import 'package:cloudcine/domain/adapters/download_task_store.dart';
import 'package:cloudcine/domain/entities/auth_credential.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/cloud_account.dart';
import 'package:cloudcine/domain/entities/download_task.dart';
import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/stream_ticket.dart';
import 'package:cloudcine/domain/services/download_queue.dart';
import 'package:cloudcine/domain/services/drive_download.dart';
import 'package:flutter_test/flutter_test.dart';

/// 下载队列的调度逻辑：**并发上限、先后顺序、暂停 / 继续 / 取消、启动归一**。
///
/// ## 为什么这些用例值得写
///
/// 队列是「下载记录页上那几个按钮」背后的东西，而它出错的方式全都**不报错**：
///
///   - 并发上限没生效 → 用户看到十几个大文件同时在下，每个都龟速，
///     网盘侧还会把账号当成在刷流量；
///   - 暂停没保住断点 → 表现是「暂停过一次的文件，继续后从 0 重下」，
///     而用户以为「已经下了 8 GB」；
///   - 启动时没把 `downloading` 归一成 `paused` → 一开应用就闷头下几十 GB，
///     界面还挂着一条永远不动的「下载中」；
///   - 重下一个已完成的文件没把字节数归零 → 续传从文件末尾要 `Range`，
///     服务端回 416，表现是「重下一次已经下过的文件直接失败」。
///
/// 这些都是「静默坏」，所以每一条都得有断言钉住。
///
/// ## 它不碰网络也不碰 SQLite
///
/// 存储换成内存里的 `Map`，下载服务换成一个由测试控制的替身 —— 于是
/// 「第几个请求先跑」「谁被暂停了」全都可以确定性地断言，不需要等真实
/// 网络，也不需要起一个真的数据库。
void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cloudcine_dq_');
    // 时钟是**每个用例各自一份**的。它是顶层变量，不复位的话上一个用例
    // 推进过的时间会漏进下一个，节流相关的断言就变成看运气了。
    _now = DateTime(2026, 10, 3, 12);
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String pathFor(String name) => '${tmp.path}/$name';

  test('并发上限：入队 5 个、上限 2，只有 2 个真的在跑', () async {
    final service = _FakeService(_gated);
    final queue = _build(service, concurrency: 2);

    for (var i = 1; i <= 5; i++) {
      await queue.enqueue(
        provider: 'quark',
        fileId: 'f$i',
        name: 'f$i.bin',
        savePath: pathFor('f$i.bin'),
      );
    }

    expect(queue.runningCount, 2,
        reason: '上限是硬约束 —— 多拉起来的那几个不会有任何报错，'
            '只会让每个下载都变慢，用户还以为是自己网不好');
    expect(service.calls.length, 2);
    // 剩下 3 个必须老实排队，不能是「已暂停」也不能是「已完成」。
    expect(
      queue.tasks.where((t) => t.status == DownloadStatus.queued).length,
      3,
    );

    for (final c in service.calls) {
      c.release();
    }
    await _settle();
    expect(queue.runningCount, 2, reason: '一个跑完就该立刻补上下一个');

    await queue.clearAll();
  });

  test('先入先出：空出并发位时先拉最早入队的那个', () async {
    final service = _FakeService(_gated);
    final queue = _build(service, concurrency: 1);

    for (var i = 1; i <= 3; i++) {
      await queue.enqueue(
        provider: 'quark',
        fileId: 'f$i',
        name: 'f$i.bin',
        savePath: pathFor('f$i.bin'),
      );
      _tick();
    }

    expect(service.calls.map((c) => c.fileId), ['f1']);

    service.calls.single.release();
    await _settle();
    expect(service.calls.map((c) => c.fileId), ['f1', 'f2'],
        reason: '列表本身是倒序展示的（新的在前），调度必须单独按创建时间正序 —— '
            '直接拿展示顺序开跑会让「批量下载」倒着下，最后一个文件先出来');

    service.calls.last.release();
    await _settle();
    expect(service.calls.map((c) => c.fileId), ['f1', 'f2', 'f3']);

    service.calls.last.release();
    await _settle();
    await queue.clearAll();
  });

  test('暂停：正在跑的落到「已暂停」，字节数取自暂停那一刻', () async {
    final service = _FakeService(
      (c) => _gated(c, pausedAt: 40, total: 100),
    );
    final queue = _build(service);

    await queue.enqueue(
      provider: 'quark',
      fileId: 'f1',
      name: 'f1.bin',
      savePath: pathFor('f1.bin'),
    );
    await _settle();
    expect(_task(queue, 'quark:f1').status, DownloadStatus.downloading);

    await queue.pause('quark:f1');
    service.calls.single.release();
    await _settle();

    final t = _task(queue, 'quark:f1');
    expect(t.status, DownloadStatus.paused);
    expect(t.receivedBytes, 40,
        reason: '断点必须写准。写大了下次发 Range 会撞 416 直接失败，'
            '写小了会重复写一段 —— 文件坏掉但不报错');
    expect(queue.runningCount, 0, reason: '暂停要真的把并发位让出来');
  });

  test('暂停排队中的任务：不用等它开跑', () async {
    final service = _FakeService(_gated);
    final queue = _build(service, concurrency: 1);

    await queue.enqueue(
        provider: 'quark', fileId: 'f1', name: 'f1.bin',
        savePath: pathFor('f1.bin'));
    await queue.enqueue(
        provider: 'quark', fileId: 'f2', name: 'f2.bin',
        savePath: pathFor('f2.bin'));
    expect(_task(queue, 'quark:f2').status, DownloadStatus.queued);

    await queue.pause('quark:f2');
    expect(_task(queue, 'quark:f2').status, DownloadStatus.paused);

    // 腾出位子也不该把它拉起来。
    service.calls.single.release();
    await _settle();
    expect(service.calls.length, 1);
    expect(queue.runningCount, 0);
  });

  test('继续：带着断点重来，startOffset 就是已下字节数', () async {
    final service = _FakeService((c) => _gated(c, pausedAt: 40, total: 100));
    final queue = _build(service);

    await queue.enqueue(
        provider: 'quark', fileId: 'f1', name: 'f1.bin',
        savePath: pathFor('f1.bin'));
    await _settle();
    await queue.pause('quark:f1');
    service.calls.single.release();
    await _settle();
    expect(_task(queue, 'quark:f1').status, DownloadStatus.paused);

    await queue.resume('quark:f1');
    await _settle();

    expect(service.calls.length, 2);
    expect(service.calls.last.startOffset, 40,
        reason: '「继续」的全部意义就是从断点接上。传 0 的话用户会觉得'
            '「暂停过一次，白下了 8 GB」');
    expect(_task(queue, 'quark:f1').status, DownloadStatus.downloading);

    service.calls.last.release();
    await _settle();
    expect(_task(queue, 'quark:f1').status, DownloadStatus.completed);
  });

  test('取消：记录消失，且它留下的 .part 一起清掉', () async {
    final service = _FakeService(_gated);
    final queue = _build(service);
    final target = pathFor('f1.bin');
    File('$target.part').writeAsStringSync('半截');

    await queue.enqueue(
        provider: 'quark', fileId: 'f1', name: 'f1.bin', savePath: target);
    await _settle();

    await queue.remove('quark:f1');
    expect(queue.tasks, isEmpty);
    expect(service.calls.single.control!.isCancelled, isTrue,
        reason: '取消要能让**正在 await 里**的下载停下来，'
            '所以是打标记而不是等它自己结束');

    service.calls.single.release();
    await _settle();
    expect(File('$target.part').existsSync(), isFalse,
        reason: '用户说的是「不要了」。留一个半截文件只是垃圾，'
            '而且下次入队时会被当成断点接上');
    expect(File(target).existsSync(), isFalse,
        reason: '取消绝不能留下一个看起来正常的半截文件');
    expect(queue.tasks, isEmpty,
        reason: '取消后下载抛 DriveDownloadCancelled，'
            '队列不能顺手把刚删掉的那行又写回列表');
  });

  test('启动：库里「下载中」的被归一成「已暂停」，且**不自动开始**', () async {
    final store = _MemoryStore();
    final old = DateTime(2026, 10, 1, 9);
    store.rows['quark:run'] = _row(
      id: 'quark:run',
      fileId: 'run',
      name: 'run.bin',
      savePath: pathFor('run.bin'),
      status: DownloadStatus.downloading,
      receivedBytes: 512,
      at: old,
    );
    store.rows['quark:done'] = _row(
      id: 'quark:done',
      fileId: 'done',
      name: 'done.bin',
      savePath: pathFor('done.bin'),
      status: DownloadStatus.completed,
      at: old,
    );

    final service = _FakeService(_gated);
    final queue = _build(service, store: store);
    await queue.init();

    expect(_task(queue, 'quark:run').status, DownloadStatus.paused,
        reason: '上次是被杀掉的，现在没有任何东西在下它。不改的话界面会'
            '永远挂着一条不动的「下载中」—— 因为并发位只数正在跑的，'
            '它连别的任务都不挡，就一直挂在那儿骗人');
    expect(_task(queue, 'quark:done').status, DownloadStatus.completed,
        reason: '已经下完的不该被改');
    expect(service.calls, isEmpty,
        reason: '一开应用就闷头下几十 GB 不是用户这次打开应用想干的事 —— '
            '「要不要继续」得由他说了算');
    expect(_task(queue, 'quark:run').receivedBytes, 512,
        reason: '断点要留着，否则「继续」会从头再来');
  });

  test('失败：记下原因与断点，继续时带着断点重试', () async {
    final service = _FakeService((c) async {
      await c.gate;
      throw const DriveException(
        type: DriveErrorType.network,
        message: '连接被重置',
      );
    });
    final queue = _build(service);
    final target = pathFor('f1.bin');

    await queue.enqueue(
        provider: 'quark', fileId: 'f1', name: 'f1.bin', savePath: target);
    await _settle();
    // 真服务失败时会留下 `.part`（只有暂停/取消之外的成功路径才会 rename）。
    File('$target.part').writeAsStringSync('x' * 77);
    service.calls.single.release();
    await _settle();

    final failed = _task(queue, 'quark:f1');
    expect(failed.status, DownloadStatus.failed);
    expect(failed.error, isNotNull, reason: '用户要看得懂为什么失败');
    expect(failed.receivedBytes, 77,
        reason: '失败时的字节数要**从 .part 现读** —— 库里的值是按秒节流写的，'
            '可能停在「已经下了 2 GB，但它说只下了 1.8 GB」');
    expect(failed.status.canResume, isTrue,
        reason: '失败之后唯一有意义的动作就是重试，而重试本来就该带断点');

    await queue.resume('quark:f1');
    await _settle();
    expect(service.calls.length, 2);
    expect(service.calls.last.startOffset, 77);
    expect(_task(queue, 'quark:f1').error, isNull,
        reason: '重试成功后上一轮的原因必须抹掉，'
            '否则界面会挂着一条早就不成立的错误');

    service.calls.last.release();
    await _settle();
  });

  test('失败文案是给用户看的一句话，不是异常字符串', () async {
    final service = _FakeService((c) async {
      await c.gate;
      throw const DriveException(
        type: DriveErrorType.rateLimited,
        message: 'too many requests',
      );
    });
    final queue = _build(service);

    await queue.enqueue(
        provider: 'quark', fileId: 'f1', name: 'f1.bin',
        savePath: pathFor('f1.bin'));
    await _settle();
    service.calls.single.release();
    await _settle();

    final t = _task(queue, 'quark:f1');
    expect(t.error, isNot(contains('too many requests')),
        reason: '把服务端的英文原文直接甩给用户等于没说');
    expect(t.error, contains('继续'),
        reason: '文案要告诉他**下一步做什么**');
  });

  test('调大并发数后 pump() 立刻多拉起几个（不用等某个跑完）', () async {
    final service = _FakeService(_gated);
    var limit = 1;
    final queue = DownloadQueue(
      store: _MemoryStore(),
      service: () => service,
      concurrency: () => limit,
    );

    for (var i = 1; i <= 3; i++) {
      await queue.enqueue(
          provider: 'quark', fileId: 'f$i', name: 'f$i.bin',
          savePath: pathFor('f$i.bin'));
      _tick();
    }
    expect(service.calls.length, 1);

    limit = 3;
    queue.pump();
    await _settle();

    expect(service.calls.length, 3,
        reason: '用户在设置页把并发数调大了，期望是立刻生效 —— '
            '等到某个任务跑完才用上新值会让他以为设置没保存');

    for (final c in service.calls) {
      c.release();
    }
    await _settle();
    await queue.clearAll();
  });

  test('重下一个已完成的文件：字节数必须归零', () async {
    final store = _MemoryStore();
    final target = pathFor('f1.bin');
    store.rows['quark:f1'] = _row(
      id: 'quark:f1',
      fileId: 'f1',
      name: 'f1.bin',
      savePath: target,
      status: DownloadStatus.completed,
      receivedBytes: 100,
      at: DateTime(2026, 10, 1),
    );

    final service = _FakeService(_gated);
    final queue = _build(service, store: store);
    await queue.init();

    await queue.enqueue(
        provider: 'quark', fileId: 'f1', name: 'f1.bin', savePath: target);
    await _settle();

    expect(service.calls.single.startOffset, 0,
        reason: '不归零的话续传会从「文件末尾」开始要 Range，'
            '服务端回 416 —— 表现是「重下一次已经下过的文件直接失败」，'
            '而文件明明就在那儿');

    service.calls.single.release();
    await _settle();
  });

  test('重下一个已暂停的文件、且保存位置没变：断点要留着', () async {
    final store = _MemoryStore();
    final target = pathFor('f1.bin');
    store.rows['quark:f1'] = _row(
      id: 'quark:f1',
      fileId: 'f1',
      name: 'f1.bin',
      savePath: target,
      status: DownloadStatus.paused,
      receivedBytes: 40,
      at: DateTime(2026, 10, 1),
    );

    final service = _FakeService(_gated);
    final queue = _build(service, store: store);
    await queue.init();

    await queue.enqueue(
        provider: 'quark', fileId: 'f1', name: 'f1.bin', savePath: target);
    await _settle();

    expect(service.calls.single.startOffset, 40,
        reason: '用户又点了一次同一个文件，期望是「接着下」而不是「从头下」');

    service.calls.single.release();
    await _settle();
  });

  test('换了保存位置重下：断点必须归零（旧断点属于另一个文件）', () async {
    final store = _MemoryStore();
    store.rows['quark:f1'] = _row(
      id: 'quark:f1',
      fileId: 'f1',
      name: 'f1.bin',
      savePath: pathFor('旧位置.bin'),
      status: DownloadStatus.paused,
      receivedBytes: 40,
      at: DateTime(2026, 10, 1),
    );

    final service = _FakeService(_gated);
    final queue = _build(service, store: store);
    await queue.init();

    await queue.enqueue(
        provider: 'quark', fileId: 'f1', name: 'f1.bin',
        savePath: pathFor('新位置.bin'));
    await _settle();

    expect(service.calls.single.startOffset, 0,
        reason: '换了目标位置就等于换了一个文件。沿用旧断点会把新文件'
            '从中间开始写，长度不对且**不会报错**');

    service.calls.single.release();
    await _settle();
  });

  test('重复点同一个正在下的文件：不打断它', () async {
    final service = _FakeService(_gated);
    final queue = _build(service);
    final target = pathFor('f1.bin');

    await queue.enqueue(
        provider: 'quark', fileId: 'f1', name: 'f1.bin', savePath: target);
    await _settle();
    await queue.enqueue(
        provider: 'quark', fileId: 'f1', name: 'f1.bin', savePath: target);
    await _settle();

    expect(service.calls.length, 1,
        reason: '用户在目录里多点了一次「下载」，期望是「已经在下了」，'
            '而不是「从 0 重新下一遍」');
    expect(queue.tasks.length, 1, reason: '同一个文件只该有一条记录');

    service.calls.single.release();
    await _settle();
  });

  test('全部暂停 / 全部继续', () async {
    final service = _FakeService((c) => _gated(c, pausedAt: 5, total: 100));
    final queue = _build(service, concurrency: 1);

    await queue.enqueue(
        provider: 'quark', fileId: 'f1', name: 'f1.bin',
        savePath: pathFor('f1.bin'));
    await queue.enqueue(
        provider: 'quark', fileId: 'f2', name: 'f2.bin',
        savePath: pathFor('f2.bin'));
    await _settle();

    await queue.pauseAll();
    service.calls.single.release();
    await _settle();

    expect(
      queue.tasks.every((t) => t.status == DownloadStatus.paused),
      isTrue,
      reason: '「全部暂停」要连排队中的一起停 —— 只停正在跑的那个，'
          '用户会看到暂停之后还有一个自己动起来了',
    );

    await queue.resumeAll();
    await _settle();
    expect(queue.runningCount, 1, reason: '继续之后仍然受并发上限约束');
    expect(
      queue.tasks.where((t) => t.status == DownloadStatus.queued).length,
      1,
    );

    service.calls.last.release();
    await _settle();
    await queue.clearAll();
  });

  test('清空已完成：失败与暂停的留着', () async {
    final store = _MemoryStore();
    final at = DateTime(2026, 10, 1);
    store.rows['quark:a'] = _row(
        id: 'quark:a', fileId: 'a', name: 'a', savePath: pathFor('a'),
        status: DownloadStatus.completed, at: at);
    store.rows['quark:b'] = _row(
        id: 'quark:b', fileId: 'b', name: 'b', savePath: pathFor('b'),
        status: DownloadStatus.failed, at: at);
    store.rows['quark:c'] = _row(
        id: 'quark:c', fileId: 'c', name: 'c', savePath: pathFor('c'),
        status: DownloadStatus.paused, at: at);

    final queue = _build(_FakeService(_gated), store: store);
    await queue.init();

    await queue.clearCompleted();

    expect(queue.tasks.map((t) => t.fileId).toSet(), {'b', 'c'},
        reason: '失败的留着 —— 用户可能还想重试。'
            '顺手清掉等于把他的重试意图一起删了');
    expect(store.rows.keys.toSet(), {'quark:b', 'quark:c'},
        reason: '库里也要真的删掉，不能只是界面看不见');
  });

  test('结构性变化立刻通知，进度变化按 4 次/秒节流', () async {
    final service = _FakeService((c) async {
      // 每块隔 10ms → 50 块跨过两个 250ms 的节流窗口。
      // ⚠️ 必须推时钟：时钟冻住的话每个回调的 `now` 都一样，节流永远
      // 「命中」，断言会**白过** —— 那时它测的是「时钟没动」而不是节流本身。
      for (var i = 1; i <= 50; i++) {
        _now = _now.add(const Duration(milliseconds: 10));
        c.onProgress?.call(DriveDownloadProgress(received: i, total: 100));
      }
      await c.gate;
      return DriveDownloadResult(path: c.savePath, bytes: 100);
    });
    final queue = _build(service);
    var notified = 0;
    queue.onChanged = () => notified++;

    await queue.enqueue(
        provider: 'quark', fileId: 'f1', name: 'f1.bin',
        savePath: pathFor('f1.bin'));
    await _settle();

    expect(notified, lessThan(10),
        reason: '50 次进度回调只该放出个位数次通知。一个几十 GB 的文件是'
            '几十万次回调，每次都让界面重建一遍列表是纯浪费 —— '
            '4 Hz 已经比人眼能分辨的还快');
    expect(notified, greaterThan(0), reason: '入队这种结构性变化必须立刻通知');

    service.calls.single.release();
    await _settle();
    expect(_task(queue, 'quark:f1').status, DownloadStatus.completed);
  });
}

// ---------------------------------------------------------------------------
// 测试脚手架
// ---------------------------------------------------------------------------

/// 时钟：**必须注入**。
///
/// 队列的节流（250ms 通知 / 1s 落库）和 FIFO 排序都读时钟。用真时钟的话
/// 「先入先出」会取决于两次 `enqueue` 之间恰好隔了多少微秒 —— 那是随机过。
var _now = DateTime(2026, 10, 3, 12);

void _tick() => _now = _now.add(const Duration(seconds: 1));

DownloadQueue _build(
  DriveDownloadService service, {
  DownloadTaskStore? store,
  int concurrency = 5,
}) =>
    DownloadQueue(
      store: store ?? _MemoryStore(),
      service: () => service,
      concurrency: () => concurrency,
      clock: () => _now,
    );

/// 让挂起的微任务与计时器跑完。
///
/// 队列里大量用 `unawaited`（落库、`_start`），断言之前必须让它们落地，
/// 否则测的是「还没写完的中间态」。
Future<void> _settle([int turns = 8]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

DownloadTask _task(DownloadQueue queue, String id) =>
    queue.tasks.firstWhere((t) => t.id == id);

DownloadTask _row({
  required String id,
  required String fileId,
  required String name,
  required String savePath,
  required DownloadStatus status,
  required DateTime at,
  int receivedBytes = 0,
}) =>
    DownloadTask(
      id: id,
      provider: 'quark',
      fileId: fileId,
      name: name,
      savePath: savePath,
      status: status,
      receivedBytes: receivedBytes,
      createdAt: at,
      updatedAt: at,
    );

/// 替身下载器：等测试放行，然后按令牌决定抛什么。
///
/// 刻意模仿真服务在**数据块边界**检查令牌这件事 —— 所以暂停 / 取消都是
/// 「等测试放行之后才生效」，与真服务一致（真服务也要等到下一块）。
Future<DriveDownloadResult> _gated(
  _DownloadCall c, {
  int? pausedAt,
  int? total,
}) async {
  c.onProgress?.call(
    DriveDownloadProgress(received: c.startOffset, total: total),
  );
  await c.gate;
  if (c.control?.isCancelled ?? false) throw const DriveDownloadCancelled();
  if (c.control?.isPaused ?? false) {
    throw DriveDownloadPaused(pausedAt ?? c.startOffset);
  }
  return DriveDownloadResult(
    path: c.savePath,
    bytes: total ?? c.startOffset,
  );
}

/// 一次 `download()` 调用。测试用它放行 / 看参数。
class _DownloadCall {
  _DownloadCall(this.fileId, this.savePath, this.startOffset, this.control,
      this.onProgress);

  final String fileId;
  final String savePath;
  final int startOffset;
  final DriveDownloadControl? control;
  final void Function(DriveDownloadProgress)? onProgress;

  final Completer<void> _gate = Completer<void>();

  Future<void> get gate => _gate.future;

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }
}

/// 只覆盖 `download` 的替身服务。适配器永远不会被用到。
class _FakeService extends DriveDownloadService {
  _FakeService(this._handler) : super(adapter: _StubAdapter());

  final Future<DriveDownloadResult> Function(_DownloadCall call) _handler;
  final List<_DownloadCall> calls = [];

  @override
  Future<DriveDownloadResult> download({
    required String fileId,
    required String savePath,
    int startOffset = 0,
    DriveDownloadControl? control,
    void Function(DriveDownloadProgress progress)? onProgress,
  }) {
    final call =
        _DownloadCall(fileId, savePath, startOffset, control, onProgress);
    calls.add(call);
    return _handler(call);
  }
}

/// 内存里的下载记录表。语义与 `DriftDownloadTaskStore` 对齐
/// （尤其是 `loadAll` 的排序与 `pauseRunning` 的「只动 downloading」）。
class _MemoryStore implements DownloadTaskStore {
  final Map<String, DownloadTask> rows = {};

  @override
  Future<List<DownloadTask>> loadAll() async => rows.values.toList()
    ..sort((a, b) {
      final byTime = b.createdAt.compareTo(a.createdAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });

  @override
  Future<void> save(DownloadTask task) async => rows[task.id] = task;

  @override
  Future<void> remove(String id) async => rows.remove(id);

  @override
  Future<void> removeMany(List<String> ids) async {
    for (final id in ids) {
      rows.remove(id);
    }
  }

  @override
  Future<void> removeCompleted() async =>
      rows.removeWhere((_, t) => t.status == DownloadStatus.completed);

  @override
  Future<int> pauseRunning(DateTime at) async {
    var changed = 0;
    for (final entry in rows.entries.toList()) {
      if (entry.value.status != DownloadStatus.downloading) continue;
      rows[entry.key] = entry.value.copyWith(
        status: DownloadStatus.paused,
        updatedAt: at,
      );
      changed++;
    }
    return changed;
  }
}

/// 占位适配器。队列的测试不该碰网盘，所以它的每个方法都直接失败 ——
/// 真被调用到就说明替身服务没有覆盖住那条路。
class _StubAdapter extends CloudDriveAdapter {
  @override
  DriveProvider get provider => DriveProvider.quark;

  @override
  Capabilities get capabilities =>
      const Capabilities(provider: DriveProvider.quark);

  @override
  String get rootId => 'root';

  @override
  Future<StreamTicket> resolveStream(String fileId, {String? qualityId}) =>
      throw UnimplementedError('队列的测试不该取链');

  @override
  Future<DrivePage> listDirectory({
    required String dirId,
    String? pageToken,
    int? pageSize,
  }) =>
      throw UnimplementedError('队列的测试不该列目录');

  @override
  Future<List<DriveEntry>> search({
    required String keyword,
    int limit = 100,
    int offset = 0,
  }) =>
      throw UnimplementedError('队列的测试不该搜索');

  @override
  Future<CloudAccount?> restoreSession() async => null;

  @override
  Future<CloudAccount> authorize(AuthCredential credential) =>
      throw UnimplementedError('队列的测试不该授权');

  @override
  Future<void> signOut() async {}

  @override
  Future<bool> ping() async => true;

  @override
  Future<void> dispose() async {}
}
