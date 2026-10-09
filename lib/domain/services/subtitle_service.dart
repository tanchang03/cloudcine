import 'dart:typed_data';

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/file_names.dart';
import '../../core/utils/subtitle_formats.dart';
import '../../core/utils/text_encoding.dart';
import '../entities/drive_entry.dart';
import '../entities/drive_provider.dart';
import '../entities/media_item.dart';
import '../entities/subtitle_track.dart';

/// 一个视频项 + 它扫到的全部字幕引用。
class SubtitleIndexEntry {
  const SubtitleIndexEntry({required this.itemId, required this.tracks});

  final String itemId;
  final List<SubtitleTrack> tracks;

  @override
  String toString() => 'SubtitleIndexEntry($itemId, ${tracks.length} 条)';
}

/// 一次目录级字幕匹配的结果。
class SubtitleIndexResult {
  const SubtitleIndexResult({required this.entries});

  final List<SubtitleIndexEntry> entries;

  /// 展开成仓储层要的引用列表。
  List<SubtitleRef> get refs => [
        for (final e in entries)
          for (final t in e.tracks) SubtitleRef(itemId: e.itemId, track: t),
      ];

  int get matchCount => refs.length;
  bool get isEmpty => entries.isEmpty;

  @override
  String toString() =>
      'SubtitleIndexResult(${entries.length} 个视频 / $matchCount 条字幕)';
}

/// 字幕**索引器**：把「同目录的一堆字幕文件」对到「同目录的视频」上。
///
/// ## 为什么按目录而不是按全盘
///
/// 网盘上字幕与视频几乎总是同目录（发布组打包时就放一起），而全盘匹配
/// 需要把所有视频名都拉到内存做笛卡尔积比对 —— 一次扫描几千个视频时
/// 那是 O(n·m) 的字符串比较。按目录做是 O(每个目录内部)，
/// 而且**更准**：跨目录的「同名文件」往往压根不是同一部片子
/// （`S01E01` 这种名字在几十个剧集目录里都会出现）。
///
/// ## 只写引用，不读正文
///
/// 扫描阶段**不下载字幕内容**。理由与参考项目的歌词索引一致：
/// 每个字幕都是一次取链 + 一次下载请求，而夸克接口有 QPS 限制；
/// 一个几千部片子的媒体库会因此多出几千次请求，其中大部分字幕
/// 用户永远不会看。正文等真的打开那部片子时再读（见 [SubtitleResolver]）。
class SubtitleIndexer {
  const SubtitleIndexer();

  /// 把一个目录里的字幕文件对到该目录的媒体项上。
  ///
  /// [items] 必须是**同一个目录**里扫出来的媒体项。
  SubtitleIndexResult indexDirectory({
    required List<MediaItem> items,
    required List<DriveEntry> subtitleFiles,
  }) {
    if (items.isEmpty || subtitleFiles.isEmpty) {
      return const SubtitleIndexResult(entries: []);
    }

    // 预计算每个媒体项的归一化名字，避免内层循环里重复做正则。
    final itemKeys = [
      for (final it in items)
        (
          item: it,
          full: _normalize(baseNameOf(it.name)),
          titleOnly: _normalize(it.title ?? ''),
        ),
    ];

    final byItem = <String, List<SubtitleTrack>>{};

    for (final file in subtitleFiles) {
      if (!SubtitleFormats.isSubtitleFile(file.name)) continue;

      final subFull = _normalize(SubtitleFormats.stripSubtitleTags(file.name));
      final subBare = _normalize(baseNameOf(file.name));

      final best = _pickBest(
        itemKeys: itemKeys,
        subFull: subFull,
        subBare: subBare,
        subtitleName: file.name,
      );
      if (best == null) {
        diag.info('字幕', '对不上任何视频，跳过：${file.name}');
        continue;
      }

      final track = _buildTrack(
        itemId: best.item.id,
        file: file,
        item: best.item,
      );
      byItem.putIfAbsent(best.item.id, () => <SubtitleTrack>[]).add(track);
    }

    final entries = byItem.entries
        .map((e) => SubtitleIndexEntry(itemId: e.key, tracks: e.value))
        .toList();
    return SubtitleIndexResult(entries: entries);
  }

