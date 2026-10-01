import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/video_formats.dart';
import 'package:flutter_test/flutter_test.dart';

/// 刮削的第一步、也是**唯一离线可用的那一步**。
///
/// 这些用例全部是真实发布组命名习惯的样本。它们的作用不是「覆盖行数」，
/// 而是钉住几条容易在重构中悄悄退化的规则：
///   - 片名的边界靠「第一个技术标记」，不是靠切词；
///   - 年份要躲开片名里的数字（`2012` vs `(2012)`）；
///   - 括号风格的第一个散组是发布组、最后一个才是片名；
///   - `groupKey` 必须把同一部剧的不同集、同一部片的不同版本归到一起。
void main() {
  const parser = MediaFilenameParser();

  group('点分风格 · 电影', () {
    test('完整发布名：片名 / 年份 / 分辨率 / 来源 / 编码 / 音轨 / 标记 / 发布组', () {
      final r = parser.parse(
        'The.Wandering.Earth.II.2023.2160p.WEB-DL.HDR.HEVC.DDP5.1-OurTV.mkv',
      );

      expect(r.kind, MediaKind.movie);
      expect(r.title, 'The Wandering Earth II');
      expect(r.year, 2023);
      expect(r.resolution, VideoResolution.uhd2160);
      expect(r.source, 'WEB-DL');
      expect(r.videoCodec, 'H.265');
      expect(r.audioCodec, 'DDP');
      expect(r.flags, contains('HDR'));
      expect(r.releaseGroup, 'OurTV');
      // 纯拉丁片名：latin 有值、cjk 为空
      expect(r.latinTitle, 'The Wandering Earth II');
      expect(r.cjkTitle, isNull);
      expect(r.isConfident, isTrue);
    });

    test('片名里的连字符与数字不被当成标记', () {
      final r = parser.parse('Spider-Man.2002.1080p.BluRay.x264.mkv');

      expect(r.title, 'Spider-Man');
      expect(r.year, 2002);
      expect(r.source, 'BluRay');
      expect(r.videoCodec, 'H.264');
    });

    test('中文片名：cjk 有值、latin 为空', () {
      final r = parser.parse('流浪地球2.2023.2160p.HDR.mkv');

      expect(r.title, '流浪地球2');
      expect(r.cjkTitle, '流浪地球2');
      expect(r.latinTitle, isNull);
      expect(r.year, 2023);
      expect(r.flags, contains('HDR'));
    });

    test('站点前缀被剥掉，剩下的仍是干净片名', () {
      final r = parser.parse(
        '[电影天堂www.dy2018.com]流浪地球2.2023.2160p.HDR.mkv',
      );

      expect(r.title, '流浪地球2');
      expect(r.year, 2023);
      expect(r.resolution, VideoResolution.uhd2160);
    });

    test('分卷号被单独识别出来，不进片名', () {
      final r = parser.parse('Some.Movie.2023.CD1.1080p.mkv');

      expect(r.title, 'Some Movie');
      expect(r.part, 1);
    });
  });

  group('点分风格 · 剧集', () {
    test('S01E02 全字段', () {
      final r = parser.parse(
        'Breaking.Bad.S01E02.1080p.BluRay.x264.DTS-HD.MA.5.1.mkv',
      );

      expect(r.kind, MediaKind.episode);
      expect(r.title, 'Breaking Bad');
      expect(r.season, 1);
      expect(r.episode, 2);
      expect(r.episodeEnd, isNull);
      expect(r.resolution, VideoResolution.fhd1080);
      expect(r.source, 'BluRay');
      expect(r.videoCodec, 'H.264');
      expect(r.audioCodec, 'DTS-HD');
      expect(r.episodeLabel, 'S01E02');
      // 剧集名里没有年份是正常的，不该因此判为「不可信」
      expect(r.year, isNull);
      expect(r.isConfident, isTrue);
    });

    test('1x02 写法', () {
      final r = parser.parse('Fleabag.1x02.720p.HDTV.x264.mkv');

      expect(r.kind, MediaKind.episode);
      expect(r.title, 'Fleabag');
      expect(r.season, 1);
      expect(r.episode, 2);
      expect(r.resolution, VideoResolution.hd720);
      expect(r.source, 'HDTV');
      expect(r.episodeLabel, 'S01E02');
    });

    test('第01集 写法（中文剧集）', () {
      final r = parser.parse('长安十二时辰.第01集.1080p.WEB-DL.mkv');

      expect(r.kind, MediaKind.episode);
      expect(r.title, '长安十二时辰');
      expect(r.cjkTitle, '长安十二时辰');
      expect(r.season, isNull);
      expect(r.episode, 1);
      expect(r.resolution, VideoResolution.fhd1080);
      expect(r.source, 'WEB-DL');
      expect(r.episodeLabel, 'E01');
      expect(r.displayTitle, '长安十二时辰 E01');
    });

    test('第01-03集 是区间，不是单集', () {
      final r = parser.parse('长安十二时辰.第01-03集.1080p.mkv');

      expect(r.episode, 1);
      expect(r.episodeEnd, 3);
      expect(r.episodeLabel, 'E01-E03');
    });

    test('整季包：只有季号、没有集号', () {
      final r = parser.parse('Some.Show.S02.1080p.BluRay.mkv');

      expect(r.kind, MediaKind.episode);
      expect(r.title, 'Some Show');
      expect(r.season, 2);
      expect(r.episode, isNull);
      expect(r.episodeLabel, isNull);
      // 集号未知时不要拼一个假的 E00 出来
      expect(r.displayTitle, 'Some Show');
    });
  });

  group('括号风格（动漫 / 日剧 / 国内压制组）', () {
    test('[组名][片名][集号][分辨率][语言] 全字段', () {
      final r = parser.parse(
        '[Nekomoe kissaten][One Piece][1001][1080p][JPSC].mp4',
      );

      expect(r.kind, MediaKind.episode);
      expect(r.title, 'One Piece');
      expect(r.releaseGroup, 'Nekomoe kissaten');
      expect(r.episode, 1001);
      expect(r.resolution, VideoResolution.fhd1080);
      expect(r.source, isNull);
    });

    test('只剩一个散组时它就是片名，不能被当发布组丢掉', () {
      final r = parser.parse('[1080p][Some Movie].mkv');

      expect(r.title, 'Some Movie');
      expect(r.releaseGroup, isNull);
      expect(r.resolution, VideoResolution.fhd1080);
      expect(r.kind, MediaKind.movie);
    });
  });

  group('目录名兜底', () {
    test('文件名提不出片名时才用目录名', () {
      final r = parser.parse('1080p.mkv', dirName: '流浪地球2 (2023)');

      expect(r.kind, MediaKind.movie);
      expect(r.title, '流浪地球2');
      expect(r.year, 2023);
    });

    test('文件名能提出片名时，目录名不参与（避免覆盖正确结果）', () {
      final r = parser.parse('Inception.2010.1080p.mkv', dirName: '随便一个目录');

      expect(r.title, 'Inception');
      expect(r.year, 2010);
    });
  });

  group('dirNameOf：从路径取末级目录名', () {
    // 扫描期与详情页的单片刮削**共用**它。两处对「什么算末级目录名」的理解
    // 一旦不同（比如一处去了尾斜杠、一处没去），同一个文件在两处就会解析出
    // 不同的片名 —— 而且两边都不报错。
    test('去掉尾斜杠后取最后一段', () {
      expect(
        MediaFilenameParser.dirNameOf('/电影/流浪地球2 (2023)/'),
        '流浪地球2 (2023)',
      );
    });

    test('多余斜杠不影响结果', () {
      expect(MediaFilenameParser.dirNameOf('a//b'), 'b');
      expect(MediaFilenameParser.dirNameOf('/a/b'), 'b');
    });

    test('没有斜杠时整串就是目录名', () {
      expect(MediaFilenameParser.dirNameOf('abc'), 'abc');
    });

    test('只有斜杠或空串 → null', () {
      expect(MediaFilenameParser.dirNameOf('/'), isNull);
      expect(MediaFilenameParser.dirNameOf('///'), isNull);
      expect(MediaFilenameParser.dirNameOf(''), isNull,
          reason: '返回空串而不是 null 的话，调用方 `dirName != null` 的判据会放行，'
              '于是一个空目录名被当成兜底片名参与解析');
    });
  });

  group('退化情形', () {
    test('完全认不出片名时 kind=unknown，但分辨率仍被抽出来', () {
      final r = parser.parse('1080p.mkv');

      expect(r.kind, MediaKind.unknown);
      expect(r.title, isNull);
      expect(r.resolution, VideoResolution.fhd1080);
      // 列表里显示空白比显示一串技术标记更糟 —— 退回文件名
      expect(r.displayTitle, '1080p');
      expect(r.isConfident, isFalse);
    });

    test('sample 是子串不算花絮（The.Sampler 是正经片名）', () {
      final r = parser.parse('The.Sampler.2023.1080p.mkv');

      expect(r.isSampleOrExtra, isFalse);
      expect(r.title, 'The Sampler');
    });

    test('iso 被判为镜像', () {
      expect(parser.parse('Some.Movie.2023.iso').isDiscImage, isTrue);
      expect(parser.parse('Some.Movie.2023.mkv').isDiscImage, isFalse);
    });

    test('发布组不会把 -1080p 这类技术标记当组名', () {
      expect(parser.parse('Movie-1080p.mkv').releaseGroup, isNull);
      expect(parser.parse('Movie.2023.1080p-GROUP.mkv').releaseGroup, 'GROUP');
    });
  });

  group('groupKey 归组', () {
    test('同一部剧不同季不同集归到同一组（不含季号）', () {
      final a = parser.parse('Breaking.Bad.S01E02.1080p.mkv');
      final b = parser.parse('Breaking.Bad.S02E05.2160p.mkv');

      expect(a.groupKey, b.groupKey);
      expect(a.groupKey, 'breakingbad');
    });

    test('同一部片的不同版本归到同一组（大小写/空格/年份一致）', () {
      final a = parser.parse('流浪地球2.2023.1080p.mkv');
      final b = parser.parse('流浪地球 2.2023.2160p.HDR.mkv');

      expect(a.groupKey, b.groupKey);
      expect(a.groupKey, '流浪地球2#2023');
    });

    test('不同年份的电影不会被并成一部', () {
      final a = parser.parse('Dune.1984.1080p.mkv');
      final b = parser.parse('Dune.2021.2160p.mkv');

      expect(a.groupKey, isNot(b.groupKey));
    });
  });
}
