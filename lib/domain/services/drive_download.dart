import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/error/drive_error.dart';
import '../../core/utils/ticket_headers.dart';
import '../adapters/cloud_drive_adapter.dart';
import '../entities/stream_ticket.dart';

/// 分块下载的默认并发连接数。
///
/// 与 `LocalStreamRelay` 同口径：8 条是实测下来「能跑满家用带宽又不上风控」
/// 的量级。网盘对单连接有吞吐上限（~3-5 MB/s），8 条并发可把这个上限乘上去。
const int kDownloadConnections = 8;

/// 分块下载的单块字节数（2 MiB）。
///
/// 与 `LocalStreamRelay` 同值：太小则 Range 请求开销占比高，太大则单块
/// 下载中断后浪费的带宽多。2 MiB 在实测中是吞吐与恢复成本的平衡点。
const int kDownloadChunkSize = 2 * 1024 * 1024;

/// 包体的**静默超时**：超过这么久没有收到新数据就判失败。
///
/// ## 为什么需要它
///
/// `dart:io` 的 `HttpClient.idleTimeout` 管的是**连接池里的空闲连接**，
/// 不是「正在读的响应」；`connectionTimeout` 只管建连。也就是说
/// 「响应头回来了、包体却再也不来」这种情况**没有任何超时兜底** ——
/// `await for` 会一直挂着。
///
/// 现场表现（2026-10-09，百度非会员通道）：下载卡在 0%，日志最后一行
/// 还是「取链成功」，直到**七分多钟后**服务端自己把连接掐掉才报错。
/// 加这道闸门之后，同样的静默会在 30 秒内变成一条明确的 `network` 错误，
/// 用户看到的是「网络中断」而不是「卡死」。
///
/// ⚠️ 判据是「**两块之间**的间隔」，不是「整份下载的耗时」—— 后者会把
/// 正常的大文件下载也判死。80 KB/s 的慢通道每块间隔只有毫秒级，
/// 30 秒的静默只可能是真停滞。
const Duration kDownloadStallTimeout = Duration(seconds: 30);

/// 把网盘上的**一个文件**下载到本地磁盘。
///
/// ## 多连接分块下载
///
/// 网盘对单条 TCP 连接有吞吐上限（实测 ~3-5 MB/s）。单连接下载永远占不满
/// 带宽——这与 `LocalStreamRelay` 文件头注释里的实测结论一致。
///
/// 因此当文件足够大（> [_kChunkThreshold]）且服务端支持 Range 时，下载走
/// [_downloadChunked]：把剩余字节切成 [chunkSize] 大小的块，开 [connections]
/// 条连接并发拉取，按**顺序**落盘到 `.part`。这样 `.part` 始终是一段连续
/// 的前缀，断点续传的语义不变。
///
/// 服务端不支持 Range（回 200 而不是 206）时，自动降级到 [_downloadSingle]
/// 单连接顺序读。
///
/// ## 为什么取链复用 `resolveStream` 而不是自己打下载接口
///
/// 夸克的 `/1/clouddrive/file/download`（字面意义上的「下载」接口）**单文件
/// 超过 50 MiB 直接回 `code=23018`**。而 `resolveStream` 内部那条降级链的
/// 第一条 `GET /file/audioplay?fid=` 实测**对任意 fid 都返回原文件本身**
/// （连被服务端判成 `text/plain` 的 DSF 也照原样给字节），且不受体积限制。
///
/// 也就是说：**「哪条接口能拿到这个文件的原始字节」这件事，
/// 适配器内部已经解完了**，而且解的顺序比这里能猜的更靠谱（它拿真实响应
/// 交叉验证过）。这里再写一遍等于把同一份知识抄第二遍 —— 抄歪了的表现是
/// 「视频能播、同一个文件下载却报 23018」，极难联想到取链顺序。
///
/// 所以：取链交给适配器，本服务只负责**「拿到地址之后怎么把它流到磁盘上」**。
///
/// ## 原子落盘
///
/// 全程写 `<目标路径>.part`，**校验通过才 rename**。直接写目标文件的话，
/// 取消 / 断网 / 体积不符时会在用户选的位置留下一个**看起来正常、其实截断**
/// 的文件 —— 那种文件最难排查（播放器 / 解压软件都只会说「损坏」）。
///
/// ## 断点续传：`.part` 就是断点
///
/// 续传不需要任何额外的元数据 —— 磁盘上那个 `.part` 有多长，就是从哪儿接。
/// 调用方给的 [download] 的 `startOffset` 只是**提示**：服务会拿 `.part` 的
/// 真实长度校正它（见下），因为两者可能不一致，而不一致时**必须以磁盘为准**。
///
/// 分块下载同样遵守这条：写盘是**顺序的**（见 [_ChunkedWriter]），`.part`
/// 的长度永远等于已连续落盘的字节数。
class DriveDownloadService {
  DriveDownloadService({
    required this.adapter,
    HttpClient Function()? clientFactory,
    this.connections = kDownloadConnections,
    this.chunkSize = kDownloadChunkSize,
    this.stallTimeout = kDownloadStallTimeout,
  }) : _clientFactory = clientFactory ?? _directClient;

