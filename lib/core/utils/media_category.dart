import 'filename_parser.dart';

/// 媒体库的**一级分类**。
///
/// ## 为什么与 [MediaKind] 是两个轴，而不是扩成一个枚举
///
/// [MediaKind] 回答的是「一个文件是单片还是多集」—— 它由**文件名结构**
/// 决定（有没有 `S01E01`），是解析器的产物，只关心结构。
///
/// 本枚举回答的是「这部作品属于哪个栏目」—— 它由**内容语义**决定，
/// 剧集和动漫的文件名结构可以完全一样（都是 `S01E01`），但用户希望
/// 它们在两个栏目里分开找。
///
/// 合成一个枚举会立刻撞上「动漫也有电影（剧场版）」这种交叉情况，
/// 那时要么被迫加 `animeMovie` 这种组合爆炸的取值，要么丢失信息。
///
/// ## 取值照搬 VidHub
///
/// VidHub 主界面的一级入口是「电影 / 剧集 / 动画 / 纪录片 / 综艺」，
/// 未识别的内容落在「其他」。这里保持同样的口径 —— 用户从别的播放器
/// 迁过来时不需要重新学一套分类。
enum MediaCategory {
  movie('电影'),
  series('剧集'),
  anime('动漫'),
  variety('综艺'),
  documentary('纪录片'),
  other('其他');

  const MediaCategory(this.label);

  /// 界面展示名。
  final String label;

  /// 从持久化字符串还原。认不出来一律回 [MediaCategory.other] ——
  /// 分类是**展示维度**，读到一个陌生值时降级显示远好于抛异常。
  static MediaCategory fromName(String? name) {
    if (name == null || name.isEmpty) return MediaCategory.other;
    for (final c in MediaCategory.values) {
      if (c.name == name) return c;
    }
    return MediaCategory.other;
  }

  /// 分类栏的固定顺序。**不按 enum 声明顺序取**，因为「其他」必须垫底，
  /// 而它的声明位置是为了让 `fromName` 的兜底读起来顺。
  static const List<MediaCategory> displayOrder = [
    MediaCategory.movie,
    MediaCategory.series,
    MediaCategory.anime,
    MediaCategory.variety,
    MediaCategory.documentary,
    MediaCategory.other,
  ];
}

/// 在没有在线刮削结果时，靠**文件名 / 目录路径 / 剧集结构**猜分类。
///
/// ## 为什么必须能离线判定
///
/// 本项目的硬约束是「本地解析永远可用，在线刮削是增强」。分类如果不满足
/// 这一条，那么「没配 TMDB Key」的用户看到的媒体库会是**一整个「其他」栏**——
/// 分类栏就成了装饰。所以判定必须只依赖扫描期一定拿得到的东西。
///
/// ## 判定顺序：先看内容语义，再看结构
///
/// 顺序不能反。综艺的命名大多是 `奔跑吧.2026-09-27.第12期.mkv`，解析器
/// 提不出季集号，[MediaKind] 会是 `unknown`；如果先按 kind 落到「其他」，
/// 关键词表就永远没机会生效。所以关键词命中优先于结构判定。
///
/// 反过来，一旦关键词都没命中，才用 kind 决定「电影 / 剧集」——
/// 那是结构唯一能提供的信息。
///
/// ## 为什么关键词表这么短
///
/// 长表看着更"聪明"，实际更脆：片名里什么词都可能出现（《动画人生》、
/// 《纪录片之死》都是真实存在的片名）。表里只放**几乎不可能出现在片名
/// 中段**的词，并且优先匹配目录路径 —— 用户整理网盘时几乎一定把动漫放进
/// `动漫/` 目录，那个信号比片名可靠得多。
abstract final class MediaCategoryGuesser {
  const MediaCategoryGuesser._();

  /// 动漫。
  ///
  /// `OVA` / `ONA` / `TV版` 是番剧圈通用的发布标记，普通影视几乎不用。
  ///
  /// ⚠️ ASCII 词一律**按词边界**匹配（见 [_hit]）。不加边界的话 `ova` 会命中
  /// `Nova.2023.mkv`、`anime` 会命中 `Animated.Movie`，而这类误判会把一整批
  /// 真人电影丢进动漫栏 —— 比漏判难发现得多，因为漏判只是分类不准，
  /// 误判是「我的电影不见了」。
  static const List<String> _anime = [
    '动漫', '动画', '番剧', '新番', '国漫', '日漫', '美漫',
    '剧场版', 'anime', 'animation', 'ova', 'ona',
  ];

  /// 综艺。
  ///
  /// 「期」是综艺最稳的结构信号：`第12期`、`20260927期`。
  /// 电视剧用「集」不用「期」，两者几乎不混。
  static const List<String> _variety = [
    '综艺', '真人秀', '脱口秀', '访谈', '晚会', '盛典', '颁奖',
    'variety', 'reality', 'talkshow', 'talk show',
  ];

  /// 综艺的**结构**信号（正则）。
  static final RegExp _varietyEpisode = RegExp(
    r'(第\s*\d+\s*期|\d{6,8}\s*期)',
  );

