import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/library_batch_delete.dart';
import 'package:flutter_test/flutter_test.dart';

/// 批量移除的文案值对象。
///
/// ## 为什么测文案
///
/// 这个弹窗是「移除」前的唯一一道闸。它上面任何一句话缺失，用户的后果
/// 分两种：该说的没说（以为网盘文件被删了，白吓一场 / 以为没代价，按下去
/// 才发现续播进度没了）。两种都是「看着正常、少说一句」—— 靠肉眼看界面
/// 发现不了，所以钉在这里。
void main() {
  final now = DateTime(2026, 10, 17);

  MediaWork work(String key, String title, {String? mergedInto}) => MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: title,
        mergedInto: mergedInto,
        updatedAt: now,
      );

  test('标题与按钮都带数量，且不重复', () {
    final plan = LibraryBatchDeletePlan(
      works: [work('a', '剧A'), work('b', '剧B')],
    );

    expect(plan.count, 2);
    expect(plan.title, '要从媒体库移除这 2 部吗？');
    expect(plan.confirmLabel, '移除 2 部');
  });

  test('「网盘文件保留」必须写在最前 —— 它是这个按钮唯一的含义', () {
    final plan = LibraryBatchDeletePlan(works: [work('a', '剧A')]);

    expect(plan.keepFilesWarning, contains('网盘上的文件原样保留'));
    expect(plan.keepFilesWarning, contains('重新扫描'));
  });

  test('本地数据会跟着走这件事也要说', () {
    final plan = LibraryBatchDeletePlan(works: [work('a', '剧A')]);

    expect(plan.localDataWarning, contains('续播'));
    expect(plan.localDataWarning, contains('网盘文件本身不受影响'));
  });

  test('摊开名字；超过上限折成「等共 N 部」', () {
    final plan = LibraryBatchDeletePlan(
      works: [for (var i = 0; i < 12; i++) work('k$i', '剧$i')],
    );

    final line = plan.previewLine();
    expect(line, contains('《剧0》'));
    expect(line, contains('《剧7》'));
    expect(line, isNot(contains('《剧8》')));
    expect(line, endsWith('等共 12 部'));
  });

  test('勾选里有别名行时多一句警告；没有时是 null', () {
    final plain = LibraryBatchDeletePlan(works: [work('a', '剧A')]);
    expect(plain.mergedWarning, isNull);

    final merged = LibraryBatchDeletePlan(
      works: [work('a', '剧A', mergedInto: 'target'), work('t', '大目标')],
    );
    // 只有「别名行」那一部数得出来（有人折进「大目标」要反查全库才知道）。
    expect(merged.mergedWarning, contains('1 部'));
  });

  test('空计划不乱说话', () {
    const plan = LibraryBatchDeletePlan(works: []);

    expect(plan.isEmpty, isTrue);
    expect(plan.previewLine(), '');
  });

  test('结果提示区分「部」与「文件行」两个数', () {
    final plan = LibraryBatchDeletePlan(
      works: [work('a', '剧A'), work('b', '剧B')],
    );

    expect(
      plan.doneMessage(removedItems: 37),
      '已移除 2 部作品（37 个文件），网盘文件未动。',
    );
  });
}