  final CloudDriveAdapter adapter;
  final HttpClient Function() _clientFactory;

  /// 分块下载的并发连接数。
  ///
  /// ⚠️ 这只是**默认值**：票据上钉了上限时以票据为准
  /// （见 [StreamTicket.maxConnections]）。
  final int connections;

  /// 分块下载的单块字节数。
  final int chunkSize;

  /// 包体两块之间的最大静默时长，超过即判 `network` 失败。
  ///
  /// 可注入是为了能测 —— 拿默认的 30 秒写用例会让测试跑 30 秒。
  final Duration stallTimeout;

  /// 文件小于此值时不走分块——单连接下小文件足够快，开多连接的握手
  /// 开销不划算。
  int get _kChunkThreshold => chunkSize * 4;

  /// 新建一条**直连**的 HTTP 客户端。
  ///
  /// ⚠️ 必须显式 `DIRECT`：`dart:io` 的 `HttpClient` 默认会读 `http_proxy`
  /// 环境变量，而本机那份代理配置是给命令行工具准备的 —— 走它会把网盘直链
  /// 一起代理掉。表现是「扫描正常、下载奇慢」，且看不出原因
  /// （与 `LocalStreamRelay._openClient` 同一口径）。
  static HttpClient _directClient() {
    final client = HttpClient();
    client.findProxy = (Uri _) => 'DIRECT';
    client.connectionTimeout = const Duration(seconds: 20);
    client.idleTimeout = const Duration(seconds: 30);
    return client;
  }

