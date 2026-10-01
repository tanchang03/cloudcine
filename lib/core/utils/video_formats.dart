/// 视频容器与分辨率识别。
///
/// 与音频侧的设计取向一致：**识别只做「这是什么」，不做「能不能播」**。
/// 能不能播由 `PlaybackController` 在运行时裁决 —— 扫描期把大批其实能播的
/// 文件标成「不可播」，是参考项目踩过的坑（夸克 download 路由的 50MiB 限制
/// 曾让 43.9% 的曲目被误判）。
///
/// 视频侧的额外理由：本应用用 **mpv**（`media_kit`）做播放后端，它对容器的
/// 容忍度远高于平台自带解码器 —— MKV/AVI/TS/RMVB 这些「平台播放器播不了」
/// 的格式 mpv 基本都能解。所以这里的容器识别**只用于展示与排序**，
/// 不用来当播放闸门。
library;

/// 视频容器类型。
///
/// `label` 用于 UI 展示，取值是用户能认得的短名。
enum VideoContainer {
  mp4('MP4'),
  matroska('MKV'),
  avi('AVI'),
  quicktime('MOV'),
  asf('WMV'),
  flash('FLV'),
  webm('WebM'),
  mpegTs('TS'),
  mpegPs('MPG'),
  realMedia('RMVB'),
  ogg('OGV'),
  vob('VOB'),
  other('视频');

  const VideoContainer(this.label);

  final String label;

  /// 是否属于「主流分发格式」。
  ///
  /// 只影响列表里的一个弱标记，不代表可播性。
  bool get isMainstream =>
      this == mp4 || this == matroska || this == avi || this == quicktime;
}

/// 分辨率档位。
///
/// 值域刻意**离散**：文件名里能可靠拿到的只有「480/720/1080/2160」这几档，
/// 硬解成像素宽高会在遇到 `1920x800`（宽银幕裁切）这类值时产生误导。
enum VideoResolution {
  sd480(480, '480P'),
  hd720(720, '720P'),
  fhd1080(1080, '1080P'),
  qhd1440(1440, '1440P'),
  uhd2160(2160, '2160P'),
  uhd4320(4320, '4320P');

  const VideoResolution(this.height, this.label);

  /// 标称高度（像素）
  final int height;

  /// 展示名，如 `1080P`
  final String label;

  /// 该档在 16:9 下的**长边**像素数（480P→854、720P→1280、1080P→1920…）。
  ///
  /// 归挡实测尺寸时用长边而不是 [height]：宽银幕裁切（`3840x1632`）按高度会
  /// 掉到 1440P，按长边才落在 2160P。实测依据见
  /// `VideoFormats.resolutionFromDimensions`。
  int get longSide => switch (this) {
        VideoResolution.sd480 => 854,
        VideoResolution.hd720 => 1280,
        VideoResolution.fhd1080 => 1920,
        VideoResolution.qhd1440 => 2560,
        VideoResolution.uhd2160 => 3840,
        VideoResolution.uhd4320 => 7680,
      };

  /// 习惯叫法，用于 UI 上更口语化的位置，如 `4K`。
  String get marketingLabel => switch (this) {
        VideoResolution.uhd2160 => '4K',
        VideoResolution.uhd4320 => '8K',
        VideoResolution.qhd1440 => '2K',
        _ => label,
      };
}

/// 视频格式工具集。全部是纯函数，便于单元测试。
class VideoFormats {
  const VideoFormats._();

  /// 扩展名 → 容器。
  ///
  /// 覆盖主流分发格式与国内常见格式。**不追求穷尽**：认不出来归
  /// [VideoContainer.other]，仍会被索引成媒体项（mpv 很可能还是能播）。
  static const Map<String, VideoContainer> _byExtension = {
    'mp4': VideoContainer.mp4,
    'm4v': VideoContainer.mp4,
    'mp4v': VideoContainer.mp4,
    'mkv': VideoContainer.matroska,
    'mk3d': VideoContainer.matroska,
    'webm': VideoContainer.webm,
    'avi': VideoContainer.avi,
    'divx': VideoContainer.avi,
    'mov': VideoContainer.quicktime,
    'qt': VideoContainer.quicktime,
    'wmv': VideoContainer.asf,
    'asf': VideoContainer.asf,
    'flv': VideoContainer.flash,
    'f4v': VideoContainer.flash,
    'ts': VideoContainer.mpegTs,
    'm2ts': VideoContainer.mpegTs,
    'mts': VideoContainer.mpegTs,
    'tp': VideoContainer.mpegTs,
    'mpg': VideoContainer.mpegPs,
    'mpeg': VideoContainer.mpegPs,
    'm2v': VideoContainer.mpegPs,
    'vob': VideoContainer.vob,
    'rmvb': VideoContainer.realMedia,
    'rm': VideoContainer.realMedia,
    'ogv': VideoContainer.ogg,
    'ogm': VideoContainer.ogg,
    '3gp': VideoContainer.mp4,
    '3g2': VideoContainer.mp4,
    'iso': VideoContainer.other,
    'mxf': VideoContainer.other,
  };

