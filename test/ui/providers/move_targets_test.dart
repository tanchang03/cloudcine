import 'dart:convert';

import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/settings_store.dart';
import 'package:cloudcine/domain/services/drive_move.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/drive_move_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「最近用过的移动目标目录」这份记录本身。
///
/// ## 为什么它值得一份单独的测试
///
/// 它是这个功能**存在的理由**（反复移动时不用重新点五层目录），而它出错的
/// 方式是**最难查的一种**：
///
///   1. **偶尔没记住**：只在冷启动后第一次出现，看起来像随机的；
///   2. **一份坏数据让整页打不开**：它是缓存不是偏好，读不懂只该退回
///      「没有最近记录」，绝不该把异常抛到界面上；
///   3. **写失败被当成移动失败**：一次**成功**的移动显示成失败，比
///      「这次没记住」坏得多。
///
/// 控制器那层已经验过「确认之后真的落库」，这里只测这份记录自己的
/// 生命周期：读取时序、上限、坏数据、读写失败。
class _SlowStore extends SettingsStore {
  _SlowStore(super.db, this.delay);

  final Duration delay;

  /// 让 `build()` 里的那次读慢下来，好把「读还没回来时用户就按了确认」
  /// 这个时序**稳定复现**出来 —— 否则它只在冷启动后第一次偶发。
  @override
  Future<String?> read(String key) async {
    await Future<void>.delayed(delay);
    return super.read(key);
  }
}

class _UnreadableStore extends SettingsStore {
  _UnreadableStore(super.db);

  @override
  Future<String?> read(String key) async => throw StateError('设置库读不了');
}

class _UnwritableStore extends SettingsStore {
  _UnwritableStore(super.db);

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('设置库写不进去');
}

