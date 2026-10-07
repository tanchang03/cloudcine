/// 媒体文件名解析 —— **刮削的第一步，也是离线可用的那一半**。
///
/// 设计立场：**本地解析永远可用，在线刮削是增强**。
/// 网盘上的媒体名绝大多数遵循发布组命名习惯，光靠名字就能可靠地拿到
/// 「片名 / 年份 / 季集 / 分辨率 / 来源 / 编码」，而且不发一次网络请求。
/// 在线刮削（TMDB 等）只负责补简介、海报、评分这些**名字里没有的东西**。
/// 这个分工让「没有 API Key」「断网」「API 限流」都不会让媒体库变成空的。
///
/// ## 两种命名风格都要认
///
/// 1. **点分风格**（欧美/电影为主）
///    `The.Wandering.Earth.II.2023.2160p.WEB-DL.HDR.HEVC.DDP5.1-OurTV.mkv`
/// 2. **括号风格**（动漫/日剧/国内压制组为主）
///    `[Nekomoe kissaten][One Piece][1001][1080p][JPSC].mp4`
///
/// 判据是「去掉扩展名后是否几乎全由 `[...]` 组成」—— 两种风格的解析路径
/// 完全不同，混在一起做只会两边都不准。
///
/// ## 核心算法（点分风格）
///
/// 找出**第一个技术标记**（年份 / 分辨率 / 来源 / 编码 / 音轨 / 季集）的位置，
/// 它之前的就是片名。这比「按分隔符切词再逐个判断」稳得多，因为片名里
/// 什么符号都可能有（`Spider-Man`、`Se7en`、`流浪地球2`）。
library;

import 'directory_anchor.dart';
import 'directory_title.dart';
import 'file_names.dart';
import 'video_formats.dart';

/// 媒体类型。
enum MediaKind {
  /// 电影（单片）
  movie,

  /// 剧集（有季/集号）
  episode,

  /// 认不出来（片名都提不出来）
  unknown;

  String get label => switch (this) {
        MediaKind.movie => '电影',
        MediaKind.episode => '剧集',
        MediaKind.unknown => '其他',
      };
}

/// 文件名解析结果。**全部字段都是「有就填，没有就是 null」**，不猜。
class ParsedMediaName {
  const ParsedMediaName({
    required this.rawName,
    required this.kind,
    this.title,
    this.cjkTitle,
    this.latinTitle,
    this.year,
    this.season,
    this.episode,
    this.episodeEnd,
    this.part,
    this.partLabel,
    this.resolution,
    this.source,
    this.videoCodec,
    this.audioCodec,
    this.flags = const {},
    this.releaseGroup,
    this.isSampleOrExtra = false,
    this.isDiscImage = false,
    this.groupKeyOverride,
  });

  /// 原始文件名（含扩展名）
  final String rawName;

  final MediaKind kind;

  /// 清洗后的完整片名（中英混排时原样保留）
  final String? title;

  /// 片名里的中文部分（若有）
  final String? cjkTitle;

  /// 片名里的拉丁部分（若有）
  final String? latinTitle;

  final int? year;

  /// 季号（从 1 开始）。剧集为 `null` 表示未标明。
  final int? season;

  /// 起始集号。
  final int? episode;

  /// 结束集号（`E01-E03` / `第1-3集` 这类）。单集为 `null`。
  final int? episodeEnd;

  /// 部号（`第X部` / `第X篇` / `上部`·`下部` / `CD1` / `Disc2` / `Part1`）。
  ///
  /// ## 与 [season] 是两个维度，不能合并
  ///
  /// 季是发布组的**强约定**（`SxxExx`、`第x季`），部是更细的一层：
  /// 《进击的巨人》第三季 Part.1 / Part.2 里，季 = 3、部 = 1/2。
  /// 而电影没有季，只有部（《流浪地球》上下部）。
  ///
  /// ## 为什么它不是「分卷」
  ///
  /// 旧注释把这里叫「分卷」（`CD1` / `Disc2`），但同一个字段现在也承载
  /// 「第 X 部」这种**叙事分部** —— 两者在展示与层级上的用法完全一致
  /// （都是季下面的一层），没必要拆成两个字段。
  final int? part;

  /// 部的**展示名**，只在部号说不清或另有叫法时才填。
  ///
  ///   - `特别篇` / `剧场版` —— 没有编号，统一排在所有编号部**之后**；
  ///   - `上部` / `下部` —— 有编号（1/2）但用户认的是这两个字。
  ///
  /// 展示口径：非空时优先用它，否则用 `第 N 部`。
  final String? partLabel;

  final VideoResolution? resolution;

  /// 来源：`BluRay` / `WEB-DL` / `HDTV` / `Remux` …
  final String? source;

  /// 视频编码：`H.265` / `AVC` / `AV1` …
  final String? videoCodec;

  /// 音轨编码：`DTS-HD` / `DDP` / `TrueHD` …
  final String? audioCodec;

  /// 其他标记：`HDR` / `DV` / `3D` / `IMAX` / `Remux` …
  final Set<String> flags;

  final String? releaseGroup;

  final bool isSampleOrExtra;
  final bool isDiscImage;

  /// 归组键的**强制覆盖** —— 由「目录锚点」给出（见 [DirectoryAnchorIndex]）。
  ///
  /// ⛔ 为什么不能靠「把 title 改成锚点作品的标题、再让 [groupKey] 算一遍」：
  ///    作品刮削之后 `title` 会变成在线源给的正式名（`兰香如故（2026）`），
  ///    而 `media_works.key` 是**首次入库时**算出来的、**永不改写**。
  ///    两者一旦不同，算出来的键就对不上那部作品 —— 结果是
  ///    「锚点说归到 A，实际又建了一部新作品」，而且不报错。
  final String? groupKeyOverride;

  /// 集号展示文本：`S01E02` / `E02` / `E02-E05` / 无则 `null`。
  String? get episodeLabel {
    final e = episode;
    if (e == null) return null;
    final end = episodeEnd;
    final s = season;
    final prefix = s == null ? '' : 'S${s.toString().padLeft(2, '0')}';
    final range = (end != null && end != e)
        ? 'E${e.toString().padLeft(2, '0')}-E${end.toString().padLeft(2, '0')}'
        : 'E${e.toString().padLeft(2, '0')}';
    return '$prefix$range';
  }

  /// 列表里的主标题：片名 + （年份/集号）。
  ///
  /// 片名都没有时退回原始文件名（去掉扩展名）—— 列表里显示空白比显示
  /// 一串技术标记更糟。
  String get displayTitle {
    final t = title;
    if (t == null || t.isEmpty) return baseNameOf(rawName);
    final ep = episodeLabel;
    if (ep != null) return '$t $ep';
    final y = year;
    return y == null ? t : '$t ($y)';
  }

