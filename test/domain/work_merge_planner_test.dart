import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/work_merge_planner.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一部作品行。只填规划器真正看的那几列 —— 其余列与判断无关，
/// 填得越少，测试越能说明「哪些列是判据」。
MediaWork _w({
  required String key,
  String? onlineId,
  ScrapeSource source = ScrapeSource.online,
  MediaKind kind = MediaKind.movie,
  int itemCount = 0,
  DateTime? firstSeenAt,
  String? title,
  String? mergedInto,
}) =>
    MediaWork(
      key: key,
      provider: DriveProvider.quark,
      kind: kind,
      title: title ?? key,
      onlineId: onlineId,
      source: source,
      itemCount: itemCount,
      firstSeenAt: firstSeenAt,
      mergedInto: mergedInto,
      updatedAt: DateTime(2026, 1, 1),
    );

void main() {
  group('按 onlineId 归组', () {
    test('同一条目的两部作品 → 一组，源是「文件少的那一部」', () {
      final plans = WorkMergePlanner.plan([
        _w(key: 'a', onlineId: 'movie/843527', itemCount: 10),
        _w(key: 'b', onlineId: 'movie/843527', itemCount: 1),
      ]);

      expect(plans, hasLength(1));
      expect(plans.single.targetKey, 'a');
      expect(plans.single.sourceKeys, ['b']);
      expect(plans.single.onlineId, 'movie/843527');
    });

    test('目标取 itemCount 最大的那部 —— 海报/简介留的是它那份', () {
      final plans = WorkMergePlanner.plan([
        _w(key: 'a', onlineId: 'movie/1', itemCount: 3),
        _w(key: 'b', onlineId: 'movie/1', itemCount: 9),
        _w(key: 'c', onlineId: 'movie/1', itemCount: 5),
      ]);

      expect(plans.single.targetKey, 'b');
      expect(plans.single.sourceKeys, ['a', 'c']);
    });

    test('文件数并列时取**先入库**的那部（老住户优先）', () {
      final plans = WorkMergePlanner.plan([
        _w(
          key: 'new',
          onlineId: 'movie/1',
          itemCount: 2,
          firstSeenAt: DateTime(2026, 5, 1),
        ),
        _w(
          key: 'old',
          onlineId: 'movie/1',
          itemCount: 2,
          firstSeenAt: DateTime(2026, 1, 1),
        ),
      ]);

      expect(plans.single.targetKey, 'old');
    });

    test('没有入库时间的行**不能**靠「没记录」赢过有记录的', () {
      final plans = WorkMergePlanner.plan([
        _w(key: 'unknown', onlineId: 'movie/1', itemCount: 2),
        _w(
          key: 'known',
          onlineId: 'movie/1',
          itemCount: 2,
          firstSeenAt: DateTime(2026, 1, 1),
        ),
      ]);

      expect(plans.single.targetKey, 'known');
    });

    test('全部并列时按 key 升序 —— 两次运行必须选出同一个目标', () {
      // 这条不是「锦上添花的稳定性」：没有它，同一个库两次运行可能选出
      // 不同的目标，用户看到的是海报在两部片子之间来回跳。
      final a = _w(key: 'zzz', onlineId: 'movie/1', itemCount: 2);
      final b = _w(key: 'aaa', onlineId: 'movie/1', itemCount: 2);

      final forward = WorkMergePlanner.plan([a, b]);
      final backward = WorkMergePlanner.plan([b, a]);

      expect(forward.single.targetKey, 'aaa');
      expect(backward.single.targetKey, 'aaa');
      expect(forward.single.sourceKeys, backward.single.sourceKeys);
    });

    test('不同 onlineId 各成一组，按 id 升序返回', () {
      final plans = WorkMergePlanner.plan([
        _w(key: 'x1', onlineId: 'movie/2', itemCount: 1),
        _w(key: 'x2', onlineId: 'movie/2', itemCount: 2),
        _w(key: 'y1', onlineId: 'movie/1', itemCount: 1),
        _w(key: 'y2', onlineId: 'movie/1', itemCount: 2),
      ]);

      expect(plans.map((p) => p.onlineId), ['movie/1', 'movie/2']);
    });

    test('只有一部有那个 id → 不成组（没什么可合的）', () {
      final plans = WorkMergePlanner.plan([
        _w(key: 'a', onlineId: 'movie/1', itemCount: 3),
        _w(key: 'b', onlineId: 'movie/2', itemCount: 3),
      ]);

      expect(plans, isEmpty);
    });

    test('空库 → 空计划', () {
      expect(WorkMergePlanner.plan(const []), isEmpty);
    });
  });

  group('四条硬约束', () {
    test('本地解析出的两部（都没刮到）**绝不**自动合并', () {
      // 这正是 `182.格力空调` 事故的形态：本地片名相似度那套一旦参与
      // 自动合并，两部不相干的片子就会被揉进一个格子。
      final plans = WorkMergePlanner.plan([
        _w(key: '182', source: ScrapeSource.local, itemCount: 1),
        _w(key: '1821', source: ScrapeSource.local, itemCount: 1),
      ]);

      expect(plans, isEmpty);
    });

    test('`source == manual`（用户手写过）的行不参与', () {
      final plans = WorkMergePlanner.plan([
        _w(key: 'a', onlineId: 'movie/1', itemCount: 5),
        _w(
          key: 'b',
          onlineId: 'movie/1',
          source: ScrapeSource.manual,
          itemCount: 1,
        ),
      ]);

      expect(plans, isEmpty);
    });

    test('onlineId 为空 / 全是空白 → 不参与（空值不参与分组）', () {
      final plans = WorkMergePlanner.plan([
        _w(key: 'a', onlineId: null, itemCount: 5),
        _w(key: 'b', onlineId: '   ', itemCount: 1),
        _w(key: 'c', onlineId: '', itemCount: 1),
      ]);

      expect(plans, isEmpty);
    });

    test('同一个 id 但 kind 不同 → 不合并（宁可不合也别合错）', () {
      final plans = WorkMergePlanner.plan([
        _w(key: 'a', onlineId: 'douban/1', kind: MediaKind.movie),
        _w(key: 'b', onlineId: 'douban/1', kind: MediaKind.episode),
      ]);

      expect(plans, isEmpty);
    });

    test('已被折叠走的行不参与，也**不能当目标**', () {
      final plans = WorkMergePlanner.plan([
        // 它文件最多，但已经是别人的别名 —— 让它当目标会形成链。
        _w(key: 'folded', onlineId: 'movie/1', itemCount: 99, mergedInto: 'root'),
        _w(key: 'a', onlineId: 'movie/1', itemCount: 5),
        _w(key: 'b', onlineId: 'movie/1', itemCount: 1),
      ]);

      expect(plans, hasLength(1));
      expect(plans.single.targetKey, 'a');
      expect(plans.single.sourceKeys, ['b']);
    });

    test('同一目标下的两个别名不会互相触发第二次折叠', () {
      final plans = WorkMergePlanner.plan([
        _w(key: 'root', onlineId: 'movie/1', itemCount: 10),
        _w(key: 's1', onlineId: 'movie/1', itemCount: 2, mergedInto: 'root'),
        _w(key: 's2', onlineId: 'movie/1', itemCount: 1, mergedInto: 'root'),
      ]);

      expect(plans, isEmpty);
    });
  });

  group('planFor：只看一部', () {
    final works = [
      _w(key: 'a', onlineId: 'movie/1', itemCount: 10),
      _w(key: 'b', onlineId: 'movie/1', itemCount: 1),
      _w(key: 'c', onlineId: 'movie/2', itemCount: 4),
    ];

    test('目标是它 → 返回那个计划', () {
      expect(WorkMergePlanner.planFor('a', works)?.targetKey, 'a');
    });

    test('源是它 → 也返回那个计划（调用方才能提示「已并入《a》」）', () {
      final plan = WorkMergePlanner.planFor('b', works);
      expect(plan?.targetKey, 'a');
      expect(plan?.sourceKeys, contains('b'));
    });

    test('没有兄弟的作品 → null', () {
      expect(WorkMergePlanner.planFor('c', works), isNull);
    });

    test('库里没有的 key → null（不抛）', () {
      expect(WorkMergePlanner.planFor('nope', works), isNull);
    });
  });

  group('siblingOf：库里有没有同一条目的另一部', () {
    test('有 → 返回那一部（拿它的片名给用户提示）', () {
      final works = [
        _w(key: 'a', onlineId: 'movie/1', itemCount: 10, title: '流浪地球2'),
        _w(
          key: 'b',
          onlineId: 'movie/1',
          itemCount: 1,
          title: 'The Wandering Earth II',
        ),
      ];

      // 传「被折走的那一部」→ 兄弟是留下的那部。
      expect(WorkMergePlanner.siblingOf(works[1], works)?.title, '流浪地球2');
      // 传「留下的那一部」→ 兄弟是折进来的源。
      expect(
        WorkMergePlanner.siblingOf(works[0], works)?.title,
        'The Wandering Earth II',
      );
    });

    test('只有它自己 → null', () {
      final works = [_w(key: 'a', onlineId: 'movie/1')];
      expect(WorkMergePlanner.siblingOf(works.single, works), isNull);
    });

    test('onlineId 为空（都还没刮到）→ null', () {
      final works = [
        _w(key: 'a', source: ScrapeSource.local),
        _w(key: 'b', source: ScrapeSource.local),
      ];
      expect(
        WorkMergePlanner.siblingOf(works.first, works),
        isNull,
        reason: '空 onlineId 不参与分组 —— 「两行都没刮到」不等于「同一条目」。',
      );
    });

    test('kind 不同 → 不算兄弟', () {
      final works = [
        _w(key: 'a', onlineId: 'douban/1', kind: MediaKind.movie),
        _w(key: 'b', onlineId: 'douban/1', kind: MediaKind.episode),
      ];
      expect(
        WorkMergePlanner.siblingOf(works[0], works),
        isNull,
        reason: '正常不会撞上（TMDB 的 id 自带 tv/ movie/ 前缀），但真撞上时'
            '不合并比合错好 —— 这与 plan() 的硬约束 3 是同一条。',
      );
    });

    test('兄弟已经被折走（别名行）→ 不算', () {
      final works = [
        _w(key: 'a', onlineId: 'movie/1'),
        _w(key: 'b', onlineId: 'movie/1', mergedInto: 'a'),
      ];
      // 别名行自己不该被当成「有兄弟」——它本来就已经并进别处了。
      expect(WorkMergePlanner.siblingOf(works[1], works), isNull);
      // 目标也不该因为「有个别名指向自己」就以为还有第二个兄弟。
      expect(WorkMergePlanner.siblingOf(works[0], works), isNull);
    });

    test('source == manual 的兄弟不参与', () {
      final works = [
        _w(key: 'a', onlineId: 'movie/1'),
        _w(key: 'b', onlineId: 'movie/1', source: ScrapeSource.manual),
      ];
      expect(
        WorkMergePlanner.siblingOf(works[0], works),
        isNull,
        reason: '用户手写过片名 / 分类的行不许被算法动 —— 这是产品规则，'
            '不是实现细节。',
      );
    });
  });

  group('manualBlocker：手动合并前的三条拦截', () {
    /// 三条判据都会形成链（A←B←C），而链上任何一环被单独撤销都会把
    /// 后面的节点孤儿化。所以它们不是「防御性编程」，是必须挡住的事。
    String? block(String sourceKey, String targetKey, List<MediaWork> all) {
      final byKey = {for (final w in all) w.key: w};
      return WorkMergePlanner.manualBlocker(
        source: byKey[sourceKey]!,
        target: byKey[targetKey]!,
        all: all,
      );
    }

    test('两个独立作品 → null（可以合）', () {
      final all = [
        _w(key: 'a', title: '流浪地球2', source: ScrapeSource.local),
        _w(key: 'b', title: 'The Wandering Earth II'),
      ];
      expect(block('a', 'b', all), isNull);
      expect(block('b', 'a', all), isNull,
          reason: '人工合并不看 onlineId、不看 kind、也不比文件数 —— '
              '方向完全由人选。');
    });

    test('自己并自己 → 拦下', () {
      final all = [_w(key: 'a', title: '甲')];
      expect(block('a', 'a', all), contains('自己'));
    });

    test('源已经是别名行 → 拦下（再折一次就是链）', () {
      final all = [
        _w(key: 'a', title: '甲'),
        _w(key: 'b', title: '乙', mergedInto: 'a'),
        _w(key: 'c', title: '丙'),
      ];
      final reason = block('b', 'c', all);
      expect(reason, isNotNull);
      expect(reason, contains('乙'));
      expect(reason, contains('拆开'),
          reason: '拦下却不说怎么办，用户只会以为应用坏了 —— '
              '必须指到那个「拆开」按钮上。');
    });

    test('目标已经是别名行 → 拦下（把别名当目标同样成链）', () {
      final all = [
        _w(key: 'a', title: '甲'),
        _w(key: 'b', title: '乙', mergedInto: 'a'),
      ];
      expect(block('a', 'b', all), isNotNull);
    });

    test('源自己已经并入了别的作品 → 拦下，并说清有几部', () {
      // 真会撞上的场景：自动归一刚把两部合到《甲》上，用户又想把《甲》
      // 并进《丙》。不做「连坐迁移」—— 那样撤销就无法精确还原。
      final all = [
        _w(key: 'a', title: '甲'),
        _w(key: 'x', title: '子一', mergedInto: 'a'),
        _w(key: 'y', title: '子二', mergedInto: 'a'),
        _w(key: 'c', title: '丙'),
      ];
      final reason = block('a', 'c', all);
      expect(reason, isNotNull);
      expect(reason, contains('2 部'));
    });

    test('目标自己折进来了几部 → **不拦**（目标可以继续收）', () {
      final all = [
        _w(key: 'a', title: '甲'),
        _w(key: 'x', title: '子一', mergedInto: 'a'),
        _w(key: 'c', title: '丙'),
      ];
      expect(block('c', 'a', all), isNull,
          reason: '「目标已经有源」不构成链：只是又多一个兄弟。');
    });

    test('manual 来源的行照常能手动合并（那是自动那条路的禁忌）', () {
      final all = [
        _w(key: 'a', title: '手写片名', source: ScrapeSource.manual),
        _w(key: 'b', title: '在线刮到的'),
      ];
      expect(block('a', 'b', all), isNull,
          reason: '「manual 不参与」是**自动**归一的规则（不许算法动用户'
              '手写的东西）；人自己点的合并当然可以。');
    });
  });
}
