import 'package:media_kit/media_kit.dart';

import '../diagnostics/diag_log.dart';

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

  /// 关掉 mpv 的 **stream 层**字节缓存（media_kit 硬编码的 `cache=yes`）。
  ///
  /// ## 为什么要关
  ///
  /// 开着它，mpv 的缓存是**两层**且互相解耦的：
  ///
  ///   网络 → stream cache（字节，后台预读）→ 解复用 → demuxer cache（秒）
  ///
  /// 而界面上那个「缓冲网速」只能量到**第二层** —— `demuxer-cache-time` 是
  /// demuxer 已缓存的时间跨度，它的数据是从本地（内存或 `cache-on-disk` 的
  /// 磁盘文件）灌进来的，速度是 CPU / 磁盘的量级，跟带宽**没有上限关系**。
  /// 一次几百 MB 的块填充可以在几十毫秒内完成，换算出来就是 GB/s
  /// （详见 `cacheBytesPerSecond` 的文档）。
  ///
  /// 关掉之后 demuxer 直接从网络读，`demuxer-cache-time` 的增速才等于真实
  /// 下载速率，缓冲指示上的 KB/s 才有意义。
  ///
  /// ## 为什么关它是安全的
  ///
  ///   - 夸克原画是支持 Range 的 seekable HTTP，转码档位是分片 HLS —— 两者
  ///     都不需要 stream cache 来提供回读；
  ///   - [bufferSize]（1 GB）同时设给 `demuxer-max-bytes` 与
  ///     `demuxer-max-back-bytes`，抗抖动与回看能力照旧；
  ///   - 少掉一层 1 GB 的字节缓存（media_kit 还硬编码了 `cache-on-disk=yes`，
  ///     超额部分会落盘），内存与磁盘占用都省一半。
  ///
  /// ⚠️ 它是 stream 层选项，**只在打开片源那一刻生效**，所以必须在 `open()`
  /// 之前设（见 [apply]）。实测若发现开播变慢或 seek 后重新缓冲，把这里改成
  /// `false` 即可回退 —— 代价只是缓冲网速重新变成估算值。
  static const bool disableStreamCache = true;

  /// 在 [Player] 创建后、`open()` 之前调用，设置 [PlayerConfiguration]
  /// 管不到的 mpv 属性。
  ///
  /// `bufferSize` 通过 [PlayerConfiguration] 在 mpv 初始化时就生效，
  /// 这里补 [disableStreamCache] 与 `demuxer-readahead-secs`（media_kit
  /// 都没有对应的构造参数）。
  ///
  /// ## 为什么调用方可以 `unawaited`
  ///
  /// media_kit 的 [NativePlayer.setProperty] 是把命令**同步投进** isolate
  /// 的命令队列的 —— 投递顺序即执行顺序。本方法在播放器构造之后、`open()`
  /// 之前被调用，所以这两条 `setProperty` 一定排在 `loadfile` 前面，不需要
  /// 调用方 `await`。（[NativePlayer.setProperty] 内部还会等播放器初始化
  /// 完成再真正发送，顺序依旧保持。）
  static Future<void> apply(Player player) async {
    final platform = player.platform;
    if (platform is NativePlayer) {
      if (disableStreamCache) {
        await platform.setProperty('cache', 'no');
        await _confirmStreamCacheOff(platform);
      }
      await platform.setProperty('demuxer-readahead-secs', readaheadSecs);
    }
  }

  /// 读回 `cache`，确认 stream 层缓存真的关了。
  ///
  /// ## 为什么必须确认
  ///
  /// media_kit 的 `setProperty` **丢掉了 mpv 的返回码**（`real.dart` 里调完
  /// `mpv_set_property_string` 直接返回，没看结果）。也就是说属性名写错、
  /// 或 mpv 不接受运行期改这个选项时，失败是**完全静默**的 —— 表现就是
  /// 「缓冲网速又变成 GB/s 级的估算值」，而诊断日志里查不到任何原因。
  ///
  /// 这里把结果记进诊断日志：诊断页里看到 `cache=no` 就说明这条路是通的；
  /// 看到 warn 就说明得改回 `disableStreamCache = false`，别再指望它。
  ///
  /// ⚠️ 三种结果都**只记日志、不抛异常**：关不掉最多是缓冲网速不准，
  /// 不该因此把播放本身搞挂。读属性失败（`getProperty` 返回空串）也一样。
  static Future<void> _confirmStreamCacheOff(NativePlayer platform) async {
    try {
      final actual = await platform.getProperty('cache');
      if (actual.isEmpty) {
        diag.debug('缓冲', '读不到 cache 属性，无法确认 stream 缓存是否关闭');
      } else if (actual != 'no') {
        diag.warn(
          '缓冲',
          'stream 层缓存没关掉（cache=$actual）—— 缓冲网速仍是估算值，'
          '不是真实下载速率',
        );
      } else {
        diag.info('缓冲', 'stream 层缓存已关闭（cache=no），缓冲网速为真实下载速率');
      }
    } catch (e) {
      // 播放器已 dispose 之类：不影响播放，静默。
      diag.debug('缓冲', '确认 cache 属性失败：$e');
    }
  }
}
