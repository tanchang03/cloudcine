import 'dart:io';

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/progress_store.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 播放进度那条链的**接线守卫**（PC 端，对应 Android 的 `ProgressWiringTest.kt`）。
///
/// ## 为什么必须有一条
///
/// 「进度能同步出去」这件事全押在组合根的两根线上，而两根线断掉都是**静默**的：
///
///   1. `mediaRepositoryProvider` 必须把 `progressStoreProvider` 交给
///      `DriftMediaRepository`。少了它，仓储的 `_progress` 是 `null`，
///      三个写方法就**只写库列、不写独立进度库** —— 界面上一切正常，
///      直到用户「清空索引库」或「恢复备份」，那一批进度才凭空消失。
///   2. 那个进度库必须落在 `appSupportDirProvider` 下面。落错地方的表现是
///      「进度文件不知道去哪了」，同样不报错。
///
/// ## 为什么这里能跑，而 Android 端只能读源码
///
/// Android 的 `LibraryDb(...)` 构造点散在各个 Activity 里，测试起不来，
/// 所以那边只能静态扫源码（见 `ProgressWiringTest.kt` 的类文档）。
/// PC 端这两根线都在 Riverpod 的 provider 图里：一个 `ProviderContainer`
/// 就能把**真实的**组合根搭起来直接观察。
///
/// ⛔ 行为断言比读源码强得多 —— 读源码只能证明「那行字还在」，
///    证明不了「真的按那个路径落了盘」。所以这里**刻意不读源码**。
///
/// ## 这条用例当初是怎么发现的
///
/// 2026-10-08 的 CI 红就是这根线的**副作用**：`folder_browser_test` 里
/// 「点了就播」那几条只 override 了 `databaseProvider`，而
/// `mediaRepositoryProvider` 新增了对 `appSupportDirProvider` 的依赖，
/// 于是点一下行就抛 `UnimplementedError`、页面根本没导航。当时没有一条
/// 用例守着这根线，只能靠一次诡异的 widget 测试失败去反推。
void main() {
  late Directory dir;
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cloudcine_progress_wiring');
    db = AppDatabase.memory();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        // ⚠️ **不要** override `mediaRepositoryProvider` / `progressStoreProvider`：
        //    这两个 provider 之间的那根线正是本文件要验的东西，
        //    盖掉任何一个，用例就变成自证。
        appSupportDirProvider.overrideWithValue(dir.path),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  final at = DateTime(2026, 10, 8, 9, 30);

  /// 造一条**已入库**的条目。
  ///
  /// ⛔ 必须先入库：三个写方法在 drift 实现里都是 `UPDATE ... WHERE id = ?`，
  ///    行不存在时它们**什么也不做**（不是插入）—— 不 seed 的话下面全是假绿。
  Future<String> seed(MediaRepository repo) async {
    final item = MediaItem(
      provider: DriveProvider.quark,
      fileId: 'f1',
      name: 'f1.mkv',
      dirId: 'd1',
      dirPath: '/剧集/看过的剧/',
      groupKey: '看过的剧',
      kind: MediaKind.episode,
      firstSeenAt: at,
      updatedAt: at,
    );
    await repo.upsertItems([item]);
    return item.id;
  }

  test('仓储的三个写方法都写透到独立进度库', () async {
    final repo = container.read(mediaRepositoryProvider);
    final store = container.read(progressStoreProvider);

    final id = await seed(repo);
    await repo.markPlayed(id, at);
    await repo.saveResumePosition(id, const Duration(seconds: 30));
    await repo.saveMaxPosition(id, const Duration(minutes: 5));

    final entry = store.book[id];
    expect(
      entry,
      isNotNull,
      reason: '仓储拿到的是一个**没有进度库**的实例（`_progress == null`）—— '
          '`mediaRepositoryProvider` 里 `progress: ref.watch(progressStoreProvider)` '
          '那根线断了。库列照写不误、界面完全正常，所以只能在这里守：'
          '少了它，用户「清空索引库 / 恢复备份」之后这一批进度就没了。',
    );
    expect(
      entry!.playedAtSec,
      at.millisecondsSinceEpoch ~/ 1000,
      reason: '`markPlayed` 要写透 `recordPlayed`（它同时是「最近播放」的排序键，'
          '也是追剧「点过就不再是 NEW」的判据）。',
    );
    expect(
      entry.resumeMs,
      30000,
      reason: '`saveResumePosition` 要写透 `recordResume` —— 少这一条，'
          '「换台电脑接着看」就永远从片头开始。',
    );
    expect(
      entry.maxMs,
      300000,
      reason: '`saveMaxPosition` 要写透 `recordMax` —— 少这一条，'
          '同步过去的进度条永远是空的。',
    );

    // 把这次落盘推完再结束。
    //
    // ⛔ 不是为了让上面的断言通过（那三个断言读的是内存里的 `book`），而是为了
    //    **别把一次异步写留到 tearDown 里去**：`progressStoreProvider` 的
    //    `onDispose` 是 `unawaited(store.dispose())`，`_dirty` 还为真时它会
    //    在 tearDown 删临时目录的**同时**往那个目录写文件。删一个正被写着的
    //    文件在 Windows 上是共享冲突（`windows-build` 这个 job 也跑
    //    `flutter test`）。先 `flush()` 把 `_dirty` 清掉，dispose 时就没有
    //    东西可写 —— 顺带也让这条用例的「写透」结论更强：真的走了整条落盘路径。
    await store.flush();
  });

  test('进度文件落在应用支持目录下，且真的落了盘', () async {
    final repo = container.read(mediaRepositoryProvider);
    final store = container.read(progressStoreProvider);

    expect(
      store.path,
      '${dir.path}${Platform.pathSeparator}${ProgressStore.fileName}',
      reason: '进度文件必须挂在 `appSupportDirProvider` 下面（与数据库、凭证、'
          '海报缓存同一个目录，见 `app_providers.dart`）。它同时也是'
          '「备份/同步时上传的是哪一个文件」的答案 —— 落错地方就是'
          '「本地明明有进度，网上那份永远不动」。',
    );

    final id = await seed(repo);
    await repo.saveMaxPosition(id, const Duration(minutes: 5));
    // 落盘是**防抖**的（`ProgressStore.flushDelay`，默认 2 秒），
    // 这里显式推一次，别去等真实计时器。
    await store.flush();

    // ⛔ 必须**另开一个** store 读同一个路径：去读上面那个实例的 `book`
    //    只是读它内存里那份，文件一个字节都没写也照样通过 ——
    //    而「落盘」正是这条链唯一真正重要的部分（进程一退内存就没了）。
    final reread = ProgressStore(filePath: store.path);
    await reread.load();
    expect(
      reread.book[id]?.maxMs,
      300000,
      reason: '磁盘上那份进度库读不回来 —— 要么没写、要么写的路径与'
          '「同步时会读的那个路径」不是同一个。',
    );
  });
}
