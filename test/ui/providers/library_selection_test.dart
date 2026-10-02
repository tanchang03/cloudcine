import 'package:cloudcine/ui/providers/library_selection_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 媒体库的多选状态。
///
/// ## 为什么要给一个只有几个字段的 provider 写测试
///
/// 它守着两条**做错不报错、只表现为数据悄悄坏掉**的不变量：
///
///   1. 退出多选必须**同时**清空选中集合 —— 漏了的话用户下次点「选择」会
///      看到「刚进来就莫名其妙选着三部」，跟着点「合并到…」就是合错片子；
///   2. `==` 必须按**集合内容**比 —— `Set` 默认是引用相等，直接比会让
///      Riverpod 误判「没变」，勾了却不高亮。
///
/// 两条都不会让任何东西变红，只会让用户在某个下午合错一批片子。
void main() {
  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  LibrarySelectionController ctl(ProviderContainer c) =>
      c.read(librarySelectionProvider.notifier);

  test('默认是「不在多选模式、一部都没选」', () {
    final c = container();
    expect(c.read(librarySelectionProvider).active, isFalse);
    expect(c.read(librarySelectionProvider).keys, isEmpty);
  });

  test('进入多选：不带 key 时是空选择', () {
    final c = container();
    ctl(c).enter();

    expect(c.read(librarySelectionProvider).active, isTrue);
    expect(c.read(librarySelectionProvider).keys, isEmpty,
        reason: '页头那个「选择」按钮只是切模式，不该顺手替用户勾上一部。');
  });

  test('长按进入：连按的那一下一起生效', () {
    final c = container();
    ctl(c).enter('a');

    expect(c.read(librarySelectionProvider).contains('a'), isTrue,
        reason: '长按的意图是「我要选这部」。长按完还得再点一次才选上，'
            '等于那一次长按白做了。');
  });

  test('退出多选会**一并**清空选择（否则下次进来还选着旧的）', () {
    final c = container();
    ctl(c).enter('a');
    ctl(c).toggle('b');
    expect(c.read(librarySelectionProvider).count, 2);

    ctl(c).exit();

    expect(c.read(librarySelectionProvider).active, isFalse);
    expect(c.read(librarySelectionProvider).keys, isEmpty,
        reason: '留着旧选择的表现是「点开多选，屏幕上莫名勾着几部」，'
            '而那几部是上一次的老选择 —— 跟着点合并就会合错。');
  });

  test('toggle 是「再点一下取消」，不是只加不减', () {
    final c = container();
    ctl(c).enter('a');
    ctl(c).toggle('a');

    expect(c.read(librarySelectionProvider).contains('a'), isFalse);
  });

  test('全选是**追加**，且只追加当前列表里可见的', () {
    final c = container();
    ctl(c).enter('x');
    ctl(c).addAll(['a', 'b']);

    expect(c.read(librarySelectionProvider).keys, {'x', 'a', 'b'},
        reason: '全选替换掉已有选择的话，用户先手动勾几部再点全选就会丢掉'
            '那几部 —— 而他是特意去勾的。');
  });

  test('已经全选时再点全选 → 状态对象不变（不白重建一次海报墙）', () {
    final c = container();
    ctl(c).enter();
    ctl(c).addAll(['a', 'b']);
    final before = c.read(librarySelectionProvider);

    ctl(c).addAll(['a', 'b']);

    expect(identical(c.read(librarySelectionProvider), before), isTrue);
  });

  test('取消选择只清集合，**留在**多选模式里', () {
    final c = container();
    ctl(c).enter('a');
    ctl(c).clearKeys();

    expect(c.read(librarySelectionProvider).active, isTrue);
    expect(c.read(librarySelectionProvider).keys, isEmpty);
  });

  group('相等性（Riverpod 靠它决定要不要重建）', () {
    test('内容一样但不是一个 Set 对象 → 仍然相等', () {
      expect(
        const LibrarySelection(active: true, keys: {'a', 'b'}),
        LibrarySelection(active: true, keys: {'b', 'a'}),
        reason: '`Set` 默认是**引用**相等。直接比会漏掉「内容一样但不是同一个'
            '对象」的更新，Riverpod 会误判成「没变」—— 勾了却不高亮。',
      );
    });

    test('选中集合不同 → 不相等（否则勾选不生效）', () {
      expect(
        const LibrarySelection(active: true, keys: {'a'}),
        isNot(const LibrarySelection(active: true, keys: {'a', 'b'})),
      );
    });

    test('模式开关不同 → 不相等（否则整页不换）', () {
      expect(
        const LibrarySelection(active: false, keys: {'a'}),
        isNot(const LibrarySelection(active: true, keys: {'a'})),
      );
    });

    test('hashCode 与顺序无关', () {
      expect(
        const LibrarySelection(active: true, keys: {'a', 'b'}).hashCode,
        LibrarySelection(active: true, keys: {'b', 'a'}).hashCode,
      );
    });
  });
}
