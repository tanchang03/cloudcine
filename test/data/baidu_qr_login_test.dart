import 'dart:convert';
import 'dart:typed_data';

import 'package:cloudcine/core/utils/redact.dart';
import 'package:cloudcine/data/auth/baidu_qr_driver.dart';
import 'package:cloudcine/data/auth/baidu_qr_login.dart';
import 'package:cloudcine/data/auth/quark_qr_driver.dart';
import 'package:cloudcine/data/auth/quark_qr_login.dart';
import 'package:cloudcine/data/http/http_client.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/services/qr_login_driver.dart';
import 'package:flutter_test/flutter_test.dart';

/// 扫码登录：百度的三跳客户端 + 两家共用的驱动层。
///
/// ## 这一组测试守什么
///
/// 1. **`channel_v` 是被二次编码的 JSON 字符串**，不是对象。当成 Map 用会
///    拿不到任何字段，现象是「扫码确认了但页面一直转圈」（`status` 永远
///    `null`）—— 而**不报任何错**。
/// 2. **长轮询超时不是失败**。`/channel/unicast` 无事件时会挂约 30 秒，
///    HTTP 层超时走 `isNetworkFailure`。映射成「失败」会让页面的
///    「连续失败 3 次就报错」在用户还没掏出手机时就触发 ——
///    而百度取码是**有次数限制**的（`errno=50000`）。
/// 3. **驱动层把两家的形态差异吃掉**。二维码是文本还是图片、有没有
///    「已扫待确认」这一态，都必须在驱动里归一化，页面里不许出现
///    `if (provider == baidu)`。
/// 按**路径**路由的假 HTTP 客户端（扫码链路的端点靠路径区分）。
class FakeHttp implements HttpClientLike {
  FakeHttp(this.routes);

  /// 路径 → 响应。
  final Map<String, HttpResult Function(Map<String, Object?> query)> routes;

  /// `getBytes` 的返回值（二维码图片）。
  Uint8List? imageBytes;

  final List<String> paths = [];

  /// 每次请求用的 HTTP 方法（与 [paths] 一一对应）。
  ///
  /// 换票的两条分支**方法不同**（主线 `GET`、风控 `POST`），只断言路径
  /// 看不出这件事 —— 而早先的 bug 正是「拿风控分支的形状去当主线」。
  final List<String> methods = [];

  /// 每次 `get` 收到的请求头（按调用顺序）。
  ///
  /// 用来守「三跳之间要把 `BAIDUID` 带回去」这条 —— 只断言 `paths`
  /// 看不出请求头，而这条一旦漏了，现象是「扫码成功但网盘接口回 -6」，
  /// 光靠端点是查不出来的。
  final List<Map<String, String>> headerCalls = [];

