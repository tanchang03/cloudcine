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
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(upstream.close);
      upstream.listen((request) async {
        cookies.add(request.headers.value('Cookie'));
        ranges.add(request.headers.value('Range'));
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
  });
}
