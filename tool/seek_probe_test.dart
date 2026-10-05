// ignore_for_file: avoid_print
// ⚠️ 临时诊断夹具，跑完即删。不是回归测试 —— 它要联网、要真实票据。
//
// 目的：回答「拖进度条之后，中继到底在拉哪一段」。
// 做法：真实 LocalStreamRelay（8×2MiB，预取/缓存 256MiB）指向一个**记录型代理**，
//      代理转发到真实夸克直链并给每个 Range 打时间戳；mpv 走中继播放，20 秒时
//      seek 到 1500 秒。同时每 2 秒打印一次中继统计。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloudcine/data/stream/local_stream_relay.dart';
import 'package:cloudcine/domain/entities/stream_ticket.dart';
import 'package:flutter_test/flutter_test.dart';

const _appFrameworks = '/Users/tandy/workbuddy-ai/网盘媒体库播放器/build/macos/'
    'Build/Products/Debug/cloudcine.app/Contents/Frameworks';

void main() {
  test('seek 实测：中继在 seek 前后到底在拉哪一段', () async {
    final cfg =
        jsonDecode(File('/tmp/qk/ticket.json').readAsStringSync()) as Map<String, dynamic>;
    final origin = Uri.parse(cfg['url'] as String);
    final total = cfg['total'] as int;
    final headers = (cfg['headers'] as Map).cast<String, String>();

    final sw = Stopwatch()..start();
    final hits = <String>[];

    // ---- 记录型上游：转发到真实夸克，并把每个 Range 打下来 ----
    final proxyClient = HttpClient();
    proxyClient.findProxy = (Uri _) => 'DIRECT';
    proxyClient.maxConnectionsPerHost = 32;
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    proxy.listen((req) async {
      final rng = req.headers.value(HttpHeaders.rangeHeader);
      hits.add('${sw.elapsedMilliseconds}\t${rng ?? "(无 Range)"}');
      try {
        final preq = await proxyClient.getUrl(origin);
        headers.forEach((k, v) => preq.headers.set(k, v));
        if (rng != null) preq.headers.set(HttpHeaders.rangeHeader, rng);
        preq.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        final pres = await preq.close();
        req.response.statusCode = pres.statusCode;
        for (final k in const ['content-type', 'content-range', 'content-length']) {
          final v = pres.headers.value(k);
          if (v != null) req.response.headers.set(k, v);
        }
        await req.response.addStream(pres);
      } catch (e) {
        hits.add('${sw.elapsedMilliseconds}\t!! proxy error: $e');
      } finally {
        await req.response.close().catchError((Object _) {});
      }
    });
    addTearDown(proxy.close);

    final relay = LocalStreamRelay(
      connections: 8,
      chunkSize: 2 * 1024 * 1024,
      prefetchBytes: 256 * 1024 * 1024,
      maxCacheBytes: 256 * 1024 * 1024,
    );
    addTearDown(relay.dispose);

    final opened = await relay.open(
      StreamTicket(
        url: Uri.parse('http://127.0.0.1:${proxy.port}/probe.mkv'),
        headers: headers,
        contentLength: total,
        contentType: 'video/x-matroska',
      ),
      label: 'seek-probe',
      startOffset: int.tryParse(Platform.environment['START_OFFSET'] ?? '0') ?? 0,
    );
    expect(opened, isNotNull);
    final endpoint = opened!;

    final env = Map<String, String>.from(Platform.environment);
    for (final k in env.keys.toList()) {
      if (k.toLowerCase().contains('proxy')) env.remove(k);
    }
    env['NO_PROXY'] = '127.0.0.1,localhost';
    env['no_proxy'] = '127.0.0.1,localhost';
    env['DYLD_FRAMEWORK_PATH'] = _appFrameworks;

    final proc = await Process.start(
      '/tmp/mpv_probe3',
      <String>[
        endpoint.uri.toString(),
        Platform.environment['SECS'] ?? '90',
        'auto',
        'null',
        Platform.environment['START'] ?? '0',
        Platform.environment['CACHE'] ?? 'no',
        '1073741824',
        Platform.environment['SEEK_AT'] ?? '20',
        Platform.environment['SEEK_TO'] ?? '1500',
      ],
      environment: env,
    );
    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => print('[mpv] $l'));
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => print('[mpv!] $l'));

    var tick = 0;
    final timer = Timer.periodic(const Duration(seconds: 2), (_) {
      tick += 2;
      final s = relay.statsOf(endpoint.token);
      if (s == null) return;
      print('[[relay]] t=${tick}s 下载=${(s.downloadedBytes / 1048576).round()}MiB '
          '缓存=${(s.cachedBytes / 1048576).round()}MiB 在拉=${s.activeWorkers} '
          '请求=${s.upstreamRequests} 连接=${s.upstreamConnects} 失败=${s.upstreamFailures}');
    });

    final code = await proc.exitCode;
    timer.cancel();
    print('== mpv 退出码 $code；上游共 ${hits.length} 次请求（t 毫秒 / Range）==');
    for (final h in hits) {
      print(h);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
