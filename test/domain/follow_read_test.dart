import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/follow_read.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「**这一集看过了没有**」——追剧 NEW 标记与「更新 N」角标的共同判据。
///
/// ## 为什么值得一个文件
///
/// 2026-10-07 现场：用户点开 `Z 遮 天 E184` 播了 **3 秒**、`E183` 播了
/// **2 秒**就关窗，日志里一次进度回报都没有（节流器只在整十秒边界触发），
/// 库里 `max_position_ms` / `last_played_at` / `resume_position_ms` 全是 NULL
/// ⇒ 行上的 `■ NEW` 不消失、海报上「更新 2」也不动。
///
/// 用户定的口径很明确：
/// > 「**无论播放了多长时间，只要点击了，就去掉 new 标记**」
///
/// 所以判据从「只看 `max_position_ms`」改成「`max_position_ms` **或**
/// `last_played_at`」。这个文件把两件事钉住：
///
///   1. [isItemWatched] 的**取或**语义（起播写的已读回执也算数）；
///   2. [syncFollowReadCount] **只下调、绝不上调** —— 上调会让「打开一次
///      详情页」凭空冒出角标。
///
/// ⚠️ 用**真 drift 库**：`itemsForWork` 的并集口径与 `maxPositions` 的
/// `max()` 语义都落在 SQL 里，替身走不到。
void main() {
  final followStarted = DateTime(2026, 10, 2, 10);
  final old = DateTime(2026, 10, 1, 10); // 追剧之前就入库了
  final fresh = DateTime(2026, 10, 7, 11); // 追剧之后才入库

  late AppDatabase db;
  late DriftMediaRepository repo;

  setUp(() {
    db = AppDatabase.memory();
    repo = DriftMediaRepository(db);
  });

  tearDown(() => db.close());

  MediaItem item(String fid, {int? episode}) => MediaItem(
        provider: DriveProvider.quark,
        fileId: fid,
        name: '$fid.mkv',
        dirId: 'd1',
        dirPath: '/来自：分享/Z 遮.天/',
        groupKey: 'zhetian',
        kind: MediaKind.episode,
        title: '遮天',
        episode: episode,
        firstSeenAt: old,
        updatedAt: old,
      );

  /// 一部在追的作品 + 两集老集 + 两集新集（`new_item_count = 2`）。
  Future<void> seed({int newItemCount = 2, bool followed = true}) async {
    await repo.upsertWorks([
      MediaWork(
        key: 'zhetian',
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: '遮天',
        followed: followed,
        followStartedAt: followed ? followStarted : null,
        followCheckedAt: followed ? followStarted : null,
        newItemCount: newItemCount,
        updatedAt: old,
      ),
    ], now: old);
    await repo.upsertItems(
      [item('f1', episode: 1), item('f2', episode: 2)],
      now: old,
    );
    await repo.upsertItems(
      [item('f3', episode: 3), item('f4', episode: 4)],
      now: fresh,
    );
  }

  group('isItemWatched：两条记录取或', () {
    test('位置有值 → 看过', () {
      final i = item('f1');
      expect(isItemWatched(i, {'quark:f1': const Duration(minutes: 3)}), isTrue);
    });

    test('位置没有、但播过（起播写的已读回执）→ 也算看过', () {
      final i = item('f1').copyWith(lastPlayedAt: fresh);
      expect(
        isItemWatched(i, const <String, Duration>{}),
        isTrue,
        reason: '用户的口径是「只要点击了就算看过」。只看了 2~3 秒时位置压根'
            '没被上报过，这一条就是唯一的证据。',
      );
    });

    test('两条都没有 → 没看过', () {
      expect(isItemWatched(item('f1'), const <String, Duration>{}), isFalse);
    });
  });

  group('syncFollowReadCount：只下调，绝不上调', () {
    test('点开一集 ⇒ 2 → 1；两集都点开 ⇒ 0', () async {
      await seed();
      await repo.markPlayed('quark:f3', fresh);

      expect(
        await syncFollowReadCount(repo, 'zhetian'),
        1,
        reason: '看过一集还剩一集 —— 停在 2 的话，用户刚看完一集却看到海报'
            '还写着「更新 2」（2026-10-07 现场原话）。',
      );
      expect((await repo.workByKey('zhetian'))!.newItemCount, 1);

      await repo.markPlayed('quark:f4', fresh);
      expect(await syncFollowReadCount(repo, 'zhetian'), 0);
      expect((await repo.workByKey('zhetian'))!.newItemCount, 0);
    });

    test('⛔ 库里是 0、但有两集没看过 ⇒ **不许**上调成 2', () async {
      await seed(newItemCount: 0);

      expect(
        await syncFollowReadCount(repo, 'zhetian'),
        0,
        reason: '上调会让「打开一次详情页」凭空冒出角标：这里的口径比'
            '`applyFollowCheck` 的累加更宽（包含「追剧之后、但被全盘扫描'
            '而不是追更检查发现的集」）。那些集该不该让角标亮，是'
            '`applyFollowCheck` 该决定的事。',
      );
      expect((await repo.workByKey('zhetian'))!.newItemCount, 0);
    });

    test('⛔ 写计数不动 `follow_started_at`（NEW 标签的基线）', () async {
      await seed();
      await repo.markPlayed('quark:f3', fresh);
      await repo.markPlayed('quark:f4', fresh);
      await syncFollowReadCount(repo, 'zhetian');

      expect(
        (await repo.workByKey('zhetian'))!.followStartedAt,
        followStarted,
        reason: '动了它，剧集行的 NEW 标签会跟着角标一起消失 —— 而那正是'
            '「哪几集是新的、我还没看」。',
      );
    });

    test('位置上报（看了 10 秒以上）同样算看过', () async {
      await seed();
      // 进度上报写的是位置，不写 `last_played_at` 之外的任何东西。
      await repo.saveMaxPosition('quark:f3', const Duration(minutes: 5));
      await repo.saveMaxPosition('quark:f4', const Duration(minutes: 5));

      expect(await syncFollowReadCount(repo, 'zhetian'), 0);
    });

    test('没在追剧的作品不动它', () async {
      await seed(followed: false, newItemCount: 3);
      await syncFollowReadCount(repo, 'zhetian');
      expect(
        (await repo.workByKey('zhetian'))!.newItemCount,
        3,
        reason: '没在追的作品不该被这个函数碰 —— 它的角标不是「追剧更新」。',
      );
    });
  });

  group('别名 key（被刮削归一折叠掉的那一行）', () {
    /// 现场形状（2026-10-07 用户库直查）：
    ///   * `media_items.group_key = 'zhetian'`（**文件名解析**出来的归组键）；
    ///   * `media_works` 里 `zhetian.merged_into = 'shroudingtheheavens'`
    ///     （刮削匹配到 TMDB 之后归一了），**追剧状态挂在目标行上**。
    ///
    /// 调用方手里只有一个 `MediaItem`，它能给的只有 `groupKey`。所以
    /// [syncFollowReadCount] 必须自己顺着 `mergedInto` 走到目标 —— 否则会
    /// 落在别名行上，而那行的 `followed` 是 false，直接提前 return，
    /// **角标永远降不下来，且不报错**。
    Future<void> seedMerged() async {
      await repo.upsertWorks([
        // 目标：用户实际在追的那一部。
        MediaWork(
          key: 'shroudingtheheavens',
          provider: DriveProvider.quark,
          kind: MediaKind.episode,
          title: '遮天',
          followed: true,
          followStartedAt: followStarted,
          followCheckedAt: followStarted,
          newItemCount: 2,
          updatedAt: old,
        ),
        // 别名：扫描时按文件名建的，刮削后被折走了。
        MediaWork(
          key: 'zhetian',
          provider: DriveProvider.quark,
          kind: MediaKind.episode,
          title: 'z遮天',
          updatedAt: old,
        ),
      ], now: old);
      await repo.mergeWorksInto('shroudingtheheavens', ['zhetian']);

      // ⛔ 归一**只写作品行**，`media_items.group_key` 保持 'zhetian' 不变
      //    （`itemsForWork` 的并集口径就是为这件事准备的）。
      await repo.upsertItems(
        [item('f3', episode: 3), item('f4', episode: 4)],
        now: fresh,
      );
    }

    test('传别名 key 也能把角标降到**目标作品**上', () async {
      await seedMerged();

      // 别名行的 `followed` 是 false —— 不跟着走的话这里直接返回 2。
      expect((await repo.workByKey('zhetian'))!.followed, isFalse);

      await repo.markPlayed('quark:f3', fresh);

      expect(
        await syncFollowReadCount(repo, 'zhetian'),
        1,
        reason: '用户点开一集，海报上的「更新 2」该变成「更新 1」。',
      );
      expect(
        (await repo.workByKey('shroudingtheheavens'))!.newItemCount,
        1,
        reason: '角标挂在**目标**作品上（列表里看得到的是它）。写到别名行上'
            '等于没写：用户看到的数字一动不动，而库里两行都是「合法」的。',
      );
      expect(
        (await repo.workByKey('zhetian'))!.newItemCount,
        0,
        reason: '别名行不该被动 —— 它已经从列表里消失了，写它没有任何意义。'
            '（算出来的 1 要是落在这里，用户看到的那枚角标一动不动，'
            '而库里两行都是「合法」的，查起来极难。）',
      );
    });
  });
}
