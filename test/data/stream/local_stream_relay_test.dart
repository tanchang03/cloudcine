import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloudcine/core/diagnostics/diag_log.dart';
import 'package:cloudcine/core/utils/hls_relay_rewrite.dart';
import 'package:cloudcine/core/utils/http_range.dart';
import 'package:cloudcine/data/stream/local_stream_relay.dart';
import 'package:cloudcine/domain/adapters/stream_relay.dart';
import 'package:cloudcine/domain/entities/stream_ticket.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isRelayableUrl', () {
    test('HLS **也**要走中继（2026-10-04 改，以前断言的是 false）', () {
      // 以前这里断言 false，理由是「分片是相对地址，中继会把拼地址的基准改成
      // 127.0.0.1」。那个理由靠**改写列表**解决（见 `rewriteHlsForRelay`），
      // 而放弃中继的代价是致命的：转码档因此成了本机唯一一条「播放器直连
      // CDN」的流，而本机 `http_proxy` 会让 ffmpeg 走进未放行的 `httpproxy`
      // 协议 —— 分片一个都取不到，表现就是「切到 4K/1080 只有声音没画面、
      // 两秒就 EOF」。原画一直没事，正因为它本来就走在 127.0.0.1 上。
      expect(isRelayableUrl(Uri.parse('https://cdn.quark.cn/media.m3u8?x=1')),
          isTrue);
    });

    test('isHlsUrl 只认 .m3u8', () {
      // 中继靠它分流：HLS 走「改写列表 + 透传分片」，其余走「按块并发预取」。
      expect(isHlsUrl(Uri.parse('https://cdn.quark.cn/media.m3u8?x=1')), isTrue);
      expect(isHlsUrl(Uri.parse('https://cdn.quark.cn/a.mkv')), isFalse);
    });

    test('普通 http/https 直链可以走中继', () {
      expect(isRelayableUrl(Uri.parse('https://cdn.quark.cn/a.mkv')), isTrue);
    });

    test('本地文件 / asset 不走中继', () {
      expect(isRelayableUrl(Uri.parse('file:///Users/a/b.mkv')), isFalse);
      expect(isRelayableUrl(Uri.parse('asset:///assets/probe.mp4')), isFalse);
    });
  });

  group('LocalStreamRelay HLS（转码档）', () {
    test('列表被改写成中继入口、分片经中继取回，Cookie 带到上游', () async {
      const segmentBody = 'SEGMENT-BYTES-0123456789';
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(upstream.close);
      final seenCookies = <String?>[];
      final seenPaths = <String>[];
      upstream.listen((request) async {
        seenCookies.add(request.headers.value('Cookie'));
        seenPaths.add(request.uri.path);
        if (request.uri.path.endsWith('.m3u8')) {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType =
                ContentType.parse('application/vnd.apple.mpegurl')
            // ⚠️ 分片是**相对地址** —— 这正是必须改写列表的原因。
            ..write('#EXTM3U\n'
                '#EXT-X-VERSION:3\n'
                '#EXT-X-PLAYLIST-TYPE:VOD\n'
                '#EXTINF:2.000,\n'
                'media-x-0.ts?auth_key=1-2-3\n'
                '#EXT-X-ENDLIST\n');
        } else {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.parse('video/MP2T')
            ..headers.set(HttpHeaders.contentLengthHeader, segmentBody.length)
            ..write(segmentBody);
        }
        await request.response.close();
      });

      final relay = LocalStreamRelay();
      addTearDown(relay.dispose);

      final endpoint = (await relay.open(
        StreamTicket(
          url: Uri.parse('http://127.0.0.1:${upstream.port}/qv/x/media.m3u8'),
          headers: const <String, String>{'Cookie': 'token=abc'},
          // 服务端声明的整档体积 —— 中继**不能**拿它当「这条流多少字节」。
          contentLength: 12345,
        ),
      ))!;

      // ① 播放器拿到的地址必须是 127.0.0.1。这就是绕开本机 http_proxy 的关键：
      //    ffmpeg 对回环地址不做代理，也就不会去用那个未放行的 httpproxy 协议。
      expect(endpoint.uri.host, '127.0.0.1');
      expect(endpoint.uri.path, endsWith('/$relayEntryPath'));
      expect(endpoint.uri.queryParameters[relayTargetQueryKey], isNotNull);

      final client = HttpClient()..findProxy = (Uri _) => 'DIRECT';
      addTearDown(client.close);

      // ② 取列表：应被改写，且**上游主机名不再出现**在正文里
      //    （分片地址被换成了中继入口）。
      final playlistResponse = await (await client.getUrl(endpoint.uri)).close();
      expect(playlistResponse.statusCode, HttpStatus.ok);
      final playlist = await utf8.decodeStream(playlistResponse);
      expect(playlist, contains('#EXT-X-ENDLIST'));
      expect(playlist, isNot(contains('127.0.0.1:${upstream.port}')));
      final segmentLine = playlist
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.isNotEmpty && !l.startsWith('#'));
      expect(segmentLine, startsWith(relayEntryPath));

      // ③ 按**列表自己的地址**解析那一行（播放器就是这么做的）→ 分片也应从
      //    127.0.0.1 取到，而不是去 CDN。
      final segmentUri = endpoint.uri.resolve(segmentLine);
      expect(segmentUri.host, '127.0.0.1');
      final segmentResponse = await (await client.getUrl(segmentUri)).close();
      expect(segmentResponse.statusCode, HttpStatus.ok);
      expect(await utf8.decodeStream(segmentResponse), segmentBody);

      // ④ Cookie 必须被中继带到上游 —— 转码档还额外依赖 Video-Auth，
      //    少了它上游一律 404。
      expect(seenCookies, isNotEmpty);
      expect(seenCookies.every((c) => c == 'token=abc'), isTrue);
      // ⑤ 上游确实收到了「列表」和「分片」两次请求，且分片那次带上了原始
      //    查询串（auth_key 丢了就是 404）。
      expect(seenPaths.where((p) => p.endsWith('.m3u8')).length, 1);
      expect(seenPaths.where((p) => p.endsWith('.ts')).length, 1);

      // ⑥ HLS 会话不做预取，所以没有 RelayStats —— `warmUpRelay` 靠这个
      //    立刻返回，不会在换档时白等一个预热超时。
      expect(relay.statsOf(endpoint.token), isNull);
      expect(relay.sessionCount, 1);

      // ⑦ 关掉之后该 token 的所有请求都变成 404（旧连接上的回声）。
      await relay.close(endpoint.token);
      expect(relay.sessionCount, 0);
      final gone = await (await client.getUrl(endpoint.uri)).close();
      expect(gone.statusCode, HttpStatus.notFound);
      await gone.drain<void>();
    });
  });

  group('LocalStreamRelay.open', () {
    test('长度未知时返回 null —— 调用方直连', () async {
      final relay = LocalStreamRelay();
      addTearDown(relay.dispose);
      final endpoint = await relay.open(
        StreamTicket(url: Uri.parse('https://cdn.quark.cn/a.mkv')),
      );
      // 按块并发预取的前提是知道总长度；不知道就老实直连。
      expect(endpoint, isNull);
    });

    test('源流不支持 Range 时返回 null', () async {
      final relay = LocalStreamRelay();
      addTearDown(relay.dispose);
      final endpoint = await relay.open(
        StreamTicket(
          url: Uri.parse('https://cdn.quark.cn/a.mkv'),
          contentLength: 1024,
          supportsRange: false,
        ),
      );
      expect(endpoint, isNull);
    });

    test('总开关关掉时返回 null', () async {
      final relay = LocalStreamRelay(enabled: false);
      addTearDown(relay.dispose);
      final endpoint = await relay.open(
        StreamTicket(
          url: Uri.parse('https://cdn.quark.cn/a.mkv'),
          contentLength: 1024,
        ),
      );
      expect(endpoint, isNull);
    });
  });

  group('LocalStreamRelay 端到端', () {
    test('拿到的字节与源流一致，Cookie 被带给上游，数据按块取', () async {
      const total = 1000;
      const chunk = 100;
      final source = Uint8List(total);
      for (var i = 0; i < total; i++) {
        source[i] = i % 251;
      }

      final cookies = <String?>[];
      final ranges = <String?>[];
      final ports = <int?>[];
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(upstream.close);
      upstream.listen((request) async {
        cookies.add(request.headers.value('Cookie'));
        ranges.add(request.headers.value('Range'));
        ports.add(request.connectionInfo?.remotePort);
        final range = parseRangeHeader(
              request.headers.value('Range'),
              total,
            ) ??
            const ByteRange(0, total - 1);
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.contentType = ContentType.binary
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            formatContentRange(range, total),
          )
          ..headers.set(HttpHeaders.contentLengthHeader, range.length)
          ..add(Uint8List.sublistView(source, range.start, range.end + 1));
        await request.response.close();
      });

      final relay = LocalStreamRelay(
        chunkSize: chunk,
        prefetchBytes: total,
        maxCacheBytes: total,
        connections: 4,
      );
      addTearDown(relay.dispose);

      final endpoint = await relay.open(
        StreamTicket(
          url: Uri.parse('http://127.0.0.1:${upstream.port}/demo.mkv'),
          headers: const <String, String>{'Cookie': 'token=abc'},
          contentLength: total,
          contentType: 'video/x-matroska',
        ),
      );
      expect(endpoint, isNotNull);
      expect(endpoint!.uri.host, '127.0.0.1');
      expect(endpoint.contentLength, total);

      final client = HttpClient()..findProxy = (Uri _) => 'DIRECT';
      addTearDown(client.close);

      // ① 整条读：字节必须逐一对得上。
      final request = await client.getUrl(endpoint.uri);
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      final body = <int>[];
      await for (final piece in response) {
        body.addAll(piece);
      }
      expect(Uint8List.fromList(body), source);

      // ② Cookie 必须原样带到上游，否则夸克直链一律 412。
      expect(cookies, isNotEmpty);
      expect(cookies.every((c) => c == 'token=abc'), isTrue);

      // ③ 数据是按块取的：整条 1000 字节被切成 10 块，而不是一次全要。
      expect(ranges.length, total ~/ chunk);

      // ④ 只请求中间一段也要准：seek 落在块中间时不能取错偏移。
      final partial = await client.getUrl(endpoint.uri);
      partial.headers.set(HttpHeaders.rangeHeader, 'bytes=250-349');
      final partialResponse = await partial.close();
      expect(partialResponse.statusCode, HttpStatus.partialContent);
      final partialBody = <int>[];
      await for (final piece in partialResponse) {
        partialBody.addAll(piece);
      }
      expect(Uint8List.fromList(partialBody),
          Uint8List.sublistView(source, 250, 350));

      // ⑤ 统计是真实计数：全部预取完就该等于文件长度。
      expect(relay.statsOf(endpoint.token)?.downloadedBytes, total);

      // ⑥ 连接复用（本次修复的核心）：10 次取块只应新建 ≤4 条连接（worker 数），
      //    而不是 10 条。旧实现「每块新建 HttpClient 再 close」在这里会是 10 ——
      //    等于每 2 MiB 一次 TLS 握手，净吞吐被握手间隙切成锯齿，高码率原画必卡。
      final stats = relay.statsOf(endpoint.token)!;
      expect(stats.upstreamRequests, total ~/ chunk);
      expect(
        stats.upstreamConnects,
        lessThanOrEqualTo(4),
        reason: '每块重连会让 upstreamConnects 逼近 upstreamRequests —— 复用没生效',
      );

      // ⑦ 线级证据：上游看到的**不同 TCP 连接**（按远端端口去重）必须远少于
      //    请求数 —— 追上请求数就说明每块都在重连。只数计数器可能被实现骗过，
      //    数端口才是真的复用了连接。
      //
      //    ⚠️ 阈值是「请求数」而不是 worker 数（4）：macOS loopback 上
      //    keep-alive 能完美复用，实测正好 4 条；Windows loopback 上 Dart
      //    连接池的时序不同，会多出几次透明重连（实测 8 条），但 HttpClient
      //    实例数（上面 upstreamConnects 的断言）始终 ≤ worker 数 —— 用户
      //    真正付钱的握手成本被压住的是它，端口数只是二阶证据。
      final distinctPorts = ports.whereType<int>().toSet();
      expect(distinctPorts.length, lessThan(stats.upstreamRequests),
          reason: '端口数追上请求数 = 每块新建连接，复用没生效');
    });

    test('换源时关掉旧会话，统计随之消失', () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(upstream.close);
      upstream.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set(HttpHeaders.contentLengthHeader, 10)
          ..add(Uint8List(10));
        await request.response.close();
      });

      final relay = LocalStreamRelay(chunkSize: 10, prefetchBytes: 10);
      addTearDown(relay.dispose);

      // ⚠️ `!` 必须包在 await **外面**：`await f()!` 会被解析成
      // `await (f()!)`，作用对象是 Future 而不是结果 —— 写了等于没写，
      // 后面所有 `first.token` 都会报「可能为空」。
      final first = (await relay.open(
        StreamTicket(
          url: Uri.parse('http://127.0.0.1:${upstream.port}/a'),
          contentLength: 10,
        ),
      ))!;
      expect(relay.statsOf(first.token), isNotNull);

      await relay.close(first.token);
      expect(relay.statsOf(first.token), isNull);

      // 关掉之后重复关闭不该抛 —— 播放器的换源路径常被重入。
      await relay.close(first.token);
    });

    test('seek：旧连接不得抢走新位置的预取带宽', () async {
      // 真实场景：拖进度条时 mpv **新开一条连接**去目标位置，但**不关掉旧连接**
      // —— 旧读取器留在原地继续被喂（实测真 libmpv：seek 后 4 条读取器一条都没断）。
      //
      // 修复前预取锚点是**整个会话唯一的一个**，谁请求谁就覆盖它，于是锚点在旧
      // 位置与新位置之间反复拉锯。实测后果：seek 后 69 秒内 **78% 的上游带宽喂给
      // 了已经不看的地方**（336 MiB 对 70 MiB），新位置只拿到约 0.8 MiB/s，而片源
      // 需要 2.37 MiB/s —— 就是「拖完进度条看一会卡一会」。
      //
      // 这条测试用真实 HTTP 复现「一旧一新两条长读取器并存」，断言 seek 之后上游
      // **优先喂新位置**：紧跟新位置那次请求之后的若干次请求里，落在旧位置的最多
      // 只有 worker 数那么多次（只可能是 seek 那一刻已经在上游路上的那几次）。
      const total = 40 * 1024 * 1024; // 40 MiB → 40 块
      const chunk = 1024 * 1024;
      const prefetchChunks = 8; // 预取窗口 8 MiB
      const seekChunk = 30; // 拖到 30 MiB
      // ⚠️ seek 目标不能太靠文件尾：`isStream` 要求请求范围 ≥ 一个预取窗口，
      // 拖到 38 MiB 只剩 2 MiB 范围，会被当成「读索引的探索引」，测不到东西。
      expect((total - seekChunk * chunk) >= prefetchChunks * chunk, isTrue);

      final source = Uint8List(total);
      for (var i = 0; i < total; i++) {
        source[i] = i % 251;
      }

      final ranges = <ByteRange>[];
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(upstream.close);
      upstream.listen((request) async {
        final range = parseRangeHeader(request.headers.value('Range'), total) ??
            const ByteRange(0, total - 1);
        ranges.add(range);
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            formatContentRange(range, total),
          )
          ..headers.set(HttpHeaders.contentLengthHeader, range.length)
          ..add(Uint8List.sublistView(source, range.start, range.end + 1));
        await request.response.close();
      });

      final relay = LocalStreamRelay(
        chunkSize: chunk,
        prefetchBytes: prefetchChunks * chunk,
        maxCacheBytes: 16 * 1024 * 1024,
        connections: 2,
      );
      addTearDown(relay.dispose);

      final endpoint = (await relay.open(
        StreamTicket(
          url: Uri.parse('http://127.0.0.1:${upstream.port}/demo.mkv'),
          contentLength: total,
          contentType: 'video/x-matroska',
        ),
      ))!;

      final client = HttpClient()..findProxy = (Uri _) => 'DIRECT';
      addTearDown(client.close);

      // 旧读取器：开放式 Range（`bytes=0-`），持续消费 —— 模拟「被抛弃但没关」
      // 的那条连接。它必须**真的在读**，否则它不会提出需求，也就复现不了争抢。
      final oldRequest = await client.getUrl(endpoint.uri);
      oldRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
      final oldResponse = await oldRequest.close();
      unawaited(oldResponse.drain<void>().catchError((Object _) {}));

      // 先让旧位置把预取窗口填满一轮，确认它「活着」。
      await _waitFor(
        () => relay.statsOf(endpoint.token)!.downloadedBytes >= prefetchChunks * chunk,
      );

      // 新读取器：seek 到 30 MiB。mpv 就是这么干的 —— 新开连接、位置跳远。
      final newRequest = await client.getUrl(endpoint.uri);
      newRequest.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=${seekChunk * chunk}-',
      );
      final newResponse = await newRequest.close();
      unawaited(newResponse.drain<void>().catchError((Object _) {}));

      // 等到「seek 之后真的去上游取新位置」出现，那一刻就是新旧分界。
      await _waitFor(
        () => ranges.any((r) => r.start >= seekChunk * chunk),
      );
      final marker = ranges.indexWhere((r) => r.start >= seekChunk * chunk);
      expect(
        marker,
        greaterThanOrEqualTo(0),
        reason: 'seek 之后必须真的去上游取新位置，否则新位置永远播不了',
      );

      // 再等 seek 之后又发了至少一个预取窗口那么多的请求 —— 这样下面取的
      // $prefetchChunks 个样本一定是满的，断言不会因为「还没跑够」而空转通过。
      await _waitFor(() => ranges.length >= marker + prefetchChunks);

      final after = ranges.skip(marker).take(prefetchChunks).toList();
      final staleCount =
          after.where((r) => r.start < seekChunk * chunk).length;
      expect(
        staleCount,
        lessThanOrEqualTo(2),
        reason: 'seek 后前 $prefetchChunks 次上游请求里有 $staleCount 次喂给了旧位置 '
            '（上游共 ${ranges.length} 次）—— 预取锚点又被旧读取器拽回去了，'
            '新位置会饿死，表现就是「拖完进度条看一会卡一会」',
      );

      // 反向确认：新窗口确实在被下载，不是「谁都没喂」。
      expect(
        after.where((r) => r.start >= seekChunk * chunk).length,
        greaterThanOrEqualTo(prefetchChunks - 2),
      );
    });
  });

  group('中继诊断日志 —— TV 上「Failed to open 127.0.0.1」的取证路径', () {
    // 这一组钉的是**日志**而不是行为，因为那个故障在真机上只能靠日志事后还原：
    // 电视上播放失败时屏幕上只有一句
    //   「播放器报错：Failed to open http://127.0.0.1:43617/s1.」
    // 而中继原来对**请求本身**一声不吭 —— 「请求压根没来」与「来了但被 404
    // 掉」在日志里长得一模一样，事后无从区分。下面每条断言就是一道分水岭。

    setUp(() {
      diag.clearBuffer();
      addTearDown(diag.clearBuffer);
    });

    String logs() => diag.lines.join('\n');

    /// 起一个「要什么给什么」的上游，返回它的端口。
    Future<int> goodUpstream(int total) async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(upstream.close);
      upstream.listen((request) async {
        final range = parseRangeHeader(request.headers.value('Range'), total) ??
            ByteRange(0, total - 1);
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            formatContentRange(range, total),
          )
          ..headers.set(HttpHeaders.contentLengthHeader, range.length)
          ..add(Uint8List(range.length));
        await request.response.close();
      });
      return upstream.port;
    }

    test('会话号与入口 URL 写进日志 —— 才能把报错里的 /s1 对上哪一次接管', () async {
      final port = await goodUpstream(10);
      final relay = LocalStreamRelay(chunkSize: 10, prefetchBytes: 10);
      addTearDown(relay.dispose);

      final endpoint = (await relay.open(
        StreamTicket(
          url: Uri.parse('http://127.0.0.1:$port/demo.mkv'),
          contentLength: 10,
        ),
      ))!;

      // 没有这一条，「Failed to open .../s1」里的 s1 就无从对应到哪一次接管
      // ——一次播放会建多条会话，只能靠顺序猜。
      expect(logs(), contains('已接管 ${endpoint.token}'));
      // 入口 URL 一起打出来，才能和屏幕上的报错逐字对上。
      expect(
        logs(),
        contains('127.0.0.1:${endpoint.uri.port}/${endpoint.token}'),
      );
    });

    test('请求到达 + 首块下发都留痕 —— 反过来「没有任何中继日志」就等于没连进来',
        () async {
      final port = await goodUpstream(10);
      final relay = LocalStreamRelay(chunkSize: 10, prefetchBytes: 10);
      addTearDown(relay.dispose);

      final endpoint = (await relay.open(
        StreamTicket(
          url: Uri.parse('http://127.0.0.1:$port/demo.mkv'),
          contentLength: 10,
        ),
      ))!;

      final client = HttpClient()..findProxy = (Uri _) => 'DIRECT';
      addTearDown(client.close);
      final request = await client.getUrl(endpoint.uri);
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();

      expect(logs(), contains('会话 ${endpoint.token} 收到读取器 #1'));
      expect(logs(), contains('首块已下发'));
      // ⚠️ 总结行（`已下发 N 字节`）是服务端 `finally` 里落的，客户端
      // `drain()` 先返回 —— macOS 上服务端总赢，Windows 上客户端总赢。
      // 直接断言读到的是竞态结果，等它出现再断言（带超时，不会卡住 CI）。
      for (var i = 0; i < 500 && !logs().contains('已下发 10 字节'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(logs(), contains('已下发 10 字节'));
    });

    test('未知 token 回 404 并落 warn —— 假「直链过期」的唯一痕迹', () async {
      final port = await goodUpstream(10);
      final relay = LocalStreamRelay(chunkSize: 10, prefetchBytes: 10);
      addTearDown(relay.dispose);

      // 先建一条真会话，好让中继服务起在某个已知端口上。
      final endpoint = (await relay.open(
        StreamTicket(
          url: Uri.parse('http://127.0.0.1:$port/demo.mkv'),
          contentLength: 10,
        ),
      ))!;

      final client = HttpClient()..findProxy = (Uri _) => 'DIRECT';
      addTearDown(client.close);
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${endpoint.uri.port}/s999'),
      );
      final response = await request.close();
      expect(response.statusCode, HttpStatus.notFound);
      await response.drain<void>();

      // 这条 warn 是「换源时先关旧会话」那条假过期路径**唯一**的痕迹：
      // 播放器只会报一句笼统的 Failed to open，分不出 404 来自中继。
      expect(logs(), contains('拒绝 GET /s999'));
      expect(logs(), contains('会话不存在'));
    });

    test('上游取不到数据 → 一个字节都没发出，必须落 warn（Failed to open 的直接机制）',
        () async {
      // 上游对每一块都回 500：中继答应得出 200，正文却一个字节都拿不到。
      // 这正是 ffmpeg 判定「打不开」的形态 —— 它拿到了响应头，却读不出容器。
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(upstream.close);
      upstream.listen((request) async {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..headers.set(HttpHeaders.contentLengthHeader, 0);
        await request.response.close();
      });

      final relay = LocalStreamRelay(chunkSize: 10, prefetchBytes: 10);
      addTearDown(relay.dispose);
      final endpoint = (await relay.open(
        StreamTicket(
          url: Uri.parse('http://127.0.0.1:${upstream.port}/demo.mkv'),
          contentLength: 10,
        ),
      ))!;

      final client = HttpClient()..findProxy = (Uri _) => 'DIRECT';
      addTearDown(client.close);
      try {
        final request = await client.getUrl(endpoint.uri);
        final response = await request.close();
        await response.drain<void>();
      } catch (_) {
        // 中继会把连接掐掉（正文一个字节都没有）—— 客户端这边报什么不重要，
        // 要断言的是**中继自己留下了痕迹**。
      }

      // 上游那一侧的证据……
      expect(logs(), contains('取块 0 失败：上游返回 500'));
      // ……以及「中继对播放器一个字节都没给出」这个结论本身。原来它和「正常
      // 换源掐断连接」共用一条 debug，现场日志里会彻底消失。
      expect(logs(), contains('一个字节都没发出'));
    });
  });
}

/// 轮询等待某个条件成立。中继是异步预取的，没法「一拍到位」——
/// 用显式轮询而不是 `Future.delayed` 定长，避免在慢机器上偶发失败。
///
/// ⚠️ 超时给得宽松（15s）：全量 `flutter test` 是并行跑的，本机同时有几十个
/// isolate 抢 CPU，中继预取 8 MiB 可能比单跑慢一个量级。真正的断言在下面，
/// 超时只用来兜住「实现真的坏了」的情况。
Future<void> _waitFor(
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待中继状态超时（${timeout.inSeconds}s）');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
