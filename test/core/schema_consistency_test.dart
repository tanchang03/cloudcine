import 'dart:io';

import 'package:cloudcine/data/db/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

/// **两端 schema 契约的一致性守卫。**
///
/// 跨端同步的唯一依据是 `cloudcine.sqlite`：备份包（`.ccbak`）里装的是这个文件
/// 的**原始字节**，PC 端恢复之后 `user_version` 一看相等就直接拿它当自己的库用。
/// 所以 Android 那边 `LibrarySchema.kt` 少一个列名，PC 端就是
/// `no such column: xxx` —— 而且**不会有迁移来兜底**。
///
/// Android 侧已有 `LibrarySchemaTest`（拿 PC 端 dump 出来的 DDL 原文逐字比对），
/// 但那份期望值是**人手抄过去的字符串**：抄漏一列，两边各自全绿。所以这里反向
/// 再守一次 —— **直接从 Kotlin 源码里抠出列名**，与 drift 运行时的列定义比集合。
///
/// ⛔ 这个守卫的价值全在「两边同时改错也会红」，所以它**不读任何中间产物**
///    （golden 文件、导出的 DDL、注释里抄的清单），只读源码 + 问 drift 运行时。
///
/// 历史事故：v18 / v19 两次加列（`learned_*` / `outro_offset_ms`）都是先改 PC，
/// 隔了一会儿才想起来改 Android —— 中间那段时间导出的备份在 PC 上能打开、
/// 在 Android 上直接报错。
void main() {
  /// Kotlin 侧的 schema 契约（相对仓库根；`flutter test` 的工作目录就是它）。
  const schemaPath =
      'android/app/src/main/java/com/cloudcine/tv/library/LibrarySchema.kt';

  late String source;

  setUpAll(() {
    final file = File(schemaPath);
    expect(
      file.existsSync(),
      isTrue,
      reason: '找不到 $schemaPath —— 守卫文件挪位置了？路径要跟着改。',
    );
    source = file.readAsStringSync();
  });

  test('user_version 必须与 PC 端 currentSchemaVersion 相等', () {
    final match = RegExp(r'const val VERSION = (\d+)').firstMatch(source);
    expect(
      match,
      isNotNull,
      reason: 'LibrarySchema.kt 里找不到 `const val VERSION = <n>`',
    );

    expect(
      int.parse(match!.group(1)!),
      AppDatabase.currentSchemaVersion,
      reason: '两端 schema 版本不一致。\n'
          '  · 写小了 → PC 端 restore 后会跑一遍迁移，多数是 ADD COLUMN，'
          '直接报 duplicate column name；\n'
          '  · 写大了 → PC 端判定「来自更高版本的数据库」并只打一条 warn，'
          '之后每次读那个列都是 no such column。\n'
          '修法：改 PC 的 `AppDatabase.currentSchemaVersion` 与 '
          'Android 的 `LibrarySchema.VERSION`，**两处一起改**，'
          '并同步 `LibrarySchemaTest` 的 DDL 期望值。',
    );
  });

  test('media_works 的列名两端逐列一致（加列时最容易漏的那张表）', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    _expectSameColumns(
      table: 'media_works',
      pc: db.mediaWorks.$columns.map((c) => c.name).toSet(),
      android: _kotlinColumns(source, 'media_works'),
    );
  });

  test('每张表两端都有，且列名逐列一致', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    // ⛔ drift 的 `allTables` 里没有内部表（`sqlite_master` 之类），但保险起见
    //    还是滤掉下划线开头的名字 —— 那种一旦混进来，报错信息会变成
    //    「Android 少了一张 __schema 表」，完全指不到真正的问题。
    final pc = <String, Set<String>>{
      for (final t in db.allTables)
        if (!t.actualTableName.startsWith('_'))
          t.actualTableName: t.$columns.map((c) => c.name).toSet(),
    };
    final android = _kotlinTables(source);

    expect(
      android.keys.toSet().difference(pc.keys.toSet()),
      isEmpty,
      reason: 'Android 里多出来的表（PC 端没有）：'
          '${android.keys.toSet().difference(pc.keys.toSet())}',
    );
    expect(
      pc.keys.toSet().difference(android.keys.toSet()),
      isEmpty,
      reason: 'Android 缺的表（PC 端有）：'
          '${pc.keys.toSet().difference(android.keys.toSet())}',
    );

    for (final name in pc.keys) {
      _expectSameColumns(
        table: name,
        pc: pc[name]!,
        android: android[name]!,
      );
    }
  });
}

