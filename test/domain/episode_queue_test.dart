import 'package:cloudcine/domain/services/episode_queue.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「播完自动下一集」的选条规则。
///
/// 这几条对应的都是**用户立刻能看见**的错：
///   - 跳进预告片 → 每集播完都自动放 30 秒花絮；
///   - 找不到当前项就从头 → 「看到第 8 集，播完跳回第 1 集」；
///   - 循环播放 → 整夜重播（流量、屏幕、电费）。
void main() {
  /// 一个够用的替身：`(id, isExtra)`。
  final entries = <(String, bool)>[
    ('ep1', false),
    ('ep2', false),
    ('ep3', false),
    ('sample', true),
    ('ep4', false),
  ];

  String idOf((String, bool) e) => e.$1;
  bool isExtra((String, bool) e) => e.$2;

  group('nextAfter', () {
    test('正常往后走一条', () {
      expect(
        EpisodeQueue.nextAfter(
          entries: entries,
          idOf: idOf,
          currentId: 'ep1',
          isExtra: isExtra,
        )?.$1,
        'ep2',
      );
    });

    test('跳过花絮 / 预告，而不是撞上就停', () {
      // 网盘上的剧集目录里经常混着 `S01E01.预告.mp4`，而且顺序不固定。
      // 只跳一格的话，第 3 集播完会开始播一个 30 秒的预告片。
      expect(
        EpisodeQueue.nextAfter(
          entries: entries,
          idOf: idOf,
          currentId: 'ep3',
          isExtra: isExtra,
        )?.$1,
        'ep4',
      );
    });

    test('最后一集 → null（不循环）', () {
      expect(
        EpisodeQueue.nextAfter(
          entries: entries,
          idOf: idOf,
          currentId: 'ep4',
          isExtra: isExtra,
        ),
        isNull,
      );
    });

    test('后面只剩花絮 → null，不去播花絮', () {
      final tail = <(String, bool)>[
        ('ep1', false),
        ('trailer', true),
      ];
      expect(
        EpisodeQueue.nextAfter(
          entries: tail,
          idOf: idOf,
          currentId: 'ep1',
          isExtra: isExtra,
        ),
        isNull,
      );
    });

    test('当前项不在列表里 → null，绝不从头开始', () {
      // 找不到说明状态已经不对（列表是别的一部剧的、或者库里这条被删了）。
      // 此时唯一安全的动作是不动 —— 猜错就是「播完跳回第 1 集」。
      expect(
        EpisodeQueue.nextAfter(
          entries: entries,
          idOf: idOf,
          currentId: '不存在的条目',
          isExtra: isExtra,
        ),
        isNull,
      );
    });

    test('空列表 / 空 id → null', () {
      expect(
        EpisodeQueue.nextAfter<(String, bool)>(
          entries: const [],
          idOf: idOf,
          currentId: 'ep1',
        ),
        isNull,
      );
      expect(
        EpisodeQueue.nextAfter(
          entries: entries,
          idOf: idOf,
          currentId: '',
        ),
        isNull,
      );
    });

    test('不传 isExtra 时一律不排除（单集电影 / 自检视频那条路）', () {
      final only = <(String, bool)>[('a', false), ('b', true)];
      expect(
        EpisodeQueue.nextAfter(entries: only, idOf: idOf, currentId: 'a')?.$1,
        'b',
      );
    });
  });

  group('indexOf', () {
    test('与 nextAfter 同一套匹配口径', () {
      // 两处口径不一致会出现「面板高亮在第 5 集、自动连播却从第 6 集开始」。
      expect(EpisodeQueue.indexOf(entries, idOf, 'ep3'), 2);
      expect(EpisodeQueue.indexOf(entries, idOf, '不存在的条目'), -1);
      expect(EpisodeQueue.indexOf(entries, idOf, ''), -1);
    });
  });
}