  @override
  Future<HttpResult> get(
    String url, {
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
    bool followRedirects = true,
  }) async {
    final path = Uri.parse(url).path;
    paths.add(path);
    methods.add('GET');
    headerCalls.add(headers ?? const {});
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
  }) async {
    final path = Uri.parse(url).path;
    paths.add(path);
    methods.add('POST');
    headerCalls.add(headers ?? const {});
    final handler = routes[path];
    if (handler == null) {
      return const HttpResult(statusCode: 404, rawBody: '');
    }
    return handler(query ?? const {});
  }

  @override
  Future<Uint8List?> getBytes(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async =>
      imageBytes;

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

void main() {
  // -------------------------------------------------------------------
  // 公共小工具
  // -------------------------------------------------------------------

  /// 一个 200 + JSON 响应。
  ///
  /// ⚠️ **必须同时给 `rawBody`**。扫码链路的响应体是 **JSONP**
  /// （`cb({...})`），客户端解析的是 `rawBody` 而不是 `json` ——
  /// 因为 `cb(...)` 不是合法 JSON，真客户端根本解析不出 `json`。
  /// 只给 `json` 的假客户端与真实响应形状不一致，会让整组测试以
  /// 「认证服务返回了无法解析的内容」全红，而那是**夹具的错**，
  /// 不是被测代码的错。
  HttpResult ok(Map<String, Object?> body) =>
      HttpResult(statusCode: 200, json: body, rawBody: jsonEncode(body));

  /// 带 `Set-Cookie` 的响应。
  HttpResult withCookies(
    List<String> setCookie, {
    Map<String, Object?>? body,
  }) =>
      HttpResult(
        statusCode: 200,
        json: body,
        rawBody: body == null ? '' : jsonEncode(body),
        headers: {'set-cookie': setCookie},
      );

  /// 造一个百度扫码客户端。
  ///
  /// `gidFactory` 固定成一个常量：`gid` 参与三跳，不确定的话断言没法写。
  BaiduQrLoginClient baiduClient(
    HttpClientLike http, {
    String gid = 'GID00000000000000000000000000000',
  }) =>
      BaiduQrLoginClient(
        http: http,
        gidFactory: () => gid,
        clock: () => DateTime(2026, 10, 8, 12),
      );

  const qrPath = '/v2/api/getqrcode';
  const unicastPath = '/channel/unicast';
  /// 换票**主线**：客户端真正在用的那条（`GET`，**不带** `loginVersion`）。
  const mainlinePath = '/v2/api/bdusslogin';

  /// 换票**风控分支**：只在主线拿不到凭证时兜底（`POST` + `loginVersion=v4`）。
  const riskPath = '/v3/login/main/qrbdusslogin';

  /// 客户端登录链第 5 步：换 netdisk 专用 `STOKEN`。
  const stokenPath = '/v3/login/api/auth';

  /// 一个正常的取码响应。
  ///
  /// `imgurl` 缺 scheme，**实测以仅 host 相对**（`passport.baidu.com/…`，
  /// 没前导 `//`）为主；`qrOk` 用这个形态。`qrOkProtocolRelative` 覆盖
  /// 备选的协议相对形态（`//passport.baidu.com/…`），保证两种都补成
  /// `https://`。
  HttpResult qrOk({String sign = 'SIGN-ABCDEFGH'}) => ok({
        'errno': 0,
        'sign': sign,
        'imgurl': 'passport.baidu.com/v2/api/qrcode?sign=$sign',
      });

  HttpResult qrOkProtocolRelative({String sign = 'SIGN-ABCDEFGH'}) => ok({
        'errno': 0,
        'sign': sign,
        'imgurl': '//passport.baidu.com/v2/api/qrcode?sign=$sign',
      });

  // -------------------------------------------------------------------
  // 第 1 跳：取二维码
  // -------------------------------------------------------------------

  group('第 1 跳 getqrcode', () {
    test('取到 sign 与 imgurl，host 相对地址补成 https（实测主形态）',
        () async {
      final http = FakeHttp({qrPath: (_) => qrOk()});
      final session = await baiduClient(http).start();

      expect(session.sign, 'SIGN-ABCDEFGH');
      expect(session.imgUrl.scheme, 'https',
          reason: 'imgurl 实测不带 scheme —— 不补会拿到没 host 的 URI，'
              'getBytes 直接失败，页面就一直显示「二维码加载失败」');
      expect(session.imgUrl.host, 'passport.baidu.com');
      // ⛔ 三跳必须用同一个 gid，服务端靠它认出「这是同一次登录」。
      expect(session.gid, 'GID00000000000000000000000000000');
    });

    test('imgurl 是协议相对（//host）时也补成 https', () async {
      // 保留对历史形态的兜底：万一哪天服务端改回带 `//`，也别漏。
      final http = FakeHttp({qrPath: (_) => qrOkProtocolRelative()});
      final session = await baiduClient(http).start();

      expect(session.imgUrl.scheme, 'https');
      expect(session.imgUrl.host, 'passport.baidu.com');
    });

    test('errno=50000 单独给「过于频繁」文案（客户端有 5e4 特判）', () async {
      final http = FakeHttp({
        qrPath: (_) => ok({'errno': 50000}),
      });
      await expectLater(
        baiduClient(http).start(),
        throwsA(
          isA<BaiduQrLoginException>()
              .having((e) => e.message, 'message', contains('过于频繁')),
        ),
      );
    });

    test('其它 errno 如实报出来', () async {
      final http = FakeHttp({
        qrPath: (_) => ok({'errno': 3}),
      });
      await expectLater(
        baiduClient(http).start(),
        throwsA(
          isA<BaiduQrLoginException>()
              .having((e) => e.message, 'message', contains('errno=3')),
        ),
      );
    });

    test('缺 sign / imgurl 时抛，而不是拿空值往下走', () async {
      final noSign = FakeHttp({
        qrPath: (_) => ok({'errno': 0, 'imgurl': '//x/y'}),
      });
      await expectLater(
        baiduClient(noSign).start(),
        throwsA(isA<BaiduQrLoginException>()),
      );

      final noImg = FakeHttp({
        qrPath: (_) => ok({'errno': 0, 'sign': 'S'}),
      });
      await expectLater(
        baiduClient(noImg).start(),
        throwsA(isA<BaiduQrLoginException>()),
      );
    });

    test('网络层失败 / HTTP 500 / 非 JSON 都抛', () async {
      final netFail = FakeHttp({
        qrPath: (_) => const HttpResult.networkFailure('timeout'),
      });
      await expectLater(
        baiduClient(netFail).start(),
        throwsA(isA<BaiduQrLoginException>()),
      );

      final http500 = FakeHttp({
        qrPath: (_) => const HttpResult(statusCode: 500, rawBody: ''),
      });
      await expectLater(
        baiduClient(http500).start(),
        throwsA(isA<BaiduQrLoginException>()),
      );

      final garbage = FakeHttp({
        qrPath: (_) => const HttpResult(statusCode: 200, rawBody: '<html>'),
      });
      await expectLater(
        baiduClient(garbage).start(),
        throwsA(isA<BaiduQrLoginException>()),
      );
    });

    test('jsonp 外壳也能解析（取第一个 ( 与最后一个 )）', () async {
      final http = FakeHttp({
        qrPath: (_) => const HttpResult(
          statusCode: 200,
          rawBody: 'cb({"errno":0,"sign":"S1","imgurl":"//x/y"})',
        ),
      });
      final session = await baiduClient(http).start();
      expect(session.sign, 'S1');
    });
  });

  // -------------------------------------------------------------------
  // 第 2 跳：长轮询
  // -------------------------------------------------------------------

  group('第 2 跳 unicast 长轮询', () {
    /// 造一个已取到码的客户端。
    Future<(BaiduQrLoginClient, FakeHttp)> started(
      Map<String, HttpResult Function(Map<String, Object?> query)> routes,
    ) async {
      final http = FakeHttp({qrPath: (_) => qrOk(), ...routes});
      final client = baiduClient(http);
      await client.start();
      return (client, http);
    }

    test('⛔ 网络层超时 = 「暂时没有事件」，**不是失败**', () async {
      final (client, _) = await started({
        unicastPath: (_) => const HttpResult.networkFailure('timeout'),
      });
      final session = BaiduQrSession(
        sign: 'S',
        imgUrl: Uri.parse('https://x/y'),
        gid: 'g',
        createdAt: DateTime(2026, 10, 8),
      );
      expect(await client.poll(session), isA<BaiduQrWaiting>());
    });

    test('errno=1 且没有 channel_v = 还没扫', () async {
      final (client, _) = await started({
        unicastPath: (_) =>
            const HttpResult(statusCode: 200, rawBody: 'cb({"errno":1})'),
      });
      expect(
        await client.poll(
          BaiduQrSession(
            sign: 'S',
            imgUrl: Uri.parse('https://x/y'),
            gid: 'g',
            createdAt: DateTime(2026, 10, 8),
          ),
        ),
        isA<BaiduQrWaiting>(),
      );
    });

    test('⛔ channel_v 是**字符串**：status=1 ⇒ 已扫待确认', () async {
      final (client, _) = await started({
        unicastPath: (_) => ok({
              'errno': 0,
              'channel_v': jsonEncode({'status': '1'}),
            }),
      });
      final outcome = await client.poll(
        BaiduQrSession(
          sign: 'S',
          imgUrl: Uri.parse('https://x/y'),
          gid: 'g',
          createdAt: DateTime(2026, 10, 8),
        ),
      );
      expect(outcome, isA<BaiduQrScanned>());
    });

    test('status=0 ⇒ 已确认，带出 v 与**已解码**的 u', () async {
      final (client, _) = await started({
        unicastPath: (_) => ok({
              'errno': 0,
              // 服务端把 u 二次编码过（客户端会 decode 一次）。
              'channel_v': jsonEncode({
                'status': '0',
                'v': 'V-VALUE',
                'u': Uri.encodeComponent('https://pan.baidu.com/'),
              }),
            }),
      });

      final outcome = await client.poll(
        BaiduQrSession(
          sign: 'S',
          imgUrl: Uri.parse('https://x/y'),
          gid: 'g',
          createdAt: DateTime(2026, 10, 8),
        ),
      );

      expect(outcome, isA<BaiduQrConfirmed>());
      final confirmed = outcome as BaiduQrConfirmed;
      expect(confirmed.v, 'V-VALUE');
      expect(confirmed.u, 'https://pan.baidu.com/');
    });

    test('status=2 ⇒ 用户在手机上取消了', () async {
      final (client, _) = await started({
        unicastPath: (_) => ok({
              'errno': 0,
              'channel_v': jsonEncode({'status': '2'}),
            }),
      });
      expect(
        await client.poll(
          BaiduQrSession(
            sign: 'S',
            imgUrl: Uri.parse('https://x/y'),
            gid: 'g',
            createdAt: DateTime(2026, 10, 8),
          ),
        ),
        isA<BaiduQrCancelled>(),
      );
    });

    test('已确认但缺 v ⇒ 如实报错，别硬着头皮往下走', () async {
      final (client, _) = await started({
        unicastPath: (_) => ok({
              'errno': 0,
              'channel_v': jsonEncode({'status': '0'}),
            }),
      });
      expect(
        await client.poll(
          BaiduQrSession(
            sign: 'S',
            imgUrl: Uri.parse('https://x/y'),
            gid: 'g',
            createdAt: DateTime(2026, 10, 8),
          ),
        ),
        isA<BaiduQrError>(),
      );
    });

    test('channel_v 已经是对象（未来改版）也能认', () async {
      final (client, _) = await started({
        unicastPath: (_) => ok({
              'errno': 0,
              'channel_v': {'status': '1'},
            }),
      });
      expect(
        await client.poll(
          BaiduQrSession(
            sign: 'S',
            imgUrl: Uri.parse('https://x/y'),
            gid: 'g',
            createdAt: DateTime(2026, 10, 8),
          ),
        ),
        isA<BaiduQrScanned>(),
      );
    });

    test('没见过的 status ⇒ 当作「还没事件」，不报错', () async {
      final (client, _) = await started({
        unicastPath: (_) => ok({
              'errno': 0,
              'channel_v': jsonEncode({'status': '9'}),
            }),
      });
      expect(
        await client.poll(
          BaiduQrSession(
            sign: 'S',
            imgUrl: Uri.parse('https://x/y'),
            gid: 'g',
            createdAt: DateTime(2026, 10, 8),
          ),
        ),
        isA<BaiduQrWaiting>(),
      );
    });

    test('HTTP 500 与非 JSON ⇒ BaiduQrError（可重试）', () async {
      final (c1, _) = await started({
        unicastPath: (_) => const HttpResult(statusCode: 500, rawBody: ''),
      });
      final session = BaiduQrSession(
        sign: 'S',
        imgUrl: Uri.parse('https://x/y'),
        gid: 'g',
        createdAt: DateTime(2026, 10, 8),
      );
      expect(await c1.poll(session), isA<BaiduQrError>());

      final (c2, _) = await started({
        unicastPath: (_) => const HttpResult(statusCode: 200, rawBody: 'oops'),
      });
      expect(await c2.poll(session), isA<BaiduQrError>());
    });

    test('轮询带齐客户端要求的参数（tpl=netdisk 填错会按别的业务线签发）', () async {
      var seen = <String, Object?>{};
      final http = FakeHttp({
        qrPath: (_) => qrOk(),
        unicastPath: (q) {
          seen = q;
          return const HttpResult(statusCode: 200, rawBody: 'cb({"errno":1})');
        },
      });
      final client = baiduClient(http, gid: 'GID-X');
      final session = await client.start();
      await client.poll(session);

      expect(seen['channel_id'], session.sign);
      expect(seen['gid'], 'GID-X');
      expect(seen['tpl'], 'netdisk');
      expect(seen['apiver'], 'v3');
      expect(seen['callback'], 'cb');
    });
  });

  // -------------------------------------------------------------------
  // 第 3 跳：换 BDUSS
  // -------------------------------------------------------------------

  group('第 3 跳 换 BDUSS（主线 /v2/api/bdusslogin 优先）', () {
    const confirmed = BaiduQrConfirmed(v: 'V-VALUE', u: 'https://pan.baidu.com/');

    BaiduQrLoginClient client(HttpClientLike http) => baiduClient(http);

    test('主线成功：判据是**顶层** errno == 0，凭证在 Set-Cookie 里', () async {
      final http = FakeHttp({
        mainlinePath: (_) => withCookies(
              ['BDUSS=BDUSS-VALUE; Path=/; Domain=.baidu.com'],
              body: {'errno': 0},
            ),
      });

      final result = await client(http).exchange(confirmed);
      expect(result.cookies['BDUSS'], 'BDUSS-VALUE');
      expect(result.hasEssential, isTrue);
    });

    test('errInfo.no == 0 / data.errno == 0 也算成功（客户端源码三个都认）',
        () async {
      final byErrInfo = FakeHttp({
        mainlinePath: (_) => withCookies(
              ['BDUSS=B1; Path=/'],
              body: {
                'errInfo': {'no': 0},
              },
            ),
      });
      expect(
        (await client(byErrInfo).exchange(confirmed)).cookies['BDUSS'],
        'B1',
      );

      final byData = FakeHttp({
        mainlinePath: (_) => withCookies(
              ['BDUSS=B2; Path=/'],
              body: {
                'data': {'errno': 0},
              },
            ),
      });
      expect((await client(byData).exchange(confirmed)).cookies['BDUSS'], 'B2');
    });

    test('⛔ 不跟重定向 —— 3xx 的 Set-Cookie 跟丢就没了', () async {
      // 记**每一次** `get` 的重定向设置：换票之后还会打一次 netdisk
      // STOKEN（那一次不需要禁重定向），只看最后一次会测错对象。
      final follows = <bool>[];
      final http = FakeHttp({
        mainlinePath: (_) => withCookies(
              ['BDUSS=B3; Path=/'],
              body: {'errno': 0},
            ),
      });
      // 用一个能记录 followRedirects 的薄包装。
      final recording = _RecordingHttp(http, follows.add);
      await client(recording).exchange(confirmed);
      expect(
        follows.first,
        isFalse,
        reason: '换票那一跳（第一次请求）必须禁重定向 —— 凭证在 Set-Cookie 里',
      );
    });

    test('⛔ 主线请求带 tpl=netdisk / bduss / u / qrcode，且**不带 loginVersion**',
        () async {
      var seen = <String, Object?>{};
      final http = FakeHttp({
        mainlinePath: (q) {
          seen = q;
          return withCookies(['BDUSS=B; Path=/'], body: {'errno': 0});
        },
      });

      await client(http).exchange(confirmed);

      expect(seen['bduss'], 'V-VALUE');
      expect(seen['u'], 'https://pan.baidu.com/');
      expect(seen['tpl'], 'netdisk');
      expect(seen['qrcode'], '1');
      expect(
        seen.containsKey('loginVersion'),
        isFalse,
        reason: 'loginVersion 属于另外两条分支（风控 v4 / 小程序 v5）。'
            '早先给主线送 v5 就是「拿错分支的形状」—— 服务端照样回 200 '
            '并发 Cookie，但签发的会话网盘侧不认，现象是紧接着 '
            '/api/account/uinfo 回 -6',
      );
    });

    test('⛔ 主线是 GET，风控分支才是 POST', () async {
      final http = FakeHttp({
        mainlinePath: (_) =>
            withCookies(['BDUSS=B; Path=/'], body: {'errno': 0}),
      });
      await client(http).exchange(confirmed);
      expect(http.methods.first, 'GET');
    });

    test('主线没下发 BDUSS ⇒ 降级走风控分支（POST + loginVersion=v4）', () async {
      final http = FakeHttp({
        mainlinePath: (_) =>
            withCookies(['SOMETHING=else'], body: {'errno': 0}),
        riskPath: (_) => withCookies(
              ['BDUSS=FROM-RISK; Path=/'],
              body: {
                'errInfo': {'no': 0},
              },
            ),
      });

      final result = await client(http).exchange(confirmed);
      expect(result.cookies['BDUSS'], 'FROM-RISK');
      expect(http.paths, contains(riskPath));
      expect(http.methods[1], 'POST');
    });

    test('两条都拿不到 ⇒ 抛「换取登录凭证失败」', () async {
      final http = FakeHttp({
        mainlinePath: (_) => ok({'errno': 1}),
        riskPath: (_) => ok({'errInfo': {'no': 1}}),
      });

      await expectLater(
        client(http).exchange(confirmed),
        throwsA(
          isA<BaiduQrLoginException>()
              .having((e) => e.message, 'message', contains('换取登录凭证失败')),
        ),
      );
    });

    test('风控（400023）单独给「去 App 确认」的文案，不做自动降级', () async {
      final http = FakeHttp({
        mainlinePath: (_) => ok({'errno': 400023}),
        riskPath: (_) => ok({'errInfo': {'no': 0}}),
      });

      await expectLater(
        client(http).exchange(confirmed),
        throwsA(
          isA<BaiduQrLoginException>()
              .having((e) => e.message, 'message', contains('安全验证')),
        ),
      );
      expect(
        http.paths,
        isNot(contains(riskPath)),
        reason: '风控不是「换条路由就好」，降级只会掩盖真实错误',
      );
    });

    test('⛔ channel_v.u 为空时退回 https://pan.baidu.com/（别送空串）', () async {
      var seen = <String, Object?>{};
      final http = FakeHttp({
        mainlinePath: (q) {
          seen = q;
          return withCookies(['BDUSS=B; Path=/'], body: {'errno': 0});
        },
      });

      await client(http).exchange(const BaiduQrConfirmed(v: 'V-VALUE', u: ''));

      expect(
        seen['u'],
        'https://pan.baidu.com/',
        reason: '空落点会让服务端按「无落点」签发，可能拿到网盘用不了的凭证',
      );
    });
  });

  // -------------------------------------------------------------------
  // 客户端登录链第 5 步：换 netdisk 专用 STOKEN
  // -------------------------------------------------------------------

  group('netdisk STOKEN（客户端第 5 步）', () {
    const confirmed = BaiduQrConfirmed(v: 'V', u: 'U');

    /// 主线换票成功 + 下发一个「换票版」STOKEN。
    Map<String, HttpResult Function(Map<String, Object?> q)> base(
      Map<String, HttpResult Function(Map<String, Object?> q)> extra,
    ) =>
        {
          mainlinePath: (_) => withCookies(
                ['BDUSS=B; Path=/', 'STOKEN=FROM-LOGIN; Path=/'],
                body: {'errno': 0},
              ),
          ...extra,
        };

    test('换到 netdisk 条目 ⇒ 覆盖换票下发的 STOKEN', () async {
      final http = FakeHttp(base({
        stokenPath: (_) => ok({
              'errno': 0,
              'data': {
                'stoken_list': {'netdisk': 'NETDISK-TOKEN'},
              },
            }),
      }));

      final result = await baiduClient(http).exchange(confirmed);
      expect(result.cookies['STOKEN'], 'NETDISK-TOKEN');
      expect(http.paths, contains(stokenPath));
    });

    test('⛔ 只有别的业务线 ⇒ 不覆盖（别把能用的值换掉）', () async {
      final http = FakeHttp(base({
        stokenPath: (_) => ok({
              'errno': 0,
              'data': {
                'stoken_list': {'wenku': 'WENKU-TOKEN'},
              },
            }),
      }));

      final result = await baiduClient(http).exchange(confirmed);
      expect(
        result.cookies['STOKEN'],
        'FROM-LOGIN',
        reason: '只认明确写着 netdisk 的条目；把别的业务线的值当 netdisk 用，'
            '等于用一个不能用的值换掉能用的值',
      );
    });

    test('换取失败（404）不影响登录', () async {
      // 不注册 stokenPath ⇒ 假客户端回 404。
      final http = FakeHttp(base(const {}));

      final result = await baiduClient(http).exchange(confirmed);
      expect(result.cookies['BDUSS'], 'B');
      expect(result.cookies['STOKEN'], 'FROM-LOGIN');
    });
  });

  // -------------------------------------------------------------------
  // 客户端登录链第 4 步：把会话「落地」到网盘域
  // -------------------------------------------------------------------

  group('落地网盘域（客户端第 4 步）', () {
    const confirmed = BaiduQrConfirmed(v: 'V-VALUE', u: 'https://pan.baidu.com/');

    /// 换票那一跳：302 + `Set-Cookie` + `Location`。
    ///
    /// ⚠️ 用 302 而不是 200：实测 `/v2/api/bdusslogin` 回的就是 302
    /// （`u` 参数就是它的落点），而**落点那一跳才是网盘域发 Cookie 的地方**。
    HttpResult redirectTo(String location) => HttpResult(
          statusCode: 302,
          rawBody: '',
          headers: {
            'set-cookie': ['BDUSS=B-VALUE; Path=/; Domain=.baidu.com'],
            'location': [location],
          },
        );

    test('⛔ 302 的 Location 必须跟过去，并收下网盘域下发的 Cookie', () async {
      final http = FakeHttp({
        mainlinePath: (_) => redirectTo('https://pan.baidu.com/'),
        '/': (_) => withCookies(
              ['PANWEB=1; Path=/; Domain=.pan.baidu.com'],
            ),
      });

      final result = await baiduClient(http).exchange(confirmed);

      expect(
        http.paths,
        contains('/'),
        reason: '逆向客户端的 WebView 会跟着 302 落到 pan.baidu.com —— '
            '网盘域下发的会话 Cookie（域过滤表里明确列了 .pan.baidu.com）'
            '只能在这一跳拿到。我们早先不跟重定向，于是只拿到 passport 域的'
            'Cookie，网盘侧不认 ⇒ 下一步 /api/account/uinfo 回 -6',
      );
      expect(
        result.cookies['PANWEB'],
        '1',
        reason: '落地那一跳的 Set-Cookie 必须并进凭证，否则「落地」等于白走',
      );
      expect(result.cookies['BDUSS'], 'B-VALUE');
    });

    test('⛔ 落地请求要带上刚换到的凭证（否则等于匿名访问）', () async {
      final http = FakeHttp({
        mainlinePath: (_) => redirectTo('https://pan.baidu.com/'),
        '/': (_) => withCookies(const []),
      });

      await baiduClient(http).exchange(confirmed);

      final settle = http.headerCalls[http.paths.indexOf('/')];
      expect(
        settle['Cookie'],
        contains('BDUSS=B-VALUE'),
        reason: '不带凭证去访问 pan.baidu.com，服务端只会给你一个匿名会话',
      );
    });

    test('没有 Location（200）时也要走一趟 postLoginUrl 落地', () async {
      final http = FakeHttp({
        mainlinePath: (_) => withCookies(
              ['BDUSS=B-VALUE; Path=/'],
              body: {'errno': 0},
            ),
        '/': (_) => withCookies(['PANWEB=1; Path=/']),
      });

      final result = await baiduClient(http).exchange(confirmed);

      expect(http.paths, contains('/'));
      expect(result.cookies['PANWEB'], '1');
    });

    test('⛔ Location 指向百度域之外 ⇒ 不跟（凭证不能被带去外站）', () async {
      final http = FakeHttp({
        mainlinePath: (_) => redirectTo('https://evil.example.com/steal'),
        '/steal': (_) => withCookies(['PANWEB=1; Path=/']),
      });

      final result = await baiduClient(http).exchange(confirmed);

      expect(http.paths, isNot(contains('/steal')));
      expect(result.cookies.containsKey('PANWEB'), isFalse);
    });

    test('落地失败（网络层 / 404）不影响登录 —— 它是加分项不是前提', () async {
      final http = FakeHttp({
        mainlinePath: (_) => redirectTo('https://pan.baidu.com/'),
        // 不注册 `/` ⇒ 假客户端回 404。
      });

      final result = await baiduClient(http).exchange(confirmed);
      expect(result.cookies['BDUSS'], 'B-VALUE');
    });

    test('落地发生在换 netdisk STOKEN 之前（对齐客户端 4 → 5 的顺序）',
        () async {
      final http = FakeHttp({
        mainlinePath: (_) => redirectTo('https://pan.baidu.com/'),
        '/': (_) => withCookies(const []),
        stokenPath: (_) => ok({
              'errno': 0,
              'data': {
                'stoken_list': {'netdisk': 'NETDISK-TOKEN'},
              },
            }),
      });

      await baiduClient(http).exchange(confirmed);

      expect(http.paths.indexOf('/'), lessThan(http.paths.indexOf(stokenPath)));
    });
  });

  // -------------------------------------------------------------------
  // 会话连续：三跳之间带同一批 Cookie
  // -------------------------------------------------------------------

  group('会话连续（BAIDUID 跨三跳）', () {
    test('⛔ 第 2、3 跳都带上第 1 跳下发的 BAIDUID', () async {
      final http = FakeHttp({
        qrPath: (_) => withCookies(
              ['BAIDUID=ID-1; Path=/; Domain=.baidu.com'],
              body: {
                'errno': 0,
                'sign': 'S',
                'imgurl': 'passport.baidu.com/v2/api/qrcode?sign=S',
              },
            ),
        unicastPath: (_) =>
            const HttpResult(statusCode: 200, rawBody: 'cb({"errno":1})'),
        mainlinePath: (_) => withCookies(
              ['BDUSS=B; Path=/'],
              body: {
                'errInfo': {'no': 0},
              },
            ),
      });

      final c = baiduClient(http);
      final session = await c.start();
      await c.poll(session);
      await c.exchange(const BaiduQrConfirmed(v: 'V', u: 'U'));

      // [0]=getqrcode（还没有 Cookie），[1]=unicast，[2]=qrbdusslogin。
      expect(
        http.headerCalls[0].containsKey('Cookie'),
        isFalse,
        reason: '取二维码时罐里还什么都没有',
      );
      expect(http.headerCalls[1]['Cookie'], contains('BAIDUID=ID-1'));
      expect(http.headerCalls[2]['Cookie'], contains('BAIDUID=ID-1'));
    });

    test('换票返回的凭证里含第 1 跳的会话标识（不是只有本跳的 Set-Cookie）',
        () async {
      final http = FakeHttp({
        qrPath: (_) => withCookies(
              ['BAIDUID=ID-1; Path=/'],
              body: {
                'errno': 0,
                'sign': 'S',
                'imgurl': 'passport.baidu.com/v2/api/qrcode?sign=S',
              },
            ),
        mainlinePath: (_) => withCookies(
              ['BDUSS=B; Path=/'],
              body: {
                'errInfo': {'no': 0},
              },
            ),
      });

      final c = baiduClient(http);
      await c.start();
      final result = await c.exchange(const BaiduQrConfirmed(v: 'V', u: 'U'));

      expect(result.cookies['BDUSS'], 'B');
      expect(result.cookies['BAIDUID'], 'ID-1');
    });

    test('新一次 start 会清空上一轮的会话 Cookie', () async {
      // 只有**第 1 次**取码下发 `BAIDUID` —— 这样第 2 轮轮询时「罐里还有没有
      // 东西」才能证明 `start()` 有没有清罐。若每轮都下发，断言恒真、测不出。
      var qrCalls = 0;
      final http = FakeHttp({
        qrPath: (_) {
          qrCalls++;
          final body = <String, Object?>{
            'errno': 0,
            'sign': 'S$qrCalls',
            'imgurl': 'passport.baidu.com/v2/api/qrcode?sign=S$qrCalls',
          };
          return qrCalls == 1
              ? withCookies(['BAIDUID=ID-OLD; Path=/'], body: body)
              : ok(body);
        },
        unicastPath: (_) =>
            const HttpResult(statusCode: 200, rawBody: 'cb({"errno":1})'),
      });

      final c = baiduClient(http);
      await c.poll(await c.start()); // 第 1 轮：罐里有 ID-OLD
      await c.poll(await c.start()); // 第 2 轮：罐该被清空

      expect(
        http.headerCalls.last.containsKey('Cookie'),
        isFalse,
        reason: 'start() 必须重置罐，否则会把上一轮的 BAIDUID 带到新一轮',
      );
    });
  });

  // -------------------------------------------------------------------
  // Cookie 过滤
  // -------------------------------------------------------------------

  group('filterBaiduCookiesForCredential', () {
    test('只留已知名单里的项，无关 Cookie 不落库', () {
      final out = filterBaiduCookiesForCredential({
        'BDUSS': 'B',
        'STOKEN': 'S',
        'BAIDUID': 'ID',
        'H_PS_PSSID': 'noise',
        'ZFY': 'noise2',
      });

      expect(out['BDUSS'], 'B');
      expect(out['STOKEN'], 'S');
      expect(out.containsKey('H_PS_PSSID'), isFalse);
      expect(out.containsKey('ZFY'), isFalse);
    });

    test('空值不留（落一个空串进安全存储只会让人以为有凭证）', () {
      final out = filterBaiduCookiesForCredential({'BDUSS': '', 'STOKEN': 'S'});
      expect(out.containsKey('BDUSS'), isFalse);
      expect(out['STOKEN'], 'S');
    });

    test('⛔ 落地网盘域收到的 Cookie 要按名字放行（它们不在固定名单里）', () {
      final out = filterBaiduCookiesForCredential(
        {'BDUSS': 'B', 'PANWEB': '1', 'PANPSC': 'psc', 'ZFY': 'noise'},
        extraNames: const ['PANWEB', 'PANPSC'],
      );

      expect(
        out['PANWEB'],
        '1',
        reason: '网盘域下发的会话 Cookie 丢了，落地那一跳就白做了 —— '
            '现象与没做时一模一样（uinfo 依旧 -6）',
      );
      expect(out['PANPSC'], 'psc');
      expect(
        out.containsKey('ZFY'),
        isFalse,
        reason: '放行是**按名字**的，不是「整锅端」—— 无关项仍然不进安全存储',
      );
    });
  });

  group('newBaiduGid', () {
    test('32 位十六进制（客户端是 randomBytes(16).toString("hex")）', () {
      final gid = newBaiduGid();
      expect(gid, hasLength(32));
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(gid), isTrue);
    });

    test('两次调用不同（每次会话都该是新的）', () {
      expect(newBaiduGid(), isNot(newBaiduGid()));
    });
  });

  // -------------------------------------------------------------------
  // 驱动层：百度
  // -------------------------------------------------------------------

  group('BaiduQrDriver：把三跳归一成统一阶段', () {
    Future<(BaiduQrDriver, FakeHttp)> driver(
      Map<String, HttpResult Function(Map<String, Object?> query)> routes, {
      Uint8List? image,
    }) async {
      final http = FakeHttp({qrPath: (_) => qrOk(), ...routes})
        ..imageBytes = image;
      return (BaiduQrDriver(client: baiduClient(http)), http);
    }

    test('start ⇒ 图片型二维码（百度本地拼不出这张图）', () async {
      final (d, _) = await driver(const {});
      final challenge = await d.start();
      expect(challenge, isA<QrChallengeImage>());
      expect((challenge as QrChallengeImage).imageUrl.host, 'passport.baidu.com');
      expect(d.provider, DriveProvider.baidu);
    });

    test('qrImageBytes 走缓存 —— 轮询每 2 秒重建一次页面，不缓存就是每秒半次请求',
        () async {
      var fetches = 0;
      final http = _ImageHttp((_) {
        fetches++;
        return Uint8List.fromList(const [1, 2, 3]);
      });
      final d = BaiduQrDriver(client: baiduClient(http));
      await d.start();

      await d.qrImageBytes();
      await d.qrImageBytes();
      await d.qrImageBytes();
      expect(fetches, 1);
    });

    test('取图失败**不缓存 null**（否则一次 CDN 抖动 = 二维码永远出不来）', () async {
      var fetches = 0;
      final http = _ImageHttp((attempt) {
        fetches++;
        // 第 1 次失败，之后成功。
        return attempt == 1 ? null : Uint8List.fromList(const [1, 2, 3]);
      });

      final d = BaiduQrDriver(client: baiduClient(http));
      await d.start();

      expect(await d.qrImageBytes(), isNull);
      expect(await d.qrImageBytes(), isNotNull);
      expect(fetches, 2);
    });

    test('轮询阶段映射：waiting / scanned / confirmed / cancelled / error',
        () async {
      Future<QrProgress> pollWith(Map<String, Object?> body) async {
        final (d, _) = await driver({
          unicastPath: (_) => ok(body),
        });
        await d.start();
        return d.poll();
      }

      expect(await pollWith({'errno': 1}), isA<QrProgressIdle>());
      expect(
        await pollWith({
          'errno': 0,
          'channel_v': jsonEncode({'status': '1'}),
        }),
        isA<QrProgressScanned>(),
      );
      expect(
        await pollWith({
          'errno': 0,
          'channel_v': jsonEncode({'status': '0', 'v': 'V', 'u': 'U'}),
        }),
        isA<QrProgressConfirmed>(),
      );
      expect(
        await pollWith({
          'errno': 0,
          'channel_v': jsonEncode({'status': '2'}),
        }),
        isA<QrProgressCancelled>(),
      );
    });

    test('exchange 产出带百度 provider 的凭证，且只留已知 Cookie', () async {
      final (d, _) = await driver({
        unicastPath: (_) => ok({
              'errno': 0,
              'channel_v': jsonEncode({'status': '0', 'v': 'V', 'u': 'U'}),
            }),
        mainlinePath: (_) => withCookies(
              ['BDUSS=BDUSS-VALUE; Path=/', 'H_PS_PSSID=noise; Path=/'],
              body: {
                'errInfo': {'no': 0},
              },
            ),
      });

      await d.start();
      expect(await d.poll(), isA<QrProgressConfirmed>());

      final credential = await d.exchange();
      expect(credential.provider, DriveProvider.baidu);
      expect(credential.mode, AuthMode.qrCode);
      expect(credential.cookies['BDUSS'], 'BDUSS-VALUE');
      expect(credential.cookies.containsKey('H_PS_PSSID'), isFalse);
    });

    test('没有待兑换回执时 exchange 抛错（而不是造一个空凭证）', () async {
      final (d, _) = await driver(const {});
      await d.start();
      await expectLater(
        d.exchange(),
        throwsA(isA<BaiduQrLoginException>()),
      );
    });

    test('⛔ 落地网盘域收到的 Cookie 要落进凭证（只按固定名单过滤会把它丢掉）',
        () async {
      final (d, _) = await driver({
        unicastPath: (_) => ok({
              'errno': 0,
              'channel_v': jsonEncode({'status': '0', 'v': 'V', 'u': 'U'}),
            }),
        mainlinePath: (_) => const HttpResult(
              statusCode: 302,
              rawBody: '',
              headers: {
                'set-cookie': ['BDUSS=BDUSS-VALUE; Path=/; Domain=.baidu.com'],
                'location': ['https://pan.baidu.com/'],
              },
            ),
        '/': (_) => withCookies(
              ['PANWEB=1; Path=/; Domain=.pan.baidu.com'],
            ),
      });

      await d.start();
      expect(await d.poll(), isA<QrProgressConfirmed>());

      final credential = await d.exchange();
      expect(credential.cookies['BDUSS'], 'BDUSS-VALUE');
      expect(
        credential.cookies['PANWEB'],
        '1',
        reason: 'PANWEB 不在 knownCookieNames 里 —— 忘了放行的后果与'
            '「没做落地」完全一样：网盘侧不认会话，uinfo 依旧 -6，'
            '而且日志上看不出差别',
      );
    });

    test('诊断行默认脱敏，点「显示原始值」才出原值', () async {
      const sign = 'SIGN-ABCDEFGH';
      final (d, _) = await driver(const {});
      await d.start();

      expect(d.diagnostics()['sign'], maskSecret(sign));
      expect(d.diagnostics(reveal: true)['sign'], sign);
      expect(d.diagnostics()['gid'], 'GID00000000000000000000000000000');
    });

    test('dispose 清掉会话（下一次 start 不会带着旧 sign）', () async {
      final (d, _) = await driver(const {});
      await d.start();
      expect(d.diagnostics(), isNotEmpty);
      d.dispose();
      expect(d.diagnostics(), isEmpty);
    });
  });

  // -------------------------------------------------------------------
  // 驱动层：夸克（形态差异的另一半）
  // -------------------------------------------------------------------

  group('QuarkQrDriver：文本型二维码、没有「已扫待确认」', () {
    const tokenPath = '/cas/ajax/getTokenForQrcodeLogin';
    const ticketPath = '/cas/ajax/getServiceTicketByQrcodeToken';
    const accountPath = '/account/info';

    QuarkQrDriver quarkDriver(FakeHttp http) =>
        QuarkQrDriver(client: QuarkQrLoginClient(http: http));

    HttpResult tokenOk() => ok({
          'status': 2000000,
          'data': {
            'members': {'token': 'TOKEN-1'},
          },
        });

    test('start ⇒ 文本型二维码（URL 由本地拼）', () async {
      final http = FakeHttp({tokenPath: (_) => tokenOk()});
      final challenge = await quarkDriver(http).start();

      expect(challenge, isA<QrChallengePayload>());
      final payload = (challenge as QrChallengePayload).payload;
      expect(payload.toString(), contains('TOKEN-1'));
    });

    test('夸克没有图片型二维码 —— qrImageBytes 恒为 null', () async {
      final http = FakeHttp({tokenPath: (_) => tokenOk()});
      final d = quarkDriver(http);
      await d.start();
      expect(await d.qrImageBytes(), isNull);
    });

    test('轮询映射：waiting / confirmed / expired / error', () async {
      Future<QrProgress> pollWith(Map<String, Object?> body) async {
        final http = FakeHttp({
          tokenPath: (_) => tokenOk(),
          ticketPath: (_) => ok(body),
        });
        final d = quarkDriver(http);
        await d.start();
        return d.poll();
      }

      expect(await pollWith({'status': 50004001}), isA<QrProgressIdle>());
      expect(
        await pollWith({
          'status': 2000000,
          'data': {
            'members': {'service_ticket': 'ST-1'},
          },
        }),
        isA<QrProgressConfirmed>(),
      );
      expect(
        await pollWith({'status': 50004002, 'message': 'Token Not Found'}),
        isA<QrProgressExpired>(),
      );
      expect(await pollWith({'status': 12345}), isA<QrProgressFailure>());
    });

    test('回执里没有 service_ticket ⇒ 失败（重试没用）', () async {
      final http = FakeHttp({
        tokenPath: (_) => tokenOk(),
        ticketPath: (_) => ok({'status': 2000000, 'data': <String, Object?>{}}),
      });
      final d = quarkDriver(http);
      await d.start();
      final progress = await d.poll();

      expect(progress, isA<QrProgressFailure>());
      expect(
        (progress as QrProgressFailure).message,
        contains('service_ticket'),
      );
    });

    test('exchange 走 service_ticket → 账号 Cookie', () async {
      final http = FakeHttp({
        tokenPath: (_) => tokenOk(),
        ticketPath: (_) => ok({
          'status': 2000000,
          'data': {
            'members': {'service_ticket': 'ST-1'},
          },
        }),
        accountPath: (_) => withCookies(
          [
            '__pus=PUS-VALUE; Path=/',
            '__puus=PUUS-VALUE; Path=/',
            '_UP_REFERER=noise; Path=/',
          ],
          body: {'success': true},
        ),
      });

      final d = quarkDriver(http);
      await d.start();
      expect(await d.poll(), isA<QrProgressConfirmed>());

      final credential = await d.exchange();
      expect(credential.provider, DriveProvider.quark);
      expect(credential.mode, AuthMode.qrCode);
      expect(credential.cookies['__pus'], 'PUS-VALUE');
      expect(credential.cookies['__puus'], 'PUUS-VALUE');
      expect(credential.cookies.containsKey('_UP_REFERER'), isFalse);
    });

    test('驱动声明的 provider 是夸克（页面靠它显示「用夸克 App 扫码」）', () async {
      final http = FakeHttp({tokenPath: (_) => tokenOk()});
      expect(quarkDriver(http).provider, DriveProvider.quark);
    });
  });
}

