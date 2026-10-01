import 'package:media_kit/media_kit.dart';

/// mpv 播放器缓冲优化配置。
///
/// media_kit 默认 `demuxer-max-bytes` 只有 **32 MB**、
/// `demuxer-readahead-secs` 只有 **1 秒**。对高码率原画影片远远不够：
///
///   - 40 Mbps 4K：32 MB ≈ 6.4 秒，1 秒预读 → 播几秒就卡、卡完再缓冲、循环
///   - 带宽没跑满：缓存填满后 mpv 停止拉流，等播放追上又卡
///
/// 本类把缓存上限提到 1 GB、预读目标设为 9999 秒（≈2.7 小时，覆盖绝大多数
/// 影片时长），让 mpv **一直往前缓存**直到影片结束或缓存填满，而不是拉一会
/// 就停。配合 media_kit 硬编码的 `cache-on-disk=yes`，超额数据落盘，内存
/// 占用可控。
class PlayerBufferConfig {
  PlayerBufferConfig._();

  /// demuxer 缓存上限（字节），传给 [PlayerConfiguration.bufferSize]。
  ///
  /// 同时设 `demuxer-max-bytes` 和 `demuxer-max-back-bytes`。
  /// 1 GB 配合 `cache-on-disk=yes`（media_kit 硬编码），超额落盘：
  ///   - 8 Mbps ≈ 1024 秒（17 分钟）
  ///   - 40 Mbps 4K ≈ 205 秒（3.4 分钟）
  ///   - 80 Mbps ≈ 102 秒（1.7 分钟）
  static const int bufferSize = 1024 * 1024 * 1024;

  /// 预读目标（秒），设 mpv 的 `demuxer-readahead-secs`。
  ///
  /// mpv 默认只预读 1 秒 —— 网络比播放快时填满就停，播放追上又卡。
  /// 设 9999 秒（≈2.7 小时）让 mpv **一直往前拉流**直到影片结束或缓存
  /// 上限填满，而不是拉一会就停。
  static const String readaheadSecs = '9999';

  /// 在 [Player] 创建后调用，设置 [PlayerConfiguration] 管不到的 mpv 属性。
  ///
  /// `bufferSize` 通过 [PlayerConfiguration] 在 mpv 初始化时就生效，
  /// 这里只补 `demuxer-readahead-secs`（media_kit 没有对应的构造参数）。
  ///
  /// 调用方用 `unawaited(PlayerBufferConfig.apply(player))` 即可 ——
  /// [NativePlayer.setProperty] 内部会等播放器初始化完成再设属性，
  /// 不需要在 `open()` 之前同步等待。
  static Future<void> apply(Player player) async {
    final platform = player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty('demuxer-readahead-secs', readaheadSecs);
    }
  }
}
