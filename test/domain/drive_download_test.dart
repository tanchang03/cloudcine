import 'dart:io';
import 'dart:typed_data';

import 'package:cloudcine/core/error/drive_error.dart';
import 'package:cloudcine/domain/adapters/cloud_drive_adapter.dart';
import 'package:cloudcine/domain/entities/auth_credential.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/cloud_account.dart';
import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/stream_ticket.dart';
import 'package:cloudcine/domain/services/drive_download.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「把网盘上的一个文件下载到本地」这条链。
///
/// ## 这里守的是什么
///
/// 下载是**唯一**一个会往用户磁盘上写东西的动作，所以它出错的方式与别处
/// 不同 —— 不报错、只是**留下一个看起来正常其实坏掉的文件**：
///
///   1. 取消 / 断网 / 体积不符时，目标位置必须**没有文件**（全程写 `.part`，
///      校验通过才 rename）；
///   2. 服务端声明了体积就**必须核对**：CDN 抖动时连接会「正常」结束而包体
///      是短的，不核对就会把半截文件当成功交付；
///   3. 取链交给适配器（`resolveStream`），这里不自己拼接口 —— 夸克的
///      「下载」接口有 50MiB 上限，而播放链第一条路由对任意 fid 都返回原
///      文件，那条知识只有适配器内部有。
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('cloudcine_dl_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 起一个本地源站，返回它的直链票据。
  ///
  /// [ticketLength] 是**票据上**声明的体积（适配器从接口响应里读到的）；
  /// [httpContentLength] 是**响应头**里声明的体积。两者刻意分开，因为
  /// 下载服务对「总长」有两条来源、要分别能测到：
  ///   - 传了 `httpContentLength` → 走响应头那条；
  ///   - 不传 → 用 chunked 传输（`response.contentLength` 为 -1），
  ///     服务退回票据上那个值。这也正是「实际比声明的少」能被构造成一次
  ///     **正常结束**的短响应的前提。
  Future<({HttpServer server, StreamTicket ticket, Uint8List bytes})> source(
    int total, {
    int? ticketLength,
    int? httpContentLength,
    int? sendBytes,
    int statusCode = 200,
    int chunkSize = 1 << 16,
    Duration chunkDelay = Duration.zero,
    bool ignoreRange = false,
    List<String>? rangeLog,
  }) async {
    final bytes = Uint8List(total);
    for (var i = 0; i < total; i++) {
      bytes[i] = i % 251;
    }

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    server.listen((request) async {
      // 客户端（尤其是「取消」那个用例）会在读完之前直接断开，
      // 之后往 response 里写会抛 —— 那是**预期内**的，别让它变成
      // 一个未捕获的异步异常把测试判红。
      try {
        final response = request.response;
        // 记下每一次请求的 `Range`。单连接路径（断点 0）**不发** Range，
        // 分块路径则必然发 `bytes=a-b` —— 这是从外面能看见的
        // 「走了哪条路」的唯一可靠痕迹。
        rangeLog?.add(request.headers.value(HttpHeaders.rangeHeader) ?? '-');
        if (statusCode >= 400) {
          response.statusCode = statusCode;
          await response.close();
          return;
        }

        // ---- 断点续传 ----
        //
        // 客户端发了 `Range: bytes=N-` 就只回那一段（206 + `Content-Range`）。
        // 偏移越界回 416 —— 那正是「`.part` 已经和源一样长、死在 rename
        // 之前」的样子，而下载服务要把它归成「直链过期」。
        // [ignoreRange] 用来复现「服务端不理 Range、直接回整份 200」。
        var from = 0;
        var count = sendBytes ?? bytes.length;
        var ranged = false;
        final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
        if (rangeHeader != null && !ignoreRange) {
          final match = RegExp(r'bytes=(\d+)-').firstMatch(rangeHeader);
          if (match != null) {
            from = int.parse(match.group(1)!);
            if (from >= bytes.length) {
              response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
              await response.close();
              return;
            }
            ranged = true;
            count = bytes.length - from;
            response.statusCode = HttpStatus.partialContent;
            response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $from-${bytes.length - 1}/${bytes.length}',
            );
          }
        }
        if (!ranged) response.statusCode = 200;

        // 走 Range 时不设 `Content-Length`：总长由 `Content-Range` 表达。
        // 两个都设的话，就分不清「总长取自哪一条」是哪一个在起作用了 ——
        // 而 206 的 `Content-Length` 只是**这一段**的长度，拿它当总长
        // 会让进度条一路超过 100%。
        final declared = ranged ? null : httpContentLength;
        if (declared != null) response.headers.contentLength = declared;

        final stop = from + count;
        for (var i = from; i < stop; i += chunkSize) {
          final end = (i + chunkSize) > stop ? stop : i + chunkSize;
          response.add(Uint8List.sublistView(bytes, i, end));
          await response.flush();
          if (chunkDelay > Duration.zero) {
            await Future<void>.delayed(chunkDelay);
          }
        }
        await response.close();
      } catch (_) {
        // 上游断开，收工。
      }
    });

    return (
      server: server,
      ticket: StreamTicket(
        url: Uri.parse('http://127.0.0.1:${server.port}/f.bin'),
        headers: const {'Cookie': 'k=v'},
        contentLength: ticketLength ?? total,
      ),
      bytes: bytes,
    );
  }

  /// 起一个「会 302 的源站」：第二跳**只在 UA 与票据一致时**才给数据。
  ///
  /// 复刻百度 2026-10-09 实测到的真实现象：
  ///
  ///   - 第一跳 `d.pcs.baidu.com/file/<fid>` 回 **302**，落点是 CDN 主机；
  ///   - 第二跳的 `sign` **是按 `User-Agent` 签的** —— 同一个 URL，
  ///     `User-Agent: netdisk` 回 `206`，其它任何 UA 回
  ///     `403 {"error_code":31362,"error_msg":"sign error"}`；
  ///   - 而 `dart:io` 的 `HttpClient` **自动跟随重定向时会丢掉
  ///     `User-Agent`**（换成客户端默认的 `Dart/x.y (dart:io)`，
  ///     `Range` / `Referer` 却保留）⇒ 第二跳必然 403。
  Future<({HttpServer server, StreamTicket ticket, Uint8List bytes})>
      redirectingSource({required String ticketUa}) async {
    final bytes = Uint8List.fromList(List<int>.generate(200, (i) => i % 251));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final base = 'http://127.0.0.1:${server.port}';

    server.listen((request) async {
      final response = request.response;
      if (request.uri.path == '/file') {
        response.statusCode = HttpStatus.found;
        response.headers
            .set(HttpHeaders.locationHeader, '$base/real?sign=a%2Fb');
        await response.close();
        return;
      }
      // 第二跳：签名（这里用 UA 代表）不对就照百度的样子拒绝。
      if (request.headers.value(HttpHeaders.userAgentHeader) != ticketUa) {
        response.statusCode = HttpStatus.forbidden;
        response.headers.contentType = ContentType.json;
        response.write('{"error_code":31362,"error_msg":"sign error"}');
        await response.close();
        return;
      }
      response.statusCode = HttpStatus.ok;
      response.headers.contentLength = bytes.length;
      response.add(bytes);
      await response.close();
    });

    return (
      server: server,
      ticket: StreamTicket(
        url: Uri.parse('$base/file'),
        headers: {'User-Agent': ticketUa},
        contentLength: bytes.length,
      ),
      bytes: bytes,
    );
  }

  test('⛔ 直链 302 之后，票据的 User-Agent 必须**跟着跳**', () async {
    // 少了这一步，Dart 会把 UA 换成 `Dart/x.y (dart:io)`，而百度 CDN 的
    // 直链签名**是按 UA 签的** ⇒ 第二跳 403 `31362 sign error`，
    // 而下载层把 403 归成 `urlExpired` ⇒ 现场看到的是「直链过期了」，
    // 于是所有排查都往「重新取链」上走，永远查不到真正的原因。
    final src = await redirectingSource(ticketUa: 'netdisk');
    final target = '${tmp.path}/跨跳.bin';

    await DriveDownloadService(adapter: _TicketAdapter(src.ticket))
        .download(fileId: 'f1', savePath: target);

    expect(File(target).readAsBytesSync(), src.bytes,
        reason: '重定向那一跳必须带着票据的 UA，否则 CDN 按签名拒绝');
  });

  test('整份落盘：字节与源一致，不留 .part', () async {
    final src = await source(4000, httpContentLength: 4000);
    final target = '${tmp.path}/片子.zip';

    final progress = <DriveDownloadProgress>[];
    final result = await DriveDownloadService(
      adapter: _TicketAdapter(src.ticket),
    ).download(fileId: 'f1', savePath: target, onProgress: progress.add);

    expect(File(target).readAsBytesSync(), src.bytes,
        reason: '下下来的必须是原样字节 —— 任何一处多写/少写都不会报错');
    expect(result.path, target);
    expect(result.bytes, 4000);
    expect(File('$target.part').existsSync(), isFalse,
        reason: '临时文件必须已经被 rename 走，不能在用户目录里留垃圾');
    expect(progress.first.received, 0, reason: '进度至少要回调一次起点');
    expect(progress.last.isDone, isTrue);
    expect(progress.last.fraction, 1.0);
  });

  test('响应头没给长度时，退回票据上声明的体积', () async {
    // 不传 `httpContentLength` → chunked，`response.contentLength` 为 -1。
    // 不退回票据的话进度条只能是不确定态，而夸克是给了体积的。
    final src = await source(3000, ticketLength: 3000);

    final progress = <DriveDownloadProgress>[];
    await DriveDownloadService(adapter: _TicketAdapter(src.ticket))
        .download(fileId: 'f1', savePath: '${tmp.path}/a.bin',
            onProgress: progress.add);

    expect(progress.last.total, 3000);
  });

  test('覆盖同名文件：先删旧的再落新的，不会写坏', () async {
    final src = await source(1000, httpContentLength: 1000);
    final target = '${tmp.path}/a.srt';
    File(target).writeAsStringSync('旧内容');

    await DriveDownloadService(adapter: _TicketAdapter(src.ticket))
        .download(fileId: 'f1', savePath: target);

    expect(File(target).readAsBytesSync(), src.bytes);
  });

  test('中途取消：抛 DriveDownloadCancelled，且**目标位置什么都没有**', () async {
    // 源站慢发，保证取消时包体还没发完。
    final src = await source(
      200000,
      httpContentLength: 200000,
      chunkSize: 4096,
      chunkDelay: const Duration(milliseconds: 2),
    );
    final target = '${tmp.path}/big.iso';
    final cancel = DriveDownloadControl();

    final future = DriveDownloadService(
      adapter: _TicketAdapter(src.ticket),
    ).download(
      fileId: 'f1',
      savePath: target,
      control: cancel,
      // 收到第一块就取消 —— 模拟用户点了「取消」。
      onProgress: (p) {
        if (p.received > 0) cancel.cancel();
      },
    );

    await expectLater(future, throwsA(isA<DriveDownloadCancelled>()));
    expect(File(target).existsSync(), isFalse,
        reason: '取消后留下一个半截文件是最糟的结果：用户以为下好了，'
            '打开才发现损坏，而界面没报过任何错');
    expect(File('$target.part').existsSync(), isFalse);
  });

  test('实际字节少于声明体积：判失败并清理，不当成功交付', () async {
    // 票据说 1000、实际只发 400 —— 这正是 CDN 抖动 / 直链中途过期的样子。
    final src = await source(1000, ticketLength: 1000, sendBytes: 400);
    final target = '${tmp.path}/half.zip';

    await expectLater(
      DriveDownloadService(adapter: _TicketAdapter(src.ticket))
          .download(fileId: 'f1', savePath: target),
      throwsA(isA<DriveException>()
          .having((e) => e.type, 'type', DriveErrorType.network)),
    );
    expect(File(target).existsSync(), isFalse);
    expect(File('$target.part').existsSync(), isFalse);
  });

  test('403 判成直链过期（而不是「权限不足」）', () async {
    final src = await source(100, statusCode: 403);
    final target = '${tmp.path}/x.zip';

    await expectLater(
      DriveDownloadService(adapter: _TicketAdapter(src.ticket))
          .download(fileId: 'f1', savePath: target),
      throwsA(isA<DriveException>()
          .having((e) => e.type, 'type', DriveErrorType.urlExpired)),
    );
    expect(File(target).existsSync(), isFalse);
  });

  test('取链失败原样上抛，不会去建文件', () async {
    final target = '${tmp.path}/never.zip';
    const failure = DriveException(
      type: DriveErrorType.unsupported,
      message: '取链失败',
    );

    await expectLater(
      DriveDownloadService(adapter: _TicketAdapter(null, error: failure))
          .download(fileId: 'f1', savePath: target),
      throwsA(same(failure)),
    );
    expect(File(target).existsSync(), isFalse);
    expect(File('$target.part').existsSync(), isFalse);
  });

  test('目标目录不存在时自己建出来', () async {
    final src = await source(64, httpContentLength: 64);
    final target = '${tmp.path}/还没建的目录/深层/a.txt';

    await DriveDownloadService(adapter: _TicketAdapter(src.ticket))
        .download(fileId: 'f1', savePath: target);

    expect(File(target).readAsBytesSync(), src.bytes);
  });

  test('续传：从断点接着下，最终字节与源一致', () async {
    final src = await source(4000);
    final target = '${tmp.path}/片子.zip';
    // 上一次下到 1500 字节就停了 —— 磁盘上那个 `.part` 本身就是断点。
    File('$target.part').writeAsBytesSync(src.bytes.sublist(0, 1500));

    final progress = <DriveDownloadProgress>[];
    final result = await DriveDownloadService(adapter: _TicketAdapter(src.ticket))
        .download(
      fileId: 'f1',
      savePath: target,
      startOffset: 1500,
      onProgress: progress.add,
    );

    expect(File(target).readAsBytesSync(), src.bytes,
        reason: '续传拼出来的文件必须与整份下载逐字节一致 —— 少一段或错一段'
            '都不会报错，只会在用户打开时才发现坏了');
    expect(result.bytes, 4000);
    expect(File('$target.part').existsSync(), isFalse);
    expect(progress.first.received, 1500,
        reason: '续传时第一条进度就是断点位置。从 0 重新爬的话，'
            '用户会以为「暂停过的文件白下了」');
    expect(progress.first.total, 4000,
        reason: '总长只能取自 Content-Range。206 的 Content-Length 是'
            '**这一段**的长度（2500），拿它当总长会让进度条超过 100%');
  });

  test('库里的字节数比磁盘上真实的偏大：以 .part 为准，不去要越界的 Range', () async {
    final src = await source(4000);
    final target = '${tmp.path}/a.bin';
    File('$target.part').writeAsBytesSync(src.bytes.sublist(0, 1200));

    final progress = <DriveDownloadProgress>[];
    await DriveDownloadService(adapter: _TicketAdapter(src.ticket)).download(
      fileId: 'f1',
      savePath: target,
      // 库里那个按秒节流的快照说 3000，磁盘上其实只有 1200。
      startOffset: 3000,
      onProgress: progress.add,
    );

    expect(progress.first.received, 1200,
        reason: '拿一个偏大的偏移去发 Range，服务端回 416 —— 表现是'
            '「点了继续直接失败」，而用户刚看到的是「已经下了 3 GB」。'
            '断点的真源必须是磁盘');
    expect(File(target).readAsBytesSync(), src.bytes);
  });

  test('服务端忽略 Range 回 200 时：从 0 重写，不把整份追加到 .part 后面', () async {
    final src = await source(4000, httpContentLength: 4000, ignoreRange: true);
    final target = '${tmp.path}/片子.zip';
    File('$target.part').writeAsBytesSync(src.bytes.sublist(0, 1500));

    final result = await DriveDownloadService(adapter: _TicketAdapter(src.ticket))
        .download(fileId: 'f1', savePath: target, startOffset: 1500);

    expect(result.bytes, 4000);
    expect(File(target).readAsBytesSync(), src.bytes,
        reason: '追加的话会得到一个 5500 字节的文件，而体积校验**会通过**'
            '（因为 received 是从 0 重新算的）—— 这是唯一一条'
            '「下载器自己把文件写坏、还报成功」的路径，必须显式挡掉');
  });

  test('暂停：抛 DriveDownloadPaused、**保留 .part**，字节数与磁盘一致', () async {
    final src = await source(
      200000,
      httpContentLength: 200000,
      chunkSize: 4096,
      chunkDelay: const Duration(milliseconds: 2),
    );
    final target = '${tmp.path}/big.iso';
    final control = DriveDownloadControl();

    DriveDownloadPaused? paused;
    try {
      await DriveDownloadService(adapter: _TicketAdapter(src.ticket)).download(
        fileId: 'f1',
        savePath: target,
        control: control,
        // 收到第一块就暂停 —— 模拟用户点了「暂停」。
        onProgress: (p) {
          if (p.received > 0) control.pause();
        },
      );
      fail('暂停应当抛 DriveDownloadPaused，而不是「正常结束」——'
          '后者会让界面显示一条下完的记录，而文件根本没下完');
    } on DriveDownloadPaused catch (e) {
      paused = e;
    }

    expect(File(target).existsSync(), isFalse, reason: '没下完的东西绝不能出现在目标位置');
    final part = File('$target.part');
    expect(part.existsSync(), isTrue,
        reason: '暂停与取消的**唯一**区别就在这里：`.part` 是「继续」的全部'
            '依据。删了就等于把断点扔掉，表现是「暂停过一次，白下了」');
    expect(part.lengthSync(), paused.received,
        reason: '报出去的字节数必须等于真正落盘的字节数。报大了下次发 Range '
            '撞 416；报小了会重复写一段 —— 文件坏掉但不报错');
  });

  test('416（.part 已经和源一样长，死在 rename 之前）判成直链过期', () async {
    final src = await source(1000);
    final target = '${tmp.path}/x.zip';
    // `.part` 是完整的，但没能 rename 成正式文件。
    File('$target.part').writeAsBytesSync(src.bytes);

    await expectLater(
      DriveDownloadService(adapter: _TicketAdapter(src.ticket))
          .download(fileId: 'f1', savePath: target, startOffset: 1000),
      throwsA(isA<DriveException>()
          .having((e) => e.type, 'type', DriveErrorType.urlExpired)),
    );
    // 归成 urlExpired 而不是「权限不足」：对它唯一有意义的动作是**重新取链**。
    // 失败路径会把 `.part` 一起清掉，于是下次「继续」的偏移会被磁盘校正成 0
    // —— 白下一遍，但不会写坏。
    expect(File(target).existsSync(), isFalse);
  });

  // ============================================================
  // 包体静默 / 通道并发上限
  // ============================================================

  /// 起一个「先给一点点、然后彻底沉默」的源站。
  ///
  /// 复刻 2026-10-09 的现场：百度非会员通道在 `13:57:22` 取链成功之后
  /// 一直有极少量字节、然后**彻底停住**，日志最后一行还停在「取链成功」，
  /// UI 停在 0%。`HttpClient` 的 `connectionTimeout` / `idleTimeout`
  /// 都管不到「响应头到了、包体却不再来」这一段 —— 必须由下载层自己兜底。
  Future<({HttpServer server, StreamTicket ticket})> stallingSource() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      try {
        final response = request.response;
        response.statusCode = 200;
        response.headers.contentLength = 100000;
        // 先给 64 字节（让客户端拿到响应头 + 第一块），然后不再发任何东西。
        response.add(Uint8List.fromList(List<int>.filled(64, 7)));
        await response.flush();
        await Future<void>.delayed(const Duration(seconds: 20));
      } catch (_) {}
    });
    return (
      server: server,
      ticket: StreamTicket(
        url: Uri.parse('http://127.0.0.1:${server.port}/stall.bin'),
        headers: const {'Cookie': 'k=v'},
        contentLength: 100000,
      ),
    );
  }

  test('包体静默不动：按超时判失败，而不是无限等下去', () async {
    final src = await stallingSource();
    final target = '${tmp.path}/stall.bin';

    final sw = Stopwatch()..start();
    await expectLater(
      DriveDownloadService(
        adapter: _TicketAdapter(src.ticket),
        stallTimeout: const Duration(milliseconds: 300),
      ).download(fileId: 'f1', savePath: target),
      throwsA(isA<DriveException>()
          .having((e) => e.type, 'type', DriveErrorType.network)
          .having((e) => e.message, 'message', contains('停滞'))),
    );
    sw.stop();

    expect(sw.elapsedMilliseconds, lessThan(5000),
        reason: '没有这道闸门时这一行会挂到服务端自己掐连接为止 ——'
            '现场是七分多钟，而用户看到的是「卡在 0% 不动」');
    expect(File(target).existsSync(), isFalse);
    expect(File('$target.part').existsSync(), isFalse);
  });

  test('票据钉了单连接：文件再大也不开分块', () async {
    // 百度普通通道的限速是**按账号**的（1 条 82 KB/s、8 条 68 KB/s 且
    // 全被掐断）。所以「够大就分块」这条判据必须能被票据上的上限否决，
    // 否则文档下载永远是「8 条连接打一条慢通道 → 每条读超时 → 失败」。
    final ranges = <String>[];
    final src = await source(
      20000,
      httpContentLength: 20000,
      rangeLog: ranges,
    );
    final target = '${tmp.path}/slow.bin';

    final result = await DriveDownloadService(
      adapter: _TicketAdapter(
        StreamTicket(
          url: src.ticket.url,
          headers: src.ticket.headers,
          contentLength: 20000,
          maxConnections: 1,
        ),
      ),
      connections: 8,
      // 阈值 = 1024 * 4 = 4 KiB ⇒ 20000 字节本来**会**走分块。
      chunkSize: 1024,
    ).download(fileId: 'f1', savePath: target);

    expect(result.bytes, 20000);
    expect(File(target).readAsBytesSync(), src.bytes);
    expect(ranges, isNotEmpty);
    expect(ranges.every((r) => r == '-'), isTrue,
        reason: '单连接路径（断点 0）不发 Range；出现 `bytes=a-b` 就说明'
            '还是走了分块 —— 那正是要挡掉的行为');
  });

  // ============================================================
  // 多连接分块下载
  //
  // 以下测试用 `connections: 3, chunkSize: 1024` 把阈值压到 4 KiB，
  // 这样 5000+ 字节的文件就能走分块路径，不用在测试里生成 MiB 级数据。
  // ============================================================

  group('分块下载', () {
    /// 起一个支持并发 Range 的源站。
    /// 与外层 `source()` 相同，但刻意单独定义一份，让分块组的依赖更清晰。
    Future<
        ({
          HttpServer server,
          StreamTicket ticket,
          Uint8List bytes
        })> chunkedSource(
      int total, {
      bool ignoreRange = false,
      List<String>? rangeLog,
    }) async {
      final bytes = Uint8List(total);
      for (var i = 0; i < total; i++) {
        bytes[i] = i % 251;
      }

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        try {
          final response = request.response;

          final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
          rangeLog?.add(rangeHeader ?? '-');
          var from = 0;
          var count = bytes.length;
          var ranged = false;

          if (rangeHeader != null && !ignoreRange) {
            final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(rangeHeader);
            if (match != null) {
              from = int.parse(match.group(1)!);
              final to = int.parse(match.group(2)!);
              if (from >= bytes.length) {
                response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
                await response.close();
                return;
              }
              count = (to + 1) - from;
              count = count.clamp(0, bytes.length - from);
              ranged = true;
              response.statusCode = HttpStatus.partialContent;
              response.headers.set(
                HttpHeaders.contentRangeHeader,
                'bytes $from-${from + count - 1}/${bytes.length}',
              );
            }
          }
          if (!ranged) response.statusCode = 200;

          final stop = from + count;
          for (var i = from; i < stop; i += 4096) {
            final end = (i + 4096) > stop ? stop : i + 4096;
            response.add(Uint8List.sublistView(bytes, i, end));
            await response.flush();
          }
          await response.close();
        } catch (_) {}
      });

      return (
        server: server,
        ticket: StreamTicket(
          url: Uri.parse('http://127.0.0.1:${server.port}/f.bin'),
          headers: const {'Cookie': 'k=v'},
          contentLength: total,
        ),
        bytes: bytes,
      );
    }

    test('多连接分块：字节与源一致，不留 .part', () async {
      // 10000 字节 / 1024 chunkSize = 10 块 / 3 连接 → 每条连接拉 3-4 块。
      final src = await chunkedSource(10000);
      final target = '${tmp.path}/chunked.bin';

      final progress = <DriveDownloadProgress>[];
      final result = await DriveDownloadService(
        adapter: _TicketAdapter(src.ticket),
        connections: 3,
        chunkSize: 1024,
      ).download(fileId: 'f1', savePath: target, onProgress: progress.add);

      expect(File(target).readAsBytesSync(), src.bytes,
          reason: '分块拼出来的文件必须逐字节一致——任何一块写偏或漏一段'
              '都不会报错，只在用户打开时才发现坏了');
      expect(result.bytes, 10000);
      expect(File('$target.part').existsSync(), isFalse);
      expect(progress.first.received, 0);
      expect(progress.last.isDone, isTrue);
    });

    test('分块续传：从断点接着下，最终字节与源一致', () async {
      final src = await chunkedSource(8000);
      final target = '${tmp.path}/resume.bin';
      // 上一次下到 3000 字节就停了。
      File('$target.part').writeAsBytesSync(src.bytes.sublist(0, 3000));

      final progress = <DriveDownloadProgress>[];
      final result = await DriveDownloadService(
        adapter: _TicketAdapter(src.ticket),
        connections: 3,
        chunkSize: 1024,
      ).download(
        fileId: 'f1',
        savePath: target,
        startOffset: 3000,
        onProgress: progress.add,
      );

      expect(File(target).readAsBytesSync(), src.bytes,
          reason: '续传拼出来的文件必须与整份下载逐字节一致');
      expect(result.bytes, 8000);
      expect(File('$target.part').existsSync(), isFalse);
      expect(progress.first.received, 3000,
          reason: '续传时第一条进度就是断点位置');
    });

    test('服务端忽略 Range：自动降级到单连接，字节与源一致', () async {
      // ignoreRange → 服务端对 Range 请求回 200。
      // 分块路径检测到 200 后抛 _RangeNotSupportedException → 降级单连接。
      final src = await chunkedSource(10000, ignoreRange: true);
      final target = '${tmp.path}/fallback.bin';

      final result = await DriveDownloadService(
        adapter: _TicketAdapter(src.ticket),
        connections: 3,
        chunkSize: 1024,
      ).download(fileId: 'f1', savePath: target);

      expect(File(target).readAsBytesSync(), src.bytes,
          reason: '降级到单连接后必须仍然下完整份文件');
      expect(result.bytes, 10000);
    });

    test('分块暂停：保留 .part，字节数与磁盘一致', () async {
      final src = await chunkedSource(20000);
      final target = '${tmp.path}/pause.bin';
      final control = DriveDownloadControl();

      DriveDownloadPaused? paused;
      try {
        await DriveDownloadService(
          adapter: _TicketAdapter(src.ticket),
          connections: 3,
          chunkSize: 1024,
        ).download(
          fileId: 'f1',
          savePath: target,
          control: control,
          onProgress: (p) {
            if (p.received > 2000) control.pause();
          },
        );
        fail('暂停应当抛 DriveDownloadPaused');
      } on DriveDownloadPaused catch (e) {
        paused = e;
      }

      expect(File(target).existsSync(), isFalse);
      final part = File('$target.part');
      expect(part.existsSync(), isTrue,
          reason: '暂停保留 .part——它是「继续」的全部依据');
      expect(part.lengthSync(), paused.received,
          reason: '报出去的字节数必须等于真正落盘的字节数');
    });

    test('分块取消：目标位置什么都没有', () async {
      final src = await chunkedSource(20000);
      final target = '${tmp.path}/cancel.bin';
      final cancel = DriveDownloadControl();

      await expectLater(
        DriveDownloadService(
          adapter: _TicketAdapter(src.ticket),
          connections: 3,
          chunkSize: 1024,
        ).download(
          fileId: 'f1',
          savePath: target,
          control: cancel,
          onProgress: (p) {
            if (p.received > 2000) cancel.cancel();
          },
        ),
        throwsA(isA<DriveDownloadCancelled>()),
      );
      expect(File(target).existsSync(), isFalse);
      expect(File('$target.part').existsSync(), isFalse);
    });

    test('小文件自动走单连接（不触发分块）', () async {
      // 100 字节远小于阈值（1024*4=4096）→ 走单连接路径。
      // 验证分块不会对小文件产生错误行为。
      final src = await chunkedSource(100);
      final target = '${tmp.path}/small.bin';

      final result = await DriveDownloadService(
        adapter: _TicketAdapter(src.ticket),
        connections: 3,
        chunkSize: 1024,
      ).download(fileId: 'f1', savePath: target);

      expect(File(target).readAsBytesSync(), src.bytes);
      expect(result.bytes, 100);
    });

    test('票据没钉上限 ⇒ 照旧走分块（默认行为不被改坏）', () async {
      // 加了 `StreamTicket.maxConnections` 之后，**没钉上限**的票据
      // 必须还是走多连接 —— dlna 通道每条连接各自限速（1 条 1.1 MB/s、
      // 8 条 4.1 MB/s），把它也一起关掉就等于白白丢 4 倍带宽。
      final ranges = <String>[];
      final src = await chunkedSource(20000, rangeLog: ranges);
      final target = '${tmp.path}/fast.bin';

      await DriveDownloadService(
        adapter: _TicketAdapter(src.ticket),
        connections: 3,
        chunkSize: 1024,
      ).download(fileId: 'f1', savePath: target);

      expect(File(target).readAsBytesSync(), src.bytes);
      expect(ranges.where((r) => r.startsWith('bytes=')), isNotEmpty,
          reason: '出现 `bytes=a-b` 才说明走的是分块路径');
    });
  });
}

