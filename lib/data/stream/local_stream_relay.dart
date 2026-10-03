import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/http_range.dart';
import '../../domain/adapters/stream_relay.dart';
import '../../domain/entities/stream_ticket.dart';
import 'chunk_cache.dart';
import 'chunk_layout.dart';

/// 网盘直链的**本地中继**：把一条源站连接变成 N 条并发连接 + 本地缓存。
///
/// ## 它解决什么
///
/// 夸克原画直链是单条 TCP、顺序读，而网盘对单连接普遍有吞吐上限。4K 原画
/// （平均十几 Mbps、峰值四十几 Mbps）在一条连接上永远追不上播放 —— 症状是
/// 「缓冲看着不少，却每隔几十秒卡一下」。夸克自己的播放器播同一个文件不卡，
/// 因为它不是这么读的。
///
/// 这里补上那一段：loopback HTTP 服务 + 按块并发预取 + LRU 缓存。mpv 从
/// `127.0.0.1` 读，单连接的上限被 [LocalStreamRelay.connections] 倍绕过。
///
/// ## 它不解决什么
///
/// 用户到网盘的**总带宽**不够时，并发也救不了 —— 这时应当在诊断里如实
/// 显示真实速率，让用户切到转码档，而不是假装缓冲很充裕。
class LocalStreamRelay implements StreamRelay {
  LocalStreamRelay({
    int connections = 8,
    this.chunkSize = 2 * 1024 * 1024,
    this.prefetchBytes = 256 * 1024 * 1024,
    this.maxCacheBytes = 256 * 1024 * 1024,
    bool enabled = true,
  })  : _connections = connections,
        _enabled = enabled;

  /// 并发拉取的连接数。可在运行时改，但**只对之后新建的会话生效** ——
  /// 已经在跑的会话有固定数量的 worker，中途增减会让正在下载的块被丢弃。
  ///
  /// 不是越大越好：网盘侧按账号限速，开太多只会让每条连接都被降速，
  /// 还会触发风控。8 条是实测下来「能跑满家用带宽又不上风控」的量级。
  int get connections => _connections;
  int _connections;

  /// 总开关。关掉后 [open] 一律返回 `null`（调用方直连）。
  bool get enabled => _enabled;
  bool _enabled;

  /// 就地改配置。**刻意不做成"改配置就重建实例"**：那样会 dispose 掉正在
  /// 后台预取的会话，把 mpv 正在读的那条流掐断 —— 而用户只是在设置页
  /// 拨了一下开关，根本没在换片子。
  void configure({bool? enabled, int? connections}) {
    if (enabled != null) _enabled = enabled;
    final next = connections;
    if (next != null && next > 0) _connections = next;
  }

  final int chunkSize;

  /// 从当前播放位置往前预取的字节数。
  final int prefetchBytes;

  final int maxCacheBytes;

  HttpServer? _server;
  int _tokenSeq = 0;
  final Map<String, _RelaySession> _sessions = <String, _RelaySession>{};

  @override
  Future<RelayEndpoint?> open(StreamTicket ticket, {String? label}) async {
    if (!enabled) return null;

    final total = ticket.contentLength;
    if (total == null || total <= 0) {
      diag.info('中继', '源流长度未知，直连播放（并发预取需要已知长度）');
      return null;
    }
    if (!ticket.supportsRange) {
      diag.info('中继', '源流不支持 Range，直连播放（无法做按块并发）');
      return null;
    }

    try {
      final server = await _ensureServer();
      final token = 's${++_tokenSeq}';
      final session = _RelaySession(
        token: token,
        source: ticket.url,
        headers: ticket.headers,
        contentType: ticket.contentType ?? 'application/octet-stream',
        label: label ?? ticket.redactedUrl,
        layout: ChunkLayout(chunkSize: chunkSize, totalLength: total),
        cache: ChunkCache(maxBytes: maxCacheBytes),
        connections: connections,
        prefetchChunks: math.max(1, prefetchBytes ~/ chunkSize),
      );
      _sessions[token] = session;
      session.start();

      final uri = Uri.parse('http://127.0.0.1:${server.port}/$token');
      diag.info(
        '中继',
        '已接管 ${label ?? ticket.redactedUrl}：'
        '${(total / 1073741824).toStringAsFixed(2)} GiB，'
        '$connections 连接 × ${(chunkSize / 1048576).round()} MiB 块，'
        '预取 ${(prefetchBytes / 1048576).round()} MiB',
      );
      return RelayEndpoint(uri: uri, token: token, contentLength: total);
    } catch (e) {
      // 起不来不是错误：直连至少还能播。这里**不能**往上抛。
      diag.warn('中继', '启动失败，直连播放：$e');
      return null;
    }
  }

