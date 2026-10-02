import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:flutter_test/flutter_test.dart';

/// `MediaItem.rowLabel` —— **整屏都是同一部作品**的列表里那一行主标题。
///
/// 这条规则出过两次实测事故，两处都必须钉住：
///
///   1. **提不出集号**时退回片名 → 列表里几十行一模一样的字（真实样本：
///      `/来自：分享/F飞CC日  志2/` 下 12 个 `01.国语.mp4` / `01.粤语.mp4`…）。
///   2. **有集号**时两处口径不同，看着像笔误，其实不能统一 —— 窄面板只写
///      `第 3 集`（片名是噪音），宽列表要保留片名（同一集的多个版本之间
///      **只有片名不同**）。统一成任一支都会让用户看到重复的行。
void main() {
  final now = DateTime(2026, 10, 2);

  MediaItem item({
    String name = 'a.mkv',
    String? title,
    int? season,
    int? episode,
    int? episodeEnd,
  }) =>
      MediaItem(
        provider: DriveProvider.quark,
        fileId: 'f1',
        name: name,
        dirId: 'd1',
        dirPath: '/电影/x/',
        groupKey: 'g',
        kind: MediaKind.episode,
        title: title,
        season: season,
        episode: episode,
        episodeEnd: episodeEnd,
        firstSeenAt: now,
        updatedAt: now,
      );

  group('有集号', () {
    test('compact：只写集号 —— 片名对每一行都一样，是噪音', () {
      expect(
        item(title: '飞常日志', episode: 3).rowLabel(RowLabelStyle.compact),
        '第 3 集',
      );
    });

    test('compact：多季补季前缀 —— 否则第二季的第 3 集跟第一季撞名', () {
      expect(
        item(title: '剧', season: 2, episode: 3).rowLabel(RowLabelStyle.compact),
        'S2 · 第 3 集',
      );
    });

    test('compact：第 1 季不补前缀（`S1 · 第 3 集` 是纯噪音）', () {
      expect(
        item(title: '剧', season: 1, episode: 3).rowLabel(RowLabelStyle.compact),
        '第 3 集',
      );
    });

    test('compact：多集连播写成区间', () {
      expect(
        item(title: '剧', episode: 3, episodeEnd: 4)
            .rowLabel(RowLabelStyle.compact),
        '第 3-4 集',
      );
    });

    test('withTitle：保留片名 —— 同一集的多个版本只有片名不同', () {
      // 真实样本：同一个作品的「翡翠台 粤语版」与「MyTVSuper」两版，集号都是
      // 1，解析出的片名不同。用 compact 口径两行都会是「第 1 集」，
      // 用户根本分不出哪行是哪版 —— 那比不显示还糟。
      final cantonese =
          item(title: '飛常日誌', episode: 1).rowLabel(RowLabelStyle.withTitle);
      final mytvsuper = item(title: 'The Airport Diary', season: 1, episode: 1)
          .rowLabel(RowLabelStyle.withTitle);

      expect(cantonese, '飛常日誌 E01');
      expect(mytvsuper, 'The Airport Diary S01E01');
      expect(cantonese, isNot(mytvsuper));
    });
  });

  group('fileName 口径 —— 撞名时的最后一道兜底', () {
    test('有集号也强行退回文件名', () {
      // 「连片名都分不开」的两条（同一集的两个压制/码率）走这一支：
      // 只有文件名保证互不相同。
      expect(
        item(name: '飞常日志.S01E01.1080p.mkv', title: '飞常日志', episode: 1)
            .rowLabel(RowLabelStyle.fileName, workTitle: '飞常日志'),
        '飞常日志.S01E01.1080p',
      );
    });

    test('没有集号时与另外两支结果一致（本来就走文件名）', () {
      final it = item(name: '01.国语.mp4', title: 'F飞CC日 志2');
      expect(
        it.rowLabel(RowLabelStyle.fileName, workTitle: '飞常日志'),
        it.rowLabel(RowLabelStyle.compact, workTitle: '飞常日志'),
      );
    });
  });

  group('提不出集号 → 剧名-文件名', () {    test('两种口径一致 —— 这一支不分场景', () {
      final it = item(name: '01.国语.mp4', title: 'F飞CC日 志2');
      expect(
        it.rowLabel(RowLabelStyle.compact, workTitle: '飞常日志'),
        '飞常日志-01.国语',
      );
      expect(
        it.rowLabel(RowLabelStyle.withTitle, workTitle: '飞常日志'),
        '飞常日志-01.国语',
      );
    });

    test('剧名优先取**作品行**的（刮削后的名字）', () {
      // 条目自己的 title 是目录名，用户认不出来。
      expect(
        item(name: '01.国语.mp4', title: 'F飞CC日 志2')
            .rowLabel(RowLabelStyle.compact, workTitle: '飞常日志'),
        '飞常日志-01.国语',
      );
    });

    test('没有作品行时退回条目自己解析出的片名', () {
      expect(
        item(name: '01.国语.mp4', title: 'F飞CC日 志2')
            .rowLabel(RowLabelStyle.compact),
        'F飞CC日 志2-01.国语',
      );
    });

    test('两个都没有时只剩文件名 —— 不能留一个前导的短横', () {
      expect(
        item(name: '01.国语.mp4').rowLabel(RowLabelStyle.compact),
        '01.国语',
      );
      expect(
        item(name: '01.国语.mp4', title: '   ').rowLabel(RowLabelStyle.compact),
        '01.国语',
        reason: '只有空白的 title 与 null 等价，拼出「  -01.国语」就是没处理',
      );
    });

    test('文件名自己已含剧名时不重复拼 —— 折掉标点后再比', () {
      // 剧名来自**目录名**（带书名号），文件名却不带。比对时不折标点的话
      // 这条去重永远不生效，结果会是「剧名-剧名 182」。
      expect(
        item(name: '姜松家电维修视频教程 182.mp4')
            .rowLabel(RowLabelStyle.compact, workTitle: '姜松《家电维修视频教程》'),
        '姜松家电维修视频教程 182',
      );
    });

    test('同一部电影的多个版本不再显示成同一行', () {
      // 以前两个版本都是 `流浪地球2 (2023)`，选不出来。
      final hd = item(name: '流浪地球2.2023.1080p.mkv', title: '流浪地球2')
          .rowLabel(RowLabelStyle.compact);
      final uhd = item(name: '流浪地球2.2023.2160p.mkv', title: '流浪地球2')
          .rowLabel(RowLabelStyle.compact);

      expect(hd, '流浪地球2.2023.1080p');
      expect(uhd, '流浪地球2.2023.2160p');
      expect(hd, isNot(uhd));
    });
  });
}
