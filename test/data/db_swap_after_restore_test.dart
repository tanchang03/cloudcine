import 'dart:io';

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/data/db/settings_store.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 恢复备份：**换掉整个 `AppDatabase`**，而不是「关掉再打开同一个」。
///
/// ## 为什么值得一个文件
///
/// 恢复备份 = 拿备份包里的 SQLite 字节覆盖 `cloudcine.sqlite`。于是有两件事
/// 必须做对，而 2026-10-07 两轮都栽在这上面：
///
///   1. **覆盖前不关连接** ⇒ SQLite 手里的页缓存 / 文件句柄仍指向旧库；
///   2. **覆盖后不重开** ⇒ Drift 只在打开连接时读一次 `PRAGMA user_version`，
///      不重开就一步迁移都不跑 ⇒ 「磁盘上是 v16 结构、连接以为还是 v17」⇒
///      碰追剧列的查询抛 `no such column: followed`，其它查询却正常。
///
/// 而「重开」**不能**写成「把刚才那个连接重新打开」—— 见第一组用例：
/// Drift 的 `close()` 是**终局**的。所以组合根里换的是**实例**
/// （`DatabaseHandle.swap`），本文件钉住这条路径：
///
///   * 换实例之后 `mediaRepositoryProvider` / `settingsStoreProvider`
///     真的指向新库（不是「重启应用才生效」）；
///   * 新库上那条当初崩掉的查询（`countUpdatedWorks`，它要读 `followed`）
///     能跑 —— 也就是 `onUpgrade` 确实补上了 v17 的 4 列；
///   * `settings` 表的内容也跟着换过来了。
void main() {
  final now = DateTime(2026, 10, 7);

  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('cloudcine_swap'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  MediaWork work(String key) => MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: key,
        updatedAt: now,
      );

  // -------------------------------------------------------------------
  // 第一组：把「为什么不能重开旧连接」钉死
  // -------------------------------------------------------------------

  test('Drift 的连接一旦 close() 就再也开不回来（所以只能换实例）', () async {
    final db = AppDatabase(NativeDatabase(File('${dir.path}/a.sqlite')));

    // 先确认它是**真的打开了**：不打开的话下面那条断言等于在测空气。
    expect(await db.customSelect('SELECT 1').get(), hasLength(1));

    await db.close();

    await expectLater(
      db.customSelect('SELECT 1').get(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains("Can't re-open a database after closing it"),
        ),
      ),
      reason: '这条抛错就是 2026-10-07 用户在设置页看到的'
          '「恢复失败：Bad state: Can\'t re-open a database…」。'
          '钉住它是为了说明：恢复流程**不能**靠「关掉再打开同一个实例」——'
          '`LazyDatabase` 只是转发，真正置位的是 `_BaseExecutor._closed`，'
          '置位之后 `ensureOpen` 直接返回 Future.error。',
    );
  });

  // -------------------------------------------------------------------
  // 第二组：恢复备份的换实例路径（走真实组合根）
  // -------------------------------------------------------------------

  test('恢复备份：换实例之后库内容、schema、设置三样一起到位', () async {
    final dbPath = '${dir.path}/cloudcine.sqlite';

    // ① 造「备份里那份库」：当前 schema 建库 → 塞 3 部作品 + 一条设置
    //    → DROP 掉 v17 的追剧 4 列 → `user_version = 16`。
    //    于是它是一份货真价实的 v16 老备份（跟用户网盘上那份同代）。
    final srcPath = '${dir.path}/from-backup.sqlite';
    final src = AppDatabase(NativeDatabase(File(srcPath)));
    await DriftMediaRepository(src).upsertWorks(
      [work('备份甲'), work('备份乙'), work('备份丙')],
      now: now,
    );
    await SettingsStore(src).write(SettingKeys.tmdbApiKey, 'from-backup');
    // ⛔ 加新列之后这里必须补 DROP：建库用的是当前 schema，列一开始就在，
    //    漏删的话 reopen 时 `onUpgrade` 会撞 `duplicate column name`。
    for (final column in const [
      'followed',
      'follow_started_at',
      'follow_checked_at',
      'new_item_count',
    ]) {
      await src.customStatement(
        'ALTER TABLE media_works DROP COLUMN $column',
      );
    }
    await src.customStatement('PRAGMA user_version = 16');
    await src.close();
    final backupBytes = await File(srcPath).readAsBytes();

    // ② 本机当前库：只有 1 部作品，设置也是本机的。
    //    用 `openFile`（生产同款，走 `createInBackground`）而不是
    //    `NativeDatabase`，为的是连「后台 isolate 版连接关掉之后能不能换」
    //    一起验掉。
    final local = AppDatabase.openFile(File(dbPath));
    await DriftMediaRepository(local).upsertWorks([work('本机唯一')], now: now);
    await SettingsStore(local).write(SettingKeys.tmdbApiKey, 'local');

    final container = ProviderContainer(
      overrides: [
        databaseHandleProvider.overrideWith(() => DatabaseHandle(local)),
        appSupportDirProvider.overrideWithValue(dir.path),
        posterCacheDirProvider.overrideWithValue('${dir.path}/posters'),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(mediaRepositoryProvider).countWorks(), 1);
    final repoBefore = container.read(mediaRepositoryProvider);
    final storeBefore = container.read(settingsStoreProvider);

    // ③ 走 `importBackup` 第 5 步的那三件事，一步不多一步不少。
    await container.read(databaseProvider).close();
    await File(dbPath).writeAsBytes(backupBytes, flush: true);
    final next = AppDatabase.openFile(File(dbPath));
    container.read(databaseHandleProvider.notifier).swap(next);
    // 懒打开：这一句才触发「读 user_version → 跑 onUpgrade」。
    // 少了它，迁移会拖到用户下一次点进媒体库。
    await next.customSelect('SELECT 1').get();
    addTearDown(next.close);

    // ④ 断言：换了实例、内容对、schema 补上、设置也换过来了。
    final repo = container.read(mediaRepositoryProvider);
    expect(
      identical(repo, repoBefore),
      isFalse,
      reason: '恢复备份必须让仓储指向**新实例**。还是同一个对象的话，'
          '它手里握着的是已经 close 掉的连接，后面每一次查询都抛 '
          'StateError。',
    );
    expect(
      identical(container.read(settingsStoreProvider), storeBefore),
      isFalse,
      reason: '设置缓存同理：`SettingsStore` 有进程内 `_cache`，'
          '不换实例的话「在新机器上恢复备份后设置页还是空的」。',
    );

    expect(await repo.countWorks(), 3, reason: '库内容真的换成备份里那份了');

    // ⛔ 这一条是**当初崩掉的那条查询**：`countUpdatedWorks` 要读
    //    `new_item_count`。v17 迁移没跑的话这里抛 `no such column`。
    expect(
      await repo.countUpdatedWorks(),
      0,
      reason: '碰追剧列的查询必须能跑 —— 它正是 2026-10-07 报 '
          '`no such column: followed` 的那一类。',
    );

    expect(
      await container.read(settingsStoreProvider).read(SettingKeys.tmdbApiKey),
      'from-backup',
      reason: '`settings` 表随整库一起被换掉了，读到的必须是备份里那份。',
    );

    final version =
        await next.customSelect('PRAGMA user_version').getSingle();
    expect(
      version.data.values.first,
      AppDatabase.currentSchemaVersion,
      reason: '换实例的意义就在于让 Drift 重新读 user_version 并跑 onUpgrade；'
          '这里还是 16 说明迁移压根没跑。',
    );
  });
}
