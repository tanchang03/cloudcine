import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

/// 「文件在网盘上已经没了」之后的两种移除：删单个文件、删整部。
///
/// ## 为什么用真的 [AppDatabase.memory]
///
/// 这两件事的**全部难点都在 SQL 里**：字幕引用没有外键（要手动级联）、
/// 作品行有三个冗余计数（要重算）、归一靠 `merged_into` 打标记（删整部时
/// 要连折叠进来的源作品一起删）。内存替身复刻得再像也证明不了真库如此，
/// 而这里漏掉任何一处的后果都是**静默**的 —— 库里留下一堆在任何界面上
/// 都看不到的数据。
void main() {
  final now = DateTime(2026, 10, 2);

  late AppDatabase db;
  late DriftMediaRepository repo;

  setUp(() {
    db = AppDatabase.memory();
    repo = DriftMediaRepository(db);
  });

  tearDown(() => db.close());

  Future<void> seedWork(
    String key, {
    String title = '片子',
    int itemCount = 0,
    int totalBytes = 0,
    int seasonCount = 0,
    String? mergedInto,
  }) async {
    await db.into(db.mediaWorks).insert(
          MediaWorksCompanion.insert(
            key: key,
            provider: DriveProvider.quark.id,
            kind: 'episode',
            title: title,
            source: 'local',
            itemCount: Value(itemCount),
            totalBytes: Value(totalBytes),
            seasonCount: Value(seasonCount),
            mergedInto: Value(mergedInto),
            updatedAt: now,
          ),
        );
  }

  Future<void> seedItem(
    String workKey,
    String fileId, {
    int? sizeBytes,
    int? season,
  }) async {
    await db.into(db.mediaItems).insert(
          MediaItemsCompanion.insert(
            id: 'quark:$fileId',
            provider: DriveProvider.quark.id,
            fileId: fileId,
            name: '$fileId.mkv',
            groupKey: workKey,
            kind: 'episode',
            sizeBytes: Value(sizeBytes),
            season: Value(season),
            firstSeenAt: now,
            updatedAt: now,
          ),
        );
  }

  /// 挂一条字幕引用到某个文件上（扫描期建的，只有引用没有正文）。
  Future<void> seedSubtitle(String itemId) async {
    await db.into(db.subtitleRefs).insert(
          SubtitleRefsCompanion.insert(
            id: '$itemId#s1',
            itemId: itemId,
            origin: 'cloudFile',
            label: '简体中文',
            format: 'srt',
          ),
        );
  }

  Future<int> countItems() async => (await db.select(db.mediaItems).get()).length;

  Future<int> countSubtitles() async =>
      (await db.select(db.subtitleRefs).get()).length;

  group('deleteItem —— 只删这一个文件', () {
    test('删掉文件本身，兄弟文件保留', () async {
      await seedWork('show');
      await seedItem('show', 'f1');
      await seedItem('show', 'f2');
      await seedItem('show', 'f3');

      expect(await repo.deleteItem('quark:f2'), isTrue);

      final left = await repo.itemsForWork('show');
      expect(left.map((i) => i.fileId), ['f1', 'f3'],
          reason: '一部剧只丢了一集时，其余的必须还在 —— 删错范围就是灾难');
    });

    test('挂在它上面的字幕引用一起走', () async {
      await seedWork('show');
      await seedItem('show', 'f1');
      await seedItem('show', 'f2');
      await seedSubtitle('quark:f1');
      await seedSubtitle('quark:f2');

      await repo.deleteItem('quark:f1');

      expect(await repo.subtitlesForItem('quark:f1'), isEmpty,
          reason: '两张表之间没有外键，字幕引用必须手动清。漏了的话它们会'
              '永远躺在表里，在任何界面上都看不到，也再删不掉');
      expect(await repo.subtitlesForItem('quark:f2'), hasLength(1),
          reason: '只清被删那一条的，不能顺手把兄弟的字幕也清了');
    });

    test('重算作品行的计数 —— 否则卡片一直写着删之前的数字', () async {
      await seedWork('show', itemCount: 3, totalBytes: 300, seasonCount: 1);
      await seedItem('show', 'f1', sizeBytes: 100, season: 1);
      await seedItem('show', 'f2', sizeBytes: 100, season: 1);
      await seedItem('show', 'f3', sizeBytes: 100, season: 1);

      await repo.deleteItem('quark:f2');

      final work = (await repo.listWorks()).single;
      expect(work.itemCount, 2, reason: '卡片上写着「3 集」，用户点完移除回头'
          '看到的还是 3 —— 他只会以为没删掉');
      expect(work.totalBytes, 200);
      expect(work.seasonCount, 1);
    });

    test('作品行自己留着（删不删由调用方决定）', () async {
      await seedWork('show');
      await seedItem('show', 'f1');

      await repo.deleteItem('quark:f1');

      expect(await repo.workByKey('show'), isNotNull,
          reason: '仓储只负责「删掉这个文件」。顺带删空作品是一条产品决定，'
              '由 MissingMediaController 判断 —— 放在仓储里就是出乎'
              '调用方意料的副作用');
    });

    test('id 不存在时返回 false', () async {
      expect(await repo.deleteItem('quark:nope'), isFalse);
    });
  });

  group('deleteWork —— 整部一起删', () {
    test('作品行、名下文件、字幕引用一起走', () async {
      await seedWork('show');
      await seedItem('show', 'f1');
      await seedItem('show', 'f2');
      await seedSubtitle('quark:f1');
      await seedSubtitle('quark:f2');

      expect(await repo.deleteWork('show'), 2);

      expect(await repo.workByKey('show'), isNull);
      expect(await repo.itemsForWork('show'), isEmpty);
      expect(await repo.subtitlesForItem('quark:f1'), isEmpty,
          reason: '「整部一起删」在用户眼里就是这一部彻底不见了。只删作品行'
              '会留下一堆看不到、却一直占着计数的孤儿文件');
      expect(await countItems(), 0);
    });

    test('折叠进来的源作品也一起删（并集口径）', () async {
      await seedWork('a', title: '目标');
      await seedWork('b', title: '别名', mergedInto: 'a');
      await seedItem('a', 'fa1');
      await seedItem('b', 'fb1');
      await seedSubtitle('quark:fb1');

      expect(await repo.deleteWork('a'), 2,
          reason: '卡片上写「2 个文件」（并集）、用户点了「移除整部剧」，'
              '结果只删掉目标自己名下那一个 —— 那是数据静默变脏，'
              '而没有任何界面会报错');

      expect(await repo.workByKey('b'), isNull);
      expect(await countItems(), 0,
          reason: '归一从不搬 `media_items.group_key`，所以源作品的文件只能'
              '靠这一条路径删掉');
      expect(await countSubtitles(), 0);
    });

    test('不存在的作品返回 0，不抛', () async {
      expect(await repo.deleteWork('nope'), 0,
          reason: '「这一部本来就不在库里」不是错误 —— 那时作品行同样已经'
              '不在了，对用户来说结果一致');
    });
  });
}
