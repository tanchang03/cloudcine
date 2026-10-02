import 'package:cloudcine/data/auth/quark_qr_login.dart';
import 'package:cloudcine/data/http/http_client.dart';
import 'package:cloudcine/ui/pages/auth_qr_login_page.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一切请求都 404：够让页面落进 `error` 阶段，从而**不启动轮询定时器**，
/// 于是 `pumpAndSettle` 不会挂死。测尺寸不需要真的扫码会话。
class _NoNetHttp implements HttpClientLike {
  @override
  Future<HttpResult> get(
    String url, {
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
    bool followRedirects = true,
  }) async =>
      const HttpResult(statusCode: 404, rawBody: '');

  @override
  Future<HttpResult> post(
    String url, {
    Object? body,
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
  }) async =>
      const HttpResult(statusCode: 404, rawBody: '');

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

/// 扫码登录页的二维码尺寸。
///
/// ## 为什么这条值得钉住
///
/// 208 是「人坐在电脑前 40 厘米」的尺寸。TV 上用户要退到 **3 米**外才看得全
/// 整个画面，208 的码在那个距离上糊成一团 —— 而「扫不出来」和「码没生成」
/// 在用户眼里是同一件事，他只会反复点「刷新二维码」。所以这不只是「大一点
/// 更好看」，而是**这个页面在 TV 上能不能用**。
///
/// 另一头也不能忘：二维码被父级裁掉一角就**永远扫不出来**，而且看起来完全
/// 正常。所以可用宽度不够时必须跟着缩，而不是画到框外面去。
void main() {
  group('qrEdgeFor：二维码边长', () {
    test('TV 上 320 —— 208 在 3 米外扫不出来', () {
      expect(qrEdgeFor(tv: true, availableWidth: 420), 320);
    });

    test('非 TV 保持 208（电脑前 40 厘米够用，不该无故改版式）', () {
      expect(qrEdgeFor(tv: false, availableWidth: 420), 208);
    });

    test('可用宽度不够时跟着缩 —— 被裁掉一角的码永远扫不出来', () {
      expect(qrEdgeFor(tv: true, availableWidth: 260), 260);
      expect(qrEdgeFor(tv: false, availableWidth: 120), 120);
    });

    test('宽度未知（无限）时用目标值，不当成「不够」', () {
      // 布局里 `LayoutBuilder` 在纵向滚动容器里可能给出无界宽度；
      // 把它当成 0 会让二维码直接消失。
      expect(qrEdgeFor(tv: true, availableWidth: double.infinity), 320);
    });
  });

  /// 在指定逻辑尺寸下打开登录页。
  ///
  /// 尺寸走 `MediaQuery` 注入（与 `tv_layout_test.dart` 同一套做法）：
  /// `AppTheme.isTvLayout` 读的就是 `MediaQuery.sizeOf`。
  Future<void> pumpPage(WidgetTester tester, {required Size size}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          qrLoginClientProvider.overrideWithValue(
            QuarkQrLoginClient(http: _NoNetHttp()),
          ),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: size),
            child: const AuthQrLoginPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// ⚠️ 复位 `debugDefaultTargetPlatformOverride` **只能写在测试体里**
  /// （这里的 `finally`）：`tearDown` / `addTearDown` 都排在 Flutter 的
  /// `_verifyInvariants` **之后**，用错会得到一条与业务毫无关系的
  /// 「The value of a foundation debug variable was changed by the test」。
  /// 详见 `test/ui/theme/tv_layout_test.dart` 的同一条注释。
  Future<void> withAndroid(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  testWidgets('TV 上真的画出 320 的二维码框（不是只有纯函数算对了）', (tester) async {
    await withAndroid(() async {
      await pumpPage(tester, size: const Size(1280, 720));

      final size = tester.getSize(find.byKey(qrAreaKey));
      expect(size.width, 320);
      expect(size.height, 320, reason: '正方形 —— 二维码非方即歪。');
    });
  });

  testWidgets('非 TV 保持 208：桌面用户不该无故看到版式变化', (tester) async {
    await withAndroid(() async {
      await pumpPage(tester, size: const Size(800, 600));
      expect(tester.getSize(find.byKey(qrAreaKey)).width, 208);
    });
  });
}