  /// 给一个字幕文件挑最合适的视频项。**返回 `null` 表示对不上**。
  ///
  /// 打分从严格到宽松，取分最低者；同分时取「名字长度差最小」的，
  /// 让 `Movie.2023.1080p.chs.srt` 优先落到 `Movie.2023.1080p.mkv`
  /// 而不是 `Movie.2023.2160p.mkv`。
  ({MediaItem item, int score, int lengthDelta})? _pickBest({
    required List<({MediaItem item, String full, String titleOnly})> itemKeys,
    required String subFull,
    required String subBare,
    required String subtitleName,
  }) {
    ({MediaItem item, int score, int lengthDelta})? best;

    for (final k in itemKeys) {
      var score = -1;

      // ① 去掉语言标记后完全同名 —— 最强的信号
      if (subFull.isNotEmpty && subFull == k.full) {
        score = 0;
      } else if (subBare == k.full) {
        score = 0;
      } else if (subFull.isNotEmpty &&
          (k.full.startsWith(subFull) || subFull.startsWith(k.full)) &&
          _minLen(subFull, k.full) >= 4) {
        // ② 一方是另一方的前缀（`Movie.2023.chs` vs `Movie.2023.1080p`）
        score = 1;
      } else if (k.titleOnly.isNotEmpty &&
          subFull.contains(k.titleOnly) &&
          k.titleOnly.length >= 2) {
        // ③ 字幕名里含视频标题
        score = 2;
      } else {
        // ④ 同目录同集号（`S02E05.chs.ass` 对 `Show.S02E05.mkv`）
        final subEp = _episodeOf(subtitleName);
        if (subEp != null && subEp == k.item.episode) score = 3;
      }

      if (score < 0) continue;

      final delta = (subFull.length - k.full.length).abs();
      if (best == null ||
          score < best.score ||
          (score == best.score && delta < best.lengthDelta)) {
        best = (item: k.item, score: score, lengthDelta: delta);
      }
    }

    // ⑤ 该目录只有一个视频时，**任何**字幕都归它。
    //    这是很常见的真实布局：`/电影/流浪地球2/movie.mkv` + `chs.srt`。
    if (best == null && itemKeys.length == 1) {
      return (item: itemKeys.first.item, score: 9, lengthDelta: 0);
    }
    return best;
  }

  SubtitleTrack _buildTrack({
    required String itemId,
    required DriveEntry file,
    required MediaItem item,
  }) {
    final lang = SubtitleFormats.languageFromName(file.name);
    final format = SubtitleFormats.formatOf(file.name);
    return SubtitleTrack(
      id: '$itemId#${file.id}',
      origin: SubtitleOrigin.cloudFile,
      label: lang?.label ?? baseNameOf(file.name),
      format: format,
      language: lang,
      fileId: file.id,
      fileName: file.name,
      isForced: SubtitleFormats.isForced(file.name),
      isSdh: SubtitleFormats.isSdh(file.name),
      isExternal: true,
    );
  }

  static int _minLen(String a, String b) =>
      a.length < b.length ? a.length : b.length;

  /// 归一化：小写 + 只留字母数字与汉字。
  static String _normalize(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]'), '');

  /// 从文件名里抠集号（`S02E05` / `E05` / `第5集` / `05`）。
  static int? _episodeOf(String fileName) {
    final s = baseNameOf(fileName).toLowerCase();
    final se = RegExp(r's\d{1,2}e(\d{1,3})').firstMatch(s);
    if (se != null) return int.tryParse(se.group(1)!);
    final e = RegExp(r'(?<![0-9a-z])ep?(\d{1,3})(?![0-9a-z])').firstMatch(s);
    if (e != null) return int.tryParse(e.group(1)!);
    final cn = RegExp(r'第\s*(\d{1,4})\s*[集话話]').firstMatch(s);
    if (cn != null) return int.tryParse(cn.group(1)!);
    return null;
  }
}

/// 取到的字幕内容。
///
/// 两种形态对应 mpv 的两种加载方式（见 `media_kit` 的 `SubtitleTrack.data`
/// 与 `SubtitleTrack.uri`）：
///   - [text]：**已解码的 UTF-8 文本**，交给播放器自己落盘（它会随播放器
///     销毁一起清理）
///   - [path]：本机已有的字幕文件路径，直接交给 mpv
///
/// 之所以区分而不是统一落成临时文件：网盘字幕的**编码**必须由我们控制
/// （见 [SubtitleResolver] 的类文档），落盘只是手段；本地文件本来就是
/// 用户自己放的，不该被我们复制一份。
class ResolvedSubtitle {
  const ResolvedSubtitle.text(String this.text) : path = null;
  const ResolvedSubtitle.file(String this.path) : text = null;

