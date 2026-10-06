import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../widgets/player_tv_panel.dart';
import '../widgets/player_tv_rows.dart';

/// 原生 TV OSD 的平台通道（`cloudcine/tv_osd`，原生侧在 `MainActivity.kt`）。
///
/// ## 它存在的理由
///
/// 云影的 TV 播放菜单原来是 Flutter widget。真机实测「按菜单键 → 上屏」
/// 要 **524 ms**（夸克原型是 0.3~8.3 ms）。原因不是画得慢，而是：
///
///   * 菜单挂在 `ListenableBuilder(listenable: controller)` 里，播放进度
///     每 tick 都重建整棵页面树；
///   * Dart 主 isolate **同时**还在跑本地中继（TLS 握手 / 解密 / 分块拷贝
///     全在那条线程上，见 `local_stream_relay.dart`）。
///
/// 换成原生 View（`android/.../TvOsdView.kt`）之后，菜单是**独立图层**，
/// 按键与重绘完全不经过 Dart —— 中继再忙也不影响它。这才是原型「跟手」的
/// 结构性原因，与「谁画得更漂亮」无关。
///
/// ## 边界
///
/// 这里只搬**行数据**（[encodeTvOsdPayload]）与**两个事件**
/// （`onActivate` / `onClose`）。播放决策仍在播放页手里
/// （[applyPlayerTvRowAction]），两边不会各有一套规则。
class TvOsdChannel {
  TvOsdChannel._();

  static const MethodChannel _channel = MethodChannel('cloudcine/tv_osd');

  /// 有没有原生实现。
  ///
  /// 只有 Android 注册了 `MainActivity` 里那个通道；桌面 / macOS 上
  /// 调用一律会 `MissingPluginException`，所以先在这里挡掉。
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 显示菜单。
  ///
  /// 返回 `false` 表示原生侧没接住（拿不到内容视图，或平台不是 Android）——
  /// 调用方**应当退回 Flutter 版菜单**，而不是让用户按了菜单键什么都没有。
  static Future<bool> show({
    required List<PlayerTvRowValue> rows,
    int selectedRow = 0,
  }) async {
    if (!supported) return false;
    final ok = await _channel.invokeMethod<bool>('show', <String, Object?>{
      'payload': encodeTvOsdPayload(rows, selectedRow: selectedRow),
    });
    return ok ?? false;
  }

  /// 收起菜单。没显示时是空操作（原生那边会先判 `visibility`）。
  static Future<void> hide() async {
    if (!supported) return;
    await _channel.invokeMethod<void>('hide');
  }

  /// 挂事件回调。
  ///
  /// `onActivate` 的 `row` 是**行下标**（对应 `PlayerTvRow.values[row]`），
  /// `chip` 是选项下标；这一行没有选项条时原生侧传 -1。
  static void attach({
    required void Function(int row, int chip) onActivate,
    required VoidCallback onClose,
  }) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onActivate':
          final args = call.arguments;
          final map = args is Map ? args : const <Object?, Object?>{};
          onActivate(
            (map['row'] as num?)?.toInt() ?? -1,
            (map['chip'] as num?)?.toInt() ?? -1,
          );
        case 'onClose':
          onClose();
      }
      return null;
    });
  }

  /// 摘掉回调。**必须在页面 `dispose` 里调**：不摘的话原生侧一次
  /// `onClose` 会打到已经销毁的 `State` 上。
  static void detach() => _channel.setMethodCallHandler(null);
}
