import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/empty_work_removal.dart';
import 'package:flutter_test/flutter_test.dart';

/// 空壳作品移除（`EmptyWorkRemovalPlan`）的文案。
///
/// ## 为什么测文案
///
/// 这个弹窗替代的是那句误导人的「这部作品下没有可播放的文件」。文案出错的
/// 方式是「看起来很正常，但少说了一句关键的」—— 用户按自己的猜想去行动，
/// 而界面不报错。所以要钉住四件事：
///
///   1. 点名是哪一部（空泛的「这部作品」会让人怀疑自己点错了卡片）；
///   2. 说出**两种**原因，而不是合成一句「可能已失效」；
///   3. 明说「只清索引、网盘文件还在、重新扫描能找回」；
///   4. 结果提示在「没有文件可删」时不提文件数（提了像漏删）。
void main() {
  final now = DateTime(2026, 10, 17);

  MediaWork work(String key, String title) => MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: title,
        updatedAt: now,
      );

  EmptyWorkRemovalPlan planFor(String title) =>
      EmptyWorkRemovalPlan(work: work('弑仙之战', title));

  test('标题点名用户刚点的那一部', () {
    final plan = planFor('仙逆剧场版：弑仙之战');

    expect(plan.headline, contains('仙逆剧场版：弑仙之战'));
    expect(plan.title, '仙逆剧场版：弑仙之战');
  });

  test('两种原因都写出来，不合成一句「可能已失效」', () {
    final plan = planFor('X');

    expect(plan.reasons, hasLength(2));
    expect(plan.reasons.first, contains('归到了别的作品名下'));
    expect(plan.reasons.last, contains('网盘上的文件已经不在'));
    expect(plan.reasons.join(), isNot(contains('可能已失效')));
  });

  test('明说只清索引、网盘文件还在、能重新扫描找回', () {
    final plan = planFor('X');

    expect(plan.keepFilesWarning, contains('只清掉这台设备上的索引'));
    expect(plan.keepFilesWarning, contains('网盘上的文件'));
    expect(plan.keepFilesWarning, contains('重新扫描'));
  });

  test('确认 / 取消按钮文案', () {
    final plan = planFor('X');

    expect(plan.confirmLabel, '从媒体库移除');
    // 没有副作用的那个放最前，文案不能写成「取消」这种让人以为啥也没发生的。
    expect(plan.dismissLabel, '暂不移除');
  });

  test('空壳作品：结果提示不提文件数', () {
    final plan = planFor('仙逆剧场版：弑仙之战');

    final msg = plan.doneMessage(removedFiles: 0);
    expect(msg, '已移除《仙逆剧场版：弑仙之战》，网盘文件未动。');
    // 「网盘文件未动」里本来就有「文件」两个字，所以这里钉的是**计数**：
    // 空壳行不带文件，报个数只会让人以为漏删了东西。
    expect(msg, isNot(contains('个文件')));
  });

  test('真删掉了文件时如实报数', () {
    final plan = planFor('仙逆');

    expect(plan.doneMessage(removedFiles: 1), '已移除《仙逆》（1 个文件），网盘文件未动。');
    expect(plan.doneMessage(removedFiles: 3), '已移除《仙逆》（3 个文件），网盘文件未动。');
  });
}