  /// **分组键**：把同一部剧的多集、同一部电影的多个版本归到一起。
  ///
  /// 归一化到「小写 + 只留字母数字与汉字」，所以
  /// `流浪地球2` 与 `流浪地球 2` 是同一组。
  ///
  /// 剧集**不含季号**：`S01` 与 `S02` 应该落在同一部剧下，由 UI 再分层。
  String get groupKey {
    // 目录锚点优先：它回答的是「这是哪部剧」，而文件名只回答「这是第几集」。
    final override = groupKeyOverride;
    if (override != null && override.isNotEmpty) return override;

    final t = (title ?? baseNameOf(rawName)).toLowerCase();
    final cleaned = t.replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]'), '');
    final y = year;
    final yearPart = y == null ? '' : '#$y';
    return kind == MediaKind.episode ? cleaned : '$cleaned$yearPart';
  }

  /// 解析是否拿到了「足够可信」的结果 —— 决定在线刮削走**哪一档闸门**。
  ///
  /// ⚠️ 它**不**管「要不要建作品行」（见 [hasUsableTitle]），也**不再**决定
  /// 「要不要刮削」：2026-10-03 起为假时不再直接放弃，而是走**宽松档** ——
  /// 仍然发请求，但闸门要求精确同名且唯一（见 `ScrapeQuery.requireExactTitle`）。
  /// 理由：无年份的电影在旧实现里**一次都刮不到**（`/来自：分享/奥德赛/`
  /// 就是现场），而闸门本来就该是「换判据」，不是「一刀切拒绝」。
  bool get isConfident => kind != MediaKind.unknown &&
      (title ?? '').isNotEmpty &&
      (year != null || kind == MediaKind.episode);

  /// 片名是否**像个名字**（含字母或汉字，且不止一个字符）。
  ///
  /// 这是**归组 / 建作品行**的门槛，与 [isConfident]（**在线刮削档位**的门槛）
  /// 是**两件事**，⛔ 别合并。两者的代价完全不对等：
  ///
  ///   - 不刮削 = 没有海报与简介，本地片名照样能用；
  ///   - 不建作品 = 这条媒体在媒体库里**永久看不到**（列表读的是作品行），
  ///     而目录视图里它还标着「已入库」、还能播 —— 用户完全无从下手，
  ///     且**没有任何报错**。
  ///
  /// 现场（2026-10-03）：`/来自：分享/奥德赛/1080P.mkv`。文件名整串只有一个
  /// 分辨率标记，片名靠目录名兜底成「奥德赛」，于是 `kind=movie` 而
  /// `year=null` → [isConfident] 为 false → 作品行一条都不建 → 媒体库空的。
  ///
  /// 两个条件的口径都**照抄现有实现**，不另立一套：
  ///
  ///   - 「含字母或汉字」= `MediaFilenameParser._isStandaloneRelease` 对
  ///     「真名字」的判据（`159.mkv`、`1080p.mkv` 提出来的编号/分辨率不算名字）；
  ///   - 「不止一个字符」= `DirectoryTitle.isContainerSegment` 对「单字符不是
  ///     名字」的判据（`a.mkv` 不该建出一部叫「a」的作品）。
  bool get hasUsableTitle {
    final t = title?.trim();
    if (t == null || t.isEmpty) return false;
    if (!RegExp(r'[a-z\u4e00-\u9fff]', caseSensitive: false).hasMatch(t)) {
      return false;
    }
    return t.length >= 2;
  }

  @override
  String toString() => 'ParsedMediaName(${kind.name}, "$title", '
      'y=$year s=$season e=$episode${episodeEnd == null ? "" : "-$episodeEnd"}, '
      'p=${part ?? partLabel ?? "-"}, '
      'res=${resolution?.label ?? "-"}, src=${source ?? "-"}, '
      'v=${videoCodec ?? "-"}, a=${audioCodec ?? "-"}, '
      'flags=${flags.join("/")})';
}

/// 文件名 → 结构化元数据。
///
/// 纯函数、无副作用、不依赖任何外部服务 —— 因此可以穷举真实命名样本做单测，
/// 而不用连 TMDB。
class MediaFilenameParser {
  const MediaFilenameParser();

  /// 从展示路径里取出末级目录名（作为 [parse] 的 `dirName` 兜底）。
  ///
  /// 放在这里而不是让调用方各写一遍：扫描期与详情页的单片刮削都要用它，
  /// 两处对「什么算末级目录名」的理解一旦不同（比如一处去了尾斜杠、
  /// 一处没去），同一个文件在两处就会解析出**不同的片名**。
  static String? dirNameOf(String path) {
    final trimmed = path.replaceAll(RegExp(r'/+$'), '');
    if (trimmed.isEmpty) return null;
    final idx = trimmed.lastIndexOf('/');
    final name = idx < 0 ? trimmed : trimmed.substring(idx + 1);
    return name.isEmpty ? null : name;
  }

