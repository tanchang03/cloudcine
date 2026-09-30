import 'package:cloudcine/ui/windows/player_protocol.dart';
import 'package:cloudcine/ui/windows/player_window_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 跨引擎通道的**主窗口一侧**是纯逻辑，不需要真窗口就能测。
///
/// 这里每一条用例都对应一个「出问题时完全安静」的故障：
///   - 待取盒子没清 → 「重新自检」会把同一部片反复重播；
///   - 进度回报没路由 → 「最近播放」永远不更新；
///   - 未实现的方法不抛 → 协议两边悄悄错位，没人发现。
void main() {
  setUp(() {
    // 这三个都是**进程级全局**（见 bridge 里的说明），用例之间必须隔离。
    debugSetPendingPlayRequest(null);
    onPlaybackProgress = null;
    onTicketRefresh = null;
  });

  tearDown(() {
    debugSetPendingPlayRequest(null);
    onPlaybackProgress = null;
    onTicketRefresh = null;
  });

  group('handlePlayerWindowCall（主窗口侧）', () {
    test('ping → pong', () async {
      expect(
        await handlePlayerWindowCall(const MethodCall(PlayerBridgeMethod.ping)),
        'pong',
      );
    });

    test('fetchPendingPlay 把请求交出去', () async {
      const request = PlayRequest(
        url: 'https://cdn.example.com/a.mp4',
        title: '银翼杀手',
        itemId: '102',
        headers: <String, String>{'Cookie': 'k=v'},
        qualityLabel: '4k(2160p)',
      );
      debugSetPendingPlayRequest(request);

      final raw = await handlePlayerWindowCall(
        const MethodCall(PlayerBridgeMethod.fetchPendingPlay),
      );

      expect(PlayRequest.fromJson(raw), request);
    });

    test('fetchPendingPlay 只交付一次 —— 否则「重新自检」会反复重播同一部片', () async {
      debugSetPendingPlayRequest(
        const PlayRequest(url: 'https://a/b.mp4', title: 'x'),
      );

      expect(
        await handlePlayerWindowCall(
          const MethodCall(PlayerBridgeMethod.fetchPendingPlay),
        ),
        isNotNull,
      );
      expect(
        await handlePlayerWindowCall(
          const MethodCall(PlayerBridgeMethod.fetchPendingPlay),
        ),
        isNull,
        reason: '第二次必须拿到 null',
      );
      expect(debugPendingPlayRequest, isNull);
    });

    test('盒子里没有请求时返回 null，不抛异常', () async {
      expect(
        await handlePlayerWindowCall(
          const MethodCall(PlayerBridgeMethod.fetchPendingPlay),
        ),
        isNull,
      );
    });

    test('reportProgress 把回报交给 UI 层装上的回调', () async {
      final received = <PlaybackProgressReport>[];
      onPlaybackProgress = received.add;

      final result = await handlePlayerWindowCall(
        MethodCall(
          PlayerBridgeMethod.reportProgress,
          const PlaybackProgressReport(
            itemId: '102',
            position: Duration(seconds: 30),
            duration: Duration(minutes: 96),
          ).toJson(),
        ),
      );

      expect(result, isNull);
      expect(received, hasLength(1));
      expect(received.single.itemId, '102');
      expect(received.single.position, const Duration(seconds: 30));
      expect(received.single.duration, const Duration(minutes: 96));
    });

    test('解不开的进度回报不回调、不抛异常', () async {
      var called = false;
      onPlaybackProgress = (_) => called = true;

      for (final raw in const <Object?>[
        null,
        'string',
        <String, Object?>{},
        <String, Object?>{'itemId': ''},
        <String, Object?>{'itemId': 102},
      ]) {
        expect(
          () => handlePlayerWindowCall(
            MethodCall(PlayerBridgeMethod.reportProgress, raw),
          ),
          returnsNormally,
          reason: 'raw=$raw',
        );
      }

      expect(called, isFalse);
    });

    test('还没装上落库回调时安静丢弃 —— 不能因此崩掉主窗口', () async {
      // 进度每 10 秒来一条，这条路径必须容忍「容器还没起来」。
      final result = await handlePlayerWindowCall(
        MethodCall(
          PlayerBridgeMethod.reportProgress,
          const PlaybackProgressReport(
            itemId: '102',
            position: Duration(seconds: 10),
          ).toJson(),
        ),
      );

      expect(result, isNull);
    });

    test('refreshTicket 把新链交回去', () async {
      onTicketRefresh = (request) async => PlayRequest(
            url: 'https://cdn.example.com/fresh.mp4',
            title: '银翼杀手',
            itemId: request.itemId,
            qualityId: request.qualityId,
            startPosition: request.position,
          );

      final raw = await handlePlayerWindowCall(
        MethodCall(
          PlayerBridgeMethod.refreshTicket,
          const TicketRefreshRequest(
            itemId: '102',
            qualityId: '4k',
            position: Duration(minutes: 42),
          ).toJson(),
        ),
      );

      final fresh = PlayRequest.fromJson(raw)!;
      expect(fresh.url, 'https://cdn.example.com/fresh.mp4');
      // 位置必须原样带回 —— 丢了它刷新会把用户扔回片头。
      expect(fresh.startPosition, const Duration(minutes: 42));
      // 档位同理：丢了它主窗口只能退回设置里的默认档。
      expect(fresh.qualityId, '4k');
    });

    test('取链回调返回 null → 原样返回 null，不抛异常', () async {
      onTicketRefresh = (_) async => null;

      final raw = await handlePlayerWindowCall(
        MethodCall(
          PlayerBridgeMethod.refreshTicket,
          const TicketRefreshRequest(itemId: '102').toJson(),
        ),
      );

      expect(raw, isNull);
    });

    test('取链回调自己抛了 → 异常冒出去（由播放窗口那侧兜）', () async {
      // 刻意不在这里吞掉：吞掉会让「取链挂了」和「服务端说刷不出来」
      // 变成同一个结果，而前者是需要被看见的故障。
      onTicketRefresh = (_) async => throw StateError('取链挂了');

      await expectLater(
        handlePlayerWindowCall(
          MethodCall(
            PlayerBridgeMethod.refreshTicket,
            const TicketRefreshRequest(itemId: '102').toJson(),
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('没装上取链回调 → 返回 null，不抛异常', () async {
      final raw = await handlePlayerWindowCall(
        MethodCall(
          PlayerBridgeMethod.refreshTicket,
          const TicketRefreshRequest(itemId: '102').toJson(),
        ),
      );

      expect(raw, isNull);
    });

    test('解不开的刷新请求不回调、不抛异常', () async {
      var called = false;
      onTicketRefresh = (_) async {
        called = true;
        return null;
      };

      for (final raw in const <Object?>[
        null,
        'string',
        <String, Object?>{},
        <String, Object?>{'itemId': ''},
        <String, Object?>{'itemId': 102},
      ]) {
        expect(
          () => handlePlayerWindowCall(
            MethodCall(PlayerBridgeMethod.refreshTicket, raw),
          ),
          returnsNormally,
          reason: 'raw=$raw',
        );
      }

      expect(called, isFalse);
    });

    test('未实现的方法一律抛 MissingPluginException', () async {
      // 静默吞掉会让协议两边悄悄错位 —— 必须显式暴露。
      await expectLater(
        handlePlayerWindowCall(const MethodCall('nope')),
        throwsA(isA<MissingPluginException>()),
      );
    });
  });

  group('handleMainWindowCall（播放窗口侧）', () {
    test('ping → pong', () async {
      expect(
        await handleMainWindowCall(const MethodCall(PlayerBridgeMethod.ping)),
        'pong',
      );
    });

    test('play 不在这里处理 —— 它要操作播放器，由 PlayerWindowApp 包一层', () async {
      // 这个纯函数只负责协议层面的事情。放进来会让「拿一个 MethodCall
      // 就能控制播放器」，测试也没法在不建引擎的情况下覆盖。
      await expectLater(
        handleMainWindowCall(const MethodCall(PlayerBridgeMethod.play)),
        throwsA(isA<MissingPluginException>()),
      );
    });

    test('未实现的方法一律抛 MissingPluginException', () async {
      await expectLater(
        handleMainWindowCall(const MethodCall('nope')),
        throwsA(isA<MissingPluginException>()),
      );
    });
  });

  group('supportsMultiWindow 平台闸', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('桌面三平台放行', () {
      for (final platform in const [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(supportsMultiWindow, isTrue, reason: '$platform');
      }
    });

    test('移动端拦住 —— 插件在这些平台上会抛 MissingPluginException', () {
      for (final platform in const [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.fuchsia,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(supportsMultiWindow, isFalse, reason: '$platform');
      }
    });
  });
}
