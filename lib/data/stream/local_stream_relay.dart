import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/hls_relay_rewrite.dart';
import '../../core/utils/http_range.dart';
import '../../domain/adapters/stream_relay.dart';
import '../../domain/entities/stream_ticket.dart';
import 'chunk_cache.dart';
import 'chunk_layout.dart';
import 'relay_reader_arbiter.dart';

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
/// ## ⚠️ 连接必须复用（否则等于没并发）
///
/// 早期实现**每取一个 2 MiB 块就新建一条 `HttpClient`、取完立刻 `close`**。
/// 对 17 GiB 的片子那是**上万次 TCP+TLS 握手**：每块都有一段「连接建不起来、
/// 吞吐为 0」的间隙，聚合吞吐被切成锯齿，稳态净速率贴着甚至低于片源码率
/// （实测片源 19.74 Mbps = 2.47 MiB/s，而单连接被限在 ~2.43 MiB/s）。
/// 结果就是「下行看着有 5 MB/s，画面仍播一会卡一会」——那 5 MB/s 是毛值。
///
/// 现在每个 worker **长期持有一条连接**（[HttpClient] 默认 keep-alive），
/// 一块接一块复用同一条 TCP/TLS，握手成本从「每块一次」降到「每 worker 一次」。
/// 判断复用有没有生效看 [RelayStats.upstreamConnects]：它应远小于
/// [RelayStats.upstreamRequests]。
///
/// ## ⚠️ 预取窗口必须跟着「正在播的那条流」（seek 卡顿的根因）
///
/// 一条会话上会**同时挂着好几个读取器**（实测 3~4 个），而播放器拖进度条时
/// **不会关掉旧连接** —— 旧读取器留在原地继续被喂。早期实现里预取窗口的锚点是
/// 整个会话唯一的一个，任何读取器请求任何块都会覆盖它，于是 seek 之后锚点在
/// 旧位置与新位置之间反复拉锯：**实测 69 秒内 78% 的上游带宽喂给了已经不看
/// 的旧位置**，新位置只拿到约 0.8 MiB/s（片源需要 2.37 MiB/s）→「拖完进度条
/// 看一会卡一会」，几十秒后才自己恢复。正常起播不卡，正是因为那时只有一条
/// 读取器，锚点没得争。
///
/// 修法是给「谁有权推动窗口」立规矩，见 [RelayReaderArbiter]：靠**请求范围
/// 长度**认出「在放片子」的读取器，最新的那个说了算；被抛弃的旧连接需求降级到
/// 低优先队列，只能捡余量。
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

  /// 单块的字节数。**它同时决定了「首字节延迟」**，所以不能只按吞吐挑。
  ///
  /// ⛔ **别为了省请求数把它放大。** [_fetchChunk] 是「整块读完才 `cache.put` +
  /// `_settle`」，而 [warmUpRelay] 的就绪判据是 `downloadedBytes >= 1 MiB`、
  /// 而 `downloadedBytes` **只在整块落地时才增加** —— 于是：
  ///
  ///     首字节延迟 ≈ 单块下载耗时 ∝ chunkSize
  ///
  /// 而它上面压着三个超时，**全都不会因为块变大而变长**：
  /// 中继预热 2500ms（`playback_controller.dart`）、mpv 打开 ~5s、ExoPlayer ~20s。
  /// 一旦首块超过 2.5s，日志里就必然出现「新中继预热超时，直接切换」，随后
  /// 播放器读到一个还没有任何数据的会话 → `Failed to open` / `Source error`。
  ///
  /// ⛔ **实测（2026-10-05 22:37 那次把它改成 8 MiB 的后果，同机同批 4K 片源）**：
  ///
  /// | chunkSize | 首块延迟 | 结果 |
  /// |---|---|---|
  /// | 2 MiB | **1.18s** | 连续播 8 分钟以上 |
  /// | 8 MiB | **12.8~45.5s** | 每次换片都 `Source error` → 回退 → `Failed to open` |
  ///
  /// 8 MiB 下预热**一次都没成功过**（12.8s 已是最快的一次，仍是 2500ms 的 5 倍）。
  /// 想提速就调 [connections] 或 [prefetchBytes]；**块大小只影响首字节延迟**。
  final int chunkSize;

  /// 从当前播放位置往前预取的字节数。
  final int prefetchBytes;

  final int maxCacheBytes;

  HttpServer? _server;
  int _tokenSeq = 0;

  /// 读取器编号。**每个 HTTP 请求一个**，用来分辨「同一个播放器的多个并行连接」
  /// 与「seek 之后新开的那条」。见 [RelayReaderArbiter]。
  int _readerSeq = 0;

  final Map<String, _RelaySession> _sessions = <String, _RelaySession>{};

  /// HLS（转码档）会话。与 [_sessions] **分开存**，因为服务方式完全不同：
  /// 字节流会话是「按块并发预取 + 本地缓存」，而 HLS 会话只是把上游地址
  /// 换成 `127.0.0.1` 的入口再原样转发 —— 上游本来就是分片并发下发的，
  /// 再套一层预取只会两头添乱。见 [_serveHls]。
  final Map<String, _HlsRelaySession> _hlsSessions = <String, _HlsRelaySession>{};

  @override
  Future<RelayEndpoint?> open(
    StreamTicket ticket, {
    String? label,
    int startOffset = 0,
  }) async {
    if (!enabled) return null;

    // 转码档走另一条路：它没有「总长度」也没有「按块预取」这回事。
    // ⚠️ 必须在下面那两个检查**之前**分流 —— HLS 的 contentLength 是服务端
    // 声明的整档体积，与「这条流多少字节」不是一回事，拿它切块会切错。
    if (isHlsUrl(ticket.url)) {
      return _openHls(ticket, label: label);
    }

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
        startOffset: startOffset,
      );
      _sessions[token] = session;
      session.start();

      final uri = Uri.parse('http://127.0.0.1:${server.port}/$token');
      // ⚠️ **token 必须进日志**：播放器打开失败时报的是它自己的原话
      // 「Failed to open http://127.0.0.1:43617/s1.」—— 那个 `s1` 就是这里的
      // token。少了它，日志里只有一串「已接管 <片名>」，事后无从判断报错指向
      // 哪一条会话（同一次播放会建多条），只能靠顺序猜。入口 URL 一起打出来，
      // 是为了把「端口 + 路径」与屏幕上的报错逐字对上。
      diag.info(
        '中继',
        '已接管 $token ${label ?? ticket.redactedUrl}：'
        '${(total / 1073741824).toStringAsFixed(2)} GiB，'
        '$connections 连接 × ${(chunkSize / 1048576).round()} MiB 块，'
        '预取 ${(prefetchBytes / 1048576).round()} MiB'
        '${startOffset > 0 ? "，起点 ${(startOffset / 1048576).round()} MiB" : ""}'
        '｜入口 $uri',
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
    if (token == null) {
      _notFound(request, reason: '路径里没有会话标识');
      return;
    }
    // HLS 会话（转码档）走另一条服务路径：播放列表要改写、分片要透传。
    final hls = _hlsSessions[token];
    if (hls != null) {
      // 分片请求一次播放有几百条，逐条记会把日志冲垮 —— 只记这条会话的
      // **第一个**请求，用来回答「播放器到底连上中继没有」。之后的总量由
      // [close] 以「上游请求 N 次，失败 M 次」落一条。
      if (!hls.sawRequest) {
        hls.sawRequest = true;
        diag.debug(
          '中继',
          'HLS 会话 $token 收到首个请求：${request.method} ${request.uri.path}',
        );
      }
      unawaited(_serveHls(request, hls));
      return;
    }
    final session = _sessions[token];
    if (session == null) {
      _notFound(request, reason: '会话不存在（已关闭或从未建立）');
      return;
    }
    // ⚠️ **这一条是「播放器报 Failed to open 127.0.0.1」的分水岭。**
    //
    // 有它 = 请求确实到了中继，故障在中继下游（上游取块失败 / 我们回错了）；
    // 没有它 = 播放器压根没连进来（端口不通 / 会话被提前关掉 / 地址发错）。
    // 这两种故障今天的日志长得**一模一样**，事后无从区分。
    //
    // 字节流会话的读取器只有个位数（mpv 开几条连接就是几条），逐条记 debug
    // 不会淹掉日志；量大的 HLS 那条路已经按会话去重。
    final reader = ++_readerSeq;
    diag.debug(
      '中继',
      '会话 $token 收到读取器 #$reader：${request.method} '
      '${request.uri.path}${_describeRange(request)}',
    );
    unawaited(_serve(request, session, reader));
  }

  /// 把请求里的 `Range` 头整理成日志片段（没有就返回空串）。
  static String _describeRange(HttpRequest request) {
    final range = request.headers.value(HttpHeaders.rangeHeader);
    return range == null ? '' : '（Range: $range）';
  }

  /// 回一条 404。中继上「token 不认识」就是这个意思 —— 会话已关 / 从没建过。
  ///
  /// ⚠️ 这个 404 会被 ffmpeg 原样报成 `http: HTTP error 404 Not Found`，
  /// 而播放窗口的 `isHttp4xxLog` **只看正文里的状态码**，分不出它来自中继。
  /// 所以「换源时先关旧会话」会引出一条假的「直链过期」——见
  /// `player_window_app._prepareSource` 里关于关闭时机的说明。
  ///
  /// ⚠️ **必须记日志**。上面那条「假的直链过期」正是最难查的一类：播放器只报
  /// 一句 `Failed to open http://127.0.0.1:PORT/sN.`，而中继这边原来一声不吭
  /// —— 事后无法区分「请求没来」与「来了但被 404 掉」。落 warn 是因为它几乎
  /// 总是异常：正常换源时，旧会话的连接是**已被占住的存量连接**，不会再来新
  /// 请求。
  void _notFound(HttpRequest request, {required String reason}) {
    diag.warn(
      '中继',
      '拒绝 ${request.method} ${request.uri.path}：$reason'
      '（当前活跃会话 ${_sessions.length} 条 + HLS ${_hlsSessions.length} 条）',
    );
    request.response
      ..statusCode = HttpStatus.notFound
      ..headers.set(HttpHeaders.contentLengthHeader, 0);
    unawaited(request.response.close().catchError((Object _) {}));
  }

  /// 从路径里取**会话标识**（只取第一段）：`/s3` → `s3`，
  /// `/h1/index.m3u8` → `h1`。
  ///
  /// ⚠️ 必须只取第一段：HLS 会话的请求路径是 `/<token>/index.m3u8`，
  /// 拿整条路径当标识的话每个分片都查不到会话 —— 表现是「播放列表取得回来、
  /// 分片全 404」，正好是最难查的那种半死状态。
  String? _tokenOf(HttpRequest request) {
    final path = request.uri.path;
    if (path.isEmpty || path == '/') return null;
    final trimmed = path.startsWith('/') ? path.substring(1) : path;
    final slash = trimmed.indexOf('/');
    final token = slash < 0 ? trimmed : trimmed.substring(0, slash);
    return token.isEmpty ? null : token;
  }

  // -------------------------------------------------------------------
  // HLS（转码档）
  // -------------------------------------------------------------------

  /// 建一条**直连**的上游连接（HLS 代理用）。
  ///
  /// ⚠️ `findProxy = DIRECT` 是整条修复的关键：`dart:io` 的 `HttpClient` 默认
  /// 会读 `http_proxy` 环境变量，而本机那份代理是为命令行工具准备的。少了它，
  /// 中继自己也会被代理掉 —— 那就等于没修。
  ///
  /// （字节流会话里也有一份同名逻辑，在 `_RelaySession._openClient` 上；
  /// 两处口径必须一致：都直连、都开 keep-alive。）
  HttpClient _directClient() {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    client.findProxy = (Uri _) => 'DIRECT';
    client.idleTimeout = const Duration(seconds: 30);
    return client;
  }

  /// 为一条 HLS 流建会话。
  ///
  /// 它**不做**并发预取，也**不要求**已知长度 / Range —— 上游本来就是分片
  /// 并发下发的，中继在这里只干一件事：把「上游地址」换成 `127.0.0.1` 的入口。
  ///
  /// 为什么要换，见 [isRelayableUrl] 的文档：本机 `http_proxy` 会让 ffmpeg
  /// 走进一个不在 protocol whitelist 里的 `httpproxy` 协议，分片一个都取不到。
  Future<RelayEndpoint?> _openHls(StreamTicket ticket, {String? label}) async {
    try {
      final server = await _ensureServer();
      final token = 'h${++_tokenSeq}';
      final name = label ?? ticket.redactedUrl;
      _hlsSessions[token] = _HlsRelaySession(
        headers: ticket.headers,
        label: name,
      );
      final entry = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: server.port,
        path: '/$token/$relayEntryPath',
        queryParameters: <String, String>{
          relayTargetQueryKey: encodeRelayTarget(ticket.url.toString()),
        },
      );
      diag.info(
        '中继',
        '已接管 $token $name（HLS 转码档）：播放列表与分片都改走 127.0.0.1，'
        '避开本机 http_proxy（那个代理会让 ffmpeg 用上未放行的 httpproxy 协议）'
        '｜入口 $entry',
      );
      return RelayEndpoint(
        uri: entry,
        token: token,
        contentLength: ticket.contentLength ?? 0,
      );
    } catch (e) {
      // 起不来不是错误：直连至少还能试。这里**不能**往上抛。
      diag.warn('中继', 'HLS 中继启动失败，直连播放：$e');
      return null;
    }
  }

  /// 服务一条 HLS 请求：**播放列表改写后回给播放器，分片原样透传**。
  ///
  /// 上游地址放在查询串 `?u=`（base64url）里，所以这一个入口同时承担「取列表」
  /// 与「取分片」两件事 —— 列表里每一行都会被改写成指向它自己（见
  /// `rewriteHlsForRelay`）。
  ///
  /// 失败一律降级成 502：中继是加速手段，它自己不该变成故障源。
  Future<void> _serveHls(HttpRequest request, _HlsRelaySession session) async {
    final response = request.response;
    final encoded = request.uri.queryParameters[relayTargetQueryKey];
    final target = encoded == null ? null : decodeRelayTarget(encoded);
    final upstream = target == null ? null : Uri.tryParse(target);
    if (upstream == null) {
      response
        ..statusCode = HttpStatus.badRequest
        ..headers.set(HttpHeaders.contentLengthHeader, 0);
      unawaited(response.close().catchError((Object _) {}));
      return;
    }

    HttpClient? client;
    try {
      // ⚠️ `_directClient()` 里那句 `findProxy = DIRECT` 是整条修复的关键：
      // 少了它，中继自己也会被 `http_proxy` 代理掉 —— 那就等于没修。
      client = _directClient();
      final upstreamRequest = await client.getUrl(upstream);
      for (final e in session.headers.entries) {
        upstreamRequest.headers.set(e.key, e.value);
      }
      // 播放器（或上游）要求 Range 时原样带过去：分片也可能被 seek 分段取。
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        upstreamRequest.headers.set(HttpHeaders.rangeHeader, range);
      }
      upstreamRequest.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');

      final up = await upstreamRequest.close();
      session.requests++;
      if (up.statusCode != HttpStatus.ok &&
          up.statusCode != HttpStatus.partialContent) {
        session.failures++;
        // ⚠️ warn 而不是 debug：健康的会话**永远**走不到这里，所以它一旦出现
        // 就是真问题（最常见是 `Video-Auth` Cookie 没带上 —— 夸克换了 HLS 之后
        // 取分片全靠它，缺了就是 4xx）。落 debug 会让「转码档播不了」在现场
        // 日志里彻底消失，而分片请求量大、逐条记又必须有个上界，取 warn 正好：
        // 正常时零条，出故障时才成片出现。
        diag.warn(
          '中继',
          'HLS 会话 ${session.label} 上游返回 ${up.statusCode}：'
          '${upstream.path}（已失败 ${session.failures} 次）',
        );
        await up.drain<void>();
        response
          ..statusCode = HttpStatus.badGateway
          ..headers.set(HttpHeaders.contentLengthHeader, 0);
        await response.close();
        return;
      }

      if (_isPlaylistResponse(upstream, up)) {
        // 播放列表很小（实测十几 KB），一次读全是安全的。
        final bytes = await up.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
        final rewritten = rewriteHlsForRelay(
          utf8.decode(bytes, allowMalformed: true),
          playlistUrl: upstream,
        );
        final body = utf8.encode(rewritten.body);
        response
          ..statusCode = HttpStatus.ok
          ..headers.set(
            HttpHeaders.contentTypeHeader,
            'application/vnd.apple.mpegurl',
          )
          ..headers.contentLength = body.length
          ..add(body);
        await response.close();
        diag.debug(
          '中继',
          'HLS 播放列表已改写 ${rewritten.entryCount} 条（${upstream.path}）',
        );
        return;
      }

      response
        ..statusCode = up.statusCode
        ..headers.set(
          HttpHeaders.contentTypeHeader,
          up.headers.contentType?.toString() ?? 'video/mp2t',
        )
        // ⚠️ 声明支持 Range：mpv 靠它判断能不能 seek，少了这行进度条拖不动
        // （同 [_serve] 里那条注释）。
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      final length = up.headers.contentLength;
      if (length >= 0) response.headers.contentLength = length;
      await response.addStream(up);
      await response.close();
    } catch (e) {
      session.failures++;
      diag.debug('中继', 'HLS 代理失败：$e');
      try {
        response
          ..statusCode = HttpStatus.badGateway
          ..headers.set(HttpHeaders.contentLengthHeader, 0);
        await response.close();
      } catch (_) {
        // 响应头可能已经发出去了，关不掉就算了 —— 这里不该再抛。
      }
    } finally {
      client?.close(force: true);
    }
  }

  /// 这条上游响应是不是播放列表。
  ///
  /// 判据**按扩展名优先**，不靠嗅探正文：分片动辄一两 MB，为了嗅探先把首块
  /// 读出来再想办法塞回去，只会让透传路径变复杂。列表的地址一定以 `.m3u8`
  /// 结尾（master 的子列表也一样），Content-Type 只作兜底。
  bool _isPlaylistResponse(Uri upstream, HttpClientResponse up) {
    if (upstream.path.toLowerCase().endsWith('.m3u8')) return true;
    final type = up.headers.contentType?.mimeType;
    return type == 'application/vnd.apple.mpegurl' ||
        type == 'application/x-mpegurl';
  }

  /// 服务一个读取器（一个 HTTP 请求）。[reader] 是它的身份 —— 用来让中继
  /// 分辨「谁在推动预取窗口」，见 [RelayReaderArbiter]。
  ///
  /// ⚠️ **seek 时旧连接不一定断**。实测（真 libmpv）播放器拖进度条后旧读取器
  /// 会留在原地继续被喂，所以「旧读取器会自己消失」这个假设不成立 —— 必须靠
  /// 身份判定把它降级，否则 8 路 worker 会一直分给已经不看的位置。
  Future<void> _serve(
    HttpRequest request,
    _RelaySession session,
    int reader,
  ) async {
    final response = request.response;
    // 实际写进响应体的字节数。**只有这里统计得到** —— 播放器报
    // `Failed to open` 时，「一个字节都没发出」与「发了几百 MiB 才断」是
    // 完全不同的两种故障；而 [session.stats] 里的 `downloadedBytes` 是
    // **上游取回**的字节数，两者不是一回事。
    var delivered = 0;
    var aborted = false;
    // 首字节延迟的起点。**这是「切换影片经常打不开」的第一现场证据** ——
    // 它直接由 `chunkSize` 决定（见 `chunkSize` 的文档），却只有在读第一块
    // 的耗时被写出来时才看得见。只算到「首块已下发」，不参与任何判断。
    final startedAt = DateTime.now();
    // 已经单独记过原因的分支（416）：别让 finally 再补一条「0 字节」的 warn，
    // 同一件事记两遍只会让现场日志更难读。
    var explained = false;
    try {
      final total = session.totalLength;
      final requested =
          parseRangeHeader(request.headers.value(HttpHeaders.rangeHeader), total);
      final range = clampRange(requested ?? ByteRange(0, total - 1), total);
      if (range == null) {
        // 成因只有一个：请求的范围完全落在流长度之外（拿旧会话的长度去读
        // 新流时会出现）。它是 416 而不是 404，但播放器同样只报一句
        // `Failed to open`，所以必须自己留下痕迹。
        diag.warn(
          '中继',
          '会话 ${session.token} 拒绝读取器 #$reader：Range 超出流长度'
          '（流长 $total 字节，请求 '
          '${request.headers.value(HttpHeaders.rangeHeader) ?? "无"}）',
        );
        explained = true;
        response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..headers.set('content-range', 'bytes */$total')
          ..headers.set(HttpHeaders.contentLengthHeader, 0);
        return;
      }

      // 登记这个读取器。范围够长才算「在放片子」，才有资格推动预取窗口 ——
      // 读 MKV `Cues` 的探索引（请求文件尾那一小段）不算，见 [RelayReaderArbiter]。
      session.attachReader(reader, range.length);

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

      // 响应头发出**之前**记一条：事后能看到「我们答应了给哪一段、答应了多少
      // 字节」。播放器打不开时，这是判断「中继回错了没有」的唯一依据 ——
      // 响应一旦开始发，头就收不回来了。
      diag.debug(
        '中继',
        '会话 ${session.token} 读取器 #$reader → ${response.statusCode} '
        '${formatContentRange(range, total)}',
      );

      var firstChunk = true;
      if (request.method != 'HEAD') {
        await for (final bytes in session.read(range, reader)) {
          if (firstChunk) {
            firstChunk = false;
            // 「首块已下发」= 上游确实取到数据了。没有这一条、播放器却仍报
            // Failed to open，问题就不在中继 —— 它连第一个字节都没能给出。
            //
            // ⚠️ **耗时一定要打**：它是 `chunkSize` 是否过大的唯一直接读数。
            // 中继预热 2500ms、mpv 打开 ~5s 都压在这上面，超过就是「换片必打
            // 不开」。判据：这一行 > 2.5s 且日志里有「新中继预热超时」→ 块太大。
            final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
            diag.debug(
              '中继',
              '会话 ${session.token} 读取器 #$reader 首块已下发'
              '（${bytes.length} 字节，耗时 ${(elapsedMs / 1000).toStringAsFixed(2)}s）',
            );
          }
          response.add(bytes);
          delivered += bytes.length;
          // 每块刷一次：不 flush 的话数据会攒在 dart:io 的缓冲里，
          // mpv 那边就是「缓冲条不动、等半天才突然涨一截」。
          await response.flush();
        }
      }
    } catch (e) {
      // 客户端断开（mpv seek 时会直接掐掉旧连接）是最常见的正常退出，
      // 不是错误。只记 debug，别惊动用户。
      aborted = true;
      diag.debug('中继', '响应中断（通常是播放器换源/seek）：$e');
    } finally {
      // 当前读取器走了必须让位，否则锚点再没人推动、窗口冻在原地。
      session.release(reader);
      await response.close().catchError((Object _) {});

      // ⚠️ 「一个字节都没发出」**升级成 warn**：这正是播放器报
      // `Failed to open <中继地址>` 的直接机制 —— ffmpeg 拿到了响应头却读不到
      // 任何数据，无法识别容器格式，于是判定「打不开」。原来它和「正常换源掐断
      // 连接」共用同一条 debug，这类故障在现场日志里会彻底消失。
      final summary = '会话 ${session.token} 读取器 #$reader 结束：'
          '已下发 $delivered 字节${aborted ? '（连接中断）' : ''}';
      if (delivered == 0 && !explained) {
        diag.warn('中继', '$summary ← 一个字节都没发出，播放器可能因此报 Failed to open');
      } else {
        diag.debug('中继', summary);
      }
    }
  }

  /// ⚠️ HLS 会话**刻意返回 null**。它不做预取，没有「已缓存多少」可言；
  /// 而 `warmUpRelay` 对 null 的语义正是「拿不到统计 → 不等了，直接切换」，
  /// 所以换档到转码档时不会白等一个预热超时。
  @override
  RelayStats? statsOf(String token) => _sessions[token]?.stats;

  /// 当前会话数（含 HLS 会话）。诊断页靠它回答「中继到底在不在干活」。
  @override
  int get sessionCount => _sessions.length + _hlsSessions.length;

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
    var connects = 0;
    for (final session in _sessions.values) {
      final s = session.stats;
      downloaded += s.downloadedBytes;
      cached += s.cachedBytes;
      workers += s.activeWorkers;
      failures += s.upstreamFailures;
      requests += s.upstreamRequests;
      connects += s.upstreamConnects;
    }
    return RelayStats(
      downloadedBytes: downloaded,
      cachedBytes: cached,
      activeWorkers: workers,
      upstreamFailures: failures,
      upstreamRequests: requests,
      upstreamConnects: connects,
    );
  }

  /// 当前会话的来源标签（脱敏后），供诊断显示。含 HLS 会话。
  @override
  List<String> get sessionLabels => <String>[
        ..._sessions.values.map((s) => s.label),
        ..._hlsSessions.values.map((s) => s.label),
      ];

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
    // HLS 会话没有要 dispose 的 worker / 缓存，摘掉登记即可 ——
    // 摘掉之后这个 token 的所有请求会立刻转成 404（见 [_notFound]）。
    final hls = _hlsSessions.remove(token);
    if (hls != null) {
      diag.info(
        '中继',
        '会话 $token 已关闭（${hls.label}）'
        '｜HLS 上游请求 ${hls.requests} 次，失败 ${hls.failures} 次',
      );
      return;
    }
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
    _hlsSessions.clear();
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
    }
  }
}