void main() {
  MoveTarget t(String fid) => MoveTarget(fid: fid, name: fid, path: '/$fid');

  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() async => db.close());

  ProviderContainer withStore(SettingsStore store) {
    final c = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// 直接把一份原始字符串塞进库里，绕过 `remember` —— 这样才能造出
  /// 「上一版程序写的 / 手工改坏的」那种值。
  Future<void> seed(String raw) =>
      SettingsStore(db).write(SettingKeys.moveTargetRecents, raw);

  test('库里没有记录时是空列表，不是异常', () async {
    final c = withStore(SettingsStore(db));
    expect(await c.read(moveTargetsProvider.future), isEmpty);
  });

  test('build 还没读完就按了确认：随后完成的 build 不会把这次记录冲掉', () async {
    await seed(jsonEncode([t('old').toJson()]));

    final c = withStore(_SlowStore(db, const Duration(milliseconds: 50)));

    // ⚠️ 刻意**不先** `await c.read(moveTargetsProvider.future)`：
    // 那正是线上「冷启动后第一次移动」的时序 —— 对话框第一次 watch 这个
    // provider，`build()` 还在异步读设置库，而用户已经选好目录按了确认。
    final notifier = c.read(moveTargetsProvider.notifier);
    await notifier.remember(t('new'));

    expect(
      (await c.read(moveTargetsProvider.future)).map((e) => e.fid),
      ['new', 'old'],
      reason: '`remember` 里若直接读 `state.valueOrNull`，此刻它是 null '
          '（state 还是 AsyncLoading），于是先写 `[new]`、随后 `build()` '
          '完成又把 state 覆盖回它读到的那份旧列表 —— 表现为「刚用过的目录'
          '没进最近列表」，而且只在冷启动后第一次出现，看起来像随机的。',
    );
  });

  test('最多留 8 条，最新的在最前', () async {
    final c = withStore(SettingsStore(db));

    for (var i = 0; i < 12; i++) {
      await c.read(moveTargetsProvider.notifier).remember(t('d$i'));
    }

    final recents = await c.read(moveTargetsProvider.future);
    expect(recents.length, moveTargetRecentsLimit);
    expect(recents.first.fid, 'd11');
    expect(recents.last.fid, 'd4',
        reason: '这一列是「摊开在对话框里、一眼点中」的行，不是需要滚动查找'
            '的列表。再多会把「要移动的条目预览」挤出屏幕 —— 而那一块才是'
            '用户真正要核对的东西。');
  });

  test('同一个目录反复用只留一条，且被提到最前', () async {
    final c = withStore(SettingsStore(db));
    final notifier = c.read(moveTargetsProvider.notifier);

    await notifier.remember(t('a'));
    await notifier.remember(t('b'));
    await notifier.remember(t('a'));

    expect(
      (await c.read(moveTargetsProvider.future)).map((e) => e.fid),
      ['a', 'b'],
      reason: '按 fid 去重。堆出好几条同名记录的话，「最近用过」会变成一串'
          '看不出区别的重复项 —— 而它全靠「一眼认出来」才有用。',
    );
  });

  test('整份记录读不懂 → 退回空列表，不抛', () async {
    for (final raw in <String>[
      '不是 json',
      '{"fid":"a"}', // 是个对象，不是数组
      '[1,2,3]', // 数组里全是垃圾
    ]) {
      await seed(raw);
      final c = withStore(SettingsStore(db));
      expect(
        await c.read(moveTargetsProvider.future),
        isEmpty,
        reason: '「$raw」这种值只可能来自旧版本格式或手工改坏。它是一份'
            '**缓存**，读不懂的后果必须只是「这次没有最近记录」—— '
            '把异常抛出去，文件夹页会直接打不开，而用户丢掉的其实只是'
            '一个快捷入口。',
      );
    }
  });

  test('一条坏记录不连累后面几条好的', () async {
    await seed(jsonEncode([
      {'fid': '', 'path': '/空的 fid'},
      t('good').toJson(),
      '不是 map',
      {'path': '/没有 fid'},
    ]));

    final recents = await withStore(SettingsStore(db))
        .read(moveTargetsProvider.future);

    expect(recents.map((e) => e.fid), ['good'],
        reason: '逐条校验而不是整份信任。一条坏记录让整份记录作废的话，'
            '用户会突然少掉好几个明明还好的入口，而且看不出为什么。');
  });

  test('设置库读不了 → 当作「还没有最近记录」，不抛', () async {
    final c = withStore(_UnreadableStore(db));

    expect(await c.read(moveTargetsProvider.future), isEmpty);
  });

  test('设置库读不了时，remember 仍然把这次移动记在内存里', () async {
    final c = withStore(_UnreadableStore(db));

    await c.read(moveTargetsProvider.notifier).remember(t('a'));

    expect(
      (await c.read(moveTargetsProvider.future)).map((e) => e.fid),
      ['a'],
      reason: '读缓存失败不该让正在进行的这次移动也失败。调用 `remember` 的'
          '是一次**已经发出去**的移动 —— 让它抛，用户会看到「移动失败」，'
          '而文件其实已经动完了。',
    );
  });

  test('设置库写不进去 → 不抛，内存状态照样更新', () async {
    final c = withStore(_UnwritableStore(db));

    await c.read(moveTargetsProvider.notifier).remember(t('a'));

    expect(
      (await c.read(moveTargetsProvider.future)).map((e) => e.fid),
      ['a'],
      reason: '写失败只影响「重启之后还记不记得」，不影响这次移动，也不影响'
          '这次会话里再用一次。把它抛上去会让一次**成功的**移动显示成失败 —— '
          '那比「下次没记住」坏得多。',
    );
  });

  test('落库的值是能读回来的 JSON 数组（不是 Dart 的 toString）', () async {
    final c = withStore(SettingsStore(db));
    await c.read(moveTargetsProvider.notifier).remember(t('a'));

    final raw = await SettingsStore(db).read(SettingKeys.moveTargetRecents);
    expect(raw, isNotNull);
    final decoded = jsonDecode(raw!);
    expect(decoded, isA<List<Object?>>(),
        reason: '`MoveTarget` 有 `toString`，一不小心就会把它当成序列化。'
            '那样写进去的是一串调试文本，下次启动读回来是空的 —— '
            '而且不会报错。');
    expect((decoded as List).single, {'fid': 'a', 'name': 'a', 'path': '/a'});
  });
}
