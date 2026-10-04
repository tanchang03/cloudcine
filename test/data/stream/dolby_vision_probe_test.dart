import 'dart:io';
import 'dart:typed_data';

import 'package:cloudcine/data/stream/dolby_vision_probe.dart';
import 'package:flutter_test/flutter_test.dart';

/// 杜比视界探测的**取字节 + 缓存**两层。
///
/// 为什么值得测：这一层决定了「开播前用哪个内核」，而它的失败方式**全是静默的**
/// —— 探不到就是 `null`，而 `null` 与「不是 DV」在接口上无法区分。
/// 所以除了「探得到」，还要钉住两条容易写错的：
///   1. 服务端**忽略 Range** 时绝不能把整个文件读进内存（真实片源是 GB 级）；
///   2. **取字节失败不许进缓存**，否则网络抖一下就把这部片子永久钉成非 DV。
void main() {
  group('DolbyVisionProbe（注入假取字节）', () {
    test('探到 DV P5 → 要求换内核', () async {
      final probe = DolbyVisionProbe(
        fetch: (url, headers, maxBytes) async => _matroskaDvcC(),
      );

      final info = await probe.probe(
        key: 'fid-1',
        url: Uri.parse('https://example.invalid/a.mkv'),
        headers: const {'Cookie': 'x=1'},
      );

      expect(info, isNotNull);
      expect(info!.profile, 5);
      expect(
        info.needsDolbyVisionEngine,
        isTrue,
        reason: 'P5 + compat 0 没有 HDR10 兜底 → 不换内核一定偏色',
      );
    });

    test('不是 DV → null（调用方按非 DV 处理）', () async {
      final probe = DolbyVisionProbe(
        fetch: (url, headers, maxBytes) async =>
            Uint8List.fromList(List<int>.filled(512, 0xAB)),
      );

      expect(
        await probe.probe(
          key: 'fid-2',
          url: Uri.parse('https://x/y'),
          headers: const {},
        ),
        isNull,
      );
    });

    test('同一 key 只探一次 —— 换清晰度不该重复往返', () async {
      var calls = 0;
      final probe = DolbyVisionProbe(
        fetch: (url, headers, maxBytes) async {
          calls++;
          return _matroskaDvcC();
        },
      );

      await probe.probe(key: 'fid', url: Uri.parse('https://x/1'), headers: const {});
      await probe.probe(key: 'fid', url: Uri.parse('https://x/2'), headers: const {});

      expect(
        calls,
        1,
        reason: '同一部片子每次取链的签名地址都不同，靠 URL 去重等于永远不命中',
      );
      expect(probe.cached('fid'), isNotNull);
    });

    test('⛔ 取字节失败**不缓存** —— 否则一次网络抖动就把片子永久钉成非 DV', () async {
      var calls = 0;
      final probe = DolbyVisionProbe(
        fetch: (url, headers, maxBytes) async {
          calls++;
          // 第一次失败（返回 null），第二次成功。
          return calls == 1 ? null : _matroskaDvcC();
        },
      );

      final first = await probe.probe(
          key: 'fid', url: Uri.parse('https://x/1'), headers: const {});
      final second = await probe.probe(
          key: 'fid', url: Uri.parse('https://x/2'), headers: const {});

      expect(first, isNull);
      expect(calls, 2, reason: '失败不进缓存 → 第二次必须真的再发一次请求');
      expect(second, isNotNull, reason: '第二次网络好了就该探到');
    });

    test('空字节按失败处理，同样不缓存', () async {
      var calls = 0;
      final probe = DolbyVisionProbe(
        fetch: (url, headers, maxBytes) async {
          calls++;
          return Uint8List(0);
        },
      );

      await probe.probe(key: 'k', url: Uri.parse('https://x'), headers: const {});
      await probe.probe(key: 'k', url: Uri.parse('https://x'), headers: const {});

      expect(calls, 2);
      expect(probe.cached('k'), isNull);
    });

    test('forget 之后会重新探（重刮 / 换源用）', () async {
      var calls = 0;
      final probe = DolbyVisionProbe(
        fetch: (url, headers, maxBytes) async {
          calls++;
          return _matroskaDvcC();
        },
      );

      await probe.probe(key: 'k', url: Uri.parse('https://x'), headers: const {});
      probe.forget('k');
      await probe.probe(key: 'k', url: Uri.parse('https://x'), headers: const {});

      expect(calls, 2);
    });
  });

  group('fetchHeadBytesDirect（真 loopback 上游）', () {
    test('⛔ 服务端**忽略 Range** 回 200 时，只读到 maxBytes', () async {
      // 1 MiB 的响应体，但只允许读 1 KiB。
      final big =
          Uint8List.fromList(List<int>.generate(1024 * 1024, (i) => i & 0xff));
      final server = await _serve((req, res) async {
        // 故意不理 Range，也**不报 Content-Length**（更接近真实的坏上游）。
        res.statusCode = 200;
        res.add(big);
        await res.close();
      });
      addTearDown(server.stop);

      final bytes = await fetchHeadBytesDirect(server.uri, const {}, 1024);

      expect(bytes, isNotNull);
      expect(
        bytes!.length,
        1024,
        reason: '收够就断。若照 Content-Length 收，这里会是 1 MiB —— '
            '而真实片源是 GB 级，等于 OOM',
      );
    });

    test('请求带 Range 与 Accept-Encoding: identity', () async {
      HttpHeaders? seen;
      final server = await _serve((req, res) async {
        seen = req.headers;
        res.statusCode = 206;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-255/1000');
        res.add(List<int>.filled(256, 0));
        await res.close();
      });
      addTearDown(server.stop);

      final bytes = await fetchHeadBytesDirect(server.uri, const {}, 256);

      expect(bytes!.length, 256);
      expect(seen!.value(HttpHeaders.rangeHeader), 'bytes=0-255');
      expect(
        seen!.value(HttpHeaders.acceptEncodingHeader),
        'identity',
        reason: '带 gzip 拿到的不是文件原始字节，而魔数判据是逐字节的',
      );
    });

    test('票据请求头原样带上（网盘直链缺 Cookie 一律 412）', () async {
      String? cookie;
      final server = await _serve((req, res) async {
        cookie = req.headers.value('cookie');
        res.statusCode = 206;
        res.add(List<int>.filled(8, 0));
        await res.close();
      });
      addTearDown(server.stop);

      await fetchHeadBytesDirect(server.uri, const {'Cookie': 'a=b'}, 8);

      expect(cookie, 'a=b');
    });

    test('上游 4xx → null（按「不是 DV」处理，不当错误）', () async {
      final server = await _serve((req, res) async {
        res.statusCode = 404;
        await res.close();
      });
      addTearDown(server.stop);

      expect(await fetchHeadBytesDirect(server.uri, const {}, 64), isNull);
    });

    test('整条链路：真 loopback 上游 + 真解析 → 探到 P5', () async {
      final head = _matroskaDvcC();
      final server = await _serve((req, res) async {
        res.statusCode = 206;
        res.add(head);
        await res.close();
      });
      addTearDown(server.stop);

      // 默认构造 → 走真的 fetchHeadBytesDirect。
      final probe = DolbyVisionProbe();
      final info =
          await probe.probe(key: 'fid', url: server.uri, headers: const {});

      expect(info, isNotNull);
      expect(info!.profile, 5);
      expect(info.blSignalCompatibilityId, 0);
    });
  });
}

