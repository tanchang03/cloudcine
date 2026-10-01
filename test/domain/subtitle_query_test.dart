import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/services/subtitle_query.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「拿什么去字幕站搜」这件事看着简单，但**搜错了不会报错** —— 只会返回
/// 一堆对不上时间轴的字幕，或者一条都没有。
///
/// 最容易踩的是拿 `displayTitle` 去搜：它的形状是
/// `指环王：力量之戒 S01E01`，带着集号。字幕站按关键词匹配，多一个 `S01E01`
/// 会让结果从几十条掉到个位数甚至零条。所以下面每一条都在钉住「哪一部分
/// 该进 query、哪一部分该进独立参数」。
void main() {
  final now = DateTime(2026, 10, 1);

  MediaItem item({
    String name = 'The.Lord.of.the.Rings.S01E01.2022.mkv',
    String? title,
    int? year,
    int? season,
    int? episode,
    MediaKind kind = MediaKind.unknown,
  }) =>
      MediaItem(
        provider: DriveProvider.quark,
        fileId: 'f1',
        name: name,
        dirId: 'd1',
        dirPath: '/电影/',
        groupKey: 'g1',
        kind: kind,
        title: title,
        year: year,
        season: season,
        episode: episode,
        firstSeenAt: now,
        updatedAt: now,
      );

  group('没有库记录', () {
    test('退回兜底片名', () {
      final search = SubtitleQuery.build(null, fallback: '银翼杀手');

      expect(search.query, '银翼杀手');
      // 没有库记录就没有季集号可给 —— 不能瞎猜。
      expect(search.season, isNull);
      expect(search.episode, isNull);
      expect(search.year, isNull);
      expect(search.type, isNull);
    });

    test('兜底片名两端空白要去掉 —— 带空格的 query 会搜不到', () {
      expect(SubtitleQuery.build(null, fallback: '  银翼杀手  ').query, '银翼杀手');
    });

    test('什么都没有时是「空搜索」，调用方据此不发请求', () {
      expect(SubtitleQuery.build(null).isEmpty, isTrue);
      expect(SubtitleQuery.build(null, fallback: '   ').isEmpty, isTrue);
    });
  });

  group('电影', () {
    test('片名进 query、年份进 year —— 不能把年份拼进片名', () {
      final search = SubtitleQuery.build(
        item(
          name: '银翼杀手2049.2017.2160p.mkv',
          title: '银翼杀手2049',
          year: 2017,
          kind: MediaKind.movie,
        ),
      );

      expect(search.query, '银翼杀手2049');
      expect(search.year, 2017);
      expect(search.type, isNull, reason: '没把握是电影还是剧集时不加类型过滤');
      expect(search.season, isNull);
      expect(search.episode, isNull);
    });

    test('没有片名时退回文件名（去扩展名）', () {
      final search = SubtitleQuery.build(item(name: 'Blade.Runner.2049.2017.mkv'));

      expect(search.query, 'Blade.Runner.2049.2017');
    });
  });

  group('剧集', () {
    test('⚠️ query 里不能出现集号 —— 这是这个文件存在的理由', () {
      final search = SubtitleQuery.build(
        item(
          title: '指环王：力量之戒',
          year: 2022,
          season: 1,
          episode: 1,
          kind: MediaKind.episode,
        ),
      );

      expect(search.query, '指环王：力量之戒');
      expect(
        search.query,
        isNot(contains('S01')),
        reason: '带着 S01E01 去搜，结果会从几十条掉到零条，而且不报错',
      );
      expect(search.season, 1);
      expect(search.episode, 1);
      expect(search.type, 'episode');
    });

    test('剧集**不按年份过滤** —— 拿首播年去卡第 3 季会一条都搜不到', () {
      final search = SubtitleQuery.build(
        item(title: '某剧', year: 2015, season: 3, episode: 7, kind: MediaKind.episode),
      );

      expect(
        search.year,
        isNull,
        reason: '一部剧跨好几年，而库里的 year 是首播年。用它当硬过滤会把'
            '后面的季全部排除掉',
      );
      expect(search.season, 3);
      expect(search.episode, 7);
    });

    test('认成剧集但没有集号时按「不确定」处理，不加 type', () {
      final search = SubtitleQuery.build(
        item(title: '某剧', kind: MediaKind.episode),
      );

      expect(search.type, isNull);
      expect(search.season, isNull);
      expect(search.episode, isNull);
    });
  });

  group('toString', () {
    test('只出条件，不出任何凭证（本来也没有）', () {
      final text = SubtitleQuery.build(
        item(title: '某剧', season: 1, episode: 2, kind: MediaKind.episode),
      ).toString();

      expect(text, contains('某剧'));
      expect(text, contains('season=1'));
      expect(text, contains('episode=2'));
    });
  });
}
