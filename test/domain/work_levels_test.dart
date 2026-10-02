import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/services/work_levels.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「作品 → 季 → 部 → 集」的层级派生。
///
/// ## 这些用例挡的是什么
///
/// 层级画多了是噪音（一部电影上多出一个「第一季」按钮），画少了是功能缺失
/// （60 集平铺成一条长列表）。**两种都不会报错** —— 只能靠断言挡住。
/// 所以每条用例的 `reason` 写的都是「错了用户会看到什么」。
void main() {
  final now = DateTime(2026, 10, 2);

  MediaItem item({
    required String id,
    int? season,
    int? episode,
    int? part,
    String? partLabel,
    bool extra = false,
  }) =>
      MediaItem(
        provider: DriveProvider.quark,
        fileId: id,
        name: '$id.mkv',
        dirId: 'd1',
        dirPath: '/剧/Show/',
        groupKey: 'show',
        kind: MediaKind.episode,
        title: 'Show',
        season: season,
        episode: episode,
        part: part,
        partLabel: partLabel,
        isSampleOrExtra: extra,
        firstSeenAt: now,
        updatedAt: now,
      );

  test('电影：一条、无季无部 → 一层都不画', () {
    final lv = WorkLevels.of([item(id: 'f1')]);

    expect(lv.hasSeasonLevel, isFalse, reason: '电影上出现「第一季」按钮就是噪音');
    expect(lv.partsOf('s:0'), isEmpty);
  });

  test('只有季 → 有季层、无部层', () {
    final lv = WorkLevels.of([
      item(id: 'a', season: 1, episode: 1),
      item(id: 'b', season: 2, episode: 1),
    ]);

    expect(lv.hasSeasonLevel, isTrue);
    expect(lv.seasons.map((g) => g.label), ['第 1 季', '第 2 季']);
    // 一季里所有集都没标部 → 部层不出现（不是出现一个「未标部」孤格）。
    expect(lv.partsOf('s:1'), isEmpty);
    expect(lv.partsOf('s:2'), isEmpty);
  });

  test('只有部（没季号）→ 无季层、有部层', () {
    final lv = WorkLevels.of([
      item(id: 'a', part: 1, episode: 1),
      item(id: 'b', part: 2, episode: 1),
    ]);

    expect(lv.hasSeasonLevel, isFalse, reason: '只有一季桶时不该画季选择器');
    expect(lv.partsOf('s:0').map((g) => g.label), ['第 1 部', '第 2 部']);
  });

  test('季 + 部（进击的巨人）：季在外、部在内，且只有那一季有部', () {
    final lv = WorkLevels.of([
      item(id: 's1', season: 1, episode: 1),
      item(id: 's3p1', season: 3, part: 1, episode: 1),
      item(id: 's3p2', season: 3, part: 2, episode: 1),
    ]);

    expect(lv.hasSeasonLevel, isTrue);
    expect(lv.partsOf('s:1'), isEmpty, reason: '第一季没分部，点进去不该多一行空选择器');
    expect(lv.partsOf('s:3').map((g) => g.label), ['第 1 部', '第 2 部']);
  });

  test('特别篇排到所有编号部之后', () {
    final lv = WorkLevels.of([
      item(id: 'a', season: 1, part: 1, episode: 1),
      item(id: 'sp', season: 1, partLabel: '特别篇', episode: 1),
      item(id: 'b', season: 1, part: 2, episode: 1),
    ]);

    expect(
      lv.partsOf('s:1').map((g) => g.label),
      ['第 1 部', '第 2 部', '特别篇'],
      reason: '特别篇排在中间会让「第 3 部」永远排在它后面',
    );
  });

  test('只有特别篇、且没季号 → 那一桶叫「特别篇」而不是「未标季」', () {
    final lv = WorkLevels.of([
      item(id: 'sp1', partLabel: '特别篇', episode: 1),
      item(id: 'sp2', partLabel: '特别篇', episode: 2),
    ]);

    expect(lv.seasons.single.label, '特别篇');
    expect(lv.partsOf('s:0').length, 1, reason: '整桶同一部 → 只有一个选项，不该再画部层');
  });

  test('count 只算正片，花絮不计入角标', () {
    final lv = WorkLevels.of([
      item(id: 'a', season: 1, episode: 1),
      item(id: 'b', season: 1, episode: 2),
      item(id: 'x', season: 1, episode: 3, extra: true),
    ]);

    expect(lv.seasons.single.count, 2, reason: '角标数字要和「文件」那一节的计数一致');
    expect(lv.seasons.single.items.length, 3, reason: '花絮仍在这一格里，只是不计入数字');
  });

  test('keyOf 把 PlayTarget 选中的那一集定位到格', () {
    final items = [
      item(id: 'a', season: 1, episode: 1),
      item(id: 'b', season: 2, episode: 1),
    ];
    final lv = WorkLevels.of(items);

    // 详情页用它把「默认高亮的层」对齐到「点播放会播的那一集」。
    expect(WorkLevels.keyOf(lv.seasons, items[1]), 's:2');
    expect(WorkLevels.keyOf(lv.seasons, null), isNull);
  });

  test('itemsIn 按 (季, 部) 取条目', () {
    final items = [
      item(id: 'a', season: 1, part: 1, episode: 1),
      item(id: 'b', season: 1, part: 2, episode: 1),
    ];
    final lv = WorkLevels.of(items);

    expect(lv.itemsIn(seasonKey: 's:1', partKey: 'p:2').single.fileId, 'b');
    expect(lv.itemsIn(seasonKey: 's:1').length, 2);
    expect(lv.itemsIn(seasonKey: 's:9'), isEmpty);
    expect(lv.itemsIn(), isEmpty, reason: '没给季键时不猜一个季');
  });

  test('未标季与具名季混在一起 → 未标季排最前（与 itemsForWork 的 ?? 0 同源）', () {
    final lv = WorkLevels.of([
      item(id: 'a', season: 2, episode: 1),
      item(id: 'b', episode: 1),
    ]);

    expect(lv.seasons.map((g) => g.label), ['未标季', '第 2 季']);
  });

  test('空列表 → 空层级', () {
    final lv = WorkLevels.of(const []);

    expect(lv.seasons, isEmpty);
    expect(lv.hasSeasonLevel, isFalse);
  });
}