/// 一个只服务单条路径的测试上游。
class _TestServer {
  _TestServer(this._server)
      : uri = Uri.parse('http://127.0.0.1:${_server.port}/f.mkv');

  final HttpServer _server;
  final Uri uri;

  Future<void> stop() => _server.close(force: true);
}

Future<_TestServer> _serve(
  Future<void> Function(HttpRequest request, HttpResponse response) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final response = request.response;
    try {
      await handler(request, response);
    } catch (_) {
      // 客户端**主动断开**（收够 maxBytes 就 cancel）会让写/close 抛异常。
      // 那是预期路径，不是测试失败。
    }
  });
  return _TestServer(server);
}

// ---------------------------------------------------------------------------
// 合成一条带 dvcC 的最小 Matroska
//
// 与 `test/core/utils/dolby_vision_test.dart` 里的那份同源；这里只需要
// 「能被 detectDolbyVision 认出来」这一条性质，所以不复制全部变体。
// ---------------------------------------------------------------------------

/// 本项目那条 4K DV 片源头部里实测的 24 字节 DOVI 记录（`dvcC @ 439`）。
const List<int> _realP5Record = <int>[1, 0, 0x0a, 0x4d, 0x00];

Uint8List _pad(List<int> head) =>
    Uint8List.fromList(head + List<int>.filled(24 - head.length, 0));

/// EBML 长度（VINT）。
///
/// ⚠️ 1 字节形式**必须带长度标记位**：长度 0 是 `0x80` 而不是 `0x00`。
/// 写成 `0x00` 会得到一个没有任何标记位的字节，真实解析器只能当坏数据 ——
/// 症状是**整个 Segment 都解析不出来**，看起来像解析器的 bug。
List<int> _vint(int n) {
  if (n < 0x7f) return <int>[0x80 | n];
  return <int>[0x40 | (n >> 8), n & 0xff];
}

List<int> _ebml(int id, List<int> body) {
  final idBytes = <int>[];
  var v = id;
  while (v > 0) {
    idBytes.insert(0, v & 0xff);
    v >>= 8;
  }
  return <int>[...idBytes, ..._vint(body.length), ...body];
}

/// Segment → Tracks → TrackEntry → BlockAdditionMapping(dvcC, DOVI 记录)。
Uint8List _matroskaDvcC() {
  const dvcC = 0x64766343; // ASCII "dvcC"
  final typeBytes = <int>[
    (dvcC >> 24) & 0xff,
    (dvcC >> 16) & 0xff,
    (dvcC >> 8) & 0xff,
    dvcC & 0xff,
  ];

  final mapping = _ebml(0x41e4, <int>[
    ..._ebml(0x41e7, typeBytes),
    ..._ebml(0x41ed, _pad(_realP5Record)),
  ]);

  return Uint8List.fromList(<int>[
    ..._ebml(0x1a45dfa3, <int>[]),
    ..._ebml(0x18538067, _ebml(0x1654ae6b, _ebml(0xae, mapping))),
  ]);
}
