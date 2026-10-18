import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/ui/widgets/media_item_row.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用**播放器实测到的时长**补齐 `duration_ms`。
///
/// ## 为什么需要这个能力（这一组守的是「进度条整条消失」）
///
/// 进度条的比例是 `历史最大位置 / 时长`。有些网盘**不下发时长**
/// （百度 `/api/list` 默认不带 `needmedia=1` 就是这样），那些条目的
/// `duration_ms` 是 NULL ⇒ 分母为零 ⇒ `itemProgressOf` /
/// `episodeProgressOf` 判定「画不出来」⇒ **看过的剧集一条进度条都没有**。
///
/// 2026-10-18 实测本机库正是这个状态：百度 40 条媒体项 `duration_ms` 全空，
/// 而其中 6 条 `max_position_ms` 有值 —— 进度记下来了，只是没分母可除。
///
/// ## 两条不能错的规则
///
///   1. **只在「还没有」时写** —— 已有值一律不动（扫描入库的元数据不该被
///      每次播放覆盖一遍）；
///   2. **重扫不许把它抹掉** —— 扫描拿不到时长时给的是 `null`，而
///      `_toCompanion` 若照直写 null，用户「重新扫描一次」就会发现进度条
///      又全没了，且扫描本身不报任何错。
void main() {
  final ts = DateTime(2026, 10, 18);

  late AppDatabase db;
  late DriftMediaRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = DriftMediaRepository(db);
  });
  tearDown(() => db.close());

  /// 一条**没有时长**的百度媒体项（就是真机上的样子）。
  MediaItem item(String fileId, {int? durationMs}) => MediaItem(
        provider: DriveProvider.baidu,
        fileId: fileId,
        name: '$fileId.mkv',
        dirId: 'd1',
        dirPath: '/剧集/Silent Honor/',
        groupKey: 'Silent Honor',
        kind: MediaKind.episode,
        durationMs: durationMs,
        firstSeenAt: ts,
        updatedAt: ts,
      );

  Future<String> seeded(String fileId, {int? durationMs}) async {
    final i = item(fileId, durationMs: durationMs);
    await repo.upsertItems(<MediaItem>[i]);
    return i.id;
  }

  test('库里没有时长 → 回填写进去', () async {
    final id = await seeded('f1');
    expect((await repo.itemById(id))?.durationMs, isNull);

    await repo.saveDurationIfMissing(id, const Duration(minutes: 43, seconds: 2));

    expect(
      (await repo.itemById(id))?.durationMs,
      const Duration(minutes: 43, seconds: 2).inMilliseconds,
    );
  });

  test('已有值 → 不覆盖（扫描入库的元数据优先）', () async {
    final id = await seeded('f1', durationMs: 3600000);

    await repo.saveDurationIfMissing(id, const Duration(minutes: 12));

    expect((await repo.itemById(id))?.durationMs, 3600000);
  });

  test('写成 0 的旧行也算「还没有」—— 0 不是「零长度文件」', () async {
    final id = await seeded('f1', durationMs: 0);

    await repo.saveDurationIfMissing(id, const Duration(minutes: 40));

    expect((await repo.itemById(id))?.durationMs, 2400000);
  });

  test('零 / 负数时长是**无操作**（不知道不等于 0 秒）', () async {
    final id = await seeded('f1');

    await repo.saveDurationIfMissing(id, Duration.zero);
    await repo.saveDurationIfMissing(id, const Duration(seconds: -5));

    expect((await repo.itemById(id))?.durationMs, isNull);
  });

  test('库里没有这一行 → 不新建（时长不决定条目存不存在）', () async {
    await repo.saveDurationIfMissing('baidu:404', const Duration(minutes: 40));
    expect(await repo.itemById('baidu:404'), isNull);
  });

  test('重扫（时长仍是 null）不许抹掉回填的值', () async {
    final id = await seeded('f1');
    await repo.saveDurationIfMissing(id, const Duration(minutes: 40));

    // 再扫一次：网盘这次同样没给时长。
    await repo.upsertItems(<MediaItem>[item('f1')]);

    expect(
      (await repo.itemById(id))?.durationMs,
      2400000,
      reason: '`_toCompanion` 的更新路径必须对 null 时长用 `Value.absent()`。'
          '照直写 null 的话，用户每重扫一次进度条就消失一次，且没有任何报错。',
    );
  });

  test('端到端：回填之后那条进度条才画得出来', () async {
    final id = await seeded('f1');
    await repo.saveMaxPosition(id, const Duration(minutes: 20));

    final before = (await repo.itemById(id))!;
    expect(
      itemProgressOf(before, const Duration(minutes: 20)),
      isNull,
      reason: '时长缺失时 `itemProgressOf` 返回 null（不画假进度）—— 这就是'
          '「看过的剧集没有进度条」的现场。',
    );

    await repo.saveDurationIfMissing(id, const Duration(minutes: 40));

    final after = (await repo.itemById(id))!;
    expect(itemProgressOf(after, const Duration(minutes: 20)), closeTo(0.5, 0.001));
  });
}