  /// 纪录片。
  ///
  /// 频道名（`BBC` / `Discovery` / `NHK`）比「纪录片」三个字更常出现在
  /// 片名里 —— 很多纪录片根本不在文件名里写「纪录片」。
  static const List<String> _documentary = [
    '纪录片', '纪实', '纪录', 'bbc', 'discovery', 'national geographic',
    'nat.geo', 'nhk', 'history channel', 'documentary',
  ];

  /// 在线刮削拿到的 TMDB 类型名 → 分类。
  ///
  /// TMDB 的类型名会随语言变化（本项目固定取中文），所以中英文都收。
  static MediaCategory? fromGenres(List<String> genres) {
    if (genres.isEmpty) return null;
    for (final raw in genres) {
      final g = raw.trim().toLowerCase();
      if (g.isEmpty) continue;
      if (g.contains('动画') || g.contains('anime') || g.contains('animation')) {
        return MediaCategory.anime;
      }
      if (g.contains('纪录') || g.contains('documentary')) {
        return MediaCategory.documentary;
      }
      if (g.contains('真人秀') ||
          g.contains('脱口秀') ||
          g.contains('reality') ||
          g.contains('talk')) {
        return MediaCategory.variety;
      }
    }
    return null;
  }

  /// 主入口。
  ///
  /// [genres] 有值时**优先**用它 —— 那是 TMDB 的真实类型，比关键词准；
  /// 只有在它给不出结论时才退回本地判定。
  ///
  /// [fileName] 与 [dirPath] 都参与匹配：很多网盘的目录结构是
  /// `/动漫/进击的巨人/S01E01.mkv`，片名本身看不出是动漫。
  static MediaCategory guess({
    required MediaKind kind,
    String? title,
    String? fileName,
    String? dirPath,
    List<String> genres = const [],
  }) {
    final byGenre = fromGenres(genres);
    if (byGenre != null) return byGenre;

    // 目录路径权重最高（用户在网盘上分目录的习惯最稳定），
    // 其次是片名，最后是文件名（含技术标记，噪音最多）。
    final dir = (dirPath ?? '').toLowerCase();
    if (_hit(dir, _anime)) return MediaCategory.anime;
    if (_hit(dir, _variety) || _varietyEpisode.hasMatch(dir)) {
      return MediaCategory.variety;
    }
    if (_hit(dir, _documentary)) return MediaCategory.documentary;

    final name = '${title ?? ''} ${fileName ?? ''}'.toLowerCase();
    if (_hit(name, _anime)) return MediaCategory.anime;
    if (_hit(name, _variety) || _varietyEpisode.hasMatch(name)) {
      return MediaCategory.variety;
    }
    if (_hit(name, _documentary)) return MediaCategory.documentary;

    return switch (kind) {
      MediaKind.movie => MediaCategory.movie,
      MediaKind.episode => MediaCategory.series,
      MediaKind.unknown => MediaCategory.other,
    };
  }

  /// 已入库作品（没有原始文件名可用）的兜底判定。
  ///
  /// 老库里的作品行只有标题，没有文件名与路径。这时只能靠标题与 kind ——
  /// 命中率低一些，但比让整库落在「其他」强得多。
  static MediaCategory guessFromWork({
    required MediaKind kind,
    required String title,
    List<String> genres = const [],
  }) =>
      guess(kind: kind, title: title, genres: genres);

  /// 关键词命中判定。
  ///
  /// 分两种匹配方式，因为两类词的"边界"性质完全不同：
  ///
  ///   - **中文词**（`动漫` / `纪录片`）：直接 `contains`。中文没有词间空格，
  ///     用边界反而会漏（`动漫合集` 里的「动漫」后面跟着「合」，
  ///     加边界就匹配不上了）；
  ///   - **ASCII 词**（`anime` / `ova` / `bbc`）：必须卡在非字母数字的边界上。
  ///     不卡的话 `ova` 会命中 `Nova`、`bbc` 会命中 `abBc` 这类偶然子串，
  ///     而误判的后果是「我的电影跑到动漫栏里不见了」。
  static bool _hit(String haystack, List<String> needles) {
    if (haystack.isEmpty) return false;
    for (final n in needles) {
      if (_isAsciiToken(n)) {
        if (_tokenPattern(n).hasMatch(haystack)) return true;
      } else if (haystack.contains(n)) {
        return true;
      }
    }
    return false;
  }

  /// 编译好的词边界正则。**缓存**：分类判定在扫描期每部作品要跑一次，
  /// 而几千部作品 × 二十几个词就是几万次正则编译。
  static final Map<String, RegExp> _tokenCache = {};

  static RegExp _tokenPattern(String token) => _tokenCache.putIfAbsent(
        token,
        () => RegExp(
          '(?<![a-z0-9])${RegExp.escape(token)}(?![a-z0-9])',
        ),
      );

  /// 纯 ASCII（含数字与 `.` `-` 空格）的词按边界匹配，含中文的直接 `contains`。
  static final RegExp _asciiOnly = RegExp(r'^[a-z0-9 ._-]+$');

  static bool _isAsciiToken(String s) => _asciiOnly.hasMatch(s);
}
