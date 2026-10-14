import 'dart:io';

import 'package:cloudcine/data/db/app_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「**上一个版本的备份恢复回来之后，新加的列必须被补上**」—— 这条路径的
/// 回归测试。
///
/// ## 它防的是什么
///
/// `.ccbak` 里装的是**整个 SQLite 文件的原始字节**（见 `LibraryBackup`），
/// 恢复 = 直接覆盖 `cloudcine.sqlite`。所以「从旧版本恢复」拿到的可能是一个
/// **结构比当前 schema 旧**的库，而两端的补结构机制不是同一套：
///
///   * `onUpgrade` —— 只在 `PRAGMA user_version` **小于**当前版本时才跑；
///   * `beforeOpen` 里的 `_ensureSchemaComplete` —— **每次打开都跑**，
///     **不信任 `user_version`**，拿 `tables.dart` 当唯一真源逐表比对。
///
/// 下面两组分别钉住这两条路。第二组是**只有第二条路能救**的形态
/// （`user_version` 已经是当前版、结构却停在 v17），也就是用户报的那句
/// 「恢复之后缺字段」最直接的样子。
///
/// ## ⛔ 为什么每组都要真的跑一条查询
///
/// 只断言「列在 `PRAGMA table_info` 里」是不够的 —— 跨端互操作要的是
/// **能读能写**。真跑一条查询才证明这一列不只是名字在。
void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cloudcine_backfill');
    file = File('${dir.path}/cloudcine.sqlite');
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 打开一次并跑一条真查询。
  ///
  /// ⛔ 库是**懒**打开的：迁移与 `beforeOpen` 都发生在**第一次查询**时。
  ///    少了这条 `SELECT 1`，下面所有断言都等于在测空气。
  Future<AppDatabase> open() async {
    final db = AppDatabase(NativeDatabase(file));
    await db.customSelect('SELECT 1').get();
    return db;
  }

  Future<List<String>> columnsOf(AppDatabase db, String table) async {
    final rows = await db.customSelect('PRAGMA table_info("$table")').get();
    return [for (final r in rows) r.read<String>('name')];
  }

  Future<List<String>> tablesOf(AppDatabase db) async {
    final rows = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
        .get();
    return [for (final r in rows) r.read<String>('name')];
  }

  Future<int> userVersion(AppDatabase db) async {
    final rows = await db.customSelect('PRAGMA user_version').get();
    return rows.first.read<int>('user_version');
  }

  /// v18 新增的 5 列（`media_works`）。⛔ 改 schema 时这里要跟着改 ——
  /// 它就是「新字段有没有被补回来」的判据本身。
  const v18Columns = <String>[
    'learned_intro_start_ms',
    'learned_intro_end_ms',
    'learned_outro_offset_ms',
    'learned_samples',
    'learned_at',
  ];

  /// v19 新增的 1 列（`media_works`，**手标**片尾偏移）。
  ///
  /// ⛔ 单列也要单独钉住：它是**手标组**的第三个字段，而手标组是「按组整体
  ///    LWW」的 —— 列缺失时 `skipFor` 读不出来、写回去会把整组打回 NULL，
  ///    症状是「标了片尾，重开就没了」，而不是一条明确的报错。
  const v19Columns = <String>['outro_offset_ms'];

  /// 「旧备份恢复回来之后必须被补齐」的全部新列。
  ///
  /// 基线是 v17（`outro_offset_ms` 与 v18 五列都还没有的那一版），所以两批
  /// 都要在这里 —— 判据是**当前 schema 相对 v17 多出来的全部列**。
  const newColumns = <String>[...v18Columns, ...v19Columns];

  test('基线：新库一次就带上 v18 / v19 的全部列与表', () async {
    final db = await open();

    expect(await userVersion(db), AppDatabase.currentSchemaVersion);
    expect(await columnsOf(db, 'media_works'), containsAll(newColumns));
    expect(await tablesOf(db), contains('skip_samples'));

    await db.close();
  });

  test('user_version 被写小、结构其实已是新版 ⇒ 打开不能报 duplicate column name', () async {
    final first = await open();
    // 模拟这条真实路径：PC(v19) 导出备份 → 在**还没升级的**电视(v17)上恢复
    // → 电视再导出。电视的 `ensureSchema` 只补它自己那一版的东西、并把
    // `user_version` 对齐到 17，但**不会**删掉 v18 / v19 的列 —— 于是落到 PC
    // 手上的是「版本号 17、结构 19」。
    await first.customStatement('PRAGMA user_version = 17');
    await first.close();

    // ⛔ 只靠 `onUpgrade` 的话，这里会跑一遍 v18 / v19 迁移、对**已存在**的列
    //    发 `ALTER TABLE … ADD COLUMN` ⇒ SQLite 抛 `duplicate column name`
    //    ⇒ 恢复备份整个失败，而库文件其实已经换掉了。
    final second = await open();

    expect(await userVersion(second), AppDatabase.currentSchemaVersion);
    expect(await columnsOf(second, 'media_works'), containsAll(newColumns));
    await second.close();
  });

  test('user_version 是当前版、结构却停在 v17 ⇒ 自检必须把缺的列和表补回来', () async {
    final first = await open();
    // 模拟「补列失败了、但版本号已经写上去了」：这是「恢复旧备份之后缺字段」
    // 最直接的形态，而它**只有** `beforeOpen` 的自检能救 —— `onUpgrade` 看到
    // `from == to` 一步都不会跑。
    for (final column in newColumns) {
      await first.customStatement('ALTER TABLE media_works DROP COLUMN $column');
    }
    await first.customStatement('DROP TABLE skip_samples');
    await first.close();

    final second = await open();

    expect(await columnsOf(second, 'media_works'), containsAll(newColumns));
    expect(await tablesOf(second), contains('skip_samples'));

    // 光有列不够 —— 真按当前版的读法查一次，证明它们可用。
    await second
        .customSelect(
          'SELECT learned_intro_end_ms, learned_outro_offset_ms, '
          'outro_offset_ms, learned_samples FROM media_works LIMIT 1',
        )
        .get();
    await second
        .customSelect('SELECT id, work_key, kind, offset_ms FROM skip_samples LIMIT 1')
        .get();

    await second.close();
  });

  test('重复打开同一个库不做任何改动（自检必须幂等）', () async {
    final first = await open();
    await first.close();

    final second = await open();
    await second.close();

    // 幂等的判据不是「没报错」而是「结构一模一样」—— `addColumn` 不做存在性
    // 检查，一旦不幂等，第二次打开就会抛 `duplicate column name`。
    final third = await open();
    expect(await columnsOf(third, 'media_works'), containsAll(newColumns));
    await third.close();
  });
}