  Future<HttpServer> _ensureServer() async {
    final existing = _server;
    if (existing != null) return existing;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_onRequest, onError: (Object e) {
      diag.debug('中继', '连接异常：$e');
    });
    _server = server;
    diag.info('中继', '本地中继已监听 127.0.0.1:${server.port}');
    return server;
  }

  void _onRequest(HttpRequest request) {
    final token = _tokenOf(request);
    final session = token == null ? null : _sessions[token];
    if (session == null) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..headers.set(HttpHeaders.contentLengthHeader, 0);
      unawaited(request.response.close().catchError((Object _) {}));
      return;
    }
    unawaited(_serve(request, session));
  }

  /// 从路径里取会话标识：`/s3` → `s3`。
  String? _tokenOf(HttpRequest request) {
    final path = request.uri.path;
    if (path.isEmpty || path == '/') return null;
    return path.startsWith('/') ? path.substring(1) : path;
  }

  Future<void> _serve(HttpRequest request, _RelaySession session) async {
    final response = request.response;
    try {
      final total = session.totalLength;
      final requested =
          parseRangeHeader(request.headers.value(HttpHeaders.rangeHeader), total);
      final range = clampRange(requested ?? ByteRange(0, total - 1), total);
      if (range == null) {
        response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..headers.set('content-range', 'bytes */$total')
          ..headers.set(HttpHeaders.contentLengthHeader, 0);
        return;
      }

      response
        ..statusCode = requested == null ? HttpStatus.ok : HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentTypeHeader, session.contentType)
        // ⚠️ 必须声明支持 Range：mpv 靠它判断能不能 seek。少了这一行的
        // 表现是「能播但进度条拖不动」。
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..headers.set(HttpHeaders.contentLengthHeader, range.length);
      if (requested != null) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          formatContentRange(range, total),
        );
      }
      // 长度已知，不要分块编码 —— mpv 对 chunked 的流无法做范围估算。
      response.headers.chunkedTransferEncoding = false;

      if (request.method != 'HEAD') {
        await for (final bytes in session.read(range)) {
          response.add(bytes);
          // 每块刷一次：不 flush 的话数据会攒在 dart:io 的缓冲里，
          // mpv 那边就是「缓冲条不动、等半天才突然涨一截」。
          await response.flush();
        }
      }
    } catch (e) {
      // 客户端断开（mpv seek 时会直接掐掉旧连接）是最常见的正常退出，
      // 不是错误。只记 debug，别惊动用户。
      diag.debug('中继', '响应中断（通常是播放器换源/seek）：$e');
    } finally {
      await response.close().catchError((Object _) {});
    }
  }

  @override
  RelayStats? statsOf(String token) => _sessions[token]?.stats;

  /// 当前会话数。
  @override
  int get sessionCount => _sessions.length;

  /// 全部会话的**汇总**统计。没有会话时返回 `null`。
  ///
  /// 诊断页靠它回答「中继到底在不在干活」。实测加速效果时这是唯一客观的
  /// 指标 —— 否则只能凭手感说「好像快了点」。
  @override
  RelayStats? get aggregateStats {
    if (_sessions.isEmpty) return null;
    var downloaded = 0;
    var cached = 0;
    var workers = 0;
    var failures = 0;
    var requests = 0;
    for (final session in _sessions.values) {
      final s = session.stats;
      downloaded += s.downloadedBytes;
      cached += s.cachedBytes;
      workers += s.activeWorkers;
      failures += s.upstreamFailures;
      requests += s.upstreamRequests;
    }
    return RelayStats(
      downloadedBytes: downloaded,
      cachedBytes: cached,
      activeWorkers: workers,
      upstreamFailures: failures,
      upstreamRequests: requests,
    );
  }

  /// 当前会话的来源标签（脱敏后），供诊断显示。
  @override
  List<String> get sessionLabels =>
      _sessions.values.map((s) => s.label).toList(growable: false);

  /// 当前会话的源长度（字节）。同时播两条流时取先注册的那条 —— 显示任意
  /// 一条都比显示「未知」有用，而「同机同时播两条」本身就是罕见情况。
  @override
  int? get primaryContentLength {
    for (final session in _sessions.values) {
      return session.totalLength;
    }
    return null;
  }

  @override
  Future<void> close(String token) async {
    final session = _sessions.remove(token);
    if (session == null) return;
    await session.dispose();
    diag.info('中继', '会话 $token 已关闭（${session.label}）');
  }

  @override
  Future<void> dispose() async {
    for (final session in _sessions.values.toList()) {
      await session.dispose();
    }
    _sessions.clear();
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
    }
  }
}