/// 记录 `followRedirects` 的薄包装 —— 换票那一跳**必须**不跟重定向，
/// 否则 302 里的 `Set-Cookie` 会跟丢。
class _RecordingHttp implements HttpClientLike {
  _RecordingHttp(this._inner, this._onFollow);

  final HttpClientLike _inner;
  final void Function(bool) _onFollow;

  @override
  Future<HttpResult> get(
    String url, {
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
    bool followRedirects = true,
  }) {
    _onFollow(followRedirects);
    return _inner.get(
      url,
      query: query,
      headers: headers,
      timeout: timeout,
      followRedirects: followRedirects,
    );
  }

  @override
  Future<HttpResult> post(
    String url, {
    Object? body,
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      _inner.post(url, body: body, query: query, headers: headers, timeout: timeout);

  @override
  Future<Uint8List?> getBytes(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      _inner.getBytes(url, headers: headers, timeout: timeout);

  @override
  Future<String> putBytes(
    String url, {
    required List<int> body,
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      _inner.putBytes(url, body: body, headers: headers, timeout: timeout);

  @override
  Future<String> postBytes(
    String url, {
    required List<int> body,
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      _inner.postBytes(url, body: body, headers: headers, timeout: timeout);

  @override
  void close() => _inner.close();
}

/// 数 `getBytes` 调用次数的假客户端（用于验证二维码图片缓存）。
///
/// `fetch` 收到的是**第几次取图**（从 `1` 开始），返回 `null` 表示这次失败。
/// 用「次数 → 结果」而不是「固定结果」，是为了测「失败不缓存」这条：
/// 若改成固定结果，就没法在一次测试里先失败后成功。
class _ImageHttp implements HttpClientLike {
  _ImageHttp(this._fetch);

  final Uint8List? Function(int attempt) _fetch;
  int _attempts = 0;

  @override
  Future<HttpResult> get(
    String url, {
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
    bool followRedirects = true,
  }) async =>
      // 只要 `start()` 能取到码就行 —— 本假客户端是用来数 `getBytes` 的。
      // `rawBody` 不能省：客户端解析的是 JSONP 的原始体。
      HttpResult(
        statusCode: 200,
        rawBody: jsonEncode(const {
          'errno': 0,
          'sign': 'SIGN-ABCDEFGH',
          'imgurl': '//passport.baidu.com/v2/api/qrcode?sign=S',
        }),
      );

  @override
  Future<HttpResult> post(
    String url, {
    Object? body,
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      throw UnimplementedError();

  @override
  Future<Uint8List?> getBytes(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async =>
      _fetch(++_attempts);

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