  /// 主入口。
  ///
  /// [dirName] 作为**兜底**：很多网盘目录是这样的结构
  /// `/电影/流浪地球2 (2023)/movie.mkv`，文件名本身没有信息量，
  /// 片名在目录名上。
  ///
  /// [dirPath] 是**完整的目录路径**，比 [dirName] 多一件事：它能让
  /// 「这个目录本身是不是一个系列」被判定出来（见 [DirectoryTitle]）。
  /// 给了 [dirPath] 时 [dirName] 由它推出，不需要也不应该再单独传 ——
  /// 两个目录来源会让「同一文件在两处解析出不同片名」重新出现。
  ///
  /// ## 目录名什么时候能顶掉文件名
  ///
  /// 实测事故（2026-10-02）：`/来自：分享/姜松《家电维修视频教程》/182.格力空调显示E6如何维修.mp4`
  /// 的文件名里只有「编号 + 描述」，提不出片名，于是它成了**一部独立作品**，
  /// 还刮成了希腊纪录片。那个目录里另外 221 个文件本该是同一部教程的集。
  ///
  /// 所以规则是：**目录名可信、且这个文件自己说不清楚时，整目录按目录名归组。**
  /// 「自己说得清楚」的判据见 [_isStandaloneRelease]：片名是真名字，
  /// 而且自带年份或季集结构（`天龙八部…S01E01.1997…`、`流浪地球2.2023…`）。
  /// 这类文件名自己就够准，用目录名去顶它只会把 `S01E01` 那样的信息抹掉。
  ///
  /// ## 目录**锚点**（[anchors]）：比上面两条都高的权威
  ///
  /// 上面两条只能看「这个文件自己的名字 + 它所在目录的名字」。可当这个目录
  /// **落在一部已有剧集的目录之下**时，还有一条更强的证据：*库里已经有那部剧
  /// 了*。此时「这是哪部剧」不该再由文件名猜 —— 见 [DirectoryAnchorIndex]。
  ///
  /// ⚠️ 它排在**最后**：只有前面几条都定不下来（或定得与锚点不同）时才覆盖。
  ///    换句话说锚点永远赢，因为它是唯一「知道库里有什么」的那一条。
  ParsedMediaName parse(
    String fileName, {
    String? dirName,
    String? dirPath,
    DirectoryAnchorIndex? anchors,
  }) {
    final base = baseNameOf(fileName);
    final isSample = VideoFormats.isSampleOrExtra(base);
    final isDisc = VideoFormats.isDiscImage(fileName);

    final bracketed = _parseBracketed(base);
    final parsed = bracketed ?? _parseDotted(base);

    // 目录名兜底：只有当文件名提不出片名时才用。
    var title = parsed.title;
    var cjk = parsed.cjkTitle;
    var latin = parsed.latinTitle;
    var year = parsed.year;
    var kind = parsed.kind;
    var season = parsed.season;
    var episode = parsed.episode;
    var episodeEnd = parsed.episodeEnd;
    var resolution = parsed.resolution;

    /// 归组键的强制覆盖（由下面的「目录锚点」填）。
    String? groupKeyOverride;

    // ⚠️ `dirPath` 优先于 `dirName`，且**只用它推 dirName**：两个来源各自
    // 生效时，同一个文件在扫描期与详情页会解析出不同的片名（静默分叉）。
    final effectiveDirName =
        dirPath != null ? dirNameOf(dirPath) : dirName;

    // ⚠️ 兜底也要**排掉容器名**：`/电影/2012.2009.1080p.mkv` 的文件名提不出
    // 片名（`2012` 被当成标记），旧代码就拿目录名兜底 → 库里多出一部叫
    // 「电影」的作品。`day01`、`来自：分享` 同理。
    // 排掉之后 title 为空 → `WorkSeedBook.add` 不归组 → 这条文件在库里以
    // 文件名示人。那比造一个假作品好（见 `WorkSeedBook.add` 的说明）。
    if ((title == null || title.isEmpty) &&
        effectiveDirName != null &&
        effectiveDirName.isNotEmpty &&
        !DirectoryTitle.isContainerSegment(effectiveDirName)) {
      final fromDir = _parseDotted(effectiveDirName);
      title = fromDir.title;
      cjk = fromDir.cjkTitle;
      latin = fromDir.latinTitle;
      year ??= fromDir.year;
      resolution ??= fromDir.resolution;
      if (fromDir.season != null) {
        season ??= fromDir.season;
        episode ??= fromDir.episode;
        episodeEnd ??= fromDir.episodeEnd;
      }
      if (kind == MediaKind.unknown) kind = fromDir.kind;
    }

    // 目录级归组（见方法头与 [DirectoryTitle]）。
    if (dirPath != null && dirPath.isNotEmpty) {
      final series = DirectoryTitle.seriesTitleOf(dirPath);
      if (series != null &&
          !_isStandaloneRelease(kind: kind, title: title, year: year) &&
          // 目录名与片名是同一个名字时，这个目录只是「那部作品的发行文件夹」，
          // 不是「装着许多集的容器」—— 顶掉它只会把电影改成剧集。
          _normalizeName(title) != _normalizeName(series)) {
        final scripts = _splitScripts(series);
        title = series;
        cjk = scripts.cjk;
        latin = scripts.latin;
        year ??= _pickYear(series, -1);
        // 整目录归一个作品 = 一部剧集。这是用户定的口径：
        // 「同目录多视频 → 作为系列整体归类，不作为独立电影存在」。
        kind = MediaKind.episode;
        // 季集号来自**单个文件**，归组后它不再代表「这部剧的第几集」，
        // 而且 `E6` 这类故障代码正是从这里混进来的（事故现场）。
        season = null;
        episode = null;
        episodeEnd = null;
      }
    }

    // 目录**锚点**（最高权威，见方法头）：这个目录落在一部已有剧集的目录
    // 之下 → 这个文件就是那部剧的一集。
    //
    // ⛔ 放在**最后**、且不受 `_isStandaloneRelease` 约束 —— 那一条判的是
    //    「文件名自己说不说得清」，而锚点用的是**库里已经有什么**，两者不是
    //    一个层面的证据。2026-10-07 现场正是被 `_isStandaloneRelease` 挡住，
    //    才把 `S01E01…mkv` 归成了一部叫「…去头去尾版」的新剧。
    //
    // 季集号**保留**：归到哪部剧与「是第几集」互不影响，UI 分层要用它。
    // 年份也保留（展示用），但进不了 key（剧集的 key 不含年份）。
    if (anchors != null && dirPath != null && dirPath.isNotEmpty) {
      final anchor = anchors.anchorFor(dirPath);
      if (anchor != null) {
        title = anchor.title;
        cjk = anchor.title;
        latin = null;
        kind = MediaKind.episode;
        groupKeyOverride = anchor.groupKey;
      }
    }

    return ParsedMediaName(
      rawName: fileName,
      kind: kind,
      title: title,
      cjkTitle: cjk,
      latinTitle: latin,
      year: year,
      season: season,
      episode: episode,
      episodeEnd: episodeEnd,
      part: parsed.part,
      partLabel: parsed.partLabel,
      resolution: resolution,
      source: parsed.source,
      videoCodec: parsed.videoCodec,
      audioCodec: parsed.audioCodec,
      flags: parsed.flags,
      releaseGroup: parsed.releaseGroup,
      isSampleOrExtra: isSample,
      isDiscImage: isDisc,
      groupKeyOverride: groupKeyOverride,
    );
  }

  // -------------------------------------------------------------------
  // 目录级归组
  // -------------------------------------------------------------------

  /// 这个文件名是否**自称一份独立发行物** —— 是的话目录名不许顶掉它。
  ///
  /// 两条都要满足：
  ///
  ///   1. 片名是**真名字**（含字母或汉字），**或者**是一串编号但**自带年份**
  ///      （见下面 [hasWord] 那一段）；
  ///   2. 它**自带年份或季集结构**。`天龙八部…S01E01.1997…` 这类文件名自己
  ///      就说得清清楚楚，用目录名去顶反而会把 `S01E01` 抹掉。
  ///
  /// ⚠️ 第 2 条依赖「故障代码不算集号」那条修复：`显示E6` 曾经被当成第 6 集，
  /// 于是 `182.格力空调显示E6如何维修.mp4` 被判成「自带季集结构」→ 保住垃圾
  /// 片名 → 各建一个作品。两条规则是**配套**的，改一条要看另一条。
  static bool _isStandaloneRelease({
    required MediaKind kind,
    required String? title,
    required int? year,
  }) {
    final t = title;
    if (t == null || t.isEmpty) return false;

    final hasWord =
        RegExp(r'[a-z\u4e00-\u9fff]', caseSensitive: false).hasMatch(t);

    // 纯数字片名：**自带年份**时才当它是真名字。
    //
    // 2026-10-03 现场：`/来自：分享/逃出白垩纪 (2023) 4K HDR & Dv/`
    // `65.2023.2160p.WEB-DL.DDP5.1.DV.HDR.H.265-FLUX.mkv`。
    // 那部电影的片名**就是** `65`（2023，Adam Driver 主演）。旧规则
    // 「没有字母汉字就不是名字」把它判成编号 → 目录名顶掉它 → 查询词变成
    // `逃出白垩纪 2023 4K HDR & Dv`（目录名里的年份与画质标记没被清掉）
    // → 两个在线源都搜不到。而 `65` + 年份 2023 本来是一击即中的查询。
    //
    // 为什么**要求自带年份**：`159.mkv`、`1080p.mp4` 提出来的确实是编号/
    // 分辨率，而它们**没有年份** —— 那条守卫（2026-10-02「182 → 希腊纪录片」
    // 事故）不能丢。何况现在还有候选链兜着：万一 `159.2023.mkv` 里的 159
    // 真是课程编号，主查询落空后会自动改用目录名再搜一次
    // （见 `ScrapeQuery.fallbacks`）。
    if (!hasWord) return year != null;

    return year != null || kind == MediaKind.episode;
  }

  /// 「同一个名字」的判定口径 —— 与 [ParsedMediaName.groupKey] 一致。
  static String _normalizeName(String? s) =>
      (s ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]'), '');

  // -------------------------------------------------------------------
  // 括号风格：`[组名][片名][集号][1080p][语言]`
  // -------------------------------------------------------------------

  /// 判据：去掉扩展名后，**几乎全部**由 `[...]` 组成。
  ///
  /// 允许组之间有空隙与少量散字（`[组] 片名 [01]`）。
  static final RegExp _bracketedWhole = RegExp(r'^(\s*\[[^\]]*\]\s*)+$');
  static final RegExp _bracketGroup = RegExp(r'\[([^\]]*)\]');
  // ⚠️ 必须带捕获组：调用处读的是 `group(1)`。曾经这里写成 `^\d{1,4}$`，
  // 于是 `[组名][片名][01][1080p]` 这种**最常见的动漫命名**在扫描时直接
  // 抛 `RangeError: Value not in range: 1`，整个扫描崩掉。
  static final RegExp _pureNumber = RegExp(r'^(\d{1,4})$');
  static final RegExp _numberRange = RegExp(r'^(\d{1,4})\s*[-~]\s*(\d{1,4})$');
  static final RegExp _chineseEpisode = RegExp(r'^第\s*(\d{1,4})\s*[集话話]$');