/// 一条流的会话：缓存 + 并发拉取 + 对外提供字节流。
class _RelaySession {
  _RelaySession({
    required this.token,
    required this.source,
    required this.headers,
    required this.contentType,
    required this.label,
    required this.layout,
    required this.cache,
    required this.connections,
    required this.prefetchChunks,
  });

  final String token;
  final Uri source;
  final Map<String, String> headers;
  final String contentType;
  final String label;
  final ChunkLayout layout;
  final ChunkCache cache;
  final int connections;
  final int prefetchChunks;

  /// 播放器此刻就要的块（插队，优先于顺序预取）。
  final Queue<int> _priority = Queue<int>();
  final Set<int> _queued = <int>{};

  /// 预取窗口的起点（块序号），跟着播放器的请求走。
  int _prefetchBase = 0;

  /// 预取窗口内的扫描游标，避免每次都从窗口头扫一遍。
  int _scan = 0;

  final Set<int> _inflight = <int>{};
  final Map<int, Completer<Uint8List?>> _waiters = <int, Completer<Uint8List?>>{};
  final List<Completer<void>> _idleWorkers = <Completer<void>>[];

  int _downloaded = 0;
  int _requests = 0;
  int _failures = 0;
  bool _closed = false;

  int get totalLength => layout.totalLength;

  RelayStats get stats => RelayStats(
        downloadedBytes: _downloaded,
        cachedBytes: cache.bytes,
        activeWorkers: _inflight.length,
        upstreamFailures: _failures,
        upstreamRequests: _requests,
      );

  void start() {
    for (var i = 0; i < connections; i++) {
      unawaited(_worker());
    }
  }

  /// 取出一段字节流。**按需拉取 + 插队**，块没到就等着。
  Stream<Uint8List> read(ByteRange range) async* {
    var offset = range.start;
    final end = range.end;
    while (offset <= end) {
      if (_closed) return;
      final index = layout.indexOf(offset);
      final data = await _ensure(index);
      if (data == null) {
        throw Exception('取块 $index 失败（上游错误 $_failures 次）');
      }
      final within = offset - layout.startOf(index);
      final take = math.min(data.lengthInBytes - within, end - offset + 1);
      if (take <= 0) return;
      yield Uint8List.sublistView(data, within, within + take);
      offset += take;
    }
  }

  /// 保证第 [index] 块就绪。已缓存就立刻返回，否则插队并等它到。
  Future<Uint8List?> _ensure(int index) {
    final cached = cache.get(index);
    if (cached != null) return Future<Uint8List?>.value(cached);

    // 预取窗口跟着播放位置走：这是「顺序播放时数据已经在那儿」的来源。
    _prefetchBase = index;
    if (!_queued.contains(index) && !_inflight.contains(index)) {
      _priority.addLast(index);
      _queued.add(index);
    }
    final waiter = _waiters.putIfAbsent(index, () => Completer<Uint8List?>());
    _notifyWorkers();
    return waiter.future;
  }

  Future<void> _worker() async {
    while (!_closed) {
      final index = _take();
      if (index == null) {
        // ⚠️ 必须是**异步** Completer。`.sync()` 会在 `complete()` 的调用栈
        // 里直接跑本 worker 的后续代码，而那一刻 `_notifyWorkers` 还在遍历
        // `_idleWorkers` —— 于是一次唤醒就抛 Concurrent modification，
        // 整条流的预取从此停摆（worker 全死，但没人报错）。
        final idle = Completer<void>();
        _idleWorkers.add(idle);
        await idle.future;
        continue;
      }
      await _fetch(index);
    }
  }

