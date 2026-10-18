import 'dart:io';

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/data/db/progress_store.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/services/playback_progress.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 第二家网盘（百度）**复用同一套进度存储**的守卫。
///
/// ## 这条契约是什么
///
/// 进度存储层**不认厂家**：键一律是 `provider:fileId`（`MediaItem.id`），
/// 于是夸克与百度共用同一份 `playback_progress.json`、同一组
/// `media_items` 三列、同一套 LWW 合并 —— 加一家网盘**不需要**第二套存储，
/// 也不该出现 `if (provider == quark)` 这种分支。
///
/// ## 为什么需要专门钉一遍
///
/// 这条契约靠的是「所有调用方都传 `MediaItem.id` 而不是 `fileId`」。
/// 漏一处的错法是**静默**的：
///
///   * 传了裸 `fileId` → 两家网盘的条目撞进同一个键，**互相覆盖进度**；
///   * 或者键对不上 → 进度写进去了，但界面永远读不到（表现为「播完没进度」）。
///
/// 两家网盘的 ID 恰好都可能是纯数字（夸克 fid 常见 `a1b2…`，但百度
/// `fs_id` 一定是数字），所以「同一个数字 ID 出现在两家」是**真实可能**的
/// 场景，不是构造出来的极端值。
void main() {
  late Directory dir;
  late String progressPath;
  late AppDatabase db;
  late ProgressStore store;
  late DriftMediaRepository repo;

  final ts = DateTime(2026, 10, 18);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cloudcine_progress_parity');
    progressPath = '${dir.path}${Platform.pathSeparator}${ProgressStore.fileName}';
    db = AppDatabase(NativeDatabase.memory());
    store = ProgressStore(
      filePath: progressPath,
      // 防抖拉到很长：用例里一律显式 `flush()`，避免定时器插进来。
      flushDelay: const Duration(hours: 1),
    );
    repo = DriftMediaRepository(db, progress: store);
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  MediaItem item(DriveProvider provider, String fileId) => MediaItem(
        provider: provider,
        fileId: fileId,
        name: '$fileId.mkv',
        dirId: 'd1',
        dirPath: '/剧集/同一部剧/',
        groupKey: '同一部剧',
        kind: MediaKind.episode,
        firstSeenAt: ts,
        updatedAt: ts,
      );

  Future<Map<String, List<int?>>> readColumns(List<String> ids) async {
    final rows = await db.select(db.mediaItems).get();
    return {
      for (final r in rows)
        if (ids.contains(r.id))
          r.id: [
            r.resumePositionMs,
            r.maxPositionMs,
            r.lastPlayedAt?.millisecondsSinceEpoch,
          ],
    };
  }

  test('同一串 fileId 出现在两家网盘 → 两个主键，进度互不覆盖', () async {
    final quark = item(DriveProvider.quark, '90001');
    final baidu = item(DriveProvider.baidu, '90001');
    await repo.upsertItems([quark, baidu]);

    expect(quark.id, 'quark:90001');
    expect(baidu.id, 'baidu:90001');
    expect(quark.id, isNot(baidu.id));

    await store.load();
    await repo.saveResumePosition(baidu.id, const Duration(seconds: 42));
    await repo.saveMaxPosition(baidu.id, const Duration(minutes: 10));

    // 写透到进度库的**只有**百度那一条。
    expect(store.book['baidu:90001']?.resumeMs, 42000);
    expect(store.book['baidu:90001']?.maxMs, 600000);
    expect(store.book['quark:90001'], isNull);

    // 库里两行也各归各的。
    final cols = await readColumns([quark.id, baidu.id]);
    expect(cols['baidu:90001']![0], 42000);
    expect(cols['baidu:90001']![1], 600000);
    expect(cols['quark:90001']![0], isNull);
    expect(cols['quark:90001']![1], isNull);
  });

  test('百度条目落盘的键带 provider 前缀，重新读回一致', () async {
    await repo.upsertItems([item(DriveProvider.baidu, '123456')]);
    await store.load();
    await repo.markPlayed(
      'baidu:123456',
      DateTime.fromMillisecondsSinceEpoch(1000 * 1000),
    );
    await repo.saveResumePosition('baidu:123456', const Duration(seconds: 7));
    await store.flush();

    final text = File(progressPath).readAsStringSync();
    expect(text, contains('"baidu:123456"'));
    // 裸 ID 绝不能出现 —— 它意味着某处漏传了 provider。
    expect(text, isNot(contains('"123456"')));

    final reloaded = ProgressBook.fromJsonString(text);
    expect(reloaded['baidu:123456']?.resumeMs, 7000);
    expect(reloaded['baidu:123456']?.playedAtSec, 1000);
  });

  test('播种：两家网盘的进度都被 progressSnapshot 带出来', () async {
    await repo.upsertItems([
      item(DriveProvider.quark, 'q1'),
      item(DriveProvider.baidu, 'b1'),
    ]);
    await repo.saveResumePosition('quark:q1', const Duration(seconds: 30));
    await repo.saveResumePosition('baidu:b1', const Duration(seconds: 60));

    final book = await repo.progressSnapshot();
    expect(book['quark:q1']?.resumeMs, 30000);
    expect(book['baidu:b1']?.resumeMs, 60000);
  });

  test('回填：远程那条只落到对应的网盘行上', () async {
    final quark = item(DriveProvider.quark, 'same');
    final baidu = item(DriveProvider.baidu, 'same');
    await repo.upsertItems([quark, baidu]);

    // 模拟「另一台设备只看了百度那一条」。
    final remote = ProgressBook()
      ..put(
        'baidu:same',
        const ProgressEntry(
          resumeMs: 90_000,
          maxMs: 120_000,
          playedAtSec: 1_700_000_000,
          updatedAtSec: 1_700_000_000,
        ),
      );
    final changed = await repo.applyProgressSnapshot(remote);
    expect(changed, 1);

    final cols = await readColumns([quark.id, baidu.id]);
    expect(cols['baidu:same']![0], 90000);
    expect(cols['baidu:same']![1], 120000);
    // ⛔ 夸克那一行必须**一点都没动**：键不同 ⇒ 不可能是同一条。
    expect(cols['quark:same']![0], isNull);
    expect(cols['quark:same']![1], isNull);
    expect(cols['quark:same']![2], isNull);
  });

  test('重扫/换设备：条目没了但进度还在，重新入库后能铺回来', () async {
    await repo.upsertItems([item(DriveProvider.baidu, '777')]);
    await store.load();
    await repo.saveResumePosition('baidu:777', const Duration(minutes: 3));
    await store.flush();

    // 扫描器把这一家清空（例如整目录被移走）—— 进度库不受影响。
    final removed = await repo.deleteItemsNotIn(DriveProvider.baidu, const {});
    expect(removed, 1);
    expect(store.book['baidu:777']?.resumeMs, 180000);

    // 文件回来了（fs_id 不变）⇒ 键不变 ⇒ 进度可以铺回去。
    await repo.upsertItems([item(DriveProvider.baidu, '777')]);
    expect(await repo.applyProgressSnapshot(store.book), 1);
    final cols = await readColumns(['baidu:777']);
    expect(cols['baidu:777']![0], 180000);
  });
}
