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
    this.resolution,
    this.source,
    this.videoCodec,
    this.audioCodec,
    this.flags = const {},
    this.releaseGroup,
    this.isSampleOrExtra = false,
    this.isDiscImage = false,
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

  /// 分卷号（`CD1` / `Disc2` / `Part1`）。
  final int? part;

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
    final t = (title ?? baseNameOf(rawName)).toLowerCase();
    final cleaned = t.replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]'), '');
    final y = year;
    final yearPart = y == null ? '' : '#$y';
    return kind == MediaKind.episode ? cleaned : '$cleaned$yearPart';
  }

  /// 解析是否拿到了「足够可信」的结果（用于决定要不要走在线刮削）。
  bool get isConfident => kind != MediaKind.unknown &&
      (title ?? '').isNotEmpty &&
      (year != null || kind == MediaKind.episode);

  @override
  String toString() => 'ParsedMediaName(${kind.name}, "$title", '
      'y=$year s=$season e=$episode${episodeEnd == null ? "" : "-$episodeEnd"}, '
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
  ParsedMediaName parse(String fileName, {String? dirName}) {
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

    if ((title == null || title.isEmpty) && dirName != null && dirName.isNotEmpty) {
      final fromDir = _parseDotted(dirName);
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
      resolution: resolution,
      source: parsed.source,
      videoCodec: parsed.videoCodec,
      audioCodec: parsed.audioCodec,
      flags: parsed.flags,
      releaseGroup: parsed.releaseGroup,
      isSampleOrExtra: isSample,
      isDiscImage: isDisc,
    );
  }

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
    RegExp(r'(?<![0-9a-z])e(?:p)?\d{1,3}(?![0-9a-z])', caseSensitive: false),
    RegExp(r'第\s*\d{1,4}\s*[集话話]'),
    RegExp(r'(?<![0-9a-z])s\d{1,2}(?![0-9a-z])', caseSensitive: false),
    RegExp(r'season\s*\d{1,2}', caseSensitive: false),
    RegExp(r'第\s*[一二三四五六七八九十\d]{1,3}\s*季'),
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

    final title = _cleanTitle(rawTitle);
    final scripts = _splitScripts(title ?? '');

    final lower = cleaned.toLowerCase();
    final tv = _matchEpisodePattern(lower);
    final resolution = VideoFormats.resolutionFromName(cleaned);
    final year = _pickYear(cleaned, markerStart);

    final flags = _flagsOf(lower);
    final kind = (tv != null)
        ? MediaKind.episode
        : ((title ?? '').isNotEmpty
            ? MediaKind.movie
            : MediaKind.unknown);

    return ParsedMediaName(
      rawName: base,
      kind: kind,
      title: title,
      cjkTitle: scripts.cjk,
      latinTitle: scripts.latin,
      year: year,
      season: tv?.season,
      episode: tv?.episode,
      episodeEnd: tv?.episodeEnd,
      part: _partOf(lower),
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
  static int? _pickYear(String cleaned, int markerStart) {
    final re = RegExp(r'(?<![0-9])(19\d{2}|20\d{2})(?![0-9])');

    if (markerStart >= 0) {
      final tail = cleaned.substring(markerStart);
      final m = re.firstMatch(tail);
      final y = m == null ? null : int.tryParse(m.group(1)!);
      if (y != null) return _saneYear(y);
    }
    for (final m in re.allMatches(cleaned)) {
      final y = _saneYear(int.parse(m.group(1)!));
      if (y != null) return y;
    }
    return null;
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
    final ep = RegExp(r'(?<![0-9a-z])ep?(\d{1,3})(?![0-9a-z])')
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
    final raw = m.group(1)!;
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

  /// 分卷号：`CD1` / `Disc 2` / `Part3` / `DVD1`。
  static int? _partOf(String lower) {
    final m = RegExp(r'(?<![0-9a-z])(?:cd|disc|disk|part|dvd)\s*(\d{1,2})(?![0-9a-z])')
        .firstMatch(lower);
    return m == null ? null : int.tryParse(m.group(1)!);
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
