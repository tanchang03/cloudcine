/// 字幕格式识别与「文件名里的语言标记」解析。
///
/// 这里的判定全部只依赖文件名，因为**扫描阶段读不到字幕内容**：夸克网盘
/// 上每个字幕文件都是一次额外的取链 + 下载请求，一次全盘扫描会因此多出
/// 成千上万次请求。所以：
///   - 扫描期只建立「哪个字幕属于哪个视频」的**引用**（本文件负责其中的
///     文件名判据）；
///   - 正文等用户真的打开那部片子时再读（见 `SubtitleResolver`）。
///
/// 与参考项目的歌词索引同一个取向（只写引用、不读正文）。
library;

import 'file_names.dart';

/// 字幕文件扩展名。
///
/// 只收**文本/位图字幕**，不收 `txt`：
/// `txt` 在网盘里更多是说明文档，混进来会让每部片子都多出几个假字幕。
const Set<String> kSubtitleExtensions = {
  'srt', 'ass', 'ssa', 'vtt', 'webvtt', 'sub', 'idx', 'smi', 'sami',
  'ttml', 'dfxp', 'sup', 'pgs', 'mks',
};

/// 字幕容器格式。
enum SubtitleFormat {
  srt('SRT'),
  ass('ASS'),
  ssa('SSA'),
  vtt('VTT'),
  microDvd('SUB'),
  vobSub('IDX'),
  sami('SAMI'),
  ttml('TTML'),
  pgs('PGS'),
  mks('MKS'),
  other('字幕');

  const SubtitleFormat(this.label);

  final String label;

  /// 是否是**纯文本**字幕。
  ///
  /// 这个区分有实际后果：位图字幕（PGS/VobSub）在 mpv 里靠 `--sub-*`
  /// 选项无法改字号/描边，UI 上的「字幕样式」设置对它们无效，必须置灰。
  bool get isText =>
      this == srt || this == ass || this == ssa || this == vtt ||
      this == microDvd || this == sami || this == ttml;

  /// 是否带完整排版（能被 libass 渲染出特效字幕）。
  bool get isRichText => this == ass || this == ssa;
}

/// 字幕语言标识。
class SubtitleLanguage {
  const SubtitleLanguage({required this.code, required this.label});

  /// 归一化语言码：`zh-Hans` / `zh-Hant` / `zh` / `en` / `ja` / `ko` …
  final String code;

  /// 展示名：`简体中文` / `繁体中文` / `英文` …
  final String label;

  @override
  bool operator ==(Object other) =>
      other is SubtitleLanguage && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => '$label($code)';
}

/// 字幕格式工具集。纯函数，可单测。
class SubtitleFormats {
  const SubtitleFormats._();

  /// 是否为字幕文件。
  static bool isSubtitleFile(String fileName) =>
      hasExtension(fileName, kSubtitleExtensions);

  /// 容器识别。认不出来返回 [SubtitleFormat.other]。
  static SubtitleFormat formatOf(String fileName) {
    return switch (extensionOf(fileName)) {
      'srt' => SubtitleFormat.srt,
      'ass' => SubtitleFormat.ass,
      'ssa' => SubtitleFormat.ssa,
      'vtt' || 'webvtt' => SubtitleFormat.vtt,
      'sub' => SubtitleFormat.microDvd,
      'idx' => SubtitleFormat.vobSub,
      'smi' || 'sami' => SubtitleFormat.sami,
      'ttml' || 'dfxp' => SubtitleFormat.ttml,
      'sup' || 'pgs' => SubtitleFormat.pgs,
      'mks' => SubtitleFormat.mks,
      _ => SubtitleFormat.other,
    };
  }

  // -------------------------------------------------------------------
  // 语言标记
  // -------------------------------------------------------------------