  /// 挑下一个要拉的块：先插队，再顺序预取。
  int? _take() {
    while (_priority.isNotEmpty) {
      final index = _priority.removeFirst();
      _queued.remove(index);
      if (!layout.isValidIndex(index)) continue;
      if (cache.contains(index) || _inflight.contains(index)) continue;
      return index;
    }

    final windowEnd = math.min(layout.chunkCount, _prefetchBase + prefetchChunks);
    if (_prefetchBase >= windowEnd) return null;
    if (_scan < _prefetchBase || _scan >= windowEnd) _scan = _prefetchBase;

    for (var i = 0; i < windowEnd - _prefetchBase; i++) {
      final index = _scan;
      _scan = _scan + 1 >= windowEnd ? _prefetchBase : _scan + 1;
      if (cache.contains(index) || _inflight.contains(index)) continue;
      return index;
    }
    return null;
  }

  Future<void> _fetch(int index) async {
    _inflight.add(index);
    _requests++;
    try {
      final data = await _fetchChunk(index);
      _downloaded += data.lengthInBytes;
      cache.put(index, data);
      _settle(index, data);
    } catch (e) {
      _failures++;
      diag.warn('中继', '取块 $index 失败：$e');
      _settle(index, null);
    } finally {
      _inflight.remove(index);
      _notifyWorkers();
    }
  }

  void _settle(int index, Uint8List? data) {
    final waiter = _waiters.remove(index);
    if (waiter != null && !waiter.isCompleted) waiter.complete(data);
  }

  Future<Uint8List> _fetchChunk(int index) async {
    final range = layout.rangeOf(index);
    final client = HttpClient();
    // ⚠️ 必须直连：`dart:io` 默认会读 `http_proxy` 环境变量，而本机那份
    // 代理配置是为命令行工具准备的，走它会把网盘直链也一起代理掉 ——
    // 表现是「扫描正常、播放奇慢」，且看不出原因。
    client.findProxy = (Uri _) => 'DIRECT';
    client.connectionTimeout = const Duration(seconds: 20);

    try {
      final request = await client.getUrl(source);
      for (final entry in headers.entries) {
        if (_hopByHop.contains(entry.key.toLowerCase())) continue;
        request.headers.set(entry.key, entry.value);
      }
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=${range.start}-${range.end}');
      // ⚠️ 禁用压缩：Range 与 gzip 同时用，服务端给的是**整条压缩流的一个
      // 区间**，根本解不出来。夸克实测对 identity 正常返回 206。
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');

      final response = await request.close();
      if (response.statusCode != HttpStatus.partialContent &&
          response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('上游返回 ${response.statusCode}');
      }

      // `HttpClientResponse` 是 `Stream<List<int>>`，不是 `Uint8List` ——
      // 强转会在某些平台拿到 `_Uint8ArrayView` 之外的实现时炸掉。
      final pieces = <List<int>>[];
      var total = 0;
      await for (final piece in response) {
        pieces.add(piece);
        total += piece.length;
      }
      final expected = layout.lengthOf(index);
      // 服务端无视 Range 返回了整条流：照单全收会把几个 GiB 塞进缓存。
      if (total > expected) {
        throw HttpException('上游忽略了 Range（给了 $total 字节，只要 $expected）');
      }

      final out = Uint8List(total);
      var p = 0;
      for (final piece in pieces) {
        out.setRange(p, p + piece.length, piece);
        p += piece.length;
      }
      return out;
    } finally {
      client.close(force: true);
    }
  }

  /// 逐跳首部：由连接本身决定，不能原样转发给上游。
  static const Set<String> _hopByHop = {
    'host',
    'content-length',
    'transfer-encoding',
    'connection',
  };

  void _notifyWorkers() {
    if (_idleWorkers.isEmpty) return;
    // ⚠️ 必须先摘出来再唤醒：`complete()` 会**同步**跑被唤醒 worker 的后续
    // 代码，而它转一圈之后又会往 `_idleWorkers` 里塞新的等待者 —— 那时
    // 正在遍历的这张表就被改了，直接抛 `Concurrent modification`。
    final pending = _idleWorkers.toList();
    _idleWorkers.clear();
    for (final idle in pending) {
      if (!idle.isCompleted) idle.complete();
    }
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    for (final waiter in _waiters.values) {
      if (!waiter.isCompleted) waiter.complete(null);
    }
    _waiters.clear();
    cache.clear();
    _notifyWorkers();
  }
}
