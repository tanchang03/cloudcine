import 'media_item.dart';

/// 一部作品的**网盘封面**：缩略图地址 + 这张图里人物的水平位置。
///
/// 两个值必须**成对**，所以它们被放在同一个对象里，而不是两个散着的
/// 可空参数：`posterFaceX` 描述的是**这一张图**里人在哪，拿甲图的人脸
/// 位置去裁乙图，画面会正好把人物切出去（`PosterImage` 里那条
/// `cover` 裁切就是靠它定位的）。
///
/// 谁提供缩略图，谁就提供锚点 —— 见 [MediaItem.faceAnchorX]。
class WorkPoster {
  const WorkPoster({required this.url, this.faceX});

  final String url;

  /// 人物水平锚点（0~1，0.5 = 正中）；没有可用人脸框时为 `null`。
  final double? faceX;

  /// 从一部作品名下的文件里挑一张缩略图。
  ///
  /// ## 为什么需要「挑」
  ///
  /// 夸克对**约 30% 的视频还没生成预览图**（实测），所以「第一个文件」往往
  /// 没图，而同一部剧里通常总有一集是有的 —— 与 `WorkSeed` 建作品时那句
  /// 「第一条没缩略图时用后面的补上」是同一件事。
  ///
  /// ## 为什么正片优先于花絮
  ///
  /// 花絮 / 样片（`isSampleOrExtra`）也是这一部的画面，但它们是幕后、预告、
  /// 彩蛋，拿它们当封面会让整墙看起来像挂错了图。只有在**一条正片都没有
  /// 图**时才退而求其次 —— 那时要么接受花絮，要么只能显示片名首字。
  ///
  /// 一部作品名下一条文件都没有（或都没有缩略图）时返回 `null`，调用方
  /// 据此保持「无封面」，不要凭空造地址。
  static WorkPoster? fromItems(Iterable<MediaItem> items) {
    MediaItem? extra;
    for (final item in items) {
      final url = item.thumbUrl;
      // 空白也当作没有：写进去就成了「有封面」，而 PosterImage 解析不出
      // 路径 —— 卡片停在占位色上，看不出是空地址还是还在下载。
      if (url == null || url.trim().isEmpty) continue;
      if (item.isSampleOrExtra) {
        extra ??= item;
        continue;
      }
      return WorkPoster(url: url, faceX: item.faceAnchorX);
    }
    final url = extra?.thumbUrl;
    if (extra == null || url == null || url.isEmpty) return null;
    return WorkPoster(url: url, faceX: extra.faceAnchorX);
  }
}