  /// `zh-Hans` 家族的写法。
  ///
  /// ⚠️ 必须**先判繁体再判简体**，且 `cht` 要排在 `ch` 前面 ——
  /// `chs`/`cht`/`ch` 互为前缀，顺序错了会把 `cht` 认成 `ch`。
  static const Map<String, SubtitleLanguage> _langTokens = {
    // 简体
    'chs': SubtitleLanguage(code: 'zh-Hans', label: '简体中文'),
    'sc': SubtitleLanguage(code: 'zh-Hans', label: '简体中文'),
    'gb': SubtitleLanguage(code: 'zh-Hans', label: '简体中文'),
    'gbk': SubtitleLanguage(code: 'zh-Hans', label: '简体中文'),
    'gb2312': SubtitleLanguage(code: 'zh-Hans', label: '简体中文'),
    'zh-cn': SubtitleLanguage(code: 'zh-Hans', label: '简体中文'),
    'zh-hans': SubtitleLanguage(code: 'zh-Hans', label: '简体中文'),
    'zhcn': SubtitleLanguage(code: 'zh-Hans', label: '简体中文'),
    '简体': SubtitleLanguage(code: 'zh-Hans', label: '简体中文'),
    '简中': SubtitleLanguage(code: 'zh-Hans', label: '简体中文'),
    '简': SubtitleLanguage(code: 'zh-Hans', label: '简体中文'),
    // 繁体
    'cht': SubtitleLanguage(code: 'zh-Hant', label: '繁体中文'),
    'tc': SubtitleLanguage(code: 'zh-Hant', label: '繁体中文'),
    'big5': SubtitleLanguage(code: 'zh-Hant', label: '繁体中文'),
    'zh-tw': SubtitleLanguage(code: 'zh-Hant', label: '繁体中文'),
    'zh-hk': SubtitleLanguage(code: 'zh-Hant', label: '繁体中文'),
    'zh-hant': SubtitleLanguage(code: 'zh-Hant', label: '繁体中文'),
    'zhtw': SubtitleLanguage(code: 'zh-Hant', label: '繁体中文'),
    '繁体': SubtitleLanguage(code: 'zh-Hant', label: '繁体中文'),
    '繁中': SubtitleLanguage(code: 'zh-Hant', label: '繁体中文'),
    '繁': SubtitleLanguage(code: 'zh-Hant', label: '繁体中文'),
    // 中英双语
    '中英': SubtitleLanguage(code: 'zh-en', label: '中英双语'),
    '双语': SubtitleLanguage(code: 'zh-en', label: '中英双语'),
    '中英双语': SubtitleLanguage(code: 'zh-en', label: '中英双语'),
    'eng-chs': SubtitleLanguage(code: 'zh-en', label: '中英双语'),
    'zh-en': SubtitleLanguage(code: 'zh-en', label: '中英双语'),
    // 中文（不分简繁）
    'ch': SubtitleLanguage(code: 'zh', label: '中文'),
    'zh': SubtitleLanguage(code: 'zh', label: '中文'),
    'chi': SubtitleLanguage(code: 'zh', label: '中文'),
    'zho': SubtitleLanguage(code: 'zh', label: '中文'),
    '中文': SubtitleLanguage(code: 'zh', label: '中文'),
    '中字': SubtitleLanguage(code: 'zh', label: '中文'),
    // 其他语言
    'en': SubtitleLanguage(code: 'en', label: '英文'),
    'eng': SubtitleLanguage(code: 'en', label: '英文'),
    'english': SubtitleLanguage(code: 'en', label: '英文'),
    '英文': SubtitleLanguage(code: 'en', label: '英文'),
    'ja': SubtitleLanguage(code: 'ja', label: '日文'),
    'jpn': SubtitleLanguage(code: 'ja', label: '日文'),
    'jp': SubtitleLanguage(code: 'ja', label: '日文'),
    'japanese': SubtitleLanguage(code: 'ja', label: '日文'),
    '日文': SubtitleLanguage(code: 'ja', label: '日文'),
    'ko': SubtitleLanguage(code: 'ko', label: '韩文'),
    'kor': SubtitleLanguage(code: 'ko', label: '韩文'),
    'korean': SubtitleLanguage(code: 'ko', label: '韩文'),
    '韩文': SubtitleLanguage(code: 'ko', label: '韩文'),
    'fr': SubtitleLanguage(code: 'fr', label: '法文'),
    'fra': SubtitleLanguage(code: 'fr', label: '法文'),
    'fre': SubtitleLanguage(code: 'fr', label: '法文'),
    'de': SubtitleLanguage(code: 'de', label: '德文'),
    'ger': SubtitleLanguage(code: 'de', label: '德文'),
    'deu': SubtitleLanguage(code: 'de', label: '德文'),
    'es': SubtitleLanguage(code: 'es', label: '西班牙文'),
    'spa': SubtitleLanguage(code: 'es', label: '西班牙文'),
    'ru': SubtitleLanguage(code: 'ru', label: '俄文'),
    'rus': SubtitleLanguage(code: 'ru', label: '俄文'),
    'it': SubtitleLanguage(code: 'it', label: '意大利文'),
    'ita': SubtitleLanguage(code: 'it', label: '意大利文'),
    'pt': SubtitleLanguage(code: 'pt', label: '葡萄牙文'),
    'por': SubtitleLanguage(code: 'pt', label: '葡萄牙文'),
  };

