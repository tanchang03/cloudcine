import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/follow_dir.dart';
import 'package:cloudcine/domain/services/follow_plan.dart';
import 'package:flutter_test/flutter_test.dart';

/// [FollowPlan] 的纯决策判据。
///
/// ## 为什么这几条值得写
///
/// 这个类里每一步的错法都是**静默的**：
///
///   * 目录没去重 → 12 集发 12 次列目录请求（会被夸克限流，但不报错）；
///   * 失败目录也推进水位线 → 那批新集被永久划进「已读」，用户再也不会
///     被提醒；
///   * 一个目录覆盖多部作品却没全部回写 → `/电影/` 里同时更新的另外几部
///     永远收不到提醒，而检查日志上一切正常。
///
/// 三种都不会抛异常，只会在几周后表现成「这功能好像坏了」。所以判据必须
/// 在单测里被钉死。
void main() {
  FollowDir dir(String id, String path, List<String> works) => FollowDir(
        provider: DriveProvider.quark,
        dirId: id,
        dirPath: path,
        workKeys: works.toSet(),
      );

  group('去重与合并', () {
    test('同一个目录出现多次只列一次，且作品取并集', () {
      final plan = FollowPlan.of([
        dir('d1', '/剧集/黑亚当/', ['adam']),
        dir('d2', '/电影/', ['nolan']),
        // 12 集同目录：仓储层本该已去重，这里再喂一遍重复输入 ——
        // 计划本身必须是可信的。
        dir('d1', '/剧集/黑亚当/', ['adam']),
        dir('d1', '/剧集/黑亚当/', ['adam']),
      ]);

      expect(
        plan.requestCount,
        2,
        reason: '同一部剧的 12 集通常在一个目录里，不去重就是 12 次列目录请求',
      );
      expect(plan.dirs.map((d) => d.dirId).toList(), ['d1', 'd2'], reason: '顺序 = 首次出现顺序');
      // 目录键现在是 `provider:dirId`（见 FollowPlan.dirKey）—— 与
      // `MediaItem.id` 同构，便于库里直接用这个键对齐。
      expect(plan.dirsByWork['adam'], {'quark:d1'});
    });

    test('路径取首次出现的那个（重复输入的路径不一致时不抖动）', () {
      final plan = FollowPlan.of([
        dir('d1', '/剧集/黑亚当/', ['adam']),
        dir('d1', '/剧集/黑亚当', ['adam']),
      ]);
      expect(plan.dirs.single.dirPath, '/剧集/黑亚当/');
    });
  });

  group('回写范围（红线 5：按目录回写，不是按发起者）', () {
    test('一个目录覆盖多部作品时，全部推进', () {
      // `/电影/` 是平铺的：一个目录里几十部片子。
      final plan = FollowPlan.of([
        dir('movies', '/电影/', ['a', 'b', 'c']),
      ]);

      expect(
        plan.checkedWorks(const {}),
        {'a', 'b', 'c'},
        reason: '只回写「发起检查的那一部」的话，同一个目录里同时更新的另外几部'
            '永远收不到提醒 —— 而检查日志一切正常',
      );
    });

    test('目录失败时，它覆盖的作品都不推进；其它作品照常推进', () {
      final plan = FollowPlan.of([
        dir('movies', '/电影/', ['a', 'b']),
        dir('tv', '/剧集/黑亚当/', ['adam']),
      ]);

      expect(plan.checkedWorks({'quark:movies'}), {'adam'});
    });
  });

  group('失败目录不推进水位线（红线 6）', () {
    test('一部作品有多个目录、其中一个失败 → 整部不推进', () {
      final plan = FollowPlan.of([
        dir('d1', '/剧集/黑亚当/', ['adam']),
        dir('d2', '/剧集/黑亚当 S02/', ['adam']),
      ]);

      expect(
        plan.checkedWorks({'quark:d2'}),
        isEmpty,
        reason: '水位线是「这里已经看过了」的承诺。d2 没读到，那批新集可能正好'
            '在里面 —— 推进等于把它们永久划进「已读」，用户再也不会被提醒',
      );
      expect(plan.checkedWorks(const {}), {'adam'}, reason: '两个目录都成功才推进');
    });

    test('失败的目录与任何作品都无关时，不影响别人', () {
      final plan = FollowPlan.of([
        dir('movies', '/电影/', ['a']),
        dir('tv', '/剧集/黑亚当/', ['adam']),
      ]);
      expect(plan.checkedWorks({'quark:tv'}), {'a'});
    });
  });

  group('边界', () {
    test('一个目录都没有的作品不在结果里', () {
      // 在追的作品可能一条 `media_items` 都没有（或 dir_id 全是空串）。
      final plan = FollowPlan.of(const []);
      expect(
        plan.checkedWorks(const {}),
        isEmpty,
        reason: '我们什么都没检查，推进水位线等于凭空宣称「查过了」—— '
            '之后它永远不会再被检查',
      );
    });

    test('workKeys 为空集的目录照常要列（只是不推进任何作品）', () {
      final plan = FollowPlan.of([dir('d1', '/电影/', const [])]);
      expect(plan.requestCount, 1);
      expect(plan.checkedWorks(const {}), isEmpty);
    });

    test('toString 不炸且带上两个计数', () {
      final plan = FollowPlan.of([dir('d1', '/电影/', ['a'])]);
      expect(plan.toString(), contains('目录 1'));
      expect(plan.toString(), contains('作品 1'));
    });
  });
}