  ParsedMediaName? _parseBracketed(String base) {
    final trimmed = base.trim();
    if (!_bracketedWhole.hasMatch(trimmed)) return null;

    final groups = _bracketGroup
        .allMatches(trimmed)
        .map((m) => (m.group(1) ?? '').trim())
        .where((g) => g.isNotEmpty)
        .toList();
    if (groups.length < 2) return null;

    final flags = <String>{};
    int? episode;
    int? episodeEnd;
    int? season;
    int? part;
    String? partLabel;
    VideoResolution? resolution;
    String? source;
    String? videoCodec;
    String? audioCodec;
    final leftovers = <String>[];

    for (final g in groups) {
      final lower = g.toLowerCase();

      // 1. 分辨率
      final res = VideoFormats.resolutionFromName(g);
      if (res != null) {
        resolution ??= res;
        continue;
      }

      // 2. 季集（`S01E02` / `01` / `第3集`）
      final tv = _matchEpisodePattern(lower);
      if (tv != null) {
        season ??= tv.season;
        episode ??= tv.episode;
        episodeEnd ??= tv.episodeEnd;
        continue;
      }
      final pure = _pureNumber.firstMatch(g);
      if (pure != null) {
        episode ??= int.tryParse(pure.group(1)!);
        continue;
      }
      final range = _numberRange.firstMatch(g);
      if (range != null) {
        episode ??= int.tryParse(range.group(1)!);
        episodeEnd ??= int.tryParse(range.group(2)!);
        continue;
      }
      final cn = _chineseEpisode.firstMatch(g);
      if (cn != null) {
        episode ??= int.tryParse(cn.group(1)!);
        continue;
      }

      // 2.5 分部（`第2部` / `特别篇` / `Part.1` / `CD1`）
      //
      // 必须排在**集号判定之后**：`第3集` 是集、`第3部` 是部，两者的写法
      // 只差最后一个字 —— 让 `_chineseEpisode` 先吃掉「集」那种，剩下的
      // 才轮到这里。
      final p = _partOf(lower);
      if (p.index != null || p.label != null) {
        part ??= p.index;
        partLabel ??= p.label;
        continue;
      }

      // 3. 来源 / 编码 / 音轨
      final src = _sourceOf(lower);
      if (src != null) {
        source ??= src;
        continue;
      }
      final vc = _videoCodecOf(lower);
      if (vc != null) {
        videoCodec ??= vc;
        continue;
      }
      final ac = _audioCodecOf(lower);
      if (ac != null) {
        audioCodec ??= ac;
        continue;
      }

      // 4. 纯标记组（`HDR` / `简繁` / `JPSC` / `CHS&JPN`）
      if (_isFlagOnlyGroup(lower)) {
        flags.addAll(_flagsOf(lower));
        continue;
      }

      leftovers.add(g);
    }

    if (leftovers.isEmpty) return null;

    // 剩下没被认领的组：**第一个是发布组，最后一个是片名**。
    // 只有一组时它就是片名（不能当发布组丢掉）。
    String? group;
    String title;
    if (leftovers.length == 1) {
      title = leftovers.first;
    } else {
      group = leftovers.first;
      title = leftovers.last;
    }

    final scripts = _splitScripts(title);
    final kind = episode != null || season != null
        ? MediaKind.episode
        : MediaKind.movie;

    return ParsedMediaName(
      rawName: base,
      kind: kind,
      title: title,
      cjkTitle: scripts.cjk,
      latinTitle: scripts.latin,
      season: season,
      episode: episode,
      episodeEnd: episodeEnd,
      part: part,
      partLabel: partLabel,
      resolution: resolution,
      source: source,
      videoCodec: videoCodec,
      audioCodec: audioCodec,
      flags: flags,
      releaseGroup: group,
    );
  }

