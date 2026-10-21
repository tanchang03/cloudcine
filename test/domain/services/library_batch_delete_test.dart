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

  // -------------------------------------------------------------------
  // 勾了「同时删除网盘文件」之后
  // -------------------------------------------------------------------
  //
  // 这一支的每一句话都在描述一件**不可逆**的事。写错的方式全是「看起来
  // 很正常，但少说了一句」—— 所以逐句钉住。

  LibraryBatchDeletePlan withDrive({int files = 24, int undeletable = 0}) =>
      LibraryBatchDeletePlan(
        works: [work('a', '剧A')],
        driveFileCount: files,
        undeletableFileCount: undeletable,
      ).withDriveDeletion(true);

  test('勾了之后标题与按钮都不再写「移除」', () {
    final plan = withDrive();

    expect(plan.alsoDeleteFromDrive, isTrue);
    expect(plan.title, '要从媒体库和网盘删除这 1 部吗？');
    expect(plan.confirmLabel, '删除 1 部（含网盘文件）');
  });

  test('勾了之后不许再出现「网盘文件本身不受影响」', () {
    final plan = withDrive();

    expect(plan.localDataWarning, isNot(contains('网盘文件本身不受影响')));
    expect(plan.localDataWarning, contains('续播'));
  });

  test('「一并删」那段必须同时说清数量、不可逆、救不回来', () {
    final plan = withDrive(files: 24);

    expect(plan.driveDeleteWarning, contains('24 个文件'));
    expect(plan.driveDeleteWarning, contains('不可撤销'));
    expect(plan.driveDeleteWarning, contains('恢复'));
  });

  test('名下没有可删文件时不给这个选项（勾上也不会生效）', () {
    const none = LibraryBatchDeletePlan(works: []);
    expect(none.canDeleteFromDrive, isFalse);

    final plan = LibraryBatchDeletePlan(
      works: [work('a', '剧A')],
    ).withDriveDeletion(true);
    expect(plan.alsoDeleteFromDrive, isFalse,
        reason: '什么都不会做的开关停在「已勾上」，用户会以为网盘那侧也清了');
  });

  test('有文件落在只读网盘上时单独说一句', () {
    expect(withDrive(undeletable: 0).undeletableWarning, isNull);

    final plan = withDrive(files: 24, undeletable: 2);
    expect(plan.undeletableWarning, contains('2 个文件'));
    expect(plan.undeletableWarning, contains('不支持删除'));
  });

  test('结果提示把网盘的成功与失败两个数都写出来', () {
    final plan = withDrive(files: 24);

    expect(
      plan.doneMessage(
        removedItems: 24,
        drive: const DriveRemovalSummary(deleted: 24, failed: 0),
      ),
      '已移除 1 部作品（24 个文件），网盘上 24 个文件已删除。',
    );

    final partial = plan.doneMessage(
      removedItems: 24,
      drive: const DriveRemovalSummary(deleted: 22, failed: 2),
    );
    expect(partial, contains('22 个成功'));
    expect(partial, contains('2 个失败'));

    final none = plan.doneMessage(
      removedItems: 24,
      drive: const DriveRemovalSummary(
        deleted: 0,
        failed: 24,
        fatalError: '登录已失效，剩下的没删',
      ),
    );
    expect(none, contains('一个都没删掉'));
    expect(none, contains('重新扫描'),
        reason: '要告诉用户这些文件下次扫描还会回来，否则他会以为界面坏了');
  });
  group('RemovalProgress：进度那一行字', () {
    test('删网盘时说清在删什么、删到第几个', () {
      const p = RemovalProgress(phase: RemovalPhase.drive, done: 120, total: 300);
      expect(p.label, '正在删除网盘文件 120/300…');
      expect(p.fraction, 0.4);
    });

    test('还没数出总数时走不确定态，但不说「0/0」', () {
      const p = RemovalProgress.starting;
      expect(p.fraction, isNull, reason: 'null 让进度条画不确定态，0/0 会画成空条');
      expect(p.label, '正在删除网盘文件…');
      expect(p.label, isNot(contains('0/0')),
          reason: '「0/0」读起来像一个算错了的数字');
    });

    test('清索引那一步单独一句话 —— 否则满格后突然消失像卡住', () {
      const p = RemovalProgress(phase: RemovalPhase.library);
      expect(p.label, '正在清理媒体库…');
      expect(p.label, isNot(contains('网盘')),
          reason: '网盘已经删完了，还提它会让用户以为没结束');
    });

    test('进度不会溢出到 1.0 以上', () {
      const p = RemovalProgress(phase: RemovalPhase.drive, done: 130, total: 120);
      expect(p.fraction, 1.0);
    });
  });
}