/// 一条 **HLS**（转码档）会话。
///
/// 与 [_RelaySession] 的区别是**它不缓存、不预取**：HLS 本来就是「播放列表 +
/// 一堆分片」，上游按需并发下发，中继在这里只负责把地址换成 `127.0.0.1`
/// （理由见 [isRelayableUrl] 的文档），把请求原样转出去。
///
/// 因此它也**没有** `RelayStats` —— 见 [LocalStreamRelay.statsOf] 的说明。
class _HlsRelaySession {
  _HlsRelaySession({required this.headers, required this.label});

  /// 上游请求头（含 Cookie）。中继转发时逐条带上 —— 夸克缺 Cookie 一律 412，
  /// 而转码档还额外依赖 `Video-Auth`。
  final Map<String, String> headers;

  /// 脱敏后的来源标签，供诊断显示。
  final String label;

  /// 是否已经收到过**第一个**请求。分片请求一次播放有几百条，只记第一条 ——
  /// 见 [LocalStreamRelay._onRequest] 里 HLS 那一支。
  bool sawRequest = false;

  /// 上游请求次数 / 失败次数。只用于关闭时落一条日志（也回答「这次换档到底
  /// 有没有真的走中继」）。
  int requests = 0;
  int failures = 0;
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
    required this.startOffset,
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