  /// 语言标记在文件名里的形态：`.chs.` / `.zh-CN.` / `[简体]` / `_繁体_`。
  ///
  /// 分隔符集合取 `[._\-\[\]()\s]`，因为字幕名从
  /// `Movie.2023.chs.srt` 到 `Movie.2023[简体].srt` 都有。
  static final RegExp _langSegment = RegExp(
    r'[._\-\[\]()\s]'
    r'([a-zA-Z\u4e00-\u9fff]{1,10})'
    r'(?=[._\-\[\]()\s]|$)',
  );

  /// 从文件名里推断字幕语言。认不出来返回 `null`。
  ///
  /// 扫描**所有**分段而不是只看最后一段：真实命名里
  /// `Movie.2023.1080p.BluRay.chs.ass` 的语言在倒数第二段，
  /// `Movie.chs.2023.srt` 在中间。
  ///
  /// 同一名字里命中多个标记时（`Movie.chs.eng.srt`）取**第一个** ——
  /// 发布组的习惯是把主字幕语言放前面。
  static SubtitleLanguage? languageFromName(String fileName) {
    final stem = baseNameOf(fileName).toLowerCase();

    // 先跑一遍「整段精确匹配」，这是绝大多数真实命名的形态。
    for (final m in _langSegment.allMatches(stem)) {
      final token = m.group(1);
      if (token == null) continue;
      final hit = _langTokens[token];
      if (hit != null) return hit;
    }

    // 兜底：连着写的 `Moviechs` 这类。仍然要求命中**完整**语言词，
    // 避免 `chen`（人名）被 `ch` 命中。
    for (final entry in _langTokens.entries) {
      final key = entry.key;
      // 短键（≤2 字符）不做子串匹配，误命中率太高。
      if (key.length <= 2) continue;
      if (stem.contains(key)) return entry.value;
    }
    return null;
  }

  /// 是否为「强制字幕」（只翻译外语对白，不覆盖全片）。
  ///
  /// 判据是文件名里的 `forced` / `强制` 标记。
  static bool isForced(String fileName) {
    final s = baseNameOf(fileName).toLowerCase();
    return s.contains('forced') || s.contains('强制') || s.contains('.frc.');
  }

  /// 是否为「听力障碍字幕」（带音效描述）。
  static bool isSdh(String fileName) {
    final s = baseNameOf(fileName).toLowerCase();
    return s.contains('sdh') ||
        s.contains('hi.') ||
        s.contains('.hi') ||
        s.contains('听障') ||
        s.contains('cc字幕');
  }

  /// 去掉语言/属性标记后的「作品名干」，用于与视频文件名比对。
  ///
  /// 例：`Movie.2023.1080p.chs&eng.ass` → `movie 2023 1080p`
  ///
  /// ⚠️ 这里**故意把分辨率/来源一起保留**：同一个目录里经常同时有
  /// `Movie.2023.1080p.mkv` 和 `Movie.2023.2160p.mkv`，把技术标记也剥掉
  /// 会让两个字幕都同时匹配到两部片子。
  static String stripSubtitleTags(String fileName) {
    var stem = baseNameOf(fileName).toLowerCase();

    // 去掉语言段
    stem = stem.replaceAllMapped(_langSegment, (m) {
      final token = m.group(1) ?? '';
      return _langTokens.containsKey(token) ? ' ' : m.group(0)!;
    });

    for (final word in const ['forced', 'sdh', 'default', '强制', '听障']) {
      stem = stem.replaceAll(word, ' ');
    }
    return stem;
  }
}
