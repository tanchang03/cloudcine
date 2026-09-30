import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 一个 Flutter 引擎承载哪种窗口。
///
/// PC 端的播放器跑在**独立引擎**里（`desktop_multi_window` 为每个窗口开一个
/// 引擎，method channel 不共享），所以每个引擎启动时都必须先回答
/// 「我该跑哪个界面」。这个枚举就是这个回答。
enum WindowKind {
  /// 主窗口：媒体库、刮削、详情页。
  main,

  /// PC 端播放器独立窗口。
  player,
}

/// `desktop_multi_window` 给子窗口注入的入口参数里的第一个元素。
///
/// 固定形状是 `['multi_window', <windowId>, <arguments>]` —— 见插件 macOS 侧
/// `FlutterMultiWindowPlugin.CreateWindow` 里的 `project.dartEntrypointArguments`。
/// **这是插件与 Dart 之间的契约**，改不得；给它起个名字是为了让这个契约
/// 在代码里有出处，并且能被单测钉住。
const String kMultiWindowEntryToken = 'multi_window';

/// `arguments` 里标记窗口种类的键。
const String kWindowKindKey = 'kind';

/// 从入口参数解析出的「这个引擎该跑什么」。
@immutable
class WindowLaunch {
  const WindowLaunch({
    required this.kind,
    required this.windowId,
    required this.payload,
  });

  /// 主窗口的默认形态。
  ///
  /// 命令行参数里没有 `multi_window` 标记时就用它 —— 包括
  /// `flutter run` 直接启动、以及 Android 端（那边根本没有多窗口）。
  const WindowLaunch.main()
      : kind = WindowKind.main,
        windowId = '',
        payload = const <String, Object?>{};

  final WindowKind kind;

  /// `desktop_multi_window` 分配的本窗口 id。
  ///
  /// 主窗口走 [WindowLaunch.main] 时为空串：主窗口的 id 要到插件
  /// `AttachWindow` 时才生成，而跨窗口通道是按**名字**配对的、不按 id，
  /// 所以 Dart 侧没有必要为它多打一次平台通道。
  final String windowId;

  /// 创建窗口时随 [encodeWindowLaunch] 一起带过来的业务参数。
  final Map<String, Object?> payload;

  bool get isPlayer => kind == WindowKind.player;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WindowLaunch &&
          other.kind == kind &&
          other.windowId == windowId &&
          mapEquals(other.payload, payload);

  @override
  int get hashCode => Object.hash(kind, windowId, _hashPayload(payload));

  @override
  String toString() =>
      'WindowLaunch(kind: ${kind.name}, windowId: $windowId, payload: $payload)';
}

/// 解析入口参数，决定这个引擎跑主窗口还是播放窗口。
///
/// 解析不出来一律**退回主窗口**，绝不抛异常：参数是我们自己写的，解不开
/// 只可能是版本错配。此时开一个白屏窗口比退回媒体库更难被发现，而退回
/// 媒体库至少是个能用的界面。
WindowLaunch parseWindowLaunch(List<String> args) {
  if (args.length < 2 || args.first != kMultiWindowEntryToken) {
    return const WindowLaunch.main();
  }
  final payload = _decodePayload(args.length >= 3 ? args[2] : '');
  return WindowLaunch(
    kind: payload[kWindowKindKey] == WindowKind.player.name
        ? WindowKind.player
        : WindowKind.main,
    windowId: args[1],
    payload: payload,
  );
}

/// 生成传给 `WindowController.create` 的 `arguments`。
///
/// `kind` 放在展开之后：显式传进来的窗口种类必须**赢过** payload。
/// 反过来的话，payload 里一个手滑写下的 `kind` 就会让「明明要开播放窗口」
/// 变成一个媒体库窗口 —— 而且这种错误没有任何报错，只是窗口里跑了别的界面。
String encodeWindowLaunch(
  WindowKind kind, [
  Map<String, Object?> payload = const <String, Object?>{},
]) =>
    jsonEncode(<String, Object?>{...payload, kWindowKindKey: kind.name});

Map<String, Object?> _decodePayload(String raw) {
  if (raw.isEmpty) return const <String, Object?>{};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) return decoded.cast<String, Object?>();
  } on FormatException {
    // 见 [parseWindowLaunch]：不抛，退回主窗口。
  }
  return const <String, Object?>{};
}

/// 让 hashCode 与 [WindowLaunch.operator==] 的口径一致（逐键逐值）。
int _hashPayload(Map<String, Object?> payload) {
  final keys = payload.keys.toList()..sort();
  return Object.hashAll(keys.map((k) => Object.hash(k, payload[k])));
}