  /// 播放器**即将开始读**的字节偏移（续播点换算）。见 [StreamRelay.open]。
  ///
  /// 只在 [start] 里用一次：把预取窗口摆到那儿。之后窗口跟着播放器真实的
  /// Range 请求走（[_ensure] 会重设 [_prefetchBase]），这个初值就不再有影响。
  final int startOffset;

  /// 播放器此刻就要的块（插队，优先于顺序预取）。
  final Queue<int> _priority = Queue<int>();
  final Set<int> _queued = <int>{};

  /// **已被抛弃的旧读取器**的需求。见 [ReaderDemand.stale]。
  ///
  /// 与 [_priority] 分开排队是必须的：混在一起的话，被拖走的旧连接会和正在播的
  /// 那条流**一比一地抢 worker**（实测旧位置吃掉 78% 带宽）。这里的需求只在
  /// 预取窗口已经填满、没有别的活干时才服务 —— 也就是「白捡的余量」。
  final Queue<int> _stale = Queue<int>();
  final Set<int> _queuedStale = <int>{};

  /// 判定「哪个读取器有权推动预取窗口」。纯状态机，见 [RelayReaderArbiter]。
  ///
  /// 阈值取「一个预取窗口的字节数」：mpv 播放时的 Range 是开放式的（几个 GiB），
  /// 读 MKV `Cues` 的探索引只有一两块，两者差好几个数量级，不会误判。
  late final RelayReaderArbiter _arbiter = RelayReaderArbiter(
    window: prefetchChunks,
    minStreamBytes: prefetchChunks * layout.chunkSize,
  );

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