/// 两端的列名集合必须**完全相等**（两个方向都查，报错信息才指得准）。
void _expectSameColumns({
  required String table,
  required Set<String> pc,
  required Set<String> android,
}) {
  final onlyAndroid = android.difference(pc);
  final onlyPc = pc.difference(android);

  expect(
    onlyAndroid,
    isEmpty,
    reason: '$table：Android 有、PC 端没有的列 $onlyAndroid。\n'
        'PC 端会直接 `no such column`，而且**没有迁移兜底**'
        '（user_version 相等 ⇒ 不跑迁移）。',
  );
  expect(
    onlyPc,
    isEmpty,
    reason: '$table：PC 端有、Android 没有的列 $onlyPc。\n'
        'Android 读那一列会抛，导出的备份也会缺列。',
  );
}

/// 从 Kotlin 源码里抠出某张表的列名。
///
/// 抓的是 `text("x")` / `int("x")` / `real("x")` / `bool("x")` 这种**位置参数**
/// 形式（`LibrarySchema.Column` 的四个构造助手，名字恒是第一个位置参数）。
Set<String> _kotlinColumns(String source, String table) {
  final start = source.indexOf('name = "$table",');
  expect(
    start,
    greaterThanOrEqualTo(0),
    reason: 'LibrarySchema.kt 里找不到表 $table',
  );

  // 表体到 `primaryKey = listOf(` 为止。主键那一行里没有列定义助手，不会误抓。
  final end = source.indexOf('primaryKey = listOf(', start);
  expect(
    end,
    greaterThan(start),
    reason: '表 $table 的定义里没有 `primaryKey = listOf(` —— 抠不出边界',
  );

  final body = _stripLineComments(source.substring(start, end));
  final names = RegExp(r'\b(?:text|int|real|bool)\("([a-z_0-9]+)"')
      .allMatches(body)
      .map((m) => m.group(1)!)
      .toSet();

  expect(
    names,
    isNotEmpty,
    reason: '表 $table 一列都没抓到 —— 列定义助手的写法变了？'
        '（这条守卫靠正则抠源码，写法一变就要跟着改）',
  );
  return names;
}

/// Kotlin 里声明的全部表：`Table(name = "…")` → 表名。
Map<String, Set<String>> _kotlinTables(String source) {
  final names = RegExp(r'Table\(\s*name = "([a-z_0-9]+)"')
      .allMatches(source)
      .map((m) => m.group(1)!)
      .toList();

  expect(
    names,
    isNotEmpty,
    reason: '一张表都没抓到 —— `Table(name = …)` 的写法变了？',
  );
  expect(
    names.toSet().length,
    names.length,
    reason: '有重名的表：$names',
  );
  return {for (final n in names) n: _kotlinColumns(source, n)};
}

/// 去掉 `//` 行注释。
///
/// ⛔ 必须去：`LibrarySchema.kt` 的注释里**大量出现反引号包着的列名**
///    （「`media_works.updated_at` ∪ …」这种），不去掉会被误抓成列定义。
///    这个文件里没有字符串字面量包含 `//`（没有 URL），所以按行切是安全的。
String _stripLineComments(String source) => source
    .split('\n')
    .map((line) {
      final i = line.indexOf('//');
      return i < 0 ? line : line.substring(0, i);
    })
    .join('\n');
