import 'dart:typed_data';

import 'package:cloudcine/core/error/drive_error.dart';
import 'package:cloudcine/data/http/http_client.dart';
import 'package:cloudcine/data/http/token_bucket.dart';
import 'package:cloudcine/data/remote/quark/quark_adapter.dart';
import 'package:cloudcine/domain/adapters/credential_store.dart';
import 'package:cloudcine/domain/entities/auth_credential.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// 取链的**原画档**回归测试。
///
/// ## 为什么这条测试重要
///
/// 2026-10-01 的现场：用户播「指环王：力量之戒 S01E01」，选「原画」时
/// **有声音、进度条在走、没有画面**，而且不报任何错。实测查明原因是
/// `play/info` 的 `audio_list`（一条 Dolby E-AC-3 纯音频流）被解析成
/// 「原画」，而原画永远排最前 → 默认播的就是那条没有视频轨的流。
///
/// 这条链上任何一处改错**都不会报错**，只会让「原画」重新变成别的流。
/// 所以这里用真实响应形状把整条链钉住：
///   `resolveStream` → 两个接口各取一半 → 合并 → 选出默认档。
void main() {
  const fid = '8e6c6e9e94294364a7bdf9a3d01d0500';
  const originalUrl = 'https://video-play-c-zb-cf.pds.quark.cn/original.mkv'
      '?auth_key=1790844081-125382-15788-sig&token=abc';
  const superUrl = 'https://video-play-c-zb.drive.quark.cn/super.mp4'
      '?auth_key=1790844081-125382-15788-sig&token=abc';
  const highUrl = 'https://video-play-c-zb-cf.pds.quark.cn/high.mp4'
      '?auth_key=1790844081-125382-15788-sig&token=abc';
  const lowUrl = 'https://video-play-c-zb-cf.pds.quark.cn/low.mp4'
      '?auth_key=1790844081-125382-15788-sig&token=abc';
  const audioOnlyUrl = 'https://cdn.example.com/dolby-only.mp4';

  /// 真实 `play/info` 响应（结构照抄实测结果，只把地址换成占位串）。
  Map<String, Object?> playInfoBody() => {
        'status': 200,
        'code': 0,
        'message': '',
        'data': {
          fid: {
            'default_resolution': 'super',
            'video_list': [
              {
                'resolution': 'super',
                'video_info': {
                  'width': 1440,
                  'height': 600,
                  'bitrate': 1518.0,
                  'codec': 'h264',
                  'url': superUrl,
                  'resolution': 'super',
                },
              },
              {
                'resolution': 'high',
                'video_info': {
                  'width': 960,
                  'height': 400,
                  'bitrate': 855.0,
                  'url': highUrl,
                  'resolution': 'high',
                },
              },
              {
                'resolution': 'low',
                'video_info': {
                  'width': 480,
                  'height': 200,
                  'url': lowUrl,
                  'resolution': 'low',
                },
              },
            ],
            // ⚠️ 纯音频流。老解析器把它当成「原画」—— 事故的成因。
            'audio_list': [
              {
                'type': 'dolby_eac3',
                'audio_info': {'url': audioOnlyUrl},
              },
            ],
            'size': 3828008839,
            'meta': {
              'size': 3828008839,
              'format': 'matroska,webm',
              'width': 1920,
              'height': 800,
              'bitrate': 7758.0,
              'codec': 'h264',
            },
          },
        },
      };

  /// 真实 `audioplay` 响应（`audio_url` 其实是**原文件**）。
  Map<String, Object?> audioPlayBody() => {
        'status': 200,
        'code': 0,
        'message': '',
        'data': {
          'fid': fid,
          'size': 3828008839,
          'format_type': 'video/x-matroska',
          'duration': 3947,
          'audio_url': originalUrl,
        },
      };

  Map<String, Object?> v2PlayBody() => {
        'status': 200,
        'code': 0,
        'data': {
          fid: {
            'video_list': [
              {
                'resolution': 'super',
                'video_info': {'url': superUrl, 'resolution': 'super'},
              },
            ],
          },
        },
      };

  test('默认档是原画，且它来自 audioplay 的原文件（不是音轨）', () async {
    final (:adapter, :http) = await readyAdapter({
      '/file/audioplay': audioPlayBody(),
      '/batch/file/play/info': playInfoBody(),
    });

    final ticket = await adapter.resolveStream(fid);

    // 原画排最前 —— 这是「默认播原画」的实现口径
    expect(ticket.qualities.map((q) => q.id).toList(),
        ['origin', 'super', 'high', 'low']);
    expect(ticket.pickActiveQualityId(null), 'origin');

    final origin = ticket.qualities.first;
    expect(origin.isOriginal, isTrue);
    expect(origin.label, '原画');
    expect(
      origin.url.toString(),
      originalUrl,
      reason: '原画必须是 audioplay 的 audio_url（原文件）。'
          '若它变成 super/high 或 dolby-only，就是又踩了「音轨当原画」那个坑',
    );
    // 副标题来自 meta，不是空的
    expect(origin.width, 1920);
    expect(origin.height, 800);
    expect(origin.bitrate, 7758000, reason: '服务端 bitrate 是 kbps，要换算成 bps');
    expect(origin.displayDetail, '1920×800 · 7.8 Mbps · MKV');

    // 音轨地址绝不出现在任何一档里
    expect(
      ticket.qualities.any((q) => q.url.toString().contains('dolby-only')),
      isFalse,
    );

    // 两个接口都要打 —— 原画与梯度来自不同来源
    expect(http.paths, contains('/file/audioplay'));
    expect(http.paths, contains('/batch/file/play/info'));
  });

  test('指定转码档位时切过去，档位表仍然完整', () async {
    final (:adapter, http: _) = await readyAdapter({
      '/file/audioplay': audioPlayBody(),
      '/batch/file/play/info': playInfoBody(),
    });

    final ticket = await adapter.resolveStream(fid, qualityId: 'high');

    expect(ticket.pickActiveQualityId('high'), 'high');
    expect(ticket.qualities.map((q) => q.id).toList(),
        ['origin', 'super', 'high', 'low']);
  });

  test('audioplay 挂了不影响播放：退回最高转码档', () async {
    final (:adapter, http: _) = await readyAdapter({
      '/file/audioplay': null, // 网络层失败
      '/batch/file/play/info': playInfoBody(),
    });

    final ticket = await adapter.resolveStream(fid);

    expect(ticket.qualities.map((q) => q.id).toList(), ['super', 'high', 'low']);
    expect(ticket.qualities.any((q) => q.isOriginal), isFalse);
    expect(ticket.pickActiveQualityId(null), 'super');
  });

  test('play/info 挂了不影响播放：只剩原画，仍能出画', () async {
    final (:adapter, http: _) = await readyAdapter({
      '/file/audioplay': audioPlayBody(),
      '/batch/file/play/info': null,
    });

    final ticket = await adapter.resolveStream(fid);

    expect(ticket.qualities.map((q) => q.id).toList(), ['origin']);
    expect(ticket.url.toString(), originalUrl);
    // 原画没有 meta 可读时副标题为空，但不该影响播放
    expect(ticket.qualities.single.isAvailable, isTrue);
  });

  test('两条主来源都挂了才走兜底路由（v2/play）', () async {
    final (:adapter, :http) = await readyAdapter({
      '/file/audioplay': null,
      '/batch/file/play/info': null,
      '/file/v2/play': v2PlayBody(),
    });

    final ticket = await adapter.resolveStream(fid);

    expect(ticket.qualities.map((q) => q.id).toList(), ['super']);
    expect(http.paths, contains('/file/v2/play'));
  });

  test('v2/play 兜底走的是 POST + {"fid":…}（GET 实测 405）', () async {
    final (:adapter, :http) = await readyAdapter({
      '/file/audioplay': null,
      '/batch/file/play/info': null,
      '/file/v2/play': v2PlayBody(),
    });

    await adapter.resolveStream(fid);

    final call = http.calls.lastWhere((c) => c.path == '/file/v2/play');
    expect(call.method, 'POST');
    expect(
      call.body,
      {'fid': fid},
      reason: '实测 POST {"fids":[fid]} 返回 400 code=14001 '
          '"Bad Parameter: [fid is empty!]"；GET 返回 405',
    );
  });

  test('授权失效直接上抛，不再浪费配额试别的路由', () async {
    final (:adapter, :http) = await readyAdapter({
      '/file/audioplay': {
        'status': 401,
        'code': 31001,
        'message': 'auth not found',
      },
      '/batch/file/play/info': playInfoBody(),
    });

    await expectLater(
      adapter.resolveStream(fid),
      throwsA(isA<DriveException>()
          .having((e) => e.needsReauth, 'needsReauth', isTrue)),
    );
    // 短路：第二条主来源根本没被打
    expect(http.paths, isNot(contains('/batch/file/play/info')));
  });

  test('取链桶的突发容量是 2：起播的两个请求不该白等一秒', () {
    expect(
      QuarkAdapter.linkBucketBurst,
      2,
      reason: '一次播放要打 audioplay 与 play/info 两个请求。'
          '桶容量回到默认的 1 时，第二个请求必然等满 1 秒（linkQps = 1.0）'
          '—— 表现是「点了播放先干等一秒多」，而这一秒换来的是零保护价值'
          '（它们是一对计划中的请求，不是重试风暴）。',
    );
  });

  test('票据带 Cookie（缺它直链一律 412）', () async {
    final (:adapter, http: _) = await readyAdapter({
      '/file/audioplay': audioPlayBody(),
      '/batch/file/play/info': playInfoBody(),
    });

    final ticket = await adapter.resolveStream(fid);

    expect(ticket.headers.keys, contains('Cookie'));
    expect(ticket.headers['Cookie'], contains('__pus='));
  });
}