  /// 累计**新建**过多少条上游连接。复用生效时它约等于 worker 数，
  /// 远小于 [_requests]；量级接近就说明每块都在重连（TLS 握手锯齿）。
  int _connects = 0;

  bool _closed = false;

  int get totalLength => layout.totalLength;

  RelayStats get stats => RelayStats(
        downloadedBytes: _downloaded,
        cachedBytes: cache.bytes,
        activeWorkers: _inflight.length,
        upstreamFailures: _failures,
        upstreamRequests: _requests,
        upstreamConnects: _connects,
      );

  void start() {
    // 把预取窗口摆到**播放器即将读的位置**，而不是永远从 0 开始。
    //
    // 换清晰度 / 换集时续播点常在中后段：从文件头预取的几百 MiB 一行都用不上，
    // 而播放器真正要的那一块还得等一次上游往返。摆对了位置，「开流到出画」
    // 这一段就少掉那次往返。
    //
    // 摆错了也没有代价：播放器紧接着发来的真实 Range 请求会在 [_ensure] 里
    // 把 [_prefetchBase] 重设成正确位置，窗口立刻跟过去。
    if (startOffset > 0) {
      final index = layout.indexOf(
        startOffset.clamp(0, layout.totalLength - 1),
      );
      if (layout.isValidIndex(index)) {
        _prefetchBase = index;
        _scan = index;
        _arbiter.seed(index);
      }
    }
    for (var i = 0; i < connections; i++) {
      unawaited(_worker());
    }
  }

