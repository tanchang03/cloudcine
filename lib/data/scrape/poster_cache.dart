import 'dart:io';
import 'dart:typed_data';

import '../../core/diagnostics/diag_log.dart';
import '../http/http_client.dart';

/// 海报 / 背景图的磁盘缓存。
///
/// ## 为什么要有磁盘缓存，而不是直接用 `Image.network`
///
/// 1. **离线可用**。媒体库是「打开就想看到墙」的东西，断网时一片灰
///    比没有海报墙更糟；
/// 2. **可预测的请求量**。滚动一次海报墙会触发几十次图片请求，
///    `Image.network` 每次重建都可能重来一遍；
/// 3. **不污染 URL**。`MediaWork.posterFile` 存的是**相对文件名**，
///    库可以整个搬走（换机器、改缓存目录）而不用改数据。
///
/// ## 文件名规则
///
/// `{归一化后的作品键}_{URL 散列 8 位}.jpg`
///
/// 两段各有分工：
///   - **作品键**保证唯一。只用散列的话，几千张海报撞一次的概率
///     并不低（生日问题），而撞了的后果是「两部不同的片子显示同一张海报」，
///     用户根本不会想到是缓存问题；
///   - **URL 散列**让「换了海报源」自然产生新文件名，旧文件不会被复用。
///     换 URL 时仓储层会把 `posterFile` 置空（见 `mergeWorkForUpsert`），
///     这里再兜一层，避免调用方忘了。
class PosterCache {
  PosterCache({
    required HttpClientLike http,
    required this.dirPath,
    Map<String, String> Function(String url)? headersFor,
    Duration timeout = const Duration(seconds: 15),
  })  : _http = http,
        _headersFor = headersFor,
        _timeout = timeout;

  final HttpClientLike _http;

  /// 缓存目录的绝对路径。
  final String dirPath;

  /// 「这个图片地址要带什么请求头」。
  ///
  /// ## 为什么缓存层要知道请求头
  ///
  /// 海报来源不止一处：
  ///   - TMDB 的图（`image.tmdb.org`）—— 裸链即可；
  ///   - **网盘自己生成的缩略图**（夸克 `/file/video/preview?fid=…`）——
  ///     实测**必须带 Cookie**，裸链 `401 auth not found`，而且夸克每次响应
  ///     轮换 `__puus`，用旧值一样 401。
  ///
  /// 两种来源混在同一个缓存目录里，缓存层就得能按地址决定带不带鉴权头。
  /// 交给回调而不是在这里判断域名，是为了让「哪家网盘、用什么头」这件事
  /// 留在适配器里 —— 缓存层不该认识任何一家网盘。
  ///
  /// 回调在**每次真正发请求时**调用（不是在 `pathFor` 时），所以它总能拿到
  /// 最新一轮的 Cookie。
  final Map<String, String> Function(String url)? _headersFor;

  final Duration _timeout;

  /// 已解析过的路径（含**正在下载中**的）。同一张海报被多个 widget 同时
  /// 请求时只会发一次网络请求。
  final Map<String, Future<String?>> _inflight = {};

  /// 取一张图的本地绝对路径。下载失败返回 `null`（UI 退化为占位图）。
  ///
  /// [knownFile] 是库里已经记着的缓存文件名。它存在就直接用 ——
  /// **连 HEAD 都不发**，这是「打开媒体库秒出图」的关键。
  Future<String?> pathFor({
    required String key,
    required String url,
    String? knownFile,
  }) {
    final memoKey = '$key|$url';

    if (knownFile != null && knownFile.isNotEmpty) {
      final existing = _absolute(knownFile);
      if (File(existing).existsSync()) return Future.value(existing);
    }

    final cached = _inflight[memoKey];
    if (cached != null) return cached;

    final future = _download(key: key, url: url);
    _inflight[memoKey] = future;
    return future;
  }

