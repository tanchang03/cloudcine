import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「最近播放」那一栏在仓储层的行为。
///
/// 判据只有一条：`MediaWork.lastPlayedAt` 非空。下面每一条都对应一个用户
/// 看得见的后果，而不是在测 SQL 长什么样。
void main() {
  final ts = DateTime(2026, 10, 1);

  MediaWork work(
    String key, {
    MediaCategory category = MediaCategory.movie,
    DateTime? playedAt,
    DateTime? updatedAt,
    int? year,
  }) =>
      MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: key,
        category: category,
        year: year,
        lastPlayedAt: playedAt,
        updatedAt: updatedAt ?? ts,
      );

  MediaItem item(String key, String fileId) => MediaItem(
        provider: DriveProvider.quark,
        fileId: fileId,
        name: '$key.mkv',
        dirId: 'd1',
        dirPath: '/电影/$key/',
        groupKey: key,
        kind: MediaKind.movie,
        title: key,
        firstSeenAt: ts,
        updatedAt: ts,
      );

  group('listWorks(playedOnly: true)', () {
    test('没播过的作品不出现', () async {
      final repo = InMemoryMediaRepository();
      await repo.upsertWorks([
        work('看过', playedAt: ts),
        work('没看过'),
      ]);

      final list = await repo.listWorks(playedOnly: true);
      expect(list.map((w) => w.key), ['看过'],
          reason: '这一栏的判据是 `lastPlayedAt` 非空。如果它不生效，'
              '用户点「最近播放」看到的会是整个媒体库 —— 那这一栏就白加了');
    });

    test('与分类是**正交**的两件事，可以同时生效', () async {
      final repo = InMemoryMediaRepository();
      await repo.upsertWorks([
        work('看过的电影', category: MediaCategory.movie, playedAt: ts),
        work('看过的动漫', category: MediaCategory.anime, playedAt: ts),
        work('没看过的电影', category: MediaCategory.movie),
      ]);

      final list = await repo.listWorks(
        category: MediaCategory.movie,
        playedOnly: true,
      );
      expect(list.map((w) => w.key), ['看过的电影'],
          reason: '一部作品同时属于「电影」和「最近播放」，两个条件叠起来是'
              '取交集。若某一侧把另一侧覆盖掉，用户会看到「电影」栏里'
              '混进动漫、或者「最近播放」里冒出没看过的片子');
    });

    test('排序仍由 sort 决定：按最近播放排时没播过的垫底', () async {
      final repo = InMemoryMediaRepository();
      await repo.upsertWorks([
        work('早看的', playedAt: ts.subtract(const Duration(days: 3))),
        work('刚看的', playedAt: ts),
        work('没看过'),
      ]);

      final list = await repo.listWorks(
        playedOnly: true,
        sort: WorkSort.recentPlayed,
      );
      expect(list.map((w) => w.key), ['刚看的', '早看的']);
    });
  });

  group('countPlayedWorks', () {
    test('数与列表一致，且与分类计数相互独立', () async {
      final repo = InMemoryMediaRepository();
      await repo.upsertWorks([
        work('看过的电影', category: MediaCategory.movie, playedAt: ts),
        work('看过的动漫', category: MediaCategory.anime, playedAt: ts),
        work('没看过的电影', category: MediaCategory.movie),
      ]);

      expect(await repo.countPlayedWorks(), 2);
      expect((await repo.listWorks(playedOnly: true)).length, 2,
          reason: '角标和列表必须是同一口径：对不上时用户会看到'
              '「最近播放 2」点进去只有一条，然后以为列表坏了');

      final byCategory = await repo.countWorksByCategory();
      expect(byCategory[MediaCategory.movie], 2,
          reason: '「电影」栏数的是全部电影，不是看过的电影。'
              '两个数字本来就不同源，不该相等');
    });
  });

  group('markPlayed 同时更新作品行', () {
    test('播一集之后整部作品进入「最近播放」', () async {
      final repo = InMemoryMediaRepository();
      await repo.upsertWorks([work('剧集', playedAt: null)]);
      await repo.upsertItems([item('剧集', 'f1'), item('剧集', 'f2')]);

      expect(await repo.countPlayedWorks(), 0);

      await repo.markPlayed('quark:f2', ts);

      expect(await repo.countPlayedWorks(), 1,
          reason: '播的是**某一条**（第 2 集），但「最近播放」是**作品级**的：'
              '只更新 item 行的话，用户看完一集回到媒体库会发现'
              '这部片子根本没进这一栏');
      final list = await repo.listWorks(playedOnly: true);
      expect(list.single.lastPlayedAt, ts);
    });
  });
}
