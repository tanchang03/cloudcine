import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 恢复备份的**接线守卫**（静态读源码，不跑 Flutter）。
///
/// ## 为什么值得一个文件
///
/// 这条链上有两处「写错了照样编译」的接线，而它们的失败表现都是**静默或
/// 半静默的**，排查代价极高（2026-10-07 连踩两轮）：
///
///   1. `main()` 必须注入 [databaseHandleProvider]，**不能**注入
///      `databaseProvider`。后者是 `ref.watch(databaseHandleProvider)`
///      转发出来的；一旦把它**本身** `overrideWithValue` 掉，那层转发就被
///      整个盖住 —— 恢复时换了实例，可**没有任何下游跟着动**，于是
///      「库文件换掉了、连接还是死的」，表现是恢复报
///      `Can't re-open a database after closing it`（或者更坏：不报错但没生效）。
///   2. `app_providers` 里 `databaseProvider` 必须真的 `watch` 那个持有者，
///      否则 ①②之间那根线断在半路。
///
/// ⛔ 为什么只能靠读源码：单测一律自己 `overrideWith(databaseHandleProvider)`，
///    所以它们**测不到 `main.dart` 那一行**；而 `main()` 又没法在测试里跑
///    （它要真的 `runApp`）。
///
/// ⛔ 断言前必须先把注释剔掉：两个文件里的文档注释**都逐字引用了错误的写法**
///    （正是为了解释它为什么错）。不剔的话，一条「把正确写法注释掉」的坏版本
///    也能通过。
void main() {
  /// 行级过滤注释。
  ///
  /// ⛔ 刻意**不用正则剥块注释**：源码里有 `https://` 这样的字符串，
  ///    朴素实现会把 `//` 当注释起点，把整行吃坏（Android 端
  ///    `LibraryActivityWiringTest` 踩过同一个坑）。
  String codeOnly(String source) => source
      .split('\n')
      .where((line) {
        final t = line.trimLeft();
        return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
      })
      .join('\n');

  String read(String path) => codeOnly(File(path).readAsStringSync());

  test('main() 注入的是持有者，不是 databaseProvider 本身', () {
    final main = read('lib/main.dart');

    expect(
      main,
      contains('databaseHandleProvider.overrideWith('),
      reason: '`main()` 必须注入持有者 —— 恢复备份靠 `DatabaseHandle.swap` '
          '换掉整个 `AppDatabase`，而只有持有者是可换的。',
    );
    expect(
      main,
      isNot(contains('databaseProvider.overrideWithValue(')),
      reason: '⛔ 直接 `overrideWithValue(db)` 会把 `databaseProvider` '
          '`ref.watch(databaseHandleProvider)` 那层转发整个盖掉 —— '
          '换实例之后没有任何下游跟着动，恢复等于没做。'
          '（24 处**单测**里这样写是对的：它们本来就要塞一个假库进去。）',
    );
  });

  test('databaseProvider 转发给持有者（那根线不能断在半路）', () {
    expect(
      read('lib/ui/providers/app_providers.dart'),
      contains('ref.watch(databaseHandleProvider)'),
      reason: '`databaseProvider` 必须是 `ref.watch(databaseHandleProvider)` '
          '转发出来的：`mediaRepositoryProvider` / `settingsStoreProvider` '
          '（以及 watch 它们的 `settingsProvider`）都挂在它下面，'
          '它不跟着换，恢复备份就要重启应用才生效。',
    );
  });
}
