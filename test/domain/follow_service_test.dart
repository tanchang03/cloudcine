import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/data/db/settings_store.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/follow_auto_check.dart';
import 'package:cloudcine/domain/services/follow_service.dart';
import 'package:cloudcine/domain/services/media_discovery.dart';
import 'package:cloudcine/domain/services/scan_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// [FollowService] 的判据 —— 全部走**真 drift 库**（`AppDatabase.memory()`）。
///
/// ## 为什么不用 `InMemoryMediaRepository`
///
/// 这个功能的核心判据有三条落在 **SQL** 里，替身根本走不到：
///
///   * `pendingNewItemCounts` 的 `first_seen_at > COALESCE(checked, started)`
///     （含两个水位线都为 `NULL` 时必须得 0 的那条）；
///   * `applyFollowCheck` 的**增量累加**（`+=`，不是重算 `=`）；
///   * 并集口径（被折叠进来的源作品名下的集也算）。
///
/// 用替身测等于只测了「我写的那份假实现」。
///
/// ## 判据表来自设计文档 §8（边界与反例推演）
///
/// 尤其是「替换文件不报更新」「重扫不报更新」两条反例 —— 它们是整个功能
/// 里最容易被改坏的地方（随手换成 `modified_at` 就会全错）。
void main() {
  final t0 = DateTime(2026, 10, 1, 10); // 首次入库
  final t1 = DateTime(2026, 10, 2, 10); // 开启追剧
  final t2 = DateTime(2026, 10, 3, 10); // 第 13 集入库 / 第一次检查

  late AppDatabase db;
  late DriftMediaRepository repo;
  late SettingsStore settings;

  setUp(() {
    db = AppDatabase.memory();
    repo = DriftMediaRepository(db);
    settings = SettingsStore(db);
  });

  tearDown(() => db.close());

  // ── 造数据 ────────────────────────────────────────────────────────

  MediaItem item(
    String fid,
    String groupKey,
    String dirId,
    String dirPath,
    DateTime seen, {
    int? episode,
    DateTime? modifiedAt,
  }) =>
      MediaItem(
        provider: DriveProvider.quark,
        fileId: fid,
        name: '黑亚当.S01E${episode ?? fid}.mkv',
        dirId: dirId,
        dirPath: dirPath,
        groupKey: groupKey,
        kind: MediaKind.episode,
        episode: episode,
        modifiedAt: modifiedAt,
        firstSeenAt: seen,
        updatedAt: seen,
      );

  Future<void> seedWork({
    String key = 'adam',
    String title = '黑亚当',
    String dirId = 'dAdam',
    String dirPath = '/剧集/黑亚当/',
    int episodes = 12,
    String fidPrefix = 'f',
  }) async {
    await repo.upsertWorks([
      MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: title,
        source: ScrapeSource.local,
        updatedAt: t0,
      ),
    ]);
    await repo.upsertItems([
      for (var i = 1; i <= episodes; i++)
        // ⛔ fid 必须带前缀：`id` 是 `provider:fileId`，两部作品都用
        //    `f1..f12` 的话后一次 upsert 会把前一部**整份覆盖**掉，
        //    而症状是「计划里只有一个目录」，看起来像取消逻辑没生效。
        item('$fidPrefix$i', key, dirId, dirPath, t0, episode: i),
    ], now: t0);
  }

  /// 一个假的「列目录」：把 [newItemsFor] 给的文件真的写进库，
  /// 并返回一次**完整**的发现结果。
  ///
  /// ⛔ 写成「真的写库」而不是「返回一个数字」是有意的：追更检查的增量
  ///    完全来自库里的 `first_seen_at`，假发现不写库的话，测的就只是
  ///    「我 mock 出来的返回值」，而不是真实的链路。
  DiscoverDirectoryFn discover({
    List<MediaItem> Function(String dirId)? newItemsFor,
    Set<String> failDirs = const {},
    Set<String> incompleteDirs = const {},
    void Function(String dirId)? onCall,
  }) {
    return ({
      required DriveProvider provider,
      required String dirId,
      required String dirPath,
    }) async {
      onCall?.call(dirId);
      if (failDirs.contains(dirId)) {
        return DiscoveryOutcome(
          scope: DiscoveryScope.directory,
          rootPath: dirPath,
          failedDirs: 1,
        );
      }
      final fresh = newItemsFor?.call(dirId) ?? const <MediaItem>[];
      if (fresh.isNotEmpty) await repo.upsertItems(fresh, now: t2);
      return DiscoveryOutcome(
        scope: DiscoveryScope.directory,
        rootPath: dirPath,
        mediaFound: fresh.length,
        added: fresh.length,
        // 「子目录没读完整」：结果不完整，水位线**不能**推进。
        failedDirs: incompleteDirs.contains(dirId) ? 1 : 0,
      );
    };
  }

  FollowService service(DiscoverDirectoryFn d, {DateTime? now}) => FollowService(
        library: repo,
        settings: settings,
        discoverDirectory: d,
        clock: () => now ?? t2,
      );

  // ── 用例 ─────────────────────────────────────────────────────────

  test('开启追剧时：已有的 12 集**不算**更新', () async {
    await seedWork();
    await repo.setFollowed('adam', true, now: t1);

    final out = await service(discover()).check(force: true);

    expect(out.newItems, 0, reason: 'first_seen_at(t0) < follow_started_at(t1)');
    expect(out.updatedWorks, 0);
    expect(
      (await repo.workByKey('adam'))!.newItemCount,
      0,
      reason: '用户刚看完 12 集才开的追剧，不该看到「更新 12」',
    );
  });

  test('网盘加了第 13 集 → 角标 1，且第 13 集算 NEW', () async {
    await seedWork();
    await repo.setFollowed('adam', true, now: t1);

    final out = await service(
      discover(
        newItemsFor: (dirId) => [item('f13', 'adam', dirId, '/剧集/黑亚当/', t2, episode: 13)],
      ),
    ).check(force: true);

    expect(out.newItems, 1);
    expect(out.updatedWorks, 1);
    final work = (await repo.workByKey('adam'))!;
    expect(work.newItemCount, 1);
    expect(work.hasUpdate, isTrue);

    // 剧集行 NEW 标签：`firstSeenAt > followStartedAt && maxPositionMs == null`
    final items = await repo.itemsForWork('adam');
    final fresh = items.where((i) => i.id.endsWith('f13')).single;
    expect(
      work.isNewSinceFollow(firstSeenAt: fresh.firstSeenAt, played: false),
      isTrue,
    );
    final old = items.firstWhere((i) => i.id.endsWith('f1'));
    expect(
      work.isNewSinceFollow(firstSeenAt: old.firstSeenAt, played: false),
      isFalse,
      reason: '追剧之前就入库的集不该被标成 NEW',
    );
  });

  test('连查两次：第二次不重复计数（水位线推进了）', () async {
    await seedWork();
    await repo.setFollowed('adam', true, now: t1);
    final d = discover(
      newItemsFor: (dirId) => [item('f13', 'adam', dirId, '/剧集/黑亚当/', t2, episode: 13)],
    );

    await service(d).check(force: true);
    // 第二次检查：假发现在没有新文件了。
    final second = await service(discover()).check(force: true);

    expect(second.newItems, 0);
    expect(
      (await repo.workByKey('adam'))!.newItemCount,
      1,
      reason: '增量累加 `+=`，不是重算 `=` —— 第二次查出 0 就该加 0，不能把角标抹掉',
    );
  });

  test('清角标之后再检查：角标**不复活**（红线 7 的核心）', () async {
    await seedWork();
    await repo.setFollowed('adam', true, now: t1);
    await service(
      discover(
        newItemsFor: (dirId) => [item('f13', 'adam', dirId, '/剧集/黑亚当/', t2, episode: 13)],
      ),
    ).check(force: true);
    expect((await repo.workByKey('adam'))!.newItemCount, 1);

    await repo.setFollowNewItemCount('adam', 0);
    expect((await repo.workByKey('adam'))!.newItemCount, 0);

    // 再查一次（水位线没动，但库里没有更新的东西了）。
    final out = await service(discover()).check(force: true);
    expect(out.newItems, 0);
    expect(
      (await repo.workByKey('adam'))!.newItemCount,
      0,
      reason: '重算 `= 本次新增数` 的话，用户刚清掉的角标会在下一次检查时复活',
    );
  });

  test('目录列失败 → 水位线不推进，角标不动（红线 6）', () async {
    await seedWork();
    await repo.setFollowed('adam', true, now: t1);

    final out = await service(
      discover(
        newItemsFor: (dirId) => [item('f13', 'adam', dirId, '/剧集/黑亚当/', t2, episode: 13)],
        failDirs: {'dAdam'},
      ),
    ).check(force: true);

    expect(out.dirsFailed, 1);
    expect(out.worksChecked, 0);
    final work = (await repo.workByKey('adam'))!;
    expect(work.newItemCount, 0, reason: '这次没读到，就不该报「有更新」');
    expect(
      work.followCheckedAt,
      t1,
      reason: '水位线停在开启追剧那一刻 —— 推进等于把这批新集永久划进「已读」，'
          '用户再也不会被提醒，而且没有任何报错',
    );

    // 下次目录正常了，那批新集必须还能被报出来。
    // ⛔ 这次假发现**要真的把新集写进库** —— 上一轮列目录失败，等于我们
    //    根本没看见它，库里自然没有它；这一轮正常了才第一次见到。
    final retry = await service(
      discover(
        newItemsFor: (dirId) => [item('f13', 'adam', dirId, '/剧集/黑亚当/', t2, episode: 13)],
      ),
    ).check(force: true);
    expect(retry.newItems, 1, reason: '水位线没推进，所以下次重来还能看到这批新集');
  });

  test('子目录没读完整（failedDirs > 0）同样不推进', () async {
    await seedWork();
    await repo.setFollowed('adam', true, now: t1);

    final out = await service(
      discover(incompleteDirs: {'dAdam'}),
    ).check(force: true);

    expect(out.worksChecked, 0);
    expect((await repo.workByKey('adam'))!.followCheckedAt, t1);
  });

  test('替换文件（换一版更高码率）**不报更新**', () async {
    await seedWork();
    await repo.setFollowed('adam', true, now: t1);

    // 第 5 集换了个 2160p 的版本：fid 相同、`modified_at` 变了。
    // 仓储的 upsert 会保留旧的 `first_seen_at`（那是历史事实）。
    final out = await service(
      discover(
        newItemsFor: (dirId) => [
          item('f5', 'adam', dirId, '/剧集/黑亚当/', t2, episode: 5, modifiedAt: t2),
        ],
      ),
    ).check(force: true);

    expect(
      out.newItems,
      0,
      reason: '判据必须是 first_seen_at。用 modified_at 的话，「换了个版本」'
          '会被误报成「更新了最新一集」',
    );
  });

  test('重扫同一批文件不报更新', () async {
    await seedWork();
    await repo.setFollowed('adam', true, now: t1);

    final out = await service(
      discover(
        newItemsFor: (dirId) => [
          for (var i = 1; i <= 12; i++)
            item('f$i', 'adam', dirId, '/剧集/黑亚当/', t2, episode: i),
        ],
      ),
    ).check(force: true);

    expect(out.newItems, 0, reason: 'first_seen_at 只在行首次插入时写，重扫不刷新');
  });

  test('一部在追的作品都没有 → 一次目录都不列', () async {
    await seedWork();
    // 没开追剧。

    var calls = 0;
    final out = await service(discover(onCall: (_) => calls++)).check(force: true);

    expect(calls, 0, reason: '空清单要提前返回 —— 追剧 0 部时一次网盘请求都不发');
    expect(out.followedWorks, 0);
  });

  test('同一个目录覆盖多部作品时，另一部的新增也被报出来（红线 5）', () async {
    // 两部片子平铺在同一个目录里。
    await repo.upsertWorks([
      MediaWork(
        key: 'a',
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: 'A',
        source: ScrapeSource.local,
        updatedAt: t0,
      ),
      MediaWork(
        key: 'b',
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: 'B',
        source: ScrapeSource.local,
        updatedAt: t0,
      ),
    ]);
    await repo.upsertItems([
      item('a1', 'a', 'dMovies', '/电影/', t0),
      item('b1', 'b', 'dMovies', '/电影/', t0),
    ], now: t0);
    await repo.setFollowed('a', true, now: t1);
    await repo.setFollowed('b', true, now: t1);

    var calls = 0;
    final out = await service(
      discover(
        onCall: (_) => calls++,
        // 只有 B 更新了 —— 但目录是同一个，A 也得被回写（增量 0）。
        newItemsFor: (dirId) => [item('b2', 'b', dirId, '/电影/', t2)],
      ),
    ).check(force: true);

    expect(calls, 1, reason: '两部作品在同一个目录 → 只发 1 次列目录请求');
    expect(out.newItems, 1);
    expect((await repo.workByKey('b'))!.newItemCount, 1);
    expect((await repo.workByKey('a'))!.newItemCount, 0);
    expect(
      (await repo.workByKey('a'))!.followCheckedAt,
      t2,
      reason: 'A 这次也被完整检查过了，水位线要一起推进',
    );
  });

  group('节流', () {
    test('窗口内不重复检查；force 无视窗口', () async {
      await seedWork();
      await repo.setFollowed('adam', true, now: t1);

      // 第一次（force）把节流零点写到 t2。
      await service(discover()).check(force: true);

      var calls = 0;
      final throttled = await service(discover(onCall: (_) => calls++))
          .check(force: false);
      expect(throttled.skipped, isTrue);
      expect(calls, 0, reason: '被节流挡掉时一次请求都不该发');

      final forced = await service(discover(onCall: (_) => calls++))
          .check(force: true);
      expect(forced.skipped, isFalse);
      expect(calls, 1);
    });

    test('超过窗口就放行', () async {
      await seedWork();
      await repo.setFollowed('adam', true, now: t1);
      await settings.write(
        SettingKeys.followLastCheckAt,
        '${t1.millisecondsSinceEpoch ~/ 1000}',
      );

      var calls = 0;
      // t2 比 t1 晚 24 小时，远超 6 小时窗口。
      final out = await service(discover(onCall: (_) => calls++)).check();
      expect(out.skipped, isFalse);
      expect(calls, 1);
    });

    test('策略为 off 时自动路径一律跳过；手动（force）仍然能跑', () async {
      await seedWork();
      await repo.setFollowed('adam', true, now: t1);
      await settings.write(SettingKeys.followAutoCheck, FollowAutoCheck.off.id);

      var calls = 0;
      final auto = await service(discover(onCall: (_) => calls++)).check();
      expect(
        auto.skipped,
        isTrue,
        reason: '⛔ 这是整个功能里最隐蔽的一个坑：`off` 的 `throttleWindow` 是 '
            '`null`，而 `null` 在下面那段节流判断里的含义是「**不节流**」—— '
            '两者含义恰好相反。只靠窗口判据的话，「关闭自动检查」会变成'
            '「每次进来都检查一遍」，一次网盘请求都不省，而日志上一切正常。'
            '所以 `off` 必须在节流闸**之前**被显式挡掉。',
      );
      expect(calls, 0, reason: '关掉之后一个目录都不该列。');

      // 手动入口（分类栏那颗「检查更新」）传 `force: true` —— 用户明确要求了，
      // 这时候连 `off` 都不该挡。
      final manual =
          await service(discover(onCall: (_) => calls++)).check(force: true);
      expect(
        manual.skipped,
        isFalse,
        reason: '`off` 只关「自动」，不该把手动入口一起关掉 —— '
            '否则那个按钮会变成「按下去什么都不发生」。',
      );
      expect(calls, 1);
    });
  });

  group('自动检查策略', () {
    test('parse：null / 空串 / 写坏的值一律退回默认（onLaunch）', () {
      expect(FollowAutoCheck.parse(null), FollowAutoCheck.onLaunch);
      expect(FollowAutoCheck.parse(''), FollowAutoCheck.onLaunch);
      expect(FollowAutoCheck.parse('乱码'), FollowAutoCheck.onLaunch);
      expect(FollowAutoCheck.parse('off'), FollowAutoCheck.off);
      expect(FollowAutoCheck.parse('every_6h'), FollowAutoCheck.every6h);
      expect(FollowAutoCheck.parse('on_launch'), FollowAutoCheck.onLaunch);
    });

    test('只有 every_6h 挂定时器；off 没有窗口', () {
      expect(FollowAutoCheck.off.throttleWindow, isNull);
      expect(FollowAutoCheck.onLaunch.throttleWindow, const Duration(hours: 6));
      expect(FollowAutoCheck.every6h.throttleWindow, const Duration(hours: 6));
      expect(FollowAutoCheck.onLaunch.runsOnTimer, isFalse);
      expect(FollowAutoCheck.every6h.runsOnTimer, isTrue);
    });
  });

  test('cancel 后不再继续列目录', () async {
    await seedWork();
    await repo.setFollowed('adam', true, now: t1);
    await seedWork(key: 'b', title: 'B', dirId: 'dB', dirPath: '/剧集/B/', fidPrefix: 'g');
    // ⛔ 两部都要**在追** —— 只有一部在追时计划里只有一个目录，
    //    循环根本走不到第二次判取消，测的就不是「取消生效」。
    await repo.setFollowed('b', true, now: t1);

    final token = ScanCancellation();
    var calls = 0;
    final out = await service(
      discover(
        onCall: (_) {
          calls++;
          token.cancel();
        },
      ),
    ).check(force: true, cancel: token);

    expect(out.cancelled, isTrue);
    expect(calls, 1, reason: '取消后剩下的目录不该再列');
  });

  test('outcome 文案：有更新才 hasNews', () async {
    await seedWork();
    await repo.setFollowed('adam', true, now: t1);

    // ⛔ 顺序不能反：全库时间列是**秒**，先跑一次安静检查会把水位线推到
    //    这一秒，紧接着以同一秒入库的新集就不再「比水位线新」了
    //    （那是真实存在的 1 秒竞态，见 `FollowService._run` 第 5 步的注释）。
    //    真实场景里「检查」与「入库」相隔数秒，所以这里按真实顺序写。
    final loud = await service(
      discover(
        newItemsFor: (dirId) => [item('f13', 'adam', dirId, '/剧集/黑亚当/', t2, episode: 13)],
      ),
    ).check(force: true);
    expect(loud.hasNews, isTrue);
    expect(loud.message, contains('1'));

    final quiet = await service(discover()).check(force: true);
    expect(quiet.hasNews, isFalse, reason: '没查出更新时不该弹任何东西');
  });
}
