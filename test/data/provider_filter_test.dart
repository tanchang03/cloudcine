import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:flutter_test/flutter_test.dart';

/// 来源筛选（按**文件级来源**，不是作品行的 `provider` 列）在两个实现上的
/// 一致性 —— 与 `media_repository_filter_test.dart`（年份 / 类型）同一思路。
///
/// 为什么单独写：年份 / 类型那一份 harness 只造 `media_works`、**不造
/// `media_items`**。而「来源」筛的是文件（`media_items.provider`），没有
/// items 就根本数不出来源。把 items 硬塞进那一份 harness 会牵动它的
/// `Spec` / `setUp`，所以这里自带一份小而明确的数据集。
///
/// 关键场景：
/// 1. 一部作品的文件**同时**来自夸克和百度（同一 `groupKey`）—— 它要**两
///    边都算**，这才是「按文件来源筛」和「按作品行 provider 列筛」的根本
///    区别（作品行的 `provider` 只有一个值，会把跨两家合成的那部片说成
///    单独某一家的）；
/// 2. 一部作品**没有任何文件** —— 它不计入任何来源桶，且来源筛选应把它
///    排除（用户勾「百度」时，不该冒出一部全是夸克文件的片）。
MediaItem _item(String groupKey, DriveProvider provider, String fileId) =>
    MediaItem(
      provider: provider,
      fileId: fileId,
      name: '$groupKey.mkv',
      dirId: 'd',
      dirPath: '/',
      groupKey: groupKey,
      kind: MediaKind.movie,
      firstSeenAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

MediaWork _work(String key, DriveProvider provider) => MediaWork(
      key: key,
      provider: provider,
      kind: MediaKind.movie,
      title: key,
      category: MediaCategory.movie,
      year: 2023,
      genres: const ['剧情'],
      source: ScrapeSource.local,
      updatedAt: DateTime(2026, 1, 1),
    );

void main() {
  late AppDatabase db;
  late DriftMediaRepository real;
  late InMemoryMediaRepository fake;
  final ts = DateTime(2026, 10, 1);

  setUp(() {
    db = AppDatabase.memory();
    real = DriftMediaRepository(db);
    fake = InMemoryMediaRepository();
  });
  tearDown(() => db.close());

  /// 同一批数据喂两个实现。
  Future<void> seed(List<MediaWork> works, List<MediaItem> items) async {
    await real.upsertWorks(works, now: ts);
    await fake.upsertWorks(works, now: ts);
    await real.upsertItems(items);
    await fake.upsertItems(items);
  }

  test('两个实现：listWorks(providers) 与 countWorksByProvider 口径一致',
      () async {
    // a → 只有夸克文件；b → 只有百度文件；shared → 夸克+百度都有。
    // orphan → 作品行存在，但一个文件都没有。
    const a = 'a';
    const b = 'b';
    const shared = 'shared';
    const orphan = 'orphan';
    final works = [
      _work(a, DriveProvider.quark),
      _work(b, DriveProvider.baidu),
      _work(shared, DriveProvider.quark),
      _work(orphan, DriveProvider.baidu),
    ];
    final items = [
      _item(a, DriveProvider.quark, 'a1'),
      _item(b, DriveProvider.baidu, 'b1'),
      _item(shared, DriveProvider.quark, 's1'),
      _item(shared, DriveProvider.baidu, 's2'),
    ];
    await seed(works, items);

    // 四种来源组合：夸克 / 百度 / 两者 / 不限。
    final sets = [
      {DriveProvider.quark},
      {DriveProvider.baidu},
      {DriveProvider.quark, DriveProvider.baidu},
      <DriveProvider>{},
    ];
    for (final p in sets) {
      final opts = p.isEmpty ? null : p;
      final rl =
          await real.listWorks(providers: opts, limit: 100);
      final fl =
          await fake.listWorks(providers: opts, limit: 100);
      expect(
        Set.of(rl.map((w) => w.key)),
        Set.of(fl.map((w) => w.key)),
        reason: 'listWorks(providers: $p) 两个实现应选出同一批作品',
      );
    }

    // 不限时：orphan 没有文件，但它是作品行，仍应出现在列表里。
    final all =
        await fake.listWorks(limit: 100);
    expect(
      Set.of(all.map((w) => w.key)),
      {a, b, shared, orphan},
      reason: '不限来源时四部作品都在（orphan 靠作品行入选，不靠文件）',
    );

    // 勾夸克：a + shared（shared 有夸克文件）。
    final quarkOnly = await fake.listWorks(
      providers: {DriveProvider.quark},
      limit: 100,
    );
    expect(Set.of(quarkOnly.map((w) => w.key)), {a, shared});

    // 勾百度：b + shared。
    final baiduOnly = await fake.listWorks(
      providers: {DriveProvider.baidu},
      limit: 100,
    );
    expect(Set.of(baiduOnly.map((w) => w.key)), {b, shared});

    // 角标计数：两个实现必须逐源相等，且 shared 两边各算一次。
    final rc = await real.countWorksByProvider();
    final fc = await fake.countWorksByProvider();
    expect(rc, equals(fc), reason: 'countWorksByProvider 两个实现必须一致');
    expect(rc[DriveProvider.quark], 2, reason: 'a + shared');
    expect(rc[DriveProvider.baidu], 2, reason: 'b + shared');
    expect(rc.containsKey(DriveProvider.aliyun), isFalse,
        reason: '没接入的网盘不应凭空出现一个来源');
  });

  test('没有文件的作品不计入任何来源桶', () async {
    await seed(
      [_work('orphan', DriveProvider.quark)],
      const [],
    );
    final counts = await fake.countWorksByProvider();
    expect(counts, isEmpty,
        reason: '零文件 → 来源面板应为空（触发「还没有入库的作品」提示）');

    final listed = await fake.listWorks(
      providers: {DriveProvider.quark},
      limit: 100,
    );
    expect(listed, isEmpty,
        reason: '勾夸克但没有任何夸克文件 → 列表空，与角标一致');
  });
}