  /// 已解码的字幕正文（网盘字幕）
  final String? text;

  /// 本机字幕路径（用户从磁盘选的字幕）
  final String? path;

  bool get isText => text != null;

  @override
  String toString() =>
      isText ? 'ResolvedSubtitle.text(${text!.length} 字符)' : 'ResolvedSubtitle.file($path)';
}

/// 字幕**取用器**：把一条字幕变成播放器能直接加载的东西。
///
/// ## 为什么网盘字幕必须由我们解码
///
/// 两个硬约束，任何一个不解决都表现为「字幕用不了」：
///
/// 1. **请求头**。夸克直链缺 Cookie 一律 `412`。`media_kit` 的
///    `SubtitleTrack.uri` / `.data` 都**没有请求头参数** —— 视频可以用
///    `Media(uri, httpHeaders:)`，字幕不行。所以字幕的字节必须由我们自己
///    取回来（走 `CloudDriveAdapter.readFileBytes`）。
/// 2. **编码**。中文外挂字幕大量是 GBK。mpv 对 GBK 的自动探测经常失败，
///    结果是满屏乱码。我们自己解码（[decodeTextBytes]：先严格 UTF-8、
///    失败再 GBK）再交给播放器，能把这一类问题**根治**。
class SubtitleResolver {
  SubtitleResolver({
    required Future<Uint8List> Function(DriveProvider provider, String fileId)
        readBytes,
  }) : _readBytes = readBytes;

  /// 取字节。**必须带上网盘** —— 见 [load] 的说明。
  final Future<Uint8List> Function(DriveProvider provider, String fileId)
      _readBytes;

  /// 已取回的字幕（trackId → 内容），避免同一次会话内重复下载。
  final Map<String, ResolvedSubtitle> _cache = {};

  /// 取一条字幕的内容。
  ///
  /// [SubtitleOrigin.embedded] 会抛 —— 内嵌轨由播放器自己切轨，没有内容
  /// 可取（它的字节在视频文件里）。
  ///
  /// ## ⛔ 为什么 [provider] 必须由调用方给，而不是内部去问「当前网盘」
  ///
  /// 媒体库是**多家网盘混在一个库里**的（主键是 `provider:fileId`），
  /// 所以「当前网盘」这个概念不存在。字幕的 fid 只在**它自己那家**网盘里
  /// 有效，用错一家去 `readFileBytes` 的后果是 404 / 参数错 ——
  /// 表现为「字幕加载失败」，而用户完全看不出是网盘选错了。
  ///
  /// 调用方手上一定有正确的值：内置播放页有 `MediaItem.provider`，
  /// 独立播放窗口有 `PlayRequest.itemId` 的前缀。
  Future<ResolvedSubtitle> load(
    SubtitleTrack track, {
    required DriveProvider provider,
  }) async {
    if (track.origin == SubtitleOrigin.embedded) {
      throw ArgumentError('内嵌字幕不需要取内容，应由播放器切轨');
    }

    final cached = _cache[track.id];
    if (cached != null) return cached;

    if (track.origin == SubtitleOrigin.localFile) {
      final p = track.localPath;
      if (p == null || p.isEmpty) {
        throw ArgumentError('本地字幕缺少路径：${track.displayLabel}');
      }
      final resolved = ResolvedSubtitle.file(p);
      _cache[track.id] = resolved;
      return resolved;
    }

    final fileId = track.fileId;
    if (fileId == null || fileId.isEmpty) {
      throw ArgumentError('网盘字幕缺少文件 ID：${track.displayLabel}');
    }

    diag.info(
      '字幕',
      '开始取字幕字节 fid=$fileId（${track.fileName ?? "-"}，'
          '网盘=${provider.displayName}）',
    );
    final bytes = await _readBytes(provider, fileId);

    // 解码 → 统一成 UTF-8 文本。这是「中文不乱码」的关键一步。
    final text = decodeTextBytes(bytes);
    diag.info(
      '字幕',
      '字幕已解码：${track.fileName ?? fileId} '
      '原始 ${bytes.length}B → ${text.length} 字符',
    );

    final resolved = ResolvedSubtitle.text(text);
    _cache[track.id] = resolved;
    return resolved;
  }

  /// 清空缓存（换片子时调用）。
  void clear() => _cache.clear();
}
