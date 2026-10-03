import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloudcine/core/utils/http_range.dart';
import 'package:cloudcine/data/stream/local_stream_relay.dart';
import 'package:cloudcine/domain/adapters/stream_relay.dart';
import 'package:cloudcine/domain/entities/stream_ticket.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isRelayableUrl', () {
    test('HLS 不走中继', () {
      // m3u8 里的分片是相对地址，中继会把拼地址的基准改成 127.0.0.1，
      // 拼出来的地址全部指向我们自己的服务 —— 播不了。
      expect(isRelayableUrl(Uri.parse('https://cdn.quark.cn/media.m3u8?x=1')),
          isFalse);
    });

    test('普通 http/https 直链可以走中继', () {
      expect(isRelayableUrl(Uri.parse('https://cdn.quark.cn/a.mkv')), isTrue);
    });

    test('本地文件 / asset 不走中继', () {
      expect(isRelayableUrl(Uri.parse('file:///Users/a/b.mkv')), isFalse);
      expect(isRelayableUrl(Uri.parse('asset:///assets/probe.mp4')), isFalse);
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

      // ⑦ 线级证据：上游看到的**不同 TCP 连接**（按远端端口去重）也应 ≤4。
      //    只数计数器可能被实现骗过；数端口才是真的复用了连接。
      final distinctPorts = ports.whereType<int>().toSet();
      expect(distinctPorts.length, lessThanOrEqualTo(4));
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
