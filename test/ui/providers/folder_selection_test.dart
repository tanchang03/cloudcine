import 'package:cloudcine/ui/providers/folder_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 目录视图的多选状态。
///
/// ## 为什么要给一个只有几个字段的 provider 写测试
///
/// 它守着两条**做错不报错、只表现为用户丢掉网盘文件**的不变量：
///
///   1. 退出多选必须**同时**清空选中集合 —— 漏了的话用户下次点「多选」会
///      看到「刚进来就莫名其妙勾着五项」，跟着按「删除 5 项」删掉的是
///      上一次的那五个；
///   2. `==` 必须按**集合内容**比 —— `Set` 默认是引用相等，直接比会让
///      Riverpod 误判「没变」，表现是勾了但复选框不高亮，而用户会以为
///      自己没点上，于是再点一次（= 取消勾选）。
void main() {
  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  FolderSelectionController ctl(ProviderContainer c) =>
      c.read(folderSelectionProvider.notifier);

  test('默认是「不在多选模式、一项没选」', () {
    final c = container();
    expect(c.read(folderSelectionProvider).active, isFalse);
    expect(c.read(folderSelectionProvider).ids, isEmpty);
  });

  test('进入多选：不带 id 时是空选择', () {
    final c = container();
    ctl(c).enter();

    expect(c.read(folderSelectionProvider).active, isTrue);
    expect(c.read(folderSelectionProvider).ids, isEmpty,
        reason: '工具条上那个「多选」只是切模式，不该顺手替用户勾上一条。');
  });

  test('长按进入：连按的那一下一起生效', () {
    final c = container();
    ctl(c).enter('a');

    expect(c.read(folderSelectionProvider).contains('a'), isTrue,
        reason: '用户长按的意图是「我要选这个（以及别的）」。长按完还得再点'
            '一次才能选上，等于那一次长按白做了。');
  });

  test('toggle 是「再点一下取消」，不是只加不减', () {
    final c = container();
    ctl(c).enter();
    ctl(c).toggle('a');
    expect(c.read(folderSelectionProvider).contains('a'), isTrue);

    ctl(c).toggle('a');
    expect(c.read(folderSelectionProvider).contains('a'), isFalse);
  });

  test('退出多选会**一并**清空选择（否则下次进来还勾着旧的）', () {
    final c = container();
    ctl(c).enter();
    ctl(c).toggle('a');
    ctl(c).toggle('b');

    ctl(c).exit();
    expect(c.read(folderSelectionProvider).active, isFalse);
    expect(c.read(folderSelectionProvider).ids, isEmpty,
        reason: '不清的话，用户下次点「多选」看到「已选 2 项」，按下删除 —— '
            '删掉的是上一次勾的那两个文件，而他以为自己在挑新的。');
  });

  test('全选是**追加**，不丢掉已经手勾的', () {
    final c = container();
    ctl(c).enter('x');
    ctl(c).addAll(['a', 'b']);

    expect(c.read(folderSelectionProvider).ids, {'x', 'a', 'b'});
  });

  test('已经全选时再点全选 → 状态对象不变（不白重建一次列表）', () {
    final c = container();
    ctl(c).enter();
    ctl(c).addAll(['a', 'b']);

    final before = c.read(folderSelectionProvider);
    ctl(c).addAll(['a', 'b']);
    expect(identical(c.read(folderSelectionProvider), before), isTrue);
  });

  test('clearIds 只清选择，**留在**多选模式里', () {
    final c = container();
    ctl(c).enter();
    ctl(c).toggle('a');

    ctl(c).clearIds();
    expect(c.read(folderSelectionProvider).ids, isEmpty);
    expect(c.read(folderSelectionProvider).active, isTrue,
        reason: '这是「切换目录」与「删完一批」之后的状态：用户往往还要接着'
            '挑下一批，每进一层都要重新点一次「多选」是多余的摩擦。');
  });

  group('相等性（Riverpod 靠它决定要不要重建）', () {
    test('内容一样但不是一个 Set 对象 → 仍然相等', () {
      expect(
        const FolderSelection(active: true, ids: {'a', 'b'}),
        const FolderSelection(active: true, ids: {'a', 'b'}),
      );
    });

    test('选中集合不同 → 不相等（否则勾选不高亮）', () {
      expect(
        const FolderSelection(active: true, ids: {'a'}),
        isNot(const FolderSelection(active: true, ids: {'a', 'b'})),
      );
    });

    test('模式开关不同 → 不相等（否则整页不换）', () {
      expect(
        const FolderSelection(active: true, ids: {'a'}),
        isNot(const FolderSelection(active: false, ids: {'a'})),
      );
    });

    test('hashCode 与顺序无关', () {
      expect(
        const FolderSelection(active: true, ids: {'a', 'b'}).hashCode,
        const FolderSelection(active: true, ids: {'b', 'a'}).hashCode,
      );
    });
  });
}