  /// 下载 [fileId] 到 [savePath]。
  ///
  /// [startOffset] 是「接着上次下到哪儿」的**期望值**（0 = 从头来）。
  /// 它会被磁盘上 `.part` 的真实长度校正，理由见下。
  ///
  /// [onProgress] 至少在开始与结束时各回调一次；服务端给了体积时
  /// `total` 非空，进度条才能显示确定值。**续传时第一次回调的
  /// `received` 是断点位置而不是 0** —— 进度条才不会从 0 重新爬。
  ///
  /// [control] 被触发时：
  ///   - `pause()` → 抛 [DriveDownloadPaused]，**保留 `.part`**（那是「继续」
  ///     要用的东西），已写下的字节全部落盘；
  ///   - `cancel()` → 抛 [DriveDownloadCancelled]，**删掉 `.part`**
  ///     （用户说的是「不要了」，留一个半截文件只是垃圾）。
  ///
  /// 注意暂停 / 取消只保证在「已经拿到响应头、正在收包体」这一段生效 ——
  /// 卡在取链或等响应头时停不下来，那两段各自有 20 秒超时兜底。
  Future<DriveDownloadResult> download({
    required String fileId,
    required String savePath,
    int startOffset = 0,
    DriveDownloadControl? control,
    void Function(DriveDownloadProgress progress)? onProgress,
  }) async {
    final ticket = await adapter.resolveStream(fileId);
    if (control?.isCancelled ?? false) throw const DriveDownloadCancelled();
    if (control?.isPaused ?? false) throw const DriveDownloadPaused(0);

    final target = File(savePath);
    final part = File('$savePath.part');

    // ---- 断点位置的**唯一真源是磁盘** ----
    //
    // 调用方给的 `startOffset` 来自数据库里那个按秒节流写的进度快照，
    // 它可能比真实值**大**（写完还没 fsync 就崩了）。拿一个偏大的偏移去
    // 发 `Range`，服务端回 **416 Range Not Satisfiable**，表现是
    // 「点了继续，直接失败」，而用户刚看到的是「已经下了 8 GB」。
    //
    // 反过来偏小则会重复写一段 —— 文件会坏但**不报错**，更糟。
    // 所以一律以 `.part` 的实际长度为准。
    var offset = startOffset;
    if (offset > 0) {
      final onDisk = await part.exists() ? await part.length() : 0;
      if (onDisk != offset) offset = onDisk;
    }

    // ---- 分块 vs 单连接 ----
    //
    // 文件足够大、服务端支持 Range、开了多条连接时走分块。
    // 任一条件不满足就退回单连接——这是正确的降级，不是「次等方案」：
    // 小文件单连接已经够快。
    //
    // ⚠️ 并发数**不是**本服务说了算：票据上可能钉了一个上限
    // （见 [StreamTicket.maxConnections]）。百度普通通道就是典型 ——
    // 它的限速按**账号**算，8 条连接的总吞吐还不如 1 条，而且每条都会
    // 被拖到读超时、最后被服务端掐断。所以这里一律用 `connectionsFor`。
    final totalSize = ticket.contentLength;
    final maxConnections = ticket.connectionsFor(connections);
    if (totalSize != null &&
        totalSize > offset + _kChunkThreshold &&
        ticket.supportsRange &&
        maxConnections > 1) {
      try {
        return await _downloadChunked(
          ticket: ticket,
          target: target,
          part: part,
          totalLength: totalSize,
          startOffset: offset,
          connections: maxConnections,
          control: control,
          onProgress: onProgress,
        );
      } on _RangeNotSupportedException {
        // 服务端不支持 Range（回 200 而非 206）→ 降级到单连接顺序读。
        // `_downloadChunked` 的 finally 已删掉 `.part`，必须把 offset 归零：
        // 否则 `_downloadSingle` 会按旧 offset 开 append 模式 / 发 Range，
        // 但 `.part` 已经不在了，拼出来的文件会错位。
        offset = 0;
      }
    }

    return _downloadSingle(
      ticket: ticket,
      target: target,
      part: part,
      startOffset: offset,
      control: control,
      onProgress: onProgress,
    );
  }

  // -------------------------------------------------------------------
  // 单连接下载（原有实现）
  // -------------------------------------------------------------------

