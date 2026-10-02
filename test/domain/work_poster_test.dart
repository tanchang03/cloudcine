import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/core/utils/filename_parser.dart' show MediaKind;
import 'package:cloudcine/domain/entities/work_poster.dart';
import 'package:flutter_test/flutter_test.dart';

/// [WorkPoster.fromItems]：从一部作品名下的文件里挑一张网盘缩略图。
///
/// ## 为什么值得一个文件
///
/// 它是「点完『自定义』还有没有封面」的**唯一**判据：选错一条、或把地址与
/// 锚点配错对象，界面上都不会报错 —— 前者是一墙灰块，后者是封面里人物
/// 被裁到画面外。两种都只有看图才发现。
void main() {
  MediaItem item({
    required String fileId,
    String? thumbUrl,
    double? faceX,
    bool extra = false,
  }) =>
      MediaItem(
        provider: DriveProvider.quark,
        fileId: fileId,
        name: '$fileId.mkv',
        dirId: 'd',
        dirPath: '/剧/',
        groupKey: 'show',
        kind: MediaKind.episode,
        isSampleOrExtra: extra,
        thumbUrl: thumbUrl,
        faceAnchorX: faceX,
        firstSeenAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

  test('第一条就有缩略图 → 直接用它', () {
    final p = WorkPoster.fromItems([
      item(fileId: 'a', thumbUrl: 'https://quark/t/a', faceX: 0.3),
      item(fileId: 'b', thumbUrl: 'https://quark/t/b', faceX: 0.8),
    ]);

    expect(p!.url, 'https://quark/t/a');
    expect(p.faceX, 0.3);
  });

  test('前面几集没图 → 顺延到后面有图的那条', () {
    // 夸克实测约 30% 的视频还没生成预览图，而同一部剧里通常总有一集有。
    // 只取第一条的话，这些作品的封面会平白无故地消失。
    final p = WorkPoster.fromItems([
      item(fileId: 'a'),
      item(fileId: 'b'),
      item(fileId: 'c', thumbUrl: 'https://quark/t/c', faceX: 0.62),
    ]);

    expect(p!.url, 'https://quark/t/c');
    expect(
      p.faceX,
      0.62,
      reason: '锚点必须来自**同一条**文件 —— 拿别条的人脸位置裁这张图，'
          'PosterImage 会把人物切出画面。',
    );
  });

  test('正片优先于花絮 / 样片', () {
    final p = WorkPoster.fromItems([
      item(fileId: 'sp', thumbUrl: 'https://quark/t/sp', extra: true),
      item(fileId: 'e01', thumbUrl: 'https://quark/t/e01'),
    ]);

    expect(
      p!.url,
      'https://quark/t/e01',
      reason: '花絮也是这一部的画面，但拿幕后 / 预告当封面，整墙看起来像'
          '挂错了图。',
    );
  });

  test('只有花絮有图 → 退而求其次（有画面好过灰块）', () {
    final p = WorkPoster.fromItems([
      item(fileId: 'e01'),
      item(fileId: 'sp', thumbUrl: 'https://quark/t/sp', faceX: 0.5, extra: true),
    ]);

    expect(p!.url, 'https://quark/t/sp');
  });

  test('一条都没有 → null（不凭空造地址）', () {
    expect(WorkPoster.fromItems([item(fileId: 'a'), item(fileId: 'b')]), isNull);
    expect(WorkPoster.fromItems(const <MediaItem>[]), isNull);
  });

  test('空字符串地址当作没有', () {
    expect(
      WorkPoster.fromItems([item(fileId: 'a', thumbUrl: '  ')]),
      isNull,
      reason: '空地址会被写成「有封面」，PosterImage 却解析不出路径 —— '
          '卡片一直停在占位色上，看不出是空地址还是还在下载。',
    );
  });
}