  Future<String?> _download({required String key, required String url}) async {
    try {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final name = fileNameFor(key: key, url: url);
      final target = _absolute(name);

      // 盘上已经有这张图就直接用 —— **不发请求**。
      //
      // ## 为什么这道判断必须有
      //
      // 缓存的「已命中」本来靠的是库里记着的 `posterFile`（`pathFor` 的
      // `knownFile`），但**没有任何代码把下载结果写回那一列**：`pathFor`
      // 返回的路径在 `PosterImage` 里用完就丢。于是每次启动应用、每张海报
      // 都会重新下一遍。
      //
      // 对 TMDB 海报这只是慢；对**网盘缩略图**是实打实的浪费 ——
      // 一千部作品就是启动后一千次带 Cookie 的请求（夸克还有 QPS 限制）。
      //
      // 用「文件是否存在」当缓存判据是安全的：文件名里带着 URL 的散列，
      // 换了地址自然换文件名；而同一个地址的图片内容不会变
      // （TMDB 的图是内容寻址的，夸克缩略图按 `fid` 固定）。
      if (File(target).existsSync()) return target;

      final bytes = await _http.getBytes(
        url,
        headers: _headersFor?.call(url),
        timeout: _timeout,
      );
      if (bytes == null || bytes.isEmpty) {
        diag.warn('海报', '下载失败（空响应）：$url');
        return null;
      }

      // 先写临时文件再改名：直接写目标文件时，进程被杀会留下一个
      // **半张图**，而它下次会被当成有效缓存直接显示。
      final tmp = File('$target.part');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(target);

      return target;
    } catch (e) {
      diag.warn('海报', '缓存失败：$e');
      return null;
    }
  }

  /// 由 [pathFor] 返回的绝对路径反推相对文件名（落库用）。
  static String? relativeNameOf(String? absolutePath, String dirPath) {
    if (absolutePath == null) return null;
    final prefix = dirPath.endsWith(Platform.pathSeparator)
        ? dirPath
        : '$dirPath${Platform.pathSeparator}';
    if (!absolutePath.startsWith(prefix)) return null;
    return absolutePath.substring(prefix.length);
  }

  String _absolute(String fileName) =>
      '$dirPath${Platform.pathSeparator}$fileName';

  /// 缓存文件名：`{归一化键}_{URL 散列 8 位}.jpg`
  ///
  /// 扩展名固定 `.jpg` **不代表内容一定是 JPEG**：网盘生成的缩略图实测是
  /// WebP。这里只当它是「一个图片文件」—— 解码由 Flutter 的
  /// `instantiateImageCodec` 按**内容**嗅探，不看扩展名。
  /// 之所以不按真实格式命名，是因为文件名在**下载之前**就得定下来
  /// （它是幂等键），而那时还不知道响应是什么格式。
  static String fileNameFor({required String key, required String url}) {
    final safe = _sanitize(key);
    return '${safe}_${_hash8(url)}.jpg';
  }

  /// 把作品键压成文件系统安全的形式。
  ///
  /// 作品键是**归组键**，可能含 `/`（目录路径）、`|`、中文、空格。
  /// 中文保留（macOS/Windows 都支持，且便于人工排查缓存），
  /// 只替换路径分隔符与 Windows 的保留字符。
  static String _sanitize(String key) {
    final cleaned = key.replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_');
    // 太长的键会撞上文件名长度上限（多数文件系统 255 字节，
    // 而中文在 UTF-8 下占 3 字节）。截断后再补一段散列保证不重名。
    if (cleaned.length <= 60) return cleaned;
    return '${cleaned.substring(0, 60)}_${_hash8(key)}';
  }

  /// URL → 8 位十六进制散列（FNV-1a 32 位）。
  ///
  /// 不用 `String.hashCode`：它在不同 Dart 版本/平台上**不保证一致**，
  /// 换一次运行时整库缓存就全部失效。也不用 `crypto` ——
  /// 这里只需要「不同 URL 尽量落到不同文件」，不需要抗碰撞
  /// （唯一性已经由文件名里的作品键保证了）。
  static String _hash8(String input) {
    var hash = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// 清空缓存目录（设置页的「清理海报缓存」）。
  Future<int> clear() async {
    _inflight.clear();
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return 0;

    var removed = 0;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        await entity.delete();
        removed++;
      } catch (_) {
        // 单个文件删不掉（被占用）不该让整个清理失败
      }
    }
    return removed;
  }

  /// 缓存占用的字节数（设置页展示）。
  Future<int> sizeOnDisk() async {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return 0;
    var total = 0;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {
          // 读不到大小就当 0，不要因此报错
        }
      }
    }
    return total;
  }

  /// 直接把字节写进缓存（刮削时已经拿到图的情况）。
  Future<String?> put({
    required String key,
    required String url,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty) return null;
    try {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final target = _absolute(fileNameFor(key: key, url: url));
      await File(target).writeAsBytes(bytes, flush: true);
      return target;
    } catch (e) {
      diag.warn('海报', '写入缓存失败：$e');
      return null;
    }
  }
}
