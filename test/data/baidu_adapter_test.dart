import 'dart:convert';
import 'dart:typed_data';

import 'package:cloudcine/core/error/drive_error.dart';
import 'package:cloudcine/data/http/http_client.dart';
import 'package:cloudcine/data/http/token_bucket.dart';
import 'package:cloudcine/data/remote/baidu/baidu_adapter.dart';
import 'package:cloudcine/data/remote/baidu/baidu_endpoints.dart';
import 'package:cloudcine/domain/adapters/credential_store.dart';
import 'package:cloudcine/domain/entities/auth_credential.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/quality_option.dart';
import 'package:flutter_test/flutter_test.dart';

/// 百度适配器（**只读**：授权 / 遍历 / 取流）。
///
/// ## 这一组测试守什么
///
/// 1. **ID → 路径的翻译**。契约收 `fs_id`，百度收路径。翻错的表现是
///    「列出来的目录永远是空的」—— 因为 `dir` 打了一个不存在的路径，
///    而服务端对不存在的路径**不报错**，只回一个空列表。
/// 2. **取链的三条路由各自独立**。任何一条失败都还有别的路可走，
///    而「三条都试过才算失败」这件事只能靠请求记录来断言。
/// 3. **只读边界**。四个写方法必须走基类的 `unsupported` 默认实现 ——
///    这条一旦破了就是**用户数据损失**。
/// 一次请求的记录（断言「打了哪个接口、带什么参数」）。
typedef Call = ({String path, Map<String, Object?> query});

/// 按**路径**路由的假 HTTP 客户端。
///
/// 网盘接口靠路径区分（`/api/list` vs `/api/filemetas`），所以按路径路由
/// 比按调用顺序路由更能表达「哪条路由被打了」。没有匹配项时返回 404，
/// 于是「不该被打的接口」被打了会立刻显形。
class FakeHttp implements HttpClientLike {
  FakeHttp(this.routes);

  final Map<String, HttpResult Function(Map<String, Object?> query)> routes;

  final List<Call> calls = [];

  /// 每次 `get` 收到的请求头（按调用顺序）。用来守「网盘接口必须带
  /// `Origin`」这条 —— 请求头不进 [calls]，只看路径断言不出来。
  final List<Map<String, String>> headerCalls = [];

  List<Call> callsTo(String path) => calls.where((c) => c.path == path).toList();

  /// 按**请求头**路由的处理器（同一个 URL、只有请求头不同时用）。
  ///
  /// [routes] 只能「按路径路由」，表达不了「同一路径、不同请求头走不同分支」。
  /// 返回 `null` 表示「不归我管」，继续走 [routes] —— 这样它就能只拦直链、
  /// 不干扰 `/api/*`。
  HttpResult? Function(String path, Map<String, String> headers)? headerHandler;

  @override
  Future<HttpResult> get(
    String url, {
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
    bool followRedirects = true,
  }) async {
    final path = Uri.parse(url).path;
    final h = headers ?? const <String, String>{};
    calls.add((path: path, query: query ?? const {}));
    headerCalls.add(h);
    final byHeader = headerHandler;
    if (byHeader != null) {
      final res = byHeader(path, h);
      if (res != null) return res;
    }
    final handler = routes[path];
    if (handler == null) {
      return const HttpResult(statusCode: 404, rawBody: '');
    }
    return handler(query ?? const {});
  }