/// 只实现取链的替身：下载这条链除了 `resolveStream` 什么都不该碰。
class _TicketAdapter extends CloudDriveAdapter {
  _TicketAdapter(this.ticket, {this.error});

  final StreamTicket? ticket;
  final DriveException? error;

  @override
  DriveProvider get provider => DriveProvider.quark;

  @override
  Capabilities get capabilities =>
      const Capabilities(provider: DriveProvider.quark);

  @override
  String get rootId => 'root';

  @override
  Future<StreamTicket> resolveStream(String fileId, {String? qualityId}) async {
    final e = error;
    if (e != null) throw e;
    return ticket!;
  }

  @override
  Future<DrivePage> listDirectory({
    required String dirId,
    String? pageToken,
    int? pageSize,
  }) =>
      throw UnimplementedError('下载不该列目录');

  @override
  Future<List<DriveEntry>> search({
    required String keyword,
    int limit = 100,
    int offset = 0,
  }) =>
      throw UnimplementedError('下载不该搜索');

  @override
  Future<CloudAccount?> restoreSession() async => null;

  @override
  Future<CloudAccount> authorize(AuthCredential credential) =>
      throw UnimplementedError('下载不该授权');

  @override
  Future<void> signOut() async {}

  @override
  Future<bool> ping() async => true;

  @override
  Future<void> dispose() async {}
}
