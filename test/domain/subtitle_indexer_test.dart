import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/subtitle_track.dart';
import 'package:cloudcine/domain/services/subtitle_service.dart';
import 'package:flutter_test/flutter_test.dart';

MediaItem _item({
  required String fileId,
  required String name,
  String? title,
  int? season,
  int? episode,
}) =>
    MediaItem(
      provider: DriveProvider.quark,
      fileId: fileId,
      name: name,
      dirId: 'dir-1',
      dirPath: '/电影/',
      groupKey: 'g',
      kind: episode == null ? MediaKind.movie : MediaKind.episode,
      title: title,
      season: season,
      episode: episode,
      firstSeenAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

DriveEntry _sub(String id, String name) =>
    DriveEntry(id: id, name: name, isDirectory: false);

void main() {
  const indexer = SubtitleIndexer();

  group('配对', () {
    test('去掉语言标记后同名 → 落到那个视频上', () {
      final result = indexer.indexDirectory(
        items: [_item(fileId: 'v1', name: 'Movie.2023.1080p.mkv', title: 'Movie')],
        subtitleFiles: [_sub('s1', 'Movie.2023.1080p.chs.srt')],
      );

      expect(result.entries, hasLength(1));
      expect(result.entries.single.itemId, 'quark:v1');

      final track = result.entries.single.tracks.single;
      expect(track.origin, SubtitleOrigin.cloudFile);
      expect(track.format.label, 'SRT');
      expect(track.language?.label, '简体中文');
      expect(track.fileId, 's1');
      expect(track.fileName, 'Movie.2023.1080p.chs.srt');
      expect(track.isExternal, isTrue);
      expect(track.displayLabel, '简体中文 (SRT)');
    });

    test('同目录两个版本时按分辨率落到正确的那个', () {
      final result = indexer.indexDirectory(
        items: [
          _item(fileId: 'v1', name: 'Movie.2023.1080p.mkv', title: 'Movie'),
          _item(fileId: 'v2', name: 'Movie.2023.2160p.mkv', title: 'Movie'),
        ],
        subtitleFiles: [_sub('s1', 'Movie.2023.1080p.chs.srt')],
      );

      expect(result.entries, hasLength(1));
      // 1080P 的字幕不该挂到 2160P 的片子上
      expect(result.entries.single.itemId, 'quark:v1');
    });

    test('S02E05 的字幕落到 E05 那一集，而不是同剧的 E06', () {
      final result = indexer.indexDirectory(
        items: [
          _item(
            fileId: 'e5',
            name: 'Show.S02E05.1080p.mkv',
            title: 'Show',
            season: 2,
            episode: 5,
          ),
          _item(
            fileId: 'e6',
            name: 'Show.S02E06.1080p.mkv',
            title: 'Show',
            season: 2,
            episode: 6,
          ),
        ],
        subtitleFiles: [_sub('s1', 'Show.S02E05.chs.ass')],
      );

      expect(result.entries, hasLength(1));
      expect(result.entries.single.itemId, 'quark:e5');
      expect(result.entries.single.tracks.single.format.label, 'ASS');
    });

    test('目录里只有一个视频时，任何字幕都归它（/电影/片名/movie.mkv + chs.srt）', () {
      final result = indexer.indexDirectory(
        items: [_item(fileId: 'v1', name: 'movie.mkv')],
        subtitleFiles: [_sub('s1', 'chs.srt')],
      );

      expect(result.entries, hasLength(1));
      expect(result.entries.single.itemId, 'quark:v1');
      expect(result.entries.single.tracks.single.language?.label, '简体中文');
    });

    test('一个视频可以挂多条字幕（简中 + 英文）', () {
      final result = indexer.indexDirectory(
        items: [_item(fileId: 'v1', name: 'Movie.2023.1080p.mkv', title: 'Movie')],
        subtitleFiles: [
          _sub('s1', 'Movie.2023.1080p.chs.srt'),
          _sub('s2', 'Movie.2023.1080p.eng.ass'),
        ],
      );

      expect(result.entries, hasLength(1));
      final tracks = result.entries.single.tracks;
      expect(tracks, hasLength(2));
      expect(tracks.map((t) => t.language?.label).toSet(), {'简体中文', '英文'});
      // 同一视频内的两条字幕 ID 必须不同，否则会被去重掉
      expect(tracks[0].id, isNot(tracks[1].id));
      expect(tracks.every((t) => t.id.startsWith('quark:v1#')), isTrue);
    });
  });

  group('拒绝误配', () {
    test('多视频目录里，对不上的字幕被跳过而不是随便挂一个', () {
      final result = indexer.indexDirectory(
        items: [
          _item(fileId: 'v1', name: 'Alpha.2020.1080p.mkv', title: 'Alpha'),
          _item(fileId: 'v2', name: 'Beta.2021.1080p.mkv', title: 'Beta'),
        ],
        subtitleFiles: [_sub('s1', 'Gamma.2022.chs.srt')],
      );

      expect(result.isEmpty, isTrue);
      expect(result.matchCount, 0);
    });

    test('非字幕文件（txt / nfo / jpg）不参与索引', () {
      final result = indexer.indexDirectory(
        items: [_item(fileId: 'v1', name: 'Movie.2023.1080p.mkv', title: 'Movie')],
        subtitleFiles: [
          _sub('a', 'readme.txt'),
          _sub('b', 'Movie.2023.1080p.nfo'),
          _sub('c', 'poster.jpg'),
        ],
      );

      expect(result.isEmpty, isTrue);
    });

    test('没有视频或没有字幕时返回空结果（不抛）', () {
      expect(
        indexer.indexDirectory(items: const [], subtitleFiles: [_sub('s', 'a.srt')]).isEmpty,
        isTrue,
      );
      expect(
        indexer.indexDirectory(
          items: [_item(fileId: 'v', name: 'a.mkv')],
          subtitleFiles: const [],
        ).isEmpty,
        isTrue,
      );
    });
  });

  group('字幕属性', () {
    test('强制字幕被标出来', () {
      final result = indexer.indexDirectory(
        items: [_item(fileId: 'v1', name: 'Movie.2023.1080p.mkv', title: 'Movie')],
        subtitleFiles: [_sub('s1', 'Movie.2023.1080p.chs.forced.srt')],
      );

      final track = result.entries.single.tracks.single;
      expect(track.isForced, isTrue);
      // 去标记后仍然对得上（forced 不该破坏匹配）
      expect(track.language?.label, '简体中文');
    });

    test('听障字幕被标出来', () {
      final result = indexer.indexDirectory(
        items: [_item(fileId: 'v1', name: 'Movie.2023.1080p.mkv', title: 'Movie')],
        subtitleFiles: [_sub('s1', 'Movie.2023.1080p.eng.sdh.srt')],
      );

      expect(result.entries.single.tracks.single.isSdh, isTrue);
    });

    test('认不出语言时退回文件名，而不是编一个语言', () {
      final result = indexer.indexDirectory(
        items: [_item(fileId: 'v1', name: 'movie.mkv')],
        subtitleFiles: [_sub('s1', 'whatever.srt')],
      );

      final track = result.entries.single.tracks.single;
      expect(track.language, isNull);
      expect(track.label, 'whatever');
    });

    test('位图字幕的 preferenceScore 比文本字幕差（同语言时）', () {
      final result = indexer.indexDirectory(
        items: [_item(fileId: 'v1', name: 'movie.mkv')],
        subtitleFiles: [
          _sub('s1', 'chs.srt'),
          _sub('s2', 'chs.sup'),
        ],
      );

      final tracks = result.entries.single.tracks;
      final text = tracks.firstWhere((t) => t.format.label == 'SRT');
      final bitmap = tracks.firstWhere((t) => t.format.label == 'PGS');
      expect(text.preferenceScore, lessThan(bitmap.preferenceScore));
    });
  });

  group('refs 展开', () {
    test('每条字幕展开成一条引用，itemId 指回所属视频', () {
      final result = indexer.indexDirectory(
        items: [
          _item(fileId: 'v1', name: 'Alpha.2020.1080p.mkv', title: 'Alpha'),
          _item(fileId: 'v2', name: 'Beta.2021.1080p.mkv', title: 'Beta'),
        ],
        subtitleFiles: [
          _sub('s1', 'Alpha.2020.1080p.chs.srt'),
          _sub('s2', 'Beta.2021.1080p.eng.srt'),
        ],
      );

      expect(result.entries, hasLength(2));
      expect(result.matchCount, 2);

      final refs = result.refs;
      expect(refs, hasLength(2));
      expect(
        refs.map((r) => '${r.itemId}|${r.track.fileId}').toSet(),
        {'quark:v1|s1', 'quark:v2|s2'},
      );
    });
  });
}