  /// 取出一段字节流。**按需拉取 + 插队**，块没到就等着。
  ///
  /// [reader] 是这个读取器的身份 —— 决定它的需求进哪个队列、能不能推动预取
  /// 窗口。见 [RelayReaderArbiter]。
  Stream<Uint8List> read(ByteRange range, int reader) async* {
    var offset = range.start;
    final end = range.end;
    while (offset <= end) {
      if (_closed) return;
      final index = layout.indexOf(offset);
      final data = await _ensure(index, reader);
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

  /// 登记一个读取器（一个 HTTP 请求）。[rangeLength] 是它这次要读的字节数。
  void attachReader(int reader, int rangeLength) =>
      _arbiter.attach(reader, stream: _arbiter.isStream(rangeLength));

  /// 一个读取器结束了：让出「当前读取器」的身份。
  void release(int reader) => _arbiter.release(reader);

  /// 保证第 [index] 块就绪。已缓存就立刻返回，否则插队并等它到。
  Future<Uint8List?> _ensure(int index, int reader) {
    final cached = cache.get(index);
    if (cached != null) return Future<Uint8List?>.value(cached);

    // ⚠️ **本文件最关键的一处判定。** 预取窗口跟着「谁」走，见
    // [RelayReaderArbiter]。改成「谁请求谁就推动窗口」的话，拖进度条之后旧连接
    // 会把窗口一路拽回旧位置，8 路 worker 被来回改派 —— 实测 seek 后 69 秒内
    // 78% 带宽喂给了已经不看的地方，新位置饿死，就是「看一会卡一会」。
    final demand = _arbiter.decide(readerId: reader, index: index);
    if (demand == ReaderDemand.anchor) {
      final jumped = (index - _prefetchBase).abs() > prefetchChunks;
      _prefetchBase = index;
      if (jumped) _onAnchorJumped(index);
    }

    if (demand == ReaderDemand.stale) {
      if (!_queuedStale.contains(index) && !_inflight.contains(index)) {
        _stale.addLast(index);
        _queuedStale.add(index);
      }
    } else if (!_queued.contains(index) && !_inflight.contains(index)) {
      _priority.addLast(index);
      _queued.add(index);
    }
    final waiter = _waiters.putIfAbsent(index, () => Completer<Uint8List?>());
    _notifyWorkers();
    return waiter.future;
  }

  /// 预取窗口整个换了地方（真 seek，不是顺读）。
  ///
  /// 三件事必须一起做，否则「换了位置」只是把锚点写对、缓存和队列还在拖后腿：
  ///
  /// 1. **旧位置的排队降级**（不是丢弃）：留在主队列里它们会和正在播的那条流
  ///    一比一抢 worker。丢弃则会让那些 `_ensure` 永远不返回，读取器就那么吊着。
  /// 2. **清掉缓存**：旧位置的块一行都用不上了，留着只会占满 LRU，把新位置的
  ///    预取窗口挤成「下了就淘汰、淘汰了再下」。
  /// 3. **把新窗口里的等待提升回主队列**：跳转后的第一块往往在降级之前就已经
  ///    排过队了，不提升的话播放器要等一个「低优先」才拿到起播那块。
  void _onAnchorJumped(int index) {
    while (_priority.isNotEmpty) {
      final queued = _priority.removeFirst();
      _queued.remove(queued);
      if (_queuedStale.contains(queued) || _inflight.contains(queued)) continue;
      _stale.addLast(queued);
      _queuedStale.add(queued);
    }
    cache.clear();

    final windowEnd = math.min(layout.chunkCount, index + prefetchChunks);
    final keep = Queue<int>();
    while (_stale.isNotEmpty) {
      final queued = _stale.removeFirst();
      _queuedStale.remove(queued);
      if (_inflight.contains(queued)) continue;
      if (queued >= index && queued < windowEnd && !_queued.contains(queued)) {
        _priority.addLast(queued);
        _queued.add(queued);
      } else if (!_queuedStale.contains(queued)) {
        keep.addLast(queued);
        _queuedStale.add(queued);
      }
    }
    _stale.addAll(keep);

    diag.info(
      '中继',
      '播放位置跳到块 $index'
      '（约 ${(index * layout.chunkSize / 1048576).round()} MiB）：'
      '预取窗口改锚，旧位置的排队已降级、缓存已清空',
    );
  }

  Future<void> _worker() async {
    // 每个 worker **长期持有一条连接**，一块接一块复用 —— 这是「不再每 2 MiB
    // 重连」的关键。复用把上万次 TLS 握手压到 worker 数量级，净喂流从
    // 「猛灌→握手间隙归零」的锯齿变平稳，稳态才追得上高码率原画。
    HttpClient? client;
    try {
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
        client ??= _openClient();
        if (!await _fetch(index, client)) {
          // 连接级失败：丢掉这条，下一块重建（只影响本 worker）。
          client.close(force: true);
          client = null;
        }
      }
    } finally {
      client?.close(force: true);
    }
  }

  /// 新建一条**直连**的上游连接，并计入 [_connects]。
  HttpClient _openClient() {
    _connects++;
    final client = HttpClient();
    // ⚠️ 必须直连：`dart:io` 默认会读 `http_proxy` 环境变量，而本机那份
    // 代理配置是为命令行工具准备的，走它会把网盘直链也一起代理掉 ——
    // 表现是「扫描正常、播放奇慢」，且看不出原因。
    client.findProxy = (Uri _) => 'DIRECT';
    client.connectionTimeout = const Duration(seconds: 20);
    // keep-alive 是 `HttpClient` 的默认行为；把空闲回收放宽一点，别让连续
    // 取块之间那几百毫秒的空档把连接回收掉 —— 回收了就等于又要握手。
    client.idleTimeout = const Duration(seconds: 30);
    return client;
  }

  /// 挑下一个要拉的块：**先插队，再顺序预取，最后才是被抛弃的旧读取器。**
  ///
  /// 三段顺序是刻意的。旧读取器的需求排在**最后**：只要预取窗口还有没拉到的块，
  /// worker 就一直在为「正在播的那条流」干活，旧连接只能捡余量。反过来（把它们
  /// 和主队列混在一起）它们会和正在播的那条流一比一抢 worker —— 实测旧位置能
  /// 吃掉 78% 的上游带宽。
  int? _take() {
    while (_priority.isNotEmpty) {
      final index = _priority.removeFirst();
      _queued.remove(index);
      if (!layout.isValidIndex(index)) continue;
      if (cache.contains(index) || _inflight.contains(index)) continue;
      return index;
    }

    final windowEnd = math.min(layout.chunkCount, _prefetchBase + prefetchChunks);
    if (_prefetchBase < windowEnd) {
      if (_scan < _prefetchBase || _scan >= windowEnd) _scan = _prefetchBase;
      for (var i = 0; i < windowEnd - _prefetchBase; i++) {
        final index = _scan;
        _scan = _scan + 1 >= windowEnd ? _prefetchBase : _scan + 1;
        if (cache.contains(index) || _inflight.contains(index)) continue;
        return index;
      }
    }

    while (_stale.isNotEmpty) {
      final index = _stale.removeFirst();
      _queuedStale.remove(index);
      if (!layout.isValidIndex(index)) continue;
      if (cache.contains(index) || _inflight.contains(index)) continue;
      return index;
    }
    return null;
  }

  /// 取第 [index] 块并落缓存。
  ///
  /// 返回 **false 表示这条上游连接已坏**，调用方应重建它；
  /// true 表示连接仍可继续复用（含「上游给了响应但状态/长度不对」）。
  Future<bool> _fetch(int index, HttpClient client) async {
    _inflight.add(index);
    _requests++;
    try {
      final data = await _fetchChunk(index, client);
      _downloaded += data.lengthInBytes;
      cache.put(index, data);
      _settle(index, data);
      return true;
    } catch (e) {
      _failures++;
      diag.warn('中继', '取块 $index 失败：$e');
      _settle(index, null);
      // 只有「上游给了响应但状态/长度不对」才保留连接（[_UpstreamException]）；
      // socket / TLS / 读中断一律按连接已坏处理，让调用方重建。
      return e is _UpstreamException;
    } finally {
      _inflight.remove(index);
      _notifyWorkers();
    }
  }

  Future<Uint8List> _fetchChunk(int index, HttpClient client) async {
    final range = layout.rangeOf(index);
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
      throw _UpstreamException('上游返回 ${response.statusCode}');
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
      throw _UpstreamException('上游忽略了 Range（给了 $total 字节，只要 $expected）');
    }

    final out = Uint8List(total);
    var p = 0;
    for (final piece in pieces) {
      out.setRange(p, p + piece.length, piece);
      p += piece.length;
    }
    return out;
  }

  void _settle(int index, Uint8List? data) {
    final waiter = _waiters.remove(index);
    if (waiter != null && !waiter.isCompleted) waiter.complete(data);
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
    _priority.clear();
    _queued.clear();
    _stale.clear();
    _queuedStale.clear();
    cache.clear();
    _notifyWorkers();
  }
}

/// 上游**给了响应**，但状态码或长度不对（非 206/200、或无视 Range 给了整条流）。
///
/// 与 socket / TLS 失败区分开：这条路径说明**连接本身是好的**，不该因此把
/// 连接池里的连接丢掉重建 —— 否则一次 416 就会连累其它正在复用的 worker。
class _UpstreamException implements Exception {
  _UpstreamException(this.message);
  final String message;

  @override
  String toString() => message;
}