  /// 全部已知视频扩展名。
  static Set<String> get extensions => _byExtension.keys.toSet();

  /// 取小写扩展名（不含点）。没有扩展名返回 `null`。
  ///
  /// 用**最后一个点**切分：`The.Wandering.Earth.II.2023.mkv` 的扩展名是
  /// `mkv` 而不是 `2023.mkv`。
  static String? extensionOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0 || dot == fileName.length - 1) return null;
    return fileName.substring(dot + 1).toLowerCase();
  }

  /// 是否为视频文件。
  ///
  /// [mimeType] 是**辅助**信号（夸克会给 `video/mp4` 这类值）：有些文件
  /// 扩展名缺失或古怪，MIME 能救回来。两者都不认才判否。
  static bool isVideoFile(String fileName, {String? mimeType}) {
    final ext = extensionOf(fileName);
    if (ext != null && _byExtension.containsKey(ext)) return true;
    final mime = mimeType?.toLowerCase().trim();
    if (mime != null && mime.startsWith('video/')) return true;
    return false;
  }

  /// 容器识别。认不出来返回 [VideoContainer.other]。
  static VideoContainer containerOf(String fileName, {String? mimeType}) {
    final ext = extensionOf(fileName);
    final byExt = ext == null ? null : _byExtension[ext];
    if (byExt != null) return byExt;

    // MIME 兜底：`video/x-matroska` → MKV。
    final mime = mimeType?.toLowerCase().trim() ?? '';
    if (mime.contains('matroska')) return VideoContainer.matroska;
    if (mime.contains('quicktime')) return VideoContainer.quicktime;
    if (mime.contains('x-msvideo') || mime.contains('msvideo')) {
      return VideoContainer.avi;
    }
    if (mime.contains('webm')) return VideoContainer.webm;
    if (mime.contains('mpegurl') || mime.contains('mp2t')) {
      return VideoContainer.mpegTs;
    }
    return VideoContainer.other;
  }

  /// 从文件名里猜分辨率。拿不到返回 `null`。
  ///
  /// 支持的写法：`1080p` / `1080i` / `720P` / `2160p` / `4K` / `8K` / `2K`
  /// / `1920x1080` / `3840x2160`。
  static VideoResolution? resolutionFromName(String fileName) {
    final lower = fileName.toLowerCase();

    // 先试「宽x高」这种最不含糊的写法。**取短边** —— 竖屏写法 `1080x1920` 的
    // 第二个数不是「高」而是长边，直接拿它比档位会把 1080P 的竖屏片说成 1440P。
    final dim = RegExp(r'(\d{3,4})\s*[x×]\s*(\d{3,4})').firstMatch(lower);
    if (dim != null) {
      final a = int.tryParse(dim.group(1)!);
      final b = int.tryParse(dim.group(2)!);
      final short = (a == null || b == null) ? (a ?? b) : (a < b ? a : b);
      final byShort = _byShortAxis(short);
      if (byShort != null) return byShort;
    }

    // `1080p` / `1080i` / `1080P50`（这个数本来就是档位数字，直接当短边比）
    final scan = RegExp(r'(?<!\d)(\d{3,4})\s*[pi](?!\w)').firstMatch(lower);
    if (scan != null) {
      final byShort = _byShortAxis(int.tryParse(scan.group(1)!));
      if (byShort != null) return byShort;
    }

    // `4K` / `8K` / `2K`（注意 `2K` 在很多发布组里就是 1080P，这里按
    // 标称高度 1440 归到 QHD —— 展示的是文件名声称的档位，不是实测值）
    final marketing = RegExp(r'(?<![a-z0-9])([248])\s*k(?![a-z0-9])')
        .firstMatch(lower);
    if (marketing != null) {
      return switch (marketing.group(1)) {
        '8' => VideoResolution.uhd4320,
        '4' => VideoResolution.uhd2160,
        _ => VideoResolution.qhd1440,
      };
    }

    return null;
  }

  /// 从**实测像素尺寸**归挡分辨率。
  ///
  /// ## 为什么两个轴都要看，并且取较高的那一档
  ///
  /// 只按**高度**会低估宽银幕。2026-10-01 实测（递归遍历 44 个目录、427 个视频）：
  /// **宽银幕裁切占 40%** —— `3840x1632`×59、`3840x1608`×31、`1920x804`×19、
  /// `4096x1742`×17、`3840x1636`×14、`1280x536`×1 ……
  /// 按高度归挡会把这 171 条**全部低估一档**：`3840x1632` → 1440P（它其实是
  /// 2.35:1 的 4K 电影），`1920x804` → 720P，`1280x536` → 480P。
  /// 后果不只是标签难看 —— 「同片多版本」的排序会把 4K 版排到 1080P 版**后面**，
  /// 用户选清晰度时会挑错文件。
  ///
  /// 但只按**长边**会漏掉 4:3 的老内容。DVD 时代的 `720x576`（PAL）/ `720x480`
  /// （NTSC）长边只有 720，**低于最低档 sd480 的长边 854** → 直接不成档返回
  /// `null`，界面上一部老剧连分辨率角标都没有。4:3 的 `960x720` 更别扭：
  /// 长边 960 落在 480P 档，但它是货真价实的 720 线。
  ///
  /// 所以两个轴各自算一遍，**取较高的一档**：长边兜住宽银幕，**短边**兜住 4:3。
  ///
  /// 第二个轴必须用**短边**，不能用「高」。竖屏的「高」是长边，拿它去比
  /// 480/720/1080 那排档位会平白抬高两档：`1080x1920` 的「高」1920 落在 1440P、
  /// `720x1280` 的 1280 落在 1080P。短边在横竖屏下都是那条短轴，两个方向共用
  /// 一套档位表，于是 16:9 与竖屏在两条轴上结论一致（`1920x1080`、`1080x1920`、
  /// `1440x2560` 都是同一个档），取较高的那档只在宽银幕和 4:3 两类内容上起作用。
  ///
  /// 长边这一路也与夸克自己的 `video_max_resolution` 分档一致（实测：
  /// 3840~4096 宽 245 条 → `4k`，1920 宽 182 条 → `super`，1280 宽 1 条 → `high`）。
  ///
  /// 竖屏因此不需要像 VidHub 那样专门存一个 `isVertical` 字段 —— 长边和短边在
  /// 横竖屏下都各是长边和短边，方向信息不需要单独记。
  ///
  /// 与 [resolutionFromName] 的关系：**实测优先**。文件名是发布组自己写的，
  /// 会错会缺；尺寸是服务端读文件头得到的。
  ///
  /// 两边都拿不到时返回 `null`（表示「不知道」，UI 上不显示分辨率角标）。
  static VideoResolution? resolutionFromDimensions(int? width, int? height) {
    final w = (width ?? 0) > 0 ? width : null;
    final h = (height ?? 0) > 0 ? height : null;
    if (w == null && h == null) return null;

    // 只给了一边时，把它当档位数字读（`1080` 就是 1080P）。
    // 实战里夸克两边都给（实测 427/427），这条只是兜底。
    if (w == null || h == null) return _byShortAxis(w ?? h);

    final longSide = w > h ? w : h;
    final shortSide = w < h ? w : h;

    final byLongSide = _byLongSide(longSide);
    final byShortSide = _byShortAxis(shortSide);

    if (byLongSide == null) return byShortSide;
    if (byShortSide == null) return byLongSide;
    // enum 按档位升序声明，index 大即档位高。
    return byLongSide.index >= byShortSide.index ? byLongSide : byShortSide;
  }

  /// 长边 → 档位。取「不超过给定长边的最大档位」，比的是 854/1280/1920/2560/3840。
  ///
  /// 只用于 [resolutionFromDimensions]（实测尺寸）。见那里的说明：它对宽银幕
  /// 正确，但单独用会漏掉 4:3 老内容，所以要和 [_byShortAxis] 取较高的那个。
  static VideoResolution? _byLongSide(int? longSide) {
    if (longSide == null) return null;
    VideoResolution? best;
    for (final r in VideoResolution.values) {
      if (r.longSide <= longSide) best = r;
    }
    return best;
  }

  /// 短边 → 档位。取「不超过给定像素数的最大档位」，比的是 480/720/1080/1440/2160。
  ///
  /// 名字里的「短边」是要紧的：**不要传「高」**（竖屏的高是长边，会抬高两档），
  /// 也不要传长边（宽银幕会低估）。两个调用点都传短轴：
  /// - [resolutionFromName] 传文件名里 `宽x高` 的较小值（`1920x800` → 800 → 720P）；
  /// - [resolutionFromDimensions] 传实测宽高的较小值。
  ///
  /// 保守取向：宁可标低一档，也不要把裁切过的画面说成 1080P。这个取向
  /// **正是解析文件名时想要的** —— 文件名里的数字是发布组自己写的、可能有水分。
  static VideoResolution? _byShortAxis(int? pixels) {
    if (pixels == null || pixels < 360) return null;
    VideoResolution? best;
    for (final r in VideoResolution.values) {
      if (r.height <= pixels) best = r;
    }
    return best;
  }

  /// 是否是「花絮 / 样片 / 预告」这类不该进媒体库正片的文件。
  ///
  /// 判据只看文件名（扫到的目录里经常整目录都是 sample）。
  /// 保守取向：**只有明确命中才判否**，宁可多收一个花絮，也不要把正片漏掉。
  ///
  /// ## 为什么英文标记必须按「整词」匹配
  ///
  /// 早期这里是朴素的 `base.contains(marker)`，于是 `The.Sampler.2023.mkv`
  /// 因为含子串 `sample` 被判成花絮 —— 一部正经电影从媒体库里凭空消失，
  /// 而且不会报任何错。所以英文标记一律要求**整词命中**（`.`/`-`/`_`/空格
  /// 都算词边界）；中文标记没有词边界的概念，仍然用子串匹配。
  static bool isSampleOrExtra(String fileName) {
    final base = _baseName(fileName).toLowerCase();
    final tokens = _wordTokens(base);
    for (final m in _extraMarkers) {
      if (_markerHits(base, tokens, m)) return true;
    }
    return false;
  }

  /// 不该进正片的标记。
  ///
  /// 注意 `proof` / `preview` / `interview` 本身也是常见片名单词
  /// （例如《Proof》），整词匹配只能挡住 `Sampler` 这类**词内**误命中，
  /// 挡不住「片名恰好就是这个单词」。真被误判时改这里即可。
  static const List<String> _extraMarkers = [
    'sample',
    'trailer',
    'preview',
    'teaser',
    'screener-sample',
    'proof',
    'featurette',
    'deleted.scenes',
    'behind.the.scenes',
    'interview',
    '片花',
    '预告',
    '花絮',
    '样片',
    '彩蛋',
  ];

  static final RegExp _cjkPattern = RegExp(r'[\u4e00-\u9fff]');

  static final RegExp _nonWordPattern = RegExp(r'[^a-z0-9\u4e00-\u9fff]+');

  /// 把文件名切成小写词元：非字母数字、非 CJK 的字符都当分隔符。
  static List<String> _wordTokens(String base) => base
      .split(_nonWordPattern)
      .where((t) => t.isNotEmpty)
      .toList(growable: false);

  /// [marker] 是否在 [base] 里出现。
  ///
  /// 含中文 → 子串匹配；纯英文 → 整段连续词匹配。
  static bool _markerHits(String base, List<String> tokens, String marker) {
    if (_cjkPattern.hasMatch(marker)) return base.contains(marker);

    final parts = marker
        .split(RegExp(r'[^a-z0-9]+'))
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) return false;

    for (var i = 0; i + parts.length <= tokens.length; i++) {
      var hit = true;
      for (var j = 0; j < parts.length; j++) {
        if (tokens[i + j] != parts[j]) {
          hit = false;
          break;
        }
      }
      if (hit) return true;
    }
    return false;
  }

  /// 是否是蓝光原盘/镜像这类「不是单个可播文件」的条目。
  ///
  /// `.iso` 与 `BDMV` 目录结构本应用**不索引**：mpv 无法直接播
  /// BD 导航，索引了只会得到一堆点了播不了的行。
  static bool isDiscImage(String fileName) {
    final ext = extensionOf(fileName);
    return ext == 'iso' || ext == 'img';
  }

  /// 去掉扩展名（用于标题解析与展示）。
  static String _baseName(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot <= 0 ? fileName : fileName.substring(0, dot);
  }
}