/// 按路径分发预置响应的假客户端。值为 `null` 表示**网络层失败**。
class _FakeHttp implements HttpClientLike {
  _FakeHttp(this.routes);

  final Map<String, Map<String, Object?>?> routes;
  final List<({String method, String path, Object? body})> calls = [];

  List<String> get paths => [for (final c in calls) c.path];

  static const List<String> _known = [
    '/batch/file/play/info',
    '/file/audioplay',
    '/file/v2/play',
    '/file/download',
    '/member',
  ];

  static String _pathOf(String url) {
    final p = Uri.parse(url).path;
    for (final key in _known) {
      if (p.endsWith(key)) return key;
    }
    return p;
  }

  HttpResult _respond(String url) {
    final path = _pathOf(url);
    if (!routes.containsKey(path)) {
      return HttpResult.networkFailure('未预置响应：$path');
    }
    final body = routes[path];
    if (body == null) return HttpResult.networkFailure('模拟网络失败：$path');
    return HttpResult(statusCode: 200, json: body);
  }

  @override
  Future<HttpResult> get(
    String url, {
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
    bool followRedirects = true,
  }) async {
    calls.add((method: 'GET', path: _pathOf(url), body: null));
    return _respond(url);
  }

  @override
  Future<HttpResult> post(
    String url, {
    Object? body,
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    calls.add((method: 'POST', path: _pathOf(url), body: body));
    return _respond(url);
  }

  @override
  Future<Uint8List?> getBytes(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async =>
      null;

  @override
  Future<String> putBytes(
    String url, {
    required List<int> body,
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      throw UnimplementedError();

  @override
  void close() {}
}

class _FakeStore implements CredentialStore {
  @override
  Future<void> save(AuthCredential credential) async {}

  @override
  Future<AuthCredential?> load(DriveProvider provider) async => AuthCredential(
        provider: DriveProvider.quark,
        mode: AuthMode.manualCookie,
        capturedAt: DateTime(2026, 10, 1),
        cookies: const {'__pus': 'PUSVALUE', '__puus': 'PUUSVALUE'},
      );

  @override
  Future<void> clear(DriveProvider provider) async {}

  @override
  Future<List<DriveProvider>> authorizedProviders() async =>
      const [DriveProvider.quark];

  @override
  bool get supportsPersistence => true;
}

/// 造一个**已完成会话校验**的适配器。
///
/// `/member` 是 `restoreSession()` 会打的接口，所以这里统一补上 ——
/// 免得每个用例都要写一遍与它无关的样板。
Future<({QuarkAdapter adapter, _FakeHttp http})> readyAdapter(
  Map<String, Map<String, Object?>?> routes,
) async {
  final http = _FakeHttp({
    '/member': {
      'status': 200,
      'code': 0,
      'data': {'member_type': 'SUPER_VIP'},
    },
    ...routes,
  });
  final adapter = QuarkAdapter(
    http: http,
    credentialStore: _FakeStore(),
    // 桶容量与适配器默认值一致，但等待用假实现 —— 单测不真的 sleep。
    linkBucket: TokenBucket(
      ratePerSecond: 1.0,
      burst: QuarkAdapter.linkBucketBurst,
      delay: (d) async {},
    ),
    listBucket: TokenBucket(ratePerSecond: 3.0, delay: (d) async {}),
  );
  await adapter.restoreSession();
  return (adapter: adapter, http: http);
}