  /// 这一组是不是「只说标记、不含片名」的组。
  static bool _isFlagOnlyGroup(String lower) {
    if (_flagsOf(lower).isNotEmpty) return true;
    // 语言组：`chs` / `jpsc` / `简繁` / `gb&big5` / `vostfr`
    const langHints = [
      'chs', 'cht', 'jpsc', 'jptc', 'jp', 'sc', 'tc', 'gb', 'big5',
      '简', '繁', '中', '日', '英', 'vostfr', 'multi', 'dual', 'sub',
      'hardsub', 'softsub', '内嵌', '外挂', '字幕',
    ];
    final stripped = lower.replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]'), '');
    if (stripped.isEmpty) return true;
    for (final h in langHints) {
      if (stripped == h) return true;
    }
    // 组合形态：`chs&jpn`、`简繁日`
    final parts = lower.split(RegExp(r'[&+/|]'));
    if (parts.length > 1) {
      return parts.every((p) {
        final s = p.replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]'), '');
        return langHints.any((h) => s == h || s.startsWith(h));
      });
    }
    return false;
  }

  // -------------------------------------------------------------------
  // 点分风格
  // -------------------------------------------------------------------

  /// 技术标记的起点正则。
  ///
  /// 顺序无所谓 —— 取的是**所有匹配里位置最小的那个**。
  /// 每个正则都用 `(?<![0-9a-z])` / `(?![0-9a-z])` 卡边界，避免把
  /// `Se7en`、`1080`（片名里的数字）、`Web`（片名里的词）误当标记。
  static final List<RegExp> _markerPatterns = [
    // 年份
    RegExp(r'(?<![0-9])(?:19\d{2}|20\d{2})(?![0-9])'),
    // 分辨率：1080p / 2160P / 4K / 1920x1080
    RegExp(r'(?<![0-9a-z])\d{3,4}[pi](?![0-9a-z])', caseSensitive: false),
    RegExp(r'(?<![0-9a-z])[248]k(?![0-9a-z])', caseSensitive: false),
    RegExp(r'(?<![0-9a-z])\d{3,4}\s*[x×]\s*\d{3,4}(?![0-9a-z])',
        caseSensitive: false),
    // 季集
    RegExp(r'(?<![0-9a-z])s\d{1,2}\s*e\d{1,3}(?![0-9a-z])',
        caseSensitive: false),
    RegExp(r'(?<![0-9a-z])\d{1,2}x\d{2,3}(?![0-9a-z])'),
    // ⚠️ 前置守卫必须**连汉字一起排除**：`格力空调显示E6` 里的 E6 是空调
    // 故障代码，而 `(?<![0-9a-z])` 让紧跟在汉字后面的 `E6` 通过了守卫 ——
    // 于是片名被截在 E6 前面、集号被记成 6（2026-10-02 事故）。
    // 家电/汽车/医疗教程里 `E1`~`E9` 是成表的，会成片误判。
    RegExp(r'(?<![0-9a-z\u4e00-\u9fff])e(?:p)?\d{1,3}(?![0-9a-z])',
        caseSensitive: false),
    RegExp(r'第\s*\d{1,4}\s*[集话話]'),
    RegExp(r'(?<![0-9a-z])s\d{1,2}(?![0-9a-z])', caseSensitive: false),
    RegExp(r'season\s*\d{1,2}', caseSensitive: false),
    RegExp(r'第\s*[一二三四五六七八九十\d]{1,3}\s*季'),
    // 分部：`第X部` / `第X篇` / `特别篇` / `剧场版`
    //
    // ⚠️ 必须和 `_partOf` 一起看：这里只负责把片名**截断**在分部标记之前
    // （`进击的巨人 特别篇 01` → 片名 `进击的巨人`），真正把「部」解析出来
    // 的是 `_partOf`。少了这一段，`特别篇` 会留在片名里，而
    // `_isStandaloneRelease` 会判定它「自带季集结构」→ 目录名顶不掉它
    // → 特别篇和正片归成**两个作品**。
    RegExp(r'第\s*[一二三四五六七八九十\d]{1,3}\s*[部篇]'),
    RegExp(r'特别篇|特別篇|剧场版|劇場版'),
    RegExp(r'上部|下部|前篇|后篇|後篇'),
    // 来源
    RegExp(
      r'(?<![0-9a-z])(?:blu-?ray|bluray|bd-?remux|remux|bd-?rip|br-?rip|bd|'
      r'web-?dl|webdl|web-?rip|web|hdtv|hd-?rip|dvd-?rip|dvd|uhd|hddvd|'
      r'tv-?rip|hdtc|cam|ts)(?![0-9a-z])',
      caseSensitive: false,
    ),
    // 编码
    RegExp(
      r'(?<![0-9a-z])(?:x264|x265|h\.?264|h\.?265|hevc|avc|av1|vp9|xvid|'
      r'divx|mpeg-?2|mpeg-?4|10bit|8bit|hi10p)(?![0-9a-z])',
      caseSensitive: false,
    ),
    // 音轨
    RegExp(
      r'(?<![0-9a-z])(?:dts-?hd|dts-?x|dts|truehd|atmos|eac3|ac3|ddp|dd\+|'
      r'aac|flac|opus|mp3|lpcm|pcm|dd5\.?1|5\.1|7\.1)(?![0-9a-z])',
      caseSensitive: false,
    ),
    // 标记
    RegExp(
      r'(?<![0-9a-z])(?:hdr10\+|hdr10|hdr|dolby\s?vision|dovi|dv|sdr|3d|'
      r'hsbs|imax|remastered|extended|uncut|repack|proper|complete|multi|'
      r'dual)(?![0-9a-z])',
      caseSensitive: false,
    ),
  ];

  ParsedMediaName _parseDotted(String base) {
    final cleaned = _stripSiteTags(base);

    // 找第一个技术标记的位置。
    var markerStart = -1;
    for (final p in _markerPatterns) {
      final m = p.firstMatch(cleaned);
      if (m == null) continue;
      if (markerStart < 0 || m.start < markerStart) markerStart = m.start;
    }

    final rawTitle = markerStart <= 0
        ? (markerStart < 0 ? cleaned : '')
        : cleaned.substring(0, markerStart);

    var title = _cleanTitle(rawTitle);

    final lower = cleaned.toLowerCase();
    final tv = _matchEpisodePattern(lower);
    final resolution = VideoFormats.resolutionFromName(cleaned);
    final year = _pickYear(cleaned, markerStart);

    // 2.6 「编号 + 空格 + 技术标记」= 没有片名，那个编号就是**集号**。
    //
    // 形如 `183 4K.mp4` / `178 4K.mp4` —— 压片组很常见的写法。
    //
    // 在此之前 `183` 被当成**片名**（`_isStandaloneRelease` 允许纯数字当名字，
    // 那是为了《65》那部 2023 年的电影），后果是连着两步一起坏：
    //
    //   ① 集号是空的；
    //   ② 紧接着的**目录级归组**把这条文件判成「自己说不清楚」，用目录名顶掉
    //      `title` 的同时**连季集号一起清掉**（`season = null; episode = null;`
    //      是防 `格力空调显示E6` 那条事故的守卫，见 `parse` 里那一段）。
    //
    // 净效果就是这些条目在库里没有集号：列表里以文件名示人、按「季→集」排的
    // 顺序里全部垫底、`PlayTarget` 也选不准 —— 而它们其实清清楚楚写着第几集。
    // 2026-10-07 现场：追剧检查把 `183 4K.mp4` 当「新集」报了，用户在详情页
    // 却认不出它是第 183 集。
    //
    // ⛔ 三条守卫缺一不可：
    //    ① 提出来的是一个**纯数字**（`^\d{1,4}$`）—— 有真片名的不进这条路，
    //       `182.格力空调显示E6如何维修.mp4` 因此完全不受影响；
    //    ② 编号与标记之间**只隔空格**（不是 `.`）—— 点分隔的
    //       `65.2023.2160p…mkv`（片名就叫《65》的 2023 年电影）被挡住；
    //    ③ 整串**没有年份**、且**确实存在技术标记**（`markerStart > 0`）——
    //       `183.mp4` / `159.mkv` 这种「整串就是一个编号」的老行为不变
    //       （它们仍然按「编号当片名」处理，由目录级归组决定去留）。
    final bareEpisode = (tv == null &&
            year == null &&
            markerStart > 0 &&
            title != null &&
            _pureNumber.hasMatch(title))
        ? int.tryParse(title)
        : null;

    // 编号既然当集号用掉了，就不能再占着「片名」的位置：留着的话上面那个
    // 「提不出片名就用目录名兜底」不生效（`title` 非空），这一条会变成
    // 一部叫「183」的独立作品 —— 正是它现在在库里的样子。
    if (bareEpisode != null) title = null;

    final scripts = _splitScripts(title ?? '');

    final flags = _flagsOf(lower);
    final kind = (tv != null || bareEpisode != null)
        ? MediaKind.episode
        : ((title ?? '').isNotEmpty
            ? MediaKind.movie
            : MediaKind.unknown);
    final partInfo = _partOf(lower);

    return ParsedMediaName(
      rawName: base,
      kind: kind,
      title: title,
      cjkTitle: scripts.cjk,
      latinTitle: scripts.latin,
      year: year,
      season: tv?.season,
      episode: tv?.episode ?? bareEpisode,
      episodeEnd: tv?.episodeEnd,
      part: partInfo.index,
      partLabel: partInfo.label,
      resolution: resolution,
      source: _sourceOf(lower),
      videoCodec: _videoCodecOf(lower),
      audioCodec: _audioCodecOf(lower),
      flags: flags,
      releaseGroup: _releaseGroupOf(base),
    );
  }

  /// 去掉站点水印 / 网址 / 压制组广告这类「不是片名」的前缀。
  ///
  /// 典型输入：`[电影天堂www.dy2018.com]流浪地球2.2023.2160p...`
  /// 典型输出：`流浪地球2.2023.2160p...`
  ///
  /// ⚠️ 只删**含域名特征**的括号组。`[简繁字幕]`、`[国语]` 这类要留着 ——
  /// 它们是标记，后面还会被识别；而且删掉可能把片名一起删了。
  static String _stripSiteTags(String base) {
    var s = base;

    // 裸网址
    s = s.replaceAll(RegExp(r'https?://\S+', caseSensitive: false), ' ');
    s = s.replaceAll(RegExp(r'www\.[\w-]+\.[a-z]{2,}', caseSensitive: false), ' ');

    // 含域名特征的括号组 / 中括号组
    final domainLike = RegExp(
      r'[\w-]+\.(?:com|net|org|cc|tv|me|io|cn|xyz|top|info|biz|pw|la|us)',
      caseSensitive: false,
    );
    s = s.replaceAllMapped(
      RegExp(r'\[[^\]]*\]|【[^】]*】|\([^)]*\)'),
      (m) => domainLike.hasMatch(m.group(0)!) ? ' ' : m.group(0)!,
    );

    // 常见站点名（不带域名也会出现）
    const siteWords = [
      '电影天堂', '阳光电影', '飘花电影', 'bt天堂', '高清影视', '人人影视',
      '字幕组', '压制组', '发布组', '论坛', '资源分享',
    ];
    for (final w in siteWords) {
      s = s.replaceAll(w, ' ');
    }
    return s;
  }

  /// 清洗片名：去掉首尾分隔符、合并空白、剥掉外层括号。
  static String? _cleanTitle(String raw) {
    var s = raw;
    // 把分隔符统一成空格；`-` 保留（Spider-Man 是片名的一部分）
    s = s.replaceAll(RegExp(r'[._]+'), ' ');
    // 去掉空括号与其内容（`()` / `[]` / `【】` 全空）
    s = s.replaceAll(RegExp(r'[\[(（【]\s*[\])）】]'), ' ');
    // 去掉「只有开括号、没有配对闭括号」的尾巴。
    //
    // 片名是在**第一个技术标记处**截断的，所以 `流浪地球2 (2023)` 这种
    // 极常见的目录名会截出 `流浪地球2 (` —— 半个括号留在片名里，既难看
    // 又会污染在线刮削的查询词。
    s = s.replaceAll(RegExp(r'[\[\(（【][^\]\)）】]*$'), ' ');
    // 去掉首尾的括号与分隔符
    s = s.replaceAll(RegExp(r'^[\s\-–—\[\(（【]+'), '');
    s = s.replaceAll(RegExp(r'[\s\-–—\]\)）】]+$'), '');
    s = s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return s.isEmpty ? null : s;
  }

  /// 中英混排时按书写系统拆成两段。
  ///
  /// `流浪地球2 The Wandering Earth II` → cjk=`流浪地球2`、latin=`The Wandering Earth II`
  ///
  /// 这是**给在线刮削用的**：TMDB 用中文名搜不到时要用英文名再搜一次。
  static ({String? cjk, String? latin}) _splitScripts(String s) {
    if (s.isEmpty) return (cjk: null, latin: null);
    final cjkRe = RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]');
    if (!cjkRe.hasMatch(s)) return (cjk: null, latin: s.trim());

    // 按「连续同一书写系统」切成段，各自拼接。
    final cjkBuf = StringBuffer();
    final latinBuf = StringBuffer();
    var lastWasCjk = false;
    for (final ch in s.split('')) {
      final isCjk = cjkRe.hasMatch(ch);
      final isWord = RegExp(r'[A-Za-z0-9]').hasMatch(ch);
      final isDigit = RegExp(r'[0-9]').hasMatch(ch);
      if (isCjk) {
        cjkBuf.write(ch);
        lastWasCjk = true;
      } else if (isDigit && lastWasCjk) {
        // 紧贴在汉字后面的数字属于中文片名的一部分（`流浪地球2`）。
        // 丢进 latin 的话 `latinTitle` 会是 `"2"` —— 而它会被
        // `_pickAlternate` 当成英文备用查询词发给 TMDB。
        // 注意这里**不**把 lastWasCjk 置回 false：后面接字母时
        // （`流浪地球2The Wandering Earth II`）仍要补那个空格。
        cjkBuf.write(ch);
      } else if (isWord) {
        // 中英之间不补空格会连成 `地球2The`，所以要留一个空格
        if (lastWasCjk && latinBuf.isNotEmpty) latinBuf.write(' ');
        latinBuf.write(ch);
        lastWasCjk = false;
      } else {
        // 标点/空格：两边都留，保持可读
        if (cjkBuf.isNotEmpty && !cjkBuf.toString().endsWith(' ')) {
          cjkBuf.write(ch);
        }
        if (latinBuf.isNotEmpty && !latinBuf.toString().endsWith(' ')) {
          latinBuf.write(ch);
        }
        lastWasCjk = false;
      }
    }
    final cjk = cjkBuf.toString().trim();
    final latin = latinBuf.toString().trim();
    return (
      cjk: cjk.isEmpty ? null : cjk,
      latin: latin.isEmpty ? null : latin,
    );
  }

  /// 年份挑选。
  ///
  /// ⚠️ 不能简单取「第一个 4 位数」：`2012`（片名）与 `(2012)`（年份）
  /// 长得一模一样。规则是**优先取标记区之后出现的年份**（发布组命名的
  /// 习惯是 `片名.年份.分辨率...`），只有在标记区里找不到时才回退到
  /// 全串里的第一个。
  ///
  /// ## 括号里的完整日期不算（2026-10-03）
  ///
  /// `[2026-02-01]` 是发布者写的**上传/整理日期**，不是出品年份。以前它会
  /// 被当成 `year=2026` 落库，于是
  /// `/来自：分享/仙逆/126 纯享-仙踪-[4K][HEVC][2026-02-01].mp4` 拿到一个
  /// 假年份，`_isStandaloneRelease` 据此判它「自称独立发行物」—— 目录名
  /// `仙逆` 被顶掉，自动刮削拿着垃圾片名 `126 纯享-仙踪` 去搜，必然一无所获
  /// （同目录另外 6 个文件名里带 `仙逆` 的都刮到了）。
  ///
  /// 假年份还有第二重代价：它让 `isConfident` 为真 → 查询走**严格档**
  /// （闸门只要求 0.6 相似度）→ 更容易刮错片子。
  ///
  /// ⚠️ 两道判据缺一不可，见 [isDateYear]：**括号里**的日期才丢，
  /// 裸写的 `2023-05-12` 是发行日期，它的年份仍然是有用的筛选条件。
  ///
  /// ⚠️ 只跳过**年份本身**，不动 `_markerPatterns` —— 那里决定「片名在哪
  /// 截断」，`2026-09-27` 仍然必须把 `奔跑吧` 截出来（否则片名会变成
  /// `奔跑吧 2026-09-27 第12期`）。
  static int? _pickYear(String cleaned, int markerStart) {
    final re = RegExp(r'(?<![0-9])(19\d{2}|20\d{2})(?![0-9])');

    /// 这个位置的年份是不是「括号里的完整日期」？
    ///
    /// 两道都要满足：
    ///
    ///   1. 后面紧跟 `-MM-DD` / `.MM.DD` / `_MM_DD`。`\d{1,2}` 与
    ///      `(?![0-9])` 是**配套**的：`Movie.2023.1080p.mkv` 里的 `.1080`
    ///      咬不动（四位数字过不了 `\d{1,2}`，也过不了 `(?![0-9])`），
    ///      `2012.2009.1080p.mkv` 同理 —— 这两个的年份必须留下；
    ///   2. 年份**紧跟在括号后面**。裸写的 `2023-05-12` 是发行日期，
    ///      其年份与 TMDB 的 `year`（发行年）口径一致，要留下。
    bool isDateYear(int start) {
      final after = cleaned.substring(start + 4);
      if (!RegExp(r'^\s*[-_.]\s*\d{1,2}\s*[-_.]\s*\d{1,2}(?![0-9])')
          .hasMatch(after)) {
        return false;
      }
      final before = cleaned.substring(0, start).trimRight();
      if (before.isEmpty) return false;
      return const {'[', '【', '(', '（'}.contains(before[before.length - 1]);
    }

    /// 从 [from] 起找第一个**不是括号日期**的年份。
    int? scan(int from) {
      for (final m in re.allMatches(cleaned)) {
        if (m.start < from) continue;
        if (isDateYear(m.start)) continue;
        final y = _saneYear(int.parse(m.group(1)!));
        if (y != null) return y;
      }
      return null;
    }

    if (markerStart >= 0) {
      final y = scan(markerStart);
      if (y != null) return y;
    }
    return scan(0);
  }

  static int? _saneYear(int y) {
    final now = DateTime.now().year;
    if (y < 1900 || y > now + 2) return null;
    return y;
  }

  /// 季集匹配。返回 `null` 表示不是剧集。
  static ({int? season, int? episode, int? episodeEnd})? _matchEpisodePattern(
    String lower,
  ) {
    // `S01E02` / `s1e2` / `S01E02E03` / `S01E02-E05` / `S01E02E03E04`
    final se = RegExp(
      r's(\d{1,2})\s*e(\d{1,3})(?:\s*[-~]\s*e?(\d{1,3}))?',
      caseSensitive: false,
    ).firstMatch(lower);
    if (se != null) {
      final s = int.tryParse(se.group(1)!);
      final e = int.tryParse(se.group(2)!);
      var end = se.group(3) == null ? null : int.tryParse(se.group(3)!);
      if (end == null) {
        // `S01E02E03` —— 没有连字符的连集写法
        final multi = RegExp(r'e(\d{1,3})(?=\s*e\d{1,3})').allMatches(lower);
        final nums = multi
            .map((m) => int.tryParse(m.group(1)!))
            .whereType<int>()
            .toList();
        if (nums.isNotEmpty) end = nums.reduce((a, b) => a > b ? a : b);
      }
      return (season: s, episode: e, episodeEnd: end);
    }

    // `1x02` / `01x02`
    final x = RegExp(r'(?<![0-9a-z])(\d{1,2})x(\d{2,3})(?![0-9a-z])')
        .firstMatch(lower);
    if (x != null) {
      return (
        season: int.tryParse(x.group(1)!),
        episode: int.tryParse(x.group(2)!),
        episodeEnd: null,
      );
    }

    // `第01集` / `第1-3集`
    final cn = RegExp(r'第\s*(\d{1,4})\s*(?:[-~至]\s*(\d{1,4})\s*)?[集话話]')
        .firstMatch(lower);
    if (cn != null) {
      return (
        season: _chineseSeason(lower),
        episode: int.tryParse(cn.group(1)!),
        episodeEnd: cn.group(2) == null ? null : int.tryParse(cn.group(2)!),
      );
    }

    // `EP01` / `E01`（单独出现，没有 S 前缀）
    //
    // ⚠️ 前置守卫**连汉字一起排除**：`显示E6` 里的 E6 是故障代码不是集号。
    // 与 `_markerPatterns` 里那条必须同时改，否则片名仍会被截在 E6 前面。
    final ep = RegExp(r'(?<![0-9a-z\u4e00-\u9fff])ep?(\d{1,3})(?![0-9a-z])')
        .firstMatch(lower);
    if (ep != null) {
      final n = int.tryParse(ep.group(1)!);
      // `E01` 里的数字如果恰好是 4 位（如 e2023）不算集号
      if (n != null && n <= 999) {
        return (season: _chineseSeason(lower), episode: n, episodeEnd: null);
      }
    }

    // 只有季号：`S02` / `Season 2` / `第二季`（整季包）
    final onlySeason = RegExp(r'(?<![0-9a-z])s(\d{1,2})(?![0-9a-z])')
        .firstMatch(lower);
    if (onlySeason != null) {
      return (
        season: int.tryParse(onlySeason.group(1)!),
        episode: null,
        episodeEnd: null,
      );
    }
    final cnSeason = _chineseSeason(lower);
    if (cnSeason != null) {
      return (season: cnSeason, episode: null, episodeEnd: null);
    }
    return null;
  }

  /// `第二季` / `第2季` → 2。
  static int? _chineseSeason(String s) {
    final m = RegExp(r'第\s*([一二三四五六七八九十\d]{1,3})\s*季').firstMatch(s);
    if (m == null) return null;
    return _chineseToInt(m.group(1)!);
  }

  /// 中文数词 → 整数：`一`→1、`十`→10、`十二`→12、`二十一`→21。
  /// 纯数字串（`2`）直接解析。
  ///
  /// 抽出来是因为**季和部都要用**：`第二季` 与 `第二部` 的换算规则一模一样，
  /// 各写一份就会在某次修改后只有一处认识「廿」。
  static int? _chineseToInt(String raw) {
    final n = int.tryParse(raw);
    if (n != null) return n;
    const digits = {
      '一': 1, '二': 2, '三': 3, '四': 4, '五': 5,
      '六': 6, '七': 7, '八': 8, '九': 9, '十': 10,
    };
    if (raw.length == 1) return digits[raw];
    // 十一 / 十二 / 二十 / 二十一 …
    if (raw == '十一') return 11;
    if (raw == '十二') return 12;
    if (raw.startsWith('十')) return 10 + (digits[raw.substring(1)] ?? 0);
    if (raw.endsWith('十')) return (digits[raw.substring(0, 1)] ?? 0) * 10;
    if (raw.contains('十')) {
      final parts = raw.split('十');
      final tens = digits[parts[0]] ?? 0;
      final ones = digits[parts[1]] ?? 0;
      return tens * 10 + ones;
    }
    return null;
  }

  /// 分部：`第X部` / `第X篇` / `上部`·`下部` / `CD1` / `Part.2` / `特别篇`。
  ///
  /// 返回 `(index, label)`：能定序的填 [index]，另有叫法的填 [label]，
  /// 两个都是 `null` 就是「没标部」。
  ///
  /// ## 特别篇 / 剧场版 为什么也算「部」
  ///
  /// 用户定的口径：它们**不独立成作品**，而是归到所属作品的一个「特别篇」
  /// 部里。所以这里给一个**非数字**的 label，排序时统一排在所有编号部
  /// **之后**（见 `MediaItem.partOrder`）。
  ///
  /// ⚠️ 与 `_markerPatterns` 里那两条分部正则**必须同时存在**：这里负责
  /// 「解析出部」，那里负责「把片名截断在部之前」。只改一处会让
  /// `进击的巨人 特别篇` 变成一个片名叫「进击的巨人 特别篇」的独立作品。
  static ({int? index, String? label}) _partOf(String lower) {
    // 1) 特别篇 / 剧场版 —— 无编号，排在最后
    if (RegExp(r'特别篇|特別篇|剧场版|劇場版').hasMatch(lower)) {
      return (index: null, label: '特别篇');
    }
    // 2) `第X部` / `第X篇`
    final cn =
        RegExp(r'第\s*([一二三四五六七八九十\d]{1,3})\s*[部篇]').firstMatch(lower);
    if (cn != null) {
      final n = _chineseToInt(cn.group(1)!);
      if (n != null) return (index: n, label: null);
    }
    // 3) `上部` / `下部` / `前篇` / `后篇`
    if (RegExp(r'上部|前篇').hasMatch(lower)) {
      return (index: 1, label: '上部');
    }
    if (RegExp(r'下部|后篇|後篇').hasMatch(lower)) {
      return (index: 2, label: '下部');
    }
    // 4) `CD1` / `Disc.2` / `Part.2` / `DVD1`
    //
    // ⚠️ 分隔符必须含 `.`：发布名里 `Part.2` 是**最常见**的写法（点分风格），
    // 只写 `\s*` 会漏掉它，而漏掉的后果是「部」解析不出来 → 层级选择器
    // 少一层，且**不报错**。
    final m = RegExp(
      r'(?<![0-9a-z])(?:cd|disc|disk|part|dvd)[\s._-]*(\d{1,2})(?![0-9a-z])',
    ).firstMatch(lower);
    if (m != null) return (index: int.tryParse(m.group(1)!), label: null);
    return (index: null, label: null);
  }

  /// 来源归一化。
  static String? _sourceOf(String lower) {
    const table = <String, String>{
      'remux': 'Remux',
      'bdremux': 'Remux',
      'bluray': 'BluRay',
      'blu-ray': 'BluRay',
      'bdrip': 'BDRip',
      'brrip': 'BDRip',
      'webdl': 'WEB-DL',
      'web-dl': 'WEB-DL',
      'webrip': 'WEBRip',
      'web-rip': 'WEBRip',
      'web': 'WEB',
      'hdtv': 'HDTV',
      'hdrip': 'HDRip',
      'dvdrip': 'DVDRip',
      'dvd': 'DVD',
      'uhd': 'UHD',
      'hddvd': 'HDDVD',
      'tvrip': 'TVRip',
      'hdtc': 'HDTC',
      'cam': 'CAM',
    };
    for (final e in table.entries) {
      if (RegExp('(?<![0-9a-z])${RegExp.escape(e.key)}(?![0-9a-z])')
          .hasMatch(lower)) {
        return e.value;
      }
    }
    // `BD` 单独出现（要放在 bdrip/bdremux 之后判）
    if (RegExp(r'(?<![0-9a-z])bd(?![0-9a-z])').hasMatch(lower)) return 'BluRay';
    return null;
  }

  /// 视频编码归一化。
  static String? _videoCodecOf(String lower) {
    if (RegExp(r'(?<![0-9a-z])x265(?![0-9a-z])').hasMatch(lower)) return 'H.265';
    if (RegExp(r'(?<![0-9a-z])h\.?265(?![0-9a-z])').hasMatch(lower)) return 'H.265';
    if (RegExp(r'(?<![0-9a-z])hevc(?![0-9a-z])').hasMatch(lower)) return 'H.265';
    if (RegExp(r'(?<![0-9a-z])x264(?![0-9a-z])').hasMatch(lower)) return 'H.264';
    if (RegExp(r'(?<![0-9a-z])h\.?264(?![0-9a-z])').hasMatch(lower)) return 'H.264';
    if (RegExp(r'(?<![0-9a-z])avc(?![0-9a-z])').hasMatch(lower)) return 'H.264';
    if (RegExp(r'(?<![0-9a-z])av1(?![0-9a-z])').hasMatch(lower)) return 'AV1';
    if (RegExp(r'(?<![0-9a-z])vp9(?![0-9a-z])').hasMatch(lower)) return 'VP9';
    if (RegExp(r'(?<![0-9a-z])xvid(?![0-9a-z])').hasMatch(lower)) return 'Xvid';
    if (RegExp(r'(?<![0-9a-z])divx(?![0-9a-z])').hasMatch(lower)) return 'DivX';
    if (RegExp(r'(?<![0-9a-z])mpeg-?2(?![0-9a-z])').hasMatch(lower)) return 'MPEG-2';
    return null;
  }

  /// 音轨编码归一化。
  ///
  /// ⚠️ 尾部的边界守卫是 `(?![a-z])` 而**不是** `(?![0-9a-z])`：
  /// 声道数会紧贴在编码后面（`DDP5.1` / `DTS5.1`），用后者的话
  /// `dd[p+]?` 匹配到 `ddp` 后一看后面是 `5` 就整个放弃 ——
  /// 于是发布名里最常见的 `DDP5.1` 反而识别不出来。
  /// 左边仍然卡 `(?<![0-9a-z])`，所以 `EAC3` 里的 `ac3`、
  /// `hddvd` 里的 `dd` 都不会被误命中。
  static String? _audioCodecOf(String lower) {
    if (RegExp(r'(?<![0-9a-z])dts-?hd(?![a-z])').hasMatch(lower)) {
      return 'DTS-HD';
    }
    if (RegExp(r'(?<![0-9a-z])dts-?x(?![a-z])').hasMatch(lower)) return 'DTS:X';
    if (RegExp(r'(?<![0-9a-z])dts(?![a-z])').hasMatch(lower)) return 'DTS';
    if (RegExp(r'(?<![0-9a-z])truehd(?![a-z])').hasMatch(lower)) return 'TrueHD';
    if (RegExp(r'(?<![0-9a-z])atmos(?![a-z])').hasMatch(lower)) return 'Atmos';
    if (RegExp(r'(?<![0-9a-z])eac3(?![a-z])').hasMatch(lower)) return 'EAC3';
    if (RegExp(r'(?<![0-9a-z])ac3(?![a-z])').hasMatch(lower)) return 'AC3';
    if (RegExp(r'(?<![0-9a-z])dd[p+]?(?![a-z])').hasMatch(lower)) return 'DDP';
    if (RegExp(r'(?<![0-9a-z])aac(?![a-z])').hasMatch(lower)) return 'AAC';
    if (RegExp(r'(?<![0-9a-z])flac(?![a-z])').hasMatch(lower)) return 'FLAC';
    if (RegExp(r'(?<![0-9a-z])opus(?![a-z])').hasMatch(lower)) return 'Opus';
    if (RegExp(r'(?<![0-9a-z])mp3(?![a-z])').hasMatch(lower)) return 'MP3';
    if (RegExp(r'(?<![0-9a-z])lpcm(?![a-z])').hasMatch(lower)) return 'LPCM';
    return null;
  }

  /// 其他标记集合（大小写归一成展示名）。
  static Set<String> _flagsOf(String lower) {
    final out = <String>{};
    if (RegExp(r'hdr10\+').hasMatch(lower)) {
      out.add('HDR10+');
    } else if (RegExp(r'(?<![0-9a-z])hdr10(?![0-9a-z])').hasMatch(lower)) {
      out.add('HDR10');
    } else if (RegExp(r'(?<![0-9a-z])hdr(?![0-9a-z])').hasMatch(lower)) {
      out.add('HDR');
    }
    if (RegExp(r'dolby\s?vision').hasMatch(lower) ||
        RegExp(r'(?<![0-9a-z])(?:dovi|dv)(?![0-9a-z])').hasMatch(lower)) {
      out.add('杜比视界');
    }
    if (RegExp(r'(?<![0-9a-z])3d(?![0-9a-z])').hasMatch(lower)) out.add('3D');
    if (RegExp(r'(?<![0-9a-z])imax(?![0-9a-z])').hasMatch(lower)) out.add('IMAX');
    if (RegExp(r'remux').hasMatch(lower)) out.add('Remux');
    if (RegExp(r'(?<![0-9a-z])extended(?![0-9a-z])').hasMatch(lower)) {
      out.add('加长版');
    }
    if (RegExp(r'(?<![0-9a-z])uncut(?![0-9a-z])').hasMatch(lower)) {
      out.add('未删减');
    }
    if (RegExp(r'remastered').hasMatch(lower)) out.add('重制版');
    if (RegExp(r'10bit|hi10p').hasMatch(lower)) out.add('10bit');
    if (RegExp(r'(?<![0-9a-z])repack(?![0-9a-z])').hasMatch(lower)) {
      out.add('Repack');
    }
    if (RegExp(r'(?<![0-9a-z])proper(?![0-9a-z])').hasMatch(lower)) {
      out.add('Proper');
    }
    if (RegExp(r'(?<![0-9a-z])complete(?![0-9a-z])').hasMatch(lower)) {
      out.add('全集');
    }
    return out;
  }

  /// 发布组：名字末尾的 `-GROUP`。
  ///
  /// ⚠️ 必须排除「`-1080p` / `-x265`」这类**技术标记**：
  /// `Movie-1080p` 的 `1080p` 不是组名。判据是「全数字不算、命中技术词不算」。
  static String? _releaseGroupOf(String base) {
    final m = RegExp(r'-([A-Za-z0-9][A-Za-z0-9._]{1,20})$').firstMatch(base);
    if (m == null) return null;
    final g = m.group(1)!;
    if (RegExp(r'^\d+$').hasMatch(g)) return null;

    final lower = g.toLowerCase();
    if (_sourceOf(lower) != null) return null;
    if (_videoCodecOf(lower) != null) return null;
    if (_audioCodecOf(lower) != null) return null;
    if (VideoFormats.resolutionFromName(lower) != null) return null;
    return g;
  }
}
