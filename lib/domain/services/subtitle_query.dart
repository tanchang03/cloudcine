import '../../core/utils/file_names.dart';
import '../../core/utils/filename_parser.dart';
import '../entities/media_item.dart';

/// 一次字幕站搜索的**条件**（不是一个字符串）。
///
/// 分开存而不是拼成一句 `query`，是因为这几项在接口上是**独立的参数**，
/// 而它们的语义完全不同：`query` 是模糊匹配的片名，`season`/`episode` 是
/// 硬过滤，`year` 用来排除同名翻拍。拼进片名里只会让服务端把它当关键词。
class SubtitleSearch {
  const SubtitleSearch({
    required this.query,
    this.type,
    this.year,
    this.season,
    this.episode,
  });

  /// 片名。**不含季集号、不含年份** —— 那两个各有自己的参数。
  final String query;

  /// `movie` / `episode`。**拿不准时是 `null`**，即不加这个过滤。
  ///
  /// 不默认填 `movie`：`MediaKind.unknown` 的条目里混着大量没识别出来的剧集，
  /// 一律标成电影会把它们的字幕全过滤掉，而用户完全看不出为什么搜不到。
  final String? type;

  final int? year;
  final int? season;
  final int? episode;

  /// 连片名都没有 —— 没什么可搜的。
  bool get isEmpty => query.trim().isEmpty;

  @override
  String toString() {
    final parts = <String>[
      'query="$query"',
      if (type != null) 'type=$type',
      if (year != null) 'year=$year',
      if (season != null) 'season=$season',
      if (episode != null) 'episode=$episode',
    ];
    return 'SubtitleSearch(${parts.join(' ')})';
  }
}

/// 把一条库记录翻译成字幕站的搜索条件。
///
/// ## 为什么值得单独一个文件
///
/// 这一段决定的是**搜索质量**，而搜索质量决定用户会不会觉得「这个功能没用」。
/// 最容易踩的坑是拿 `displayTitle` 去搜 —— 它的形状是
/// `指环王：力量之戒 S01E01`，带着集号。字幕站按关键词匹配，多一个 `S01E01`
/// 会让结果从几十条掉到个位数甚至零条，而且**不报错**。
///
/// 所以这里只做一件事：把「作品级的片名」与「集级的季/集号」拆开，各走各的
/// 参数。纯函数，好钉住。
abstract final class SubtitleQuery {
  /// [item] 为空（手输直链、内置自检视频）时退回 [fallback]。
  ///
  /// [fallback] 是**显示标题**，可能带集号 —— 没有更好的信息了，原样用。
  /// 猜着拆反而更糟：`Nova.2023.S01` 这种名字拆错了会把片名一起吃掉。
  static SubtitleSearch build(MediaItem? item, {String fallback = ''}) {
    if (item == null) return SubtitleSearch(query: fallback.trim());

    // ⚠️ 用 `title` 而不是 `displayTitle`：后者会追加 `S01E01` / `(2023)`，
    // 那正是这里要剥掉的东西。
    final title = (item.title ?? '').trim();
    final query = title.isNotEmpty ? title : baseNameOf(item.name);

    final isEpisode = item.kind == MediaKind.episode && item.episode != null;
    return SubtitleSearch(
      query: query,
      // 只在**确定是剧集**时才给 type：其余情况不加这个过滤（见字段文档）。
      type: isEpisode ? 'episode' : null,
      // 剧集不按年份过滤：一部剧跨好几年，而 `year` 在库里的口径是「首播年」，
      // 拿它去卡第 3 季会一条都搜不到。
      year: isEpisode ? null : item.year,
      season: isEpisode ? item.season : null,
      episode: isEpisode ? item.episode : null,
    );
  }
}
