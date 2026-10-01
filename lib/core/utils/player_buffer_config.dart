import 'package:media_kit/media_kit.dart';

/// mpv 播放器缓冲优化配置。
///
/// media_kit 默认 `demuxer-max-bytes`=32MB、`demuxer-readahead-secs`=1s，
/// 对 40Mbps 的 4K 原画只有约 6.4 秒缓存且只往前读 1 秒，
/// 导致「播放→卡→缓冲→播放」循环。
///
/// 本文件是两个播放器共用的缓冲配置真源，改参数改这一处即可。
class PlayerBufferConfig {
  PlayerBufferConfig._();

  /// 1 GB demuxer 缓冲区，配合 media_kit 硬编码的 `cache-on-disk=yes`，
  /// 超额部分落盘，不占用额外内存。
  static const int bufferSize = 1024 * 1024 * 1024;

  /// 设 9999 秒（≈2.7 小时）让 mpv 一直往前拉流，不因读够秒数而停。
  static const String readaheadSecs = '9999';

  /// 在 [Player] 创建后调用，设置 mpv 的 `demuxer-readahead-secs`。
  ///
  /// `bufferSize` 已通过 `PlayerConfiguration.bufferSize` 映射到
  /// `demuxer-max-bytes` + `demuxer-max-back-bytes`，
  /// 但 `demuxer-readahead-secs` 没有构造参数，只能走 `setProperty`。
  static Future<void> apply(Player player) async {
    final platform = player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty('demuxer-readahead-secs', readaheadSecs);
    }
  }
}
