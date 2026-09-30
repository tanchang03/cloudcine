import 'dart:convert';

import 'package:cloudcine/ui/windows/window_launch.dart';
import 'package:flutter_test/flutter_test.dart';

/// 入口参数是**插件与 Dart 之间的契约**，形状由原生代码写死：
/// `project.dartEntrypointArguments = ["multi_window", windowId, arguments]`
/// （见 `desktop_multi_window` 的 `FlutterMultiWindowPlugin.CreateWindow`）。
///
/// 这一组用例存在的理由：解析出错的表现是「窗口起来了，但里面是错的界面」，
/// 或者更糟 —— 一个白屏窗口。两种都不会抛异常、不会有日志，只会让人以为
/// 「多窗口不好使」。所以把每一种畸形输入都钉成一条确定的结论。
void main() {
  group('parseWindowLaunch', () {
    test('没有入口参数 → 主窗口（flutter run 与 Android 端的普通启动）', () {
      final launch = parseWindowLaunch(const <String>[]);

      expect(launch.kind, WindowKind.main);
      expect(launch.isPlayer, isFalse);
      expect(launch.windowId, isEmpty);
      expect(launch.payload, isEmpty);
    });

    test('参数前缀不是 multi_window → 主窗口，且不把首元素当窗口 id', () {
      final launch = parseWindowLaunch(const [
        'something-else',
        'w1',
        '{"kind":"player"}',
      ]);

      expect(launch.kind, WindowKind.main);
      expect(launch.windowId, isEmpty);
    });

    test('播放窗口参数 → 播放窗口，并带上 windowId', () {
      final launch = parseWindowLaunch(const [
        kMultiWindowEntryToken,
        'w-42',
        '{"kind":"player"}',
      ]);

      expect(launch.kind, WindowKind.player);
      expect(launch.isPlayer, isTrue);
      expect(launch.windowId, 'w-42');
    });

    test('只有两个元素（缺 arguments）时不崩，按主窗口处理', () {
      final launch = parseWindowLaunch(const [kMultiWindowEntryToken, 'w-42']);

      expect(launch.kind, WindowKind.main);
      expect(launch.windowId, 'w-42');
      expect(launch.payload, isEmpty);
    });

    test('arguments 不是合法 JSON → 退回主窗口，绝不抛异常', () {
      const args = <String>[kMultiWindowEntryToken, 'w1', '这不是 json'];

      expect(() => parseWindowLaunch(args), returnsNormally);

      final launch = parseWindowLaunch(args);
      expect(launch.kind, WindowKind.main);
      expect(launch.payload, isEmpty);
    });

    test('arguments 是合法 JSON 但不是对象 → 退回主窗口', () {
      for (final raw in const ['[1,2]', '"player"', '123', 'null', 'true']) {
        final launch = parseWindowLaunch([kMultiWindowEntryToken, 'w1', raw]);

        expect(launch.kind, WindowKind.main, reason: 'raw=$raw');
        expect(launch.payload, isEmpty, reason: 'raw=$raw');
      }
    });

    test('缺 kind 键 → 主窗口，但 payload 仍然完整保留', () {
      final launch = parseWindowLaunch(const [
        kMultiWindowEntryToken,
        'w1',
        '{"workId":7}',
      ]);

      expect(launch.kind, WindowKind.main);
      expect(launch.payload['workId'], 7);
    });

    test('kind 值不认识 → 主窗口', () {
      final launch = parseWindowLaunch(const [
        kMultiWindowEntryToken,
        'w1',
        '{"kind":"settings"}',
      ]);

      expect(launch.kind, WindowKind.main);
    });

    test('任何畸形输入都不抛异常（宁可退回主窗口，也不开白屏窗口）', () {
      const raws = <String>['', '{', '{}', '[]', '{"kind":null}', '{"kind":1}'];
      for (final raw in raws) {
        expect(
          () => parseWindowLaunch([kMultiWindowEntryToken, '', raw]),
          returnsNormally,
          reason: 'raw=$raw',
        );
      }
    });
  });

  group('encodeWindowLaunch', () {
    test('每种窗口类型都能原样解回来', () {
      for (final kind in WindowKind.values) {
        final raw = encodeWindowLaunch(kind);
        final launch = parseWindowLaunch([kMultiWindowEntryToken, 'w1', raw]);

        expect(launch.kind, kind, reason: '$kind 编解码不对称');
      }
    });

    test('payload 会被带过去', () {
      final raw = encodeWindowLaunch(WindowKind.player, const {
        'workId': 7,
        'title': '银翼杀手',
      });
      final launch = parseWindowLaunch([kMultiWindowEntryToken, 'w1', raw]);

      expect(launch.isPlayer, isTrue);
      expect(launch.payload['workId'], 7);
      expect(launch.payload['title'], '银翼杀手');
    });

    test('payload 里混进 kind 也改不掉窗口类型', () {
      // 显式传进来的 kind 参数必须赢：否则 payload 里一个手滑写下的
      // `kind` 就会让「要开播放窗口」静默变成开出一个媒体库窗口。
      final raw = encodeWindowLaunch(WindowKind.player, const {'kind': 'main'});
      final launch = parseWindowLaunch([kMultiWindowEntryToken, 'w1', raw]);

      expect(launch.isPlayer, isTrue);
      expect(launch.payload[kWindowKindKey], 'player');
    });

    test('产物是 JSON 对象，且 kind 是必有的键', () {
      final decoded = jsonDecode(encodeWindowLaunch(WindowKind.player)) as Map;

      expect(decoded[kWindowKindKey], 'player');
    });
  });

  group('WindowLaunch 值语义', () {
    test('字段相同即相等，且 payload 的键序不影响相等性', () {
      const a = WindowLaunch(
        kind: WindowKind.player,
        windowId: 'w1',
        payload: <String, Object?>{'x': 1, 'y': 2},
      );
      const b = WindowLaunch(
        kind: WindowKind.player,
        windowId: 'w1',
        payload: <String, Object?>{'y': 2, 'x': 1},
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('任一字段不同就不相等', () {
      const base = WindowLaunch(
        kind: WindowKind.player,
        windowId: 'w1',
        payload: <String, Object?>{'x': 1},
      );

      expect(
        base ==
            const WindowLaunch(
              kind: WindowKind.main,
              windowId: 'w1',
              payload: <String, Object?>{'x': 1},
            ),
        isFalse,
        reason: '窗口类型不同',
      );
      expect(
        base ==
            const WindowLaunch(
              kind: WindowKind.player,
              windowId: 'w2',
              payload: <String, Object?>{'x': 1},
            ),
        isFalse,
        reason: 'windowId 不同',
      );
      expect(
        base ==
            const WindowLaunch(
              kind: WindowKind.player,
              windowId: 'w1',
              payload: <String, Object?>{'x': 2},
            ),
        isFalse,
        reason: 'payload 不同',
      );
    });

    test('WindowLaunch.main() 就是主窗口的空形态', () {
      const launch = WindowLaunch.main();

      expect(launch.kind, WindowKind.main);
      expect(launch.isPlayer, isFalse);
      expect(launch.windowId, isEmpty);
      expect(launch.payload, isEmpty);
    });
  });
}