  Future<DriveDownloadResult> _downloadSingle({
    required StreamTicket ticket,
    required File target,
    required File part,
    required int startOffset,
    required DriveDownloadControl? control,
    required void Function(DriveDownloadProgress)? onProgress,
  }) async {
    HttpClient? client;
    IOSink? sink;
    var paused = false;
    try {
      client = _clientFactory();
      client.autoUncompress = false;

      final request = await client.getUrl(ticket.url);
      // ⛔ 不能只 `headers.forEach(set)`：直链 302 之后 Dart 会丢掉 UA，
      //    而百度 CDN 的签名是按 UA 签的 —— 见 [applyTicketHeaders]。
      applyTicketHeaders(client, request, ticket.headers);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (startOffset > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$startOffset-');
      }

      final response = await request.close();
      if (response.statusCode >= 400) {
        // 同上：留一小段体，见 `_readBodySnippet` 的文档。
        final snippet = await _readBodySnippet(response);
        throw DriveException(
          type: _typeForStatus(response.statusCode),
          message: '下载失败：服务器返回 HTTP ${response.statusCode}'
              '${snippet.isEmpty ? "" : "，响应体=$snippet"}',
          httpStatus: response.statusCode,
        );
      }

      // 服务端**忽略了 Range**（回 200 而不是 206）时必须从 0 重来。
      if (startOffset > 0 && response.statusCode != 206) startOffset = 0;

      final declared =
          _totalBytes(response, ticket, startOffset);

      await target.parent.create(recursive: true);
      sink =
          part.openWrite(mode: startOffset > 0 ? FileMode.append : FileMode.write);

      var received = startOffset;
      onProgress?.call(DriveDownloadProgress(received: received, total: declared));

      // ⚠️ 必须过 `_stallGuarded`：见 [kDownloadStallTimeout] ——
      //    没有它，「响应头到了、包体不来」会让这一行永远挂住。
      await for (final chunk in _stallGuarded(response, stallTimeout)) {
        if (control?.isCancelled ?? false) throw const DriveDownloadCancelled();
        if (control?.isPaused ?? false) {
          paused = true;
          throw DriveDownloadPaused(received);
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(
          DriveDownloadProgress(received: received, total: declared),
        );
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (declared != null && declared > 0 && received != declared) {
        throw DriveException(
          type: DriveErrorType.network,
          message: '下载中断：只收到 $received / $declared 字节，文件可能不完整',
        );
      }

      if (await target.exists()) await target.delete();
      final saved = await part.rename(target.path);
      return DriveDownloadResult(path: saved.path, bytes: received);
    } on DriveDownloadPaused {
      rethrow;
    } on DriveDownloadCancelled {
      rethrow;
    } on DriveException {
      rethrow;
    } on SocketException catch (e) {
      throw DriveException(
        type: DriveErrorType.network,
        message: '下载中断：${e.message}',
      );
    } catch (e) {
      throw DriveException(
        type: DriveErrorType.unknown,
        message: '下载失败：$e',
      );
    } finally {
      await sink?.close().catchError((Object _) {});
      client?.close(force: true);
      if (!paused) {
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {}
      }
    }
  }

  // -------------------------------------------------------------------
  // 多连接分块下载
  // -------------------------------------------------------------------

  /// 用 [connections] 条 TCP 连接并发拉取文件的不同部分，按顺序落盘。
  ///
  /// ## 设计要点
  ///
  /// - **Worker** 负责取块：每条连接长期持有（keep-alive），从共享的
  ///   `nextFetch` 计数器取下一块序号，发 `Range` 请求，把字节放进
  ///   有界的内存缓冲区 `buffer`。
  /// - **Writer** 负责落盘：按 `nextWrite` 顺序从 `buffer` 取块，追加
  ///   写入 `.part`。这样 `.part` 永远是一段连续的前缀——断点续传的
  ///   语义与单连接完全一致。
  /// - **背压**：缓冲区满时 worker 等待，避免内存失控。
  /// - **错误传播**：worker 捕获异常后存入 `workerError` 并退出；
  ///   writer 在「worker 全退了但需要的块还缺」时抛出那个错误。
  /// - **暂停 / 取消**：worker 和 writer 都在每个块边界检查 `control`。
  ///
  /// ## 为什么不复用 `LocalStreamRelay`
  ///
  /// 中继的调度目标是「让正在播的那条流不断」（预取窗口跟着播放头走、
  /// LRU 淘汰旧块、读取器仲裁）。下载要的是「从头到尾把整份文件搬下来」
  /// ——不需要预取窗口、不需要淘汰、不需要 127.0.0.1 的 HTTP 往返。
  /// 但**多连接 + 分块 + Range 请求**这个核心思路是相通的。
  Future<DriveDownloadResult> _downloadChunked({
    required StreamTicket ticket,
    required File target,
    required File part,
    required int totalLength,
    required int startOffset,
    required int connections,
    required DriveDownloadControl? control,
    required void Function(DriveDownloadProgress)? onProgress,
  }) async {
    final remaining = totalLength - startOffset;
    if (remaining <= 0) {
      // 已完整——直接 rename。
      if (await target.exists()) await target.delete();
      final saved = await part.rename(target.path);
      return DriveDownloadResult(path: saved.path, bytes: totalLength);
    }

    final chunkCount = (remaining + chunkSize - 1) ~/ chunkSize;
    final maxBuffer = connections + 4;

    // 共享状态（Dart 单 isolate，同步操作间无竞态）
    var nextFetch = 0;
    var nextWrite = 0;
    var written = startOffset;
    var activeWorkers = 0;
    Object? workerError;
    var paused = false;

    final buffer = <int, Uint8List>{};
    final clients = <HttpClient>[];
    IOSink? sink;

    try {
      await target.parent.create(recursive: true);
      sink =
          part.openWrite(mode: startOffset > 0 ? FileMode.append : FileMode.write);

      onProgress?.call(
          DriveDownloadProgress(received: written, total: totalLength));

      // ---- Worker：取块 ----
      Future<void> runWorker(HttpClient client) async {
        activeWorkers++;
        try {
          while (true) {
            if (control?.isCancelled ?? false) return;
            if (control?.isPaused ?? false) return;

            // 背压：缓冲区满时等 writer 消费。
            while (buffer.length >= maxBuffer) {
              if (control?.isCancelled ?? false) return;
              if (control?.isPaused ?? false) return;
              if (workerError != null) return;
              await Future<void>.delayed(const Duration(milliseconds: 1));
            }

            final index = nextFetch++;
            if (index >= chunkCount) return;

            try {
              final byteStart = startOffset + index * chunkSize;
              final byteEnd = math.min(
                      byteStart + chunkSize, totalLength) -
                  1;

              final request = await client.getUrl(ticket.url);
              // 同上：分块路径一样要熬过 302，见 [applyTicketHeaders]。
              applyTicketHeaders(client, request, ticket.headers);
              request.headers
                  .set(HttpHeaders.acceptEncodingHeader, 'identity');
              request.headers
                  .set(HttpHeaders.rangeHeader, 'bytes=$byteStart-$byteEnd');

              final response = await request.close();

              if (response.statusCode != HttpStatus.partialContent) {
                // ⛔ **先留一小段响应体再丢弃**。网盘的业务错（百度的 `errno`、
                // 夸克的 `code`）都写在体里；而「直链被 CDN 拒」这种**不是**
                // 业务错的失败，响应体往往是唯一的线索。只报一句 `HTTP 403`
                // 会把「请求形状不对」误判成「直链过期」——这个坑踩过。
                final snippet = await _readBodySnippet(response);
                if (response.statusCode == HttpStatus.ok) {
                  // 服务端无视 Range 返回整份——分块不可行。
                  throw _RangeNotSupportedException(response.statusCode);
                }
                throw DriveException(
                  type: _typeForStatus(response.statusCode),
                  message: '分块下载失败：HTTP ${response.statusCode}'
                      '${snippet.isEmpty ? "" : "，响应体=$snippet"}',
                  httpStatus: response.statusCode,
                );
              }

              final pieces = <List<int>>[];
              var total = 0;
              // 同上：一条连接卡住不该把整次下载拖成「无限等」。
              await for (final piece in _stallGuarded(response, stallTimeout)) {
                if (control?.isCancelled ?? false) return;
                if (control?.isPaused ?? false) return;
                pieces.add(piece);
                total += piece.length;
              }

              final expected = byteEnd - byteStart + 1;
              if (total > expected) {
                throw DriveException(
                  type: DriveErrorType.network,
                  message: '分块 $index 收到 $total 字节，只要 $expected'
                      '（服务端可能忽略了 Range）',
                );
              }
              if (total < expected) {
                throw DriveException(
                  type: DriveErrorType.network,
                  message: '分块 $index 不完整：$total / $expected 字节',
                );
              }

              final data = Uint8List(total);
              var p = 0;
              for (final piece in pieces) {
                data.setRange(p, p + piece.length, piece);
                p += piece.length;
              }
              buffer[index] = data;
            } catch (e) {
              if (e is DriveDownloadCancelled ||
                  e is DriveDownloadPaused) {
                return;
              }
              workerError ??= e;
              return;
            }
          }
        } finally {
          activeWorkers--;
        }
      }

      // ---- Writer：顺序落盘 ----
      Future<void> runWriter() async {
        while (nextWrite < chunkCount) {
          if (control?.isCancelled ?? false) {
            throw const DriveDownloadCancelled();
          }
          if (control?.isPaused ?? false) {
            paused = true;
            throw DriveDownloadPaused(written);
          }

          final data = buffer.remove(nextWrite);
          if (data == null) {
            // 需要的块还没到。如果 worker 全退了就是出错了。
            if (activeWorkers == 0) {
              final err = workerError;
              if (err != null) {
                if (err is DriveException) throw err;
                if (err is _RangeNotSupportedException) throw err;
                throw DriveException(
                  type: DriveErrorType.unknown,
                  message: '下载失败：$err',
                );
              }
              // worker 全退了但没报错——块缺失（不应该发生）。
              throw DriveException(
                type: DriveErrorType.network,
                message: '分块 $nextWrite 缺失，下载不完整',
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 1));
            continue;
          }

          sink!.add(data);
          written += data.length;
          nextWrite++;
          onProgress?.call(
              DriveDownloadProgress(received: written, total: totalLength));
        }
      }

      // ---- 启动 ----
      for (var i = 0; i < connections; i++) {
        final c = _clientFactory()..autoUncompress = false;
        clients.add(c);
        unawaited(runWorker(c));
      }

      await runWriter();

      // ---- 收尾 ----
      await sink.flush();
      await sink.close();
      sink = null;

      if (written != totalLength) {
        throw DriveException(
          type: DriveErrorType.network,
          message: '下载中断：只收到 $written / $totalLength 字节，'
              '文件可能不完整',
        );
      }

      if (await target.exists()) await target.delete();
      final saved = await part.rename(target.path);
      return DriveDownloadResult(path: saved.path, bytes: written);
    } on DriveDownloadPaused {
      rethrow;
    } on DriveDownloadCancelled {
      rethrow;
    } on _RangeNotSupportedException {
      rethrow;
    } on DriveException {
      rethrow;
    } on SocketException catch (e) {
      throw DriveException(
        type: DriveErrorType.network,
        message: '下载中断：${e.message}',
      );
    } catch (e) {
      throw DriveException(
        type: DriveErrorType.unknown,
        message: '下载失败：$e',
      );
    } finally {
      await sink?.close().catchError((Object _) {});
      for (final c in clients) {
        c.close(force: true);
      }
      if (!paused) {
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {}
      }
    }
  }

  // -------------------------------------------------------------------
  // 工具方法
  // -------------------------------------------------------------------

  /// 这一次响应对应的**文件总长**。
  ///
  /// 三条来源按可靠性排序：
  ///   1. `Content-Range: bytes 500-999/1234` 里的那个 `1234` —— 续传时
  ///      这是唯一正确的来源，`contentLength` 那栏给的是**这一段**的长度；
  ///   2. `Content-Length` + 断点偏移（非续传时它就等于总长）；
  ///   3. 票据上声明的体积（响应是 chunked、没有长度头时的兜底）。
  static int? _totalBytes(
    HttpClientResponse response,
    StreamTicket ticket,
    int offset,
  ) {
    final fromRange = _totalFromContentRange(
      response.headers.value(HttpHeaders.contentRangeHeader),
    );
    if (fromRange != null && fromRange > 0) return fromRange;
    if (response.contentLength > 0) return offset + response.contentLength;
    return ticket.contentLength;
  }

  /// 从 `Content-Range` 里取总长。`bytes 0-499/1234` → `1234`；
  /// 总长未知（`bytes 0-499/*`）或格式不认识 → `null`。
  static int? _totalFromContentRange(String? header) {
    if (header == null || header.isEmpty) return null;
    final slash = header.lastIndexOf('/');
    if (slash < 0) return null;
    return int.tryParse(header.substring(slash + 1).trim());
  }

  /// HTTP 状态码 → 归一化错误类型。
  ///
  /// 403 判成 [DriveErrorType.urlExpired] 是刻意的：网盘直链带签名，
  /// 过期后 CDN 回的正是 403 —— 判成 `permissionDenied` 会把用户引到
  /// 「去检查权限」，而正确动作是「重新取一次链」。
  static DriveErrorType _typeForStatus(int code) => switch (code) {
        401 => DriveErrorType.unauthorized,
        403 => DriveErrorType.urlExpired,
        404 => DriveErrorType.notFound,
        416 => DriveErrorType.urlExpired,
        >= 500 => DriveErrorType.network,
        _ => DriveErrorType.unknown,
      };

  /// 给包体加一道**静默超时**：两块之间超过 [idle] 没数据就报错。
  ///
  /// 为什么不能靠 `HttpClient` 自带的超时，见 [kDownloadStallTimeout]。
  ///
  /// 超时后除了往流里 `addError`，还会**主动取消上游订阅** —— 不然那条
  /// TCP 连接会一直挂在 socket 上，`client.close(force: true)` 之前
  /// 白白占着一个连接位（百度会因此把后续请求判成风控）。
  static Stream<List<int>> _stallGuarded(
    Stream<List<int>> source,
    Duration idle,
  ) {
    late StreamSubscription<List<int>> sub;
    final ctl = StreamController<List<int>>();
    Timer? timer;

    void arm() {
      timer?.cancel();
      timer = Timer(idle, () {
        timer = null;
        unawaited(sub.cancel());
        if (ctl.isClosed) return;
        ctl.addError(
          DriveException(
            type: DriveErrorType.network,
            message: '下载停滞：超过 ${idle.inSeconds} 秒没有收到新数据',
          ),
        );
        ctl.close();
      });
    }

    void finish([Object? error, StackTrace? stack]) {
      timer?.cancel();
      timer = null;
      if (ctl.isClosed) return;
      if (error != null) ctl.addError(error, stack);
      ctl.close();
    }

    sub = source.listen(
      (chunk) {
        if (ctl.isClosed) return;
        arm();
        ctl.add(chunk);
      },
      onError: (Object e, StackTrace s) => finish(e, s),
      onDone: finish,
      cancelOnError: true,
    );
    ctl.onCancel = () {
      timer?.cancel();
      timer = null;
      return sub.cancel();
    };
    // 先武装一次：覆盖「响应头到了、**第一个字节**都不来」那种停滞。
    arm();
    return ctl.stream;
  }

  /// 读响应体最前面的 [maxBytes] 字节（用于错误信息），其余丢掉。
  ///
  /// 只留 300 字节：够分辨「JSON 业务错」（`errno` / `code` / `show_msg`）
  /// 与「CDN 的 HTML 拒绝页」，又不会让超大错误体进内存。
  ///
  /// 为什么值得为它多读一次体：网盘直链被拒时，**响应体是唯一能区分
  /// 「请求形状不对」与「链接真的过期」的证据** —— 两者在日志里都只是
  /// 一个 `HTTP 403`（见 [DriveErrorType.urlExpired] 的注释）。
  static Future<String> _readBodySnippet(
    Stream<List<int>> body, {
    int maxBytes = 300,
  }) async {
    final buf = <int>[];
    try {
      await for (final piece in body) {
        buf.addAll(piece.take(maxBytes - buf.length));
        if (buf.length >= maxBytes) break;
      }
    } catch (_) {
      // 读体失败不影响「已经拿到状态码」这个结论。
    }
    return utf8
        .decode(buf, allowMalformed: true)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

/// 一次下载的进度快照。
class DriveDownloadProgress {
  const DriveDownloadProgress({required this.received, this.total});

  /// 已经落盘的字节数。**续传时它不是从 0 开始的** —— 第一次回调报的就是
  /// 断点位置（已下 8 GB 的文件，继续时第一条进度就是 8 GB）。
  final int received;

  /// 总字节数。服务端没声明时为 `null` —— 此时进度条只能是不确定态，
  /// 别拿 `received` 假装百分比。
  final int? total;

  /// 完成比例（0..1）。总长未知时返回 `null`。
  double? get fraction {
    final t = total;
    if (t == null || t <= 0) return null;
    return (received / t).clamp(0.0, 1.0);
  }

  bool get isDone => total != null && total! > 0 && received >= total!;

  @override
  String toString() => 'DriveDownloadProgress($received/$total)';
}

/// 下载成功的结果。
class DriveDownloadResult {
  const DriveDownloadResult({required this.path, required this.bytes});

  /// 落盘后的绝对路径（**不是** `.part` 那个临时路径）。
  final String path;

  final int bytes;

  @override
  String toString() => 'DriveDownloadResult($path, $bytes B)';
}

/// 用户主动取消。**不是错误** —— UI 应静默收场，不弹失败提示。
///
/// 语义是「这个下载不要了」：`.part` 会被删掉，记录也应当从队列里消失。
/// 想「先停一下、之后接着下」请用 [DriveDownloadPaused]。
class DriveDownloadCancelled implements Exception {
  const DriveDownloadCancelled();

  @override
  String toString() => 'DriveDownloadCancelled';
}

/// 用户主动暂停（或应用正在退出）。
///
/// **不是错误**，而且与取消的关键区别是：`.part` 会被**保留**，
/// [received] 是暂停那一刻已经落盘的字节数 —— 它就是要写进下载记录、
/// 下次用来发 `Range: bytes=<received>-` 的那个值。
class DriveDownloadPaused implements Exception {
  const DriveDownloadPaused(this.received);

  /// 暂停时已落盘的字节数。
  final int received;

  @override
  String toString() => 'DriveDownloadPaused($received)';
}

/// 暂停 / 取消的协作式令牌。下载循环在每个数据块边界检查一次。
///
/// 做成一个可变的小对象而不是 `StreamSubscription.cancel`，是因为这两个动作
/// 要能从**别的地方**触发（下载记录页上的按钮、应用退出），而那时下载已经
/// 跑在 `await` 里了。
///
/// ## 为什么暂停与取消共用同一个对象
///
/// 它们在下载循环里是同一个检查点（`if cancelled → throw; if paused → throw`），
/// 分成两个对象只会让调用方多持有、多传一个参数。真正不同的是**抛出去的
/// 异常**，而那个由服务自己决定。
class DriveDownloadControl {
  bool _cancelled = false;
  bool _paused = false;

  bool get isCancelled => _cancelled;
  bool get isPaused => _paused;

  /// 不要了。`.part` 会被删掉。
  void cancel() {
    _cancelled = true;
    _paused = false;
  }

  /// 先停一下。`.part` 保留，可以继续。
  ///
  /// 已经取消过的令牌不再接受暂停 —— 取消是更强的意图。
  void pause() {
    if (_cancelled) return;
    _paused = true;
  }
}

/// 服务端不支持 Range（回 200 而非 206）时抛出，触发降级到单连接。
class _RangeNotSupportedException implements Exception {
  const _RangeNotSupportedException(this.statusCode);

  final int statusCode;

  @override
  String toString() =>
      '_RangeNotSupportedException(HTTP $statusCode)';
}