  @override
  Future<HttpResult> post(
    String url, {
    Object? body,
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      throw UnimplementedError('百度适配器不该用 POST');

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
  Future<String> postBytes(
    String url, {
    required List<int> body,
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      throw UnimplementedError();

  @override
  void close() {}
}

class FakeStore implements CredentialStore {
  FakeStore({this.credential});

  AuthCredential? credential;
  int saveCount = 0;
  int clearCount = 0;

  @override
  Future<void> save(AuthCredential c) async {
    credential = c;
    saveCount++;
  }

  @override
  Future<AuthCredential?> load(DriveProvider provider) async => credential;

  @override
  Future<void> clear(DriveProvider provider) async {
    credential = null;
    clearCount++;
  }

  @override
  Future<List<DriveProvider>> authorizedProviders() async =>
      credential == null ? const [] : const [DriveProvider.baidu];

  @override
  bool get supportsPersistence => true;
}

void main() {
  // -------------------------------------------------------------------
  // 公共小工具
  // -------------------------------------------------------------------

  AuthCredential baiduCredential() => AuthCredential(
        provider: DriveProvider.baidu,
        mode: AuthMode.qrCode,
        capturedAt: DateTime(2026, 10, 8),
        cookies: const {'BDUSS': 'BDUSS-VALUE', 'STOKEN': 'STOKEN-VALUE'},
      );

  HttpResult ok(Map<String, Object?> body) =>
      HttpResult(statusCode: 200, json: body);

  HttpResult errno(int code, {String? showMsg}) => HttpResult(
        statusCode: 200,
        json: {
          'errno': code,
          if (showMsg != null) 'show_msg': showMsg,
        },
      );

  /// `uinfo` + `quota` 的固定应答 —— 每个用例都要它，抽出来免得样板满天飞。
  Map<String, HttpResult Function(Map<String, Object?> query)> accountRoutes({
    int vipType = BaiduVipType.normal,
  }) =>
      {
        BaiduEndpoints.accountUinfo: (_) => ok({
              'errno': 0,
              'data': {'netdisk_name': '测试号', 'uk': 42, 'vip_type': vipType},
            }),
        BaiduEndpoints.quota: (_) => ok({
              'errno': 0,
              'total': 1000,
              'used': 250,
            }),
      };

  /// 造一个**已恢复会话**的适配器。
  ///
  /// [restore] 为 `false` 时不自动恢复 —— 供「恢复本身就该失败」的用例
  /// 自己调 `restoreSession()`（否则失败会发生在夹具里，拿不到 `http` 断言）。
  Future<({BaiduAdapter adapter, FakeHttp http, FakeStore store})> ready({
    Map<String, HttpResult Function(Map<String, Object?> query)> routes =
        const {},
    int vipType = BaiduVipType.normal,
    bool withSession = true,
    bool restore = true,
  }) async {
    final http = FakeHttp({...accountRoutes(vipType: vipType), ...routes});
    final store = FakeStore(credential: withSession ? baiduCredential() : null);
    final adapter = BaiduAdapter(
      http: http,
      credentialStore: store,
      // 桶的等待换成空实现 —— 单测不真的 sleep。容量与默认值一致，
      // 这样「突发几次」的行为仍然被覆盖。
      listBucket: TokenBucket(ratePerSecond: 2.0, delay: (d) async {}),
      linkBucket: TokenBucket(
        ratePerSecond: 1.0,
        burst: BaiduAdapter.linkBucketBurst,
        delay: (d) async {},
      ),
    );
    if (withSession && restore) await adapter.restoreSession();
    return (adapter: adapter, http: http, store: store);
  }

  // -------------------------------------------------------------------
  // 授权
  // -------------------------------------------------------------------

  group('授权', () {
    test('空凭证直接拒绝，不落库', () async {
      final r = await ready(withSession: false);
      await expectLater(
        r.adapter.authorize(
          AuthCredential(
            provider: DriveProvider.baidu,
            mode: AuthMode.manualCookie,
            capturedAt: DateTime(2026, 10, 8),
          ),
        ),
        throwsA(
          isA<DriveException>()
              .having((e) => e.type, 'type', DriveErrorType.unauthorized),
        ),
      );
      expect(r.store.saveCount, 0);
    });

    test('校验通过才落库（避免把废凭证写进安全存储）', () async {
      final r = await ready(withSession: false);
      final account = await r.adapter.authorize(baiduCredential());

      expect(account.provider, DriveProvider.baidu);
      expect(account.displayName, '测试号');
      expect(account.memberLabel, '普通用户');
      expect(account.storageTotalBytes, 1000);
      expect(r.store.saveCount, 1);
      expect(r.adapter.hasSession, isTrue);
    });

    test('校验失败（errno=-6）时**不落库**，并把内存里的会话丢掉', () async {
      final http = FakeHttp({
        BaiduEndpoints.accountUinfo: (_) =>
            errno(-6, showMsg: '账户已过期，重新登陆'),
        BaiduEndpoints.quota: (_) => ok({'errno': 0}),
      });
      final store = FakeStore();
      final adapter = BaiduAdapter(
        http: http,
        credentialStore: store,
        listBucket: TokenBucket(ratePerSecond: 2.0, delay: (d) async {}),
        linkBucket: TokenBucket(ratePerSecond: 1.0, delay: (d) async {}),
      );

      await expectLater(
        adapter.authorize(baiduCredential()),
        throwsA(
          isA<DriveException>()
              .having((e) => e.type, 'type', DriveErrorType.unauthorized),
        ),
      );
      expect(store.saveCount, 0, reason: '废凭证不该进安全存储');
      expect(adapter.hasSession, isFalse);
    });

    test('quota 失败不影响登录（容量是附属信息）', () async {
      final http = FakeHttp({
        BaiduEndpoints.accountUinfo: (_) => ok({
              'errno': 0,
              'data': {'netdisk_name': '测试号'},
            }),
        BaiduEndpoints.quota: (_) => errno(-6),
      });
      final adapter = BaiduAdapter(
        http: http,
        credentialStore: FakeStore(credential: baiduCredential()),
        listBucket: TokenBucket(ratePerSecond: 2.0, delay: (d) async {}),
        linkBucket: TokenBucket(ratePerSecond: 1.0, delay: (d) async {}),
      );

      final account = await adapter.restoreSession();
      expect(account, isNotNull);
      expect(account!.displayName, '测试号');
      expect(account.hasStorageInfo, isFalse);
    });

    test('restoreSession：存储为空时返回 null（不是抛）', () async {
      final r = await ready(withSession: false);
      expect(await r.adapter.restoreSession(), isNull);
    });

    test('signOut 清内存会话 + 清存储', () async {
      final r = await ready();
      await r.adapter.signOut();
      expect(r.adapter.hasSession, isFalse);
      expect(r.store.clearCount, 1);
    });

    test('refreshAccount 不动凭证存储（百度没有 Cookie 轮换）', () async {
      final r = await ready();
      final account = await r.adapter.refreshAccount();
      expect(account, isNotNull);
      expect(r.store.saveCount, 0);
      expect(r.store.clearCount, 0);
    });

    test('⛔ 网盘接口请求带 Origin（与已知能跑通的实现对齐）', () async {
      // 2026-10-08 实测：缺 `Origin` 的 `/api/account/uinfo` 回了 `errno=-6`。
      // 它是我们与一个**能跑通**的社区实现之间唯一的结构性差异，所以钉住它。
      final r = await ready();
      expect(r.http.headerCalls, isNotEmpty);
      for (final h in r.http.headerCalls) {
        expect(h['Origin'], 'https://pan.baidu.com');
        expect(h['Referer'], isNotNull);
        expect(h['Cookie'], isNotNull);
      }
    });
  });

  // -------------------------------------------------------------------
  // ping
  // -------------------------------------------------------------------

  group('ping：连接诊断', () {
    test('没有会话时直接 false，不打网络', () async {
      final r = await ready(withSession: false);
      expect(await r.adapter.ping(), isFalse);
      expect(r.http.callsTo(BaiduEndpoints.quota), isEmpty);
    });

    test('会话有效 → true', () async {
      final r = await ready();
      expect(await r.adapter.ping(), isTrue);
    });

    test('errno=-6 → false（而不是抛）', () async {
      final r = await ready(
        routes: {
          BaiduEndpoints.quota: (_) => errno(-6),
        },
      );
      expect(await r.adapter.ping(), isFalse);
    });
  });

  // -------------------------------------------------------------------
  // 列目录：ID → 路径
  // -------------------------------------------------------------------

  /// 一次 `/api/list` 的响应：一个目录 + 一个视频。
  HttpResult listing(String dir) => ok({
        'errno': 0,
        'list': [
          {
            'fs_id': 100,
            'server_filename': '电影',
            'isdir': 1,
            'path': '$dir电影',
          },
          {
            'fs_id': 101,
            'server_filename': 'a.mkv',
            'isdir': 0,
            'size': 1024,
            'path': '${dir}a.mkv',
            'server_mtime': 1759900000,
            'duration': 100,
          },
        ],
        'request_id': 1,
      });

  group('listDirectory：把 fs_id 翻译成路径', () {
    test('根目录走 dir=/（不是 fs_id）', () async {
      final r = await ready(routes: {BaiduEndpoints.list: (_) => listing('/')});

      final page = await r.adapter.listDirectory(dirId: r.adapter.rootId);

      expect(page.entries, hasLength(2));
      expect(page.entries[0].isDirectory, isTrue);
      expect(page.entries[1].isDirectory, isFalse);
      expect(page.entries[1].sizeBytes, 1024);
      expect(r.http.callsTo(BaiduEndpoints.list).single.query['dir'], '/');
    });

    test('⭐ 列完父目录就白捡了子项路径 ⇒ 子目录**不再**多打一次解析', () async {
      final r = await ready(
        routes: {
          BaiduEndpoints.list: (q) => listing(q['dir'] == '/' ? '/' : '/电影/'),
        },
      );

      await r.adapter.listDirectory(dirId: r.adapter.rootId);
      final before = r.http.callsTo(BaiduEndpoints.xpanMultimedia).length;

      // 用**列表里那一项的 id**（100 = 「电影」）继续往下列。
      final sub = await r.adapter.listDirectory(dirId: '100');

      expect(sub.entries, hasLength(2));
      expect(
        r.http.callsTo(BaiduEndpoints.xpanMultimedia),
        hasLength(before),
        reason: '路径缓存命中时不该再打一次 filemetas',
      );
      expect(r.http.callsTo(BaiduEndpoints.list).last.query['dir'], '/电影');
    });

    test('路径缓存未命中时回退到 filemetas 解析（只多一次请求）', () async {
      final r = await ready(
        routes: {
          BaiduEndpoints.list: (_) => listing('/随便/'),
          BaiduEndpoints.xpanMultimedia: (_) => ok({
                'errno': 0,
                'list': [
                  {'fs_id': 777, 'path': '/下载'},
                ],
              }),
        },
      );

      await r.adapter.listDirectory(dirId: '777');

      final resolve = r.http.callsTo(BaiduEndpoints.xpanMultimedia).single;
      expect(resolve.query['method'], 'filemetas');
      expect(resolve.query['fsids'], '[777]');
      expect(r.http.callsTo(BaiduEndpoints.list).last.query['dir'], '/下载');
    });

    test('解析不出路径时抛 notFound（而不是拿空路径去打列目录）', () async {
      final r = await ready(
        routes: {
          BaiduEndpoints.xpanMultimedia: (_) => ok({'errno': 0, 'list': []}),
        },
      );

      await expectLater(
        r.adapter.listDirectory(dirId: '777'),
        throwsA(
          isA<DriveException>()
              .having((e) => e.type, 'type', DriveErrorType.notFound),
        ),
      );
      expect(
        r.http.callsTo(BaiduEndpoints.list),
        isEmpty,
        reason: '路径都不知道就别去打列目录了',
      );
    });

    test('errno=-6 映射成 unauthorized 并标记需要重新授权', () async {
      final r = await ready(
        routes: {
          BaiduEndpoints.list: (_) =>
              errno(-6, showMsg: '账户已过期，重新登陆'),
        },
      );

      await expectLater(
        r.adapter.listDirectory(dirId: r.adapter.rootId),
        throwsA(
          isA<DriveException>()
              .having((e) => e.type, 'type', DriveErrorType.unauthorized)
              .having((e) => e.needsReauth, 'needsReauth', isTrue)
              .having((e) => e.providerCode, 'providerCode', -6),
        ),
      );
    });

    test('未授权时直接抛，不打网络', () async {
      final r = await ready(withSession: false);
      await expectLater(
        r.adapter.listDirectory(dirId: '/'),
        throwsA(
          isA<DriveException>()
              .having((e) => e.type, 'type', DriveErrorType.unauthorized),
        ),
      );
      expect(r.http.callsTo(BaiduEndpoints.list), isEmpty);
    });
  });

  group('listDirectory：分页', () {
    Map<String, HttpResult Function(Map<String, Object?> query)> paging(
      Map<String, Object?> body,
    ) =>
        {
          BaiduEndpoints.list: (_) => ok({'errno': 0, ...body}),
        };

    test('has_more=1 ⇒ 有下一页', () async {
      final r = await ready(
        routes: paging({
          'list': [
            {'fs_id': 1, 'server_filename': 'a', 'isdir': 0},
          ],
          'has_more': 1,
        }),
      );
      final page = await r.adapter.listDirectory(dirId: '/');
      expect(page.nextPageToken, '2');
    });

    test('has_more=0 ⇒ 没有下一页（哪怕刚好满页）', () async {
      final r = await ready(
        routes: paging({
          'list': [
            {'fs_id': 1, 'server_filename': 'a', 'isdir': 0},
          ],
          'has_more': 0,
        }),
      );
      final page = await r.adapter.listDirectory(dirId: '/', pageSize: 1);
      expect(page.nextPageToken, isNull);
    });

    test('没有 has_more 时退回「满页启发式」（与夸克同一套）', () async {
      final r = await ready(
        routes: paging({
          'list': [
            {'fs_id': 1, 'server_filename': 'a', 'isdir': 0},
          ],
        }),
      );
      final full = await r.adapter.listDirectory(dirId: '/', pageSize: 1);
      expect(full.nextPageToken, '2');

      final partial = await r.adapter.listDirectory(dirId: '/', pageSize: 10);
      expect(partial.nextPageToken, isNull);
    });

    test('pageToken 非法值回落到第 1 页（而不是崩）', () async {
      final r = await ready(
        routes: paging({
          'list': [
            {'fs_id': 1, 'server_filename': 'a', 'isdir': 0},
          ],
        }),
      );
      await r.adapter.listDirectory(dirId: '/', pageToken: 'abc');
      expect(r.http.callsTo(BaiduEndpoints.list).single.query['page'], 1);

      await r.adapter.listDirectory(dirId: '/', pageToken: '-3');
      expect(r.http.callsTo(BaiduEndpoints.list).last.query['page'], 1);

      await r.adapter.listDirectory(dirId: '/', pageToken: '5');
      expect(r.http.callsTo(BaiduEndpoints.list).last.query['page'], 5);
    });
  });

  // -------------------------------------------------------------------
  // 取流：三条路由的降级阶梯
  // -------------------------------------------------------------------

  group('resolveStream：路由阶梯', () {
    const originalUrl = 'https://d.pcs.baidu.com/original.mkv?fid=1';
    const ladderUrl = 'https://cdn.example.com/transcoded.mp4';

    /// ① xpan 原画成功。**带 `path`** —— 路径缓存靠它回填，
    /// 而 ③ 转码档需要路径。
    HttpResult fsidOriginal() => ok({
          'errno': 0,
          'list': [
            {
              'fs_id': 1,
              'path': '/电影/a.mkv',
              'size': 8 * 1024 * 1024,
              'dlink': originalUrl,
            },
          ],
        });

    /// ① 通了但**响应里没有地址** —— 这正是「响应形状没验证过」要处理的情况。
    /// 它同时会把 `path` 回填进缓存。
    HttpResult fsidNoDlink() => ok({
          'errno': 0,
          'list': [
            {'fs_id': 1, 'path': '/电影/a.mkv'},
          ],
        });

    HttpResult ladderOk({String url = ladderUrl}) => ok({
          'errno': 0,
          'list': [
            {'dlink': url, 'size': 1024 * 1024},
          ],
        });

    test('① + ③ 都成功 ⇒ 原画排最前，转码档跟在后面', () async {
      final r = await ready(
        routes: {
          BaiduEndpoints.xpanMultimedia: (_) => fsidOriginal(),
          BaiduEndpoints.batchStreaming: (_) => ladderOk(),
        },
      );

      final ticket = await r.adapter.resolveStream('1');

      expect(ticket.url.toString(), originalUrl);
      expect(ticket.qualities, hasLength(2));
      expect(ticket.qualities.first.id, kOriginalQualityId);
      expect(ticket.qualities.first.isOriginal, isTrue);
      expect(ticket.qualities.first.label, '原画');
      // 默认选中原画 —— 否则「点开就是转码流」，而用户看不出来。
      expect(ticket.pickActiveQualityId(null), kOriginalQualityId);
    });

    test('直链必须带 UA: pan.baidu.com 与 Cookie（否则 31326 / -6）', () async {
      final r = await ready(
        routes: {
          BaiduEndpoints.xpanMultimedia: (_) => fsidOriginal(),
          BaiduEndpoints.batchStreaming: (_) => ladderOk(),
        },
      );

      final ticket = await r.adapter.resolveStream('1');
      expect(ticket.headers['User-Agent'], 'pan.baidu.com');
      expect(ticket.headers['Cookie'], contains('BDUSS=BDUSS-VALUE'));
      expect(ticket.contentLength, 8 * 1024 * 1024);
    });

    test('非 SVIP 只探 480P（SVIP 档位服务端根本不给，白费配额）', () async {
      final r = await ready(
        routes: {
          BaiduEndpoints.xpanMultimedia: (_) => fsidOriginal(),
          BaiduEndpoints.batchStreaming: (_) => ladderOk(),
        },
      );

      await r.adapter.resolveStream('1');

      final q = r.http.callsTo(BaiduEndpoints.batchStreaming).single.query;
      expect(q['type'], BaiduResolution.p480);
      expect(q['check_blue'], 1);
      // ⛔ 必须是 JSON 数组字符串，不是裸路径。
      expect(jsonDecode(q['path'] as String), ['/电影/a.mkv']);
    });

    test('SVIP 探 1080P', () async {
      final r = await ready(
        vipType: BaiduVipType.svip,
        routes: {
          BaiduEndpoints.xpanMultimedia: (_) => fsidOriginal(),
          BaiduEndpoints.batchStreaming: (_) => ladderOk(),
        },
      );

      await r.adapter.resolveStream('1');
      expect(
        r.http.callsTo(BaiduEndpoints.batchStreaming).single.query['type'],
        BaiduResolution.p1080,
      );
    });

    test('① 通了但没地址 ⇒ 走 ② 路径路由（JSON 数组参数，**视频带 origin=dlna**）', () async {
      final r = await ready(
        routes: {
          BaiduEndpoints.xpanMultimedia: (_) => fsidNoDlink(),
          BaiduEndpoints.filemetas: (_) => ok({
                'errno': 0,
                'info': [
                  {
                    'fs_id': 1,
                    'path': '/电影/a.mkv',
                    // ⛔ `category` 决定走哪条通道 —— 服务端权威的文件类型。
                    //    1 = 视频（快通道），4 = 文档（普通通道）。
                    'category': BaiduEndpoints.categoryVideo,
                    'dlink': originalUrl,
                  },
                ],
              }),
          BaiduEndpoints.batchStreaming: (_) => ladderOk(),
        },
      );

      final ticket = await r.adapter.resolveStream('1');
      expect(ticket.url.toString(), originalUrl);

      final calls = r.http.callsTo(BaiduEndpoints.filemetas);
      expect(calls, hasLength(1),
          reason: '视频一次就够 —— 播放走这条路，起播延迟敏感');
      final q = calls.single.query;
      expect(q['dlink'], 1);
      expect(q['web'], 5);
      expect(jsonDecode(q['target'] as String), ['/电影/a.mkv']);
      // ⛔ `origin=dlna` 是**唯一**能跑满带宽的通道（实测 1410 KB/s vs
      //    83 KB/s），但它只服务**媒体**（视频 + 音频）—— 所以媒体才带。
      expect(q['origin'], BaiduEndpoints.dlnaOrigin,
          reason: '视频必须带 origin=dlna，否则播放只有 ~80 KB/s');
      expect(ticket.maxConnections, isNull,
          reason: 'dlna 通道每条连接各自限速，交给下载服务默认值即可');
    });

    test('音频（category=2）**也走** dlna 快通道 —— 一次请求，不重取', () async {
      // 2026-10-09 当晚补测：`category=2` 带 `origin=dlna` 拿到的直链
      // 实测 **1024 KB/s**，不带 origin 只有 84 KB/s。
      // 所以快通道不是「只服务视频」，而是「只服务**媒体**」。
      final r = await ready(
        routes: {
          BaiduEndpoints.xpanMultimedia: (_) => fsidNoDlink(),
          BaiduEndpoints.filemetas: (_) => ok({
                'errno': 0,
                'info': [
                  {
                    'fs_id': 1,
                    'path': '/音乐/a.mp3',
                    'category': BaiduEndpoints.categoryAudio,
                    'dlink': originalUrl,
                  },
                ],
              }),
          BaiduEndpoints.batchStreaming: (_) => ladderOk(),
        },
      );

      final ticket = await r.adapter.resolveStream('1');

      expect(ticket.url.toString(), originalUrl);
      final calls = r.http.callsTo(BaiduEndpoints.filemetas);
      expect(calls, hasLength(1),
          reason: '音频与视频一样，一次往返就该拿到地址');
      expect(calls.single.query['origin'], BaiduEndpoints.dlnaOrigin);
      expect(ticket.maxConnections, isNull,
          reason: '快通道不限并发；钉成 1 会把音频也拖慢');
    });

    test('⛔ 非媒体：dlna 直链会被 CDN 拒 ⇒ 重取一次（去掉 origin）并钉死单连接', () async {
      // 2026-10-09 实测：拿 `origin=dlna` 的直链去取 PDF，CDN 回
      // `403 31329 hit black userlist , hit illeage dlna`（与账号无关）。
      // 去掉 origin 之后文档能下，但那条通道被**按账号**限速到 ~80 KB/s，
      // 而且多开连接只会把每条都拖到读超时 ⇒ 必须单连接。
      var seen = 0;
      final r = await ready(
        routes: {
          BaiduEndpoints.xpanMultimedia: (_) => fsidNoDlink(),
          BaiduEndpoints.filemetas: (_) {
            seen++;
            return ok({
              'errno': 0,
              'info': [
                {
                  'fs_id': 1,
                  'path': '/资料/a.pdf',
                  'category': BaiduEndpoints.categoryDocument,
                  'dlink': seen == 1 ? '$originalUrl&vuk=1' : originalUrl,
                },
              ],
            });
          },
          BaiduEndpoints.batchStreaming: (_) => ladderOk(),
        },
      );

      final ticket = await r.adapter.resolveStream('1');

      expect(ticket.url.toString(), originalUrl,
          reason: '必须用第二次（无 origin）取回来的那条直链');
      final calls = r.http.callsTo(BaiduEndpoints.filemetas);
      expect(calls, hasLength(2));
      expect(calls.first.query['origin'], BaiduEndpoints.dlnaOrigin,
          reason: '第一取按快通道取 —— 类型只有拿到响应才知道');
      expect(calls.last.query.containsKey('origin'), isFalse,
          reason: '第二取必须去掉 origin，否则文档拿不到能下的直链');
      expect(ticket.maxConnections, 1,
          reason: '普通通道限速按账号算，开多条连接只会让每条都读超时、'
              '最后被服务端掐断 —— 那正是「下载卡在 0%」的原因');
    });

    /// ② 路由能出直链、③ 也能用的标准布置。
    Future<({BaiduAdapter adapter, FakeHttp http, FakeStore store})>
        crackRoute() => ready(
              routes: {
                BaiduEndpoints.xpanMultimedia: (_) => fsidNoDlink(),
                BaiduEndpoints.filemetas: (_) => ok({
                      'errno': 0,
                      'info': [
                        {
                          'fs_id': 1,
                          'path': '/电影/a.mkv',
                          'category': BaiduEndpoints.categoryVideo,
                          'dlink': originalUrl,
                        },
                      ],
                    }),
                BaiduEndpoints.batchStreaming: (_) => ladderOk(),
              },
            );

    test('⛔ crack 直链的请求头 = UA netdisk + **Cookie**（不带 Referer）', () async {
      // 2026-10-09 三轮实测的形状：
      //   - **视频**取链带 `origin=dlna`（快通道，直链自带 `vuk`）；
      //   - 非视频取链**不带 `origin`**（普通通道，直链没有 `vuk`）；
      //   - 两条通道的直链都带 `Cookie` 最省心：有 `vuk` 时它无害，
      //     没 `vuk` 时它是**唯一**的身份来源（只带 UA → `403 31045
      //     user not exists`）；
      //   - dlna 直链第二跳 `*.baidupcs.com` 的 `sign` **按 UA 签**，
      //     所以 UA 必须是 `netdisk`（见 `applyTicketHeaders`）。
      final r = await crackRoute();

      final ticket = await r.adapter.resolveStream('1');

      expect(ticket.headers['User-Agent'], 'netdisk',
          reason: 'dlna 直链第二跳按 UA 签签名，换了就 403 31362 sign error');
      expect(ticket.headers['Cookie'], isNotEmpty,
          reason: '无 vuk 的直链靠 Cookie 认领用户，缺了就 403 31045');
      expect(ticket.headers.containsKey('Referer'), isFalse,
          reason: 'Referer 不是必需项，保持最小形状');
    });

    test('① 与 ② 都没地址、③ 成功 ⇒ 仍返回票据（只有转码档可选）', () async {
      final r = await ready(
        routes: {
          BaiduEndpoints.xpanMultimedia: (_) => fsidNoDlink(),
          BaiduEndpoints.filemetas: (_) => ok({'errno': 0, 'info': []}),
          BaiduEndpoints.batchStreaming: (_) => ladderOk(),
        },
      );

      final ticket = await r.adapter.resolveStream('1');

      expect(ticket.url.toString(), ladderUrl);
      expect(ticket.qualities, hasLength(1));
      expect(
        ticket.qualities.single.id,
        BaiduResolution.idFor(BaiduResolution.p480),
      );
      expect(ticket.qualities.single.isOriginal, isFalse);
    });

    test('三条全失败 ⇒ 抛错，且**不返回假票据**', () async {
      final r = await ready(
        routes: {
          BaiduEndpoints.xpanMultimedia: (_) => fsidNoDlink(),
          BaiduEndpoints.filemetas: (_) => ok({'errno': 0, 'info': []}),
          BaiduEndpoints.batchStreaming: (_) => ok({'errno': 0, 'list': []}),
        },
      );

      await expectLater(
        r.adapter.resolveStream('1'),
        throwsA(
          isA<DriveException>()
              .having((e) => e.type, 'type', DriveErrorType.unknown)
              .having((e) => e.message, 'message', contains('取链失败')),
        ),
      );
    });

    test('⛔ 授权失效（-6）**立即上抛** —— 换接口结果一样，别白费配额', () async {
      final r = await ready(
        routes: {
          BaiduEndpoints.xpanMultimedia: (_) => errno(-6),
          BaiduEndpoints.filemetas: (_) => ok({'errno': 0, 'info': []}),
          BaiduEndpoints.batchStreaming: (_) => ladderOk(),
        },
      );

      await expectLater(
        r.adapter.resolveStream('1'),
        throwsA(
          isA<DriveException>()
              .having((e) => e.type, 'type', DriveErrorType.unauthorized),
        ),
      );
      expect(
        r.http.callsTo(BaiduEndpoints.filemetas),
        isEmpty,
        reason: 'needsReauth 时不该继续试下一条路由',
      );
      expect(r.http.callsTo(BaiduEndpoints.batchStreaming), isEmpty);
    });

    test('⛔ 文件不存在（-7）也立即上抛 —— 同样不值得换接口再试', () async {
      final r = await ready(
        routes: {
          BaiduEndpoints.xpanMultimedia: (_) => errno(-7, showMsg: '文件不存在'),
          BaiduEndpoints.filemetas: (_) => ok({'errno': 0, 'info': []}),
          BaiduEndpoints.batchStreaming: (_) => ladderOk(),
        },
      );

      await expectLater(
        r.adapter.resolveStream('1'),
        throwsA(
          isA<DriveException>()
              .having((e) => e.type, 'type', DriveErrorType.notFound),
        ),
      );
      expect(r.http.callsTo(BaiduEndpoints.filemetas), isEmpty);
    });

    test('指定转码档 ⇒ 换到转码档的地址', () async {
      final r = await ready(
        routes: {
          BaiduEndpoints.xpanMultimedia: (_) => fsidOriginal(),
          BaiduEndpoints.batchStreaming: (_) => ladderOk(),
        },
      );

      final ticket = await r.adapter.resolveStream(
        '1',
        qualityId: BaiduResolution.idFor(BaiduResolution.p480),
      );
      expect(ticket.url.toString(), ladderUrl);
    });

    test('指定原画 ⇒ 留在原画地址', () async {
      final r = await ready(
        routes: {
          BaiduEndpoints.xpanMultimedia: (_) => fsidOriginal(),
          BaiduEndpoints.batchStreaming: (_) => ladderOk(),
        },
      );

      final ticket =
          await r.adapter.resolveStream('1', qualityId: kOriginalQualityId);
      expect(ticket.url.toString(), originalUrl);
    });

    test('指定一个本次没有的档位 ⇒ 保留原画，**不抛错**', () async {
      final r = await ready(
        routes: {
          BaiduEndpoints.xpanMultimedia: (_) => fsidOriginal(),
          BaiduEndpoints.batchStreaming: (_) => ladderOk(),
        },
      );

      final ticket = await r.adapter.resolveStream('1', qualityId: 'baidu_5');
      expect(ticket.url.toString(), originalUrl);
    });

    test('未授权时直接抛，一条路由都不打', () async {
      final r = await ready(withSession: false);
      await expectLater(
        r.adapter.resolveStream('1'),
        throwsA(
          isA<DriveException>()
              .having((e) => e.type, 'type', DriveErrorType.unauthorized),
        ),
      );
      expect(r.http.calls, isEmpty);
    });
  });

  // -------------------------------------------------------------------
  // 搜索
  // -------------------------------------------------------------------

  group('search', () {
    test('关键词为空时直接返回空，不打搜索接口', () async {
      final r = await ready();
      expect(await r.adapter.search(keyword: '   '), isEmpty);
      expect(r.http.callsTo(BaiduEndpoints.search), isEmpty);
    });

    test('递归全盘搜（不带 recursion 只会搜到一个奇怪的子集）', () async {
      final r = await ready(
        routes: {
          BaiduEndpoints.search: (_) => ok({
                'errno': 0,
                'list': [
                  {'fs_id': 5, 'server_filename': 'a.mkv', 'isdir': 0},
                ],
              }),
        },
      );

      final entries = await r.adapter.search(keyword: '流浪');
      expect(entries, hasLength(1));
      final q = r.http.callsTo(BaiduEndpoints.search).single.query;
      expect(q['wd'], '流浪');
      expect(q['recursion'], 1);
    });
  });

  // -------------------------------------------------------------------
  // 只读边界
  // -------------------------------------------------------------------

  group('⛔ 只读边界：四个写方法必须是 unsupported', () {
    test('createFolder / deleteFiles / moveFiles / uploadFile 一律抛 unsupported',
        () async {
      final r = await ready();

      Future<void> expectUnsupported(Future<Object?> Function() call) async {
        // ⚠️ 必须 `Future.sync` 包一层：基类那四个默认实现**同步**抛
        // （它们不是 `async` 函数），直接 `call()` 会在构造 Future 之前就抛，
        // `expectLater` 拿不到 Future，测试会以「抛出了未捕获异常」失败 ——
        // 看起来像「适配器不支持」这件事本身错了。
        await expectLater(
          Future.sync(call),
          throwsA(
            isA<DriveException>()
                .having((e) => e.type, 'type', DriveErrorType.unsupported),
          ),
        );
      }

      await expectUnsupported(
        () => r.adapter.createFolder(parentId: '/', name: '云影备份'),
      );
      await expectUnsupported(() => r.adapter.deleteFiles(fileIds: ['1']));
      await expectUnsupported(
        () => r.adapter.moveFiles(fileIds: ['1'], targetFolderId: '/'),
      );
      await expectUnsupported(
        () => r.adapter.uploadFile(
          parentId: '/',
          fileName: 'a.txt',
          bytes: const [1, 2, 3],
        ),
      );
    });

    test('能力声明如实：可遍历 / 可取链 / 直链需要请求头', () async {
      final r = await ready();
      final caps = r.adapter.capabilities;

      expect(caps.canListDirectory, isTrue);
      expect(caps.canResolveDirectLink, isTrue);
      expect(caps.directLinkNeedsHeaders, isTrue);
      expect(caps.authModes, contains(AuthMode.qrCode));
      // ⛔ 不声明体积上限：声明一个猜的上限会让大批能播的文件被误判成不可播。
      expect(caps.hasFileSizeLimit, isFalse);
    });

    test('ownsUrl 按 baidu.com 后缀判（缩略图主机有好几个）', () async {
      final r = await ready();
      expect(r.adapter.ownsUrl('https://thumbnail.baidu.com/a.jpg'), isTrue);
      expect(r.adapter.ownsUrl('https://d.pcs.baidu.com/a.jpg'), isTrue);
      expect(r.adapter.ownsUrl('https://pan.baidu.com/a.jpg'), isTrue);
      expect(r.adapter.ownsUrl('https://image.tmdb.org/a.jpg'), isFalse);
    });

    test('根目录 id 是路径 `/`，不是夸克那种 `0`', () async {
      final r = await ready();
      expect(r.adapter.rootId, '/');
    });
  });

  // -------------------------------------------------------------------
  // bdstoken：客户端登录链第 7 步，网盘 `/api/*` 的会话令牌
  // -------------------------------------------------------------------

  group('bdstoken（客户端登录链第 7 步）', () {
    /// `gettemplatevariable` 的正常应答。
    Map<String, HttpResult Function(Map<String, Object?> q)> tokenRoutes() => {
          BaiduEndpoints.gettemplatevariable: (_) => ok({
                'errno': 0,
                'result': {'bdstoken': 'BDSTOKEN-1', 'uk': 42},
              }),
        };

    /// `uinfo` **只在带了 `bdstoken`** 时才成功 —— 复刻实测的 `-6` 语义。
    Map<String, HttpResult Function(Map<String, Object?> q)> uinfoNeedsToken() =>
        {
          BaiduEndpoints.accountUinfo: (q) => q['bdstoken'] == null
              ? errno(-6)
              : ok({
                  'errno': 0,
                  'data': {'netdisk_name': '测试号', 'uk': 42},
                }),
        };

    test('⛔ 缺 bdstoken 拿到 -6 ⇒ 补令牌后**重试一次**，登录最终成功', () async {
      final r = await ready(routes: {...uinfoNeedsToken(), ...tokenRoutes()});

      expect(
        r.adapter.currentAccount,
        isNotNull,
        reason: '-6 的成因之一是「缺 bdstoken」，而那是**可以自愈**的；'
            '不自愈就等于把一个能登进去的账号报成「登录状态无效」',
      );

      final uinfoCalls = r.http.callsTo(BaiduEndpoints.accountUinfo);
      expect(uinfoCalls, hasLength(2), reason: '第一次 -6、补令牌后重试一次');
      expect(
        uinfoCalls.first.query.containsKey('bdstoken'),
        isFalse,
        reason: '第一次还不知道令牌，只能不带',
      );
      expect(uinfoCalls.last.query['bdstoken'], 'BDSTOKEN-1');
    });

    test('⛔ 取 bdstoken 的那次请求**自己不带** bdstoken（否则必然是空的）',
        () async {
      final r = await ready(routes: {...uinfoNeedsToken(), ...tokenRoutes()});

      final tokenCalls = r.http.callsTo(BaiduEndpoints.gettemplatevariable);
      expect(tokenCalls, hasLength(1));
      expect(tokenCalls.single.query.containsKey('bdstoken'), isFalse);
      expect(
        tokenCalls.single.query['fields'],
        contains('bdstoken'),
        reason: '客户端就是靠 fields 指定要哪些模板变量',
      );
    });

    test('⛔ 取到一次就缓存：后续接口都带上它，且不再重复取', () async {
      final r = await ready(routes: {
        ...uinfoNeedsToken(),
        ...tokenRoutes(),
        BaiduEndpoints.list: (q) => q['bdstoken'] == null
            ? errno(-6)
            : ok({'errno': 0, 'list': const []}),
      });

      await r.adapter.listDirectory(dirId: '/');

      final listCalls = r.http.callsTo(BaiduEndpoints.list);
      expect(listCalls, hasLength(1));
      expect(listCalls.single.query['bdstoken'], 'BDSTOKEN-1');
      expect(
        r.http.callsTo(BaiduEndpoints.gettemplatevariable),
        hasLength(1),
        reason: '每次请求都重取一遍令牌是纯浪费，而且会成倍放大限流压力',
      );
    });

    test('⛔ 两条来源都取不到 ⇒ 不无限重试，如实上抛 -6', () async {
      final r = await ready(
        restore: false,
        routes: {
          BaiduEndpoints.accountUinfo: (_) => errno(-6),
          BaiduEndpoints.gettemplatevariable: (_) => errno(-6),
          BaiduEndpoints.getTemplate: (_) => errno(-6),
        },
      );

      await expectLater(
        r.adapter.restoreSession(),
        throwsA(isA<DriveException>()),
      );

      expect(
        r.http.callsTo(BaiduEndpoints.accountUinfo),
        hasLength(1),
        reason: '补令牌失败 ⇒ 不重试，否则会把一次失败放大成三次请求',
      );
      expect(r.http.callsTo(BaiduEndpoints.gettemplatevariable), hasLength(1));
      expect(
        r.http.callsTo(BaiduEndpoints.getTemplate),
        hasLength(1),
        reason: '两条来源各试一次就够 —— 客户端也是「先 A 后 B」的兜底顺序',
      );
    });
  });
}
