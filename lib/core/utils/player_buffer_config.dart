import 'package:media_kit/media_kit.dart';

import '../diagnostics/diag_log.dart';

/// mpv 播放器缓冲配置 —— **按设备分两套**。
///
/// ## 为什么电视上不能沿用桌面那套
///
/// 桌面那套的参数（1 GB 缓存、无限预读、关掉 stream 层缓存）是为了「把整部
/// 片子尽量拉下来」，前提是内存与磁盘都够用。电视盒子三样都差一个数量级：
///
///   | 项 | 桌面 | 电视盒子 |
///   |---|---|---|
///   | 内存 | 8–32 GB | **1–2 GB** |
///   | 存储 | NVMe SSD | **eMMC**，慢一个数量级 |
///   | 网络 | 多数有线 / Wi-Fi 6 | **多为 Wi-Fi，抖动大** |
///
/// 而 media_kit 硬编码了 `cache-on-disk=yes` —— 缓存超过内存部分会**落盘**。
/// 于是 1 GB 那套在电视上意味着「持续往 eMMC 写几个 GB」，磁盘 IO 与网络
/// 抢占同一个瓶颈，表现就是用户报的那两条：**卡帧**，以及**音画不同步**
/// （视频解码跟不上音频 → mpv 为追上主时钟跳帧 → 观感上就是对不上）。
///
/// ⚠️ 下面几个数是**经验值，不是实测最优**。它们共同的取向是「不把设备资源
/// 吃满」：缓存够抗抖动就停、预读有个上限、stream 层缓存开着挡网络抖动。
/// 真机上若仍有卡顿，调大 [tvBufferSize] 是第一个该试的旋钮。
///
/// ⛔ 但要知道：**这一套只解决「数据没到位」，解决不了「解码跟不上」**。
/// 后者由 [tvHwdec]（硬件解码）负责 —— 两条独立的路，缺一条原画还是卡。
class PlayerBufferConfig {
  PlayerBufferConfig._();

  // ---- 桌面 / 手机 ----

  /// demuxer 缓存上限（字节）。同时设 `demuxer-max-bytes` 与
  /// `demuxer-max-back-bytes`。
  static const int desktopBufferSize = 1024 * 1024 * 1024;

  /// 预读目标（秒）。9999 ≈ 2.7 小时，覆盖绝大多数影片时长。
  static const String desktopReadaheadSecs = '9999';

  /// 关掉 stream 层字节缓存（理由见 [tvDisableStreamCache] 上方的文档）。
  static const bool desktopDisableStreamCache = true;

  // ---- Android TV ----

  /// TV 上的 demuxer 缓存上限：**256 MB**，是桌面值的四分之一。
  ///
  /// 换算成能扛多久的抖动：
  ///   - 8 Mbps ≈ 256 秒（4.3 分钟）
  ///   - 40 Mbps 4K 原画 ≈ **51 秒**
  ///   - 80 Mbps ≈ 26 秒
  ///
  /// 原画那 51 秒看着不长，但它的用途是**吸收 Wi-Fi 抖动**（几百毫秒到几秒
  /// 级别的掉速），不是「把整部片装进来」—— 后者在电视上做不到，也不该做。
  /// 再往上加，吃的是内存与 eMMC 的写入带宽，而那正是卡帧的来源。
  static const int tvBufferSize = 256 * 1024 * 1024;

  /// TV 上的预读目标：**60 秒**。
  ///
  /// 桌面的 9999 会让 mpv **一路全速拉流**直到影片结束或缓存填满。电视上
  /// 那意味着解码线程、网络栈、磁盘写入全程满载 —— 而它们抢的是同一颗
  /// 本来就不宽裕的 SoC。60 秒足够铺满缓冲并吸收抖动，之后只在播放追上时
  /// 才补。
  static const String tvReadaheadSecs = '60';

  /// TV 上**开回** stream 层字节缓存（桌面是关着的）。
  ///
  /// stream 缓存是**字节级**的后台预读，位置在「网络 → 这里 → demuxer」，
  /// 它的作用正是平滑网络抖动。桌面上关掉它是为了一个**纯 UI 的理由**：
  /// 只有关掉它，`demuxer-cache-time` 的增速才等于真实下载速率，界面上那个
  /// 「缓冲网速」才有意义。
  ///
  /// 电视上这个取舍反过来 —— 没有人隔着三米去看一个 KB/s 的数字，而抖动
  /// 直接变成卡顿。所以这里拿那个读数换流畅。
  ///
  /// ⚠️ 代价：诊断页里的「缓冲网速」在 TV 上会重新变成**估算值**（GB/s 级
  /// 的虚高数字，因为数据是从本地缓存灌进 demuxer 的）。看到那个数字时
  /// 别以为带宽真的有那么高 —— 见 `_confirmStreamCacheOff`。
  static const bool tvDisableStreamCache = false;

  /// TV 上**开启硬件解码**（`auto-safe`）。
  ///
  /// ⚠️ 这一项不属于「缓冲」。放在这个类里是因为它与上面几项**在同一个时刻
  /// 下发**（[apply]），而为一个常量单开一个类不值当。
  ///
  /// ## 为什么非加不可
  ///
  /// mpv 的 `hwdec` **默认是 `no`（纯软件解码）**，而 media_kit 那张默认属性表
  /// （`media_kit/lib/src/player/native/player/real.dart` 里的 `properties` 映射）
  /// **也没有这一项** —— 全项目搜 `hwdec` 一处都没有。
  /// 也就是说电视盒子一直在**软解**高码率原画，而那颗 SoC 通常只够软解 1080p。
  /// 表现正是用户报的那两条：**卡帧** + **音画不同步** ——
  /// 视频解码跟不上音频 → mpv 为追音频主时钟跳帧 → 观感上就是「嘴动了声没动」。
  ///
  /// ⚠️ 上面那套缓冲参数只解决「数据没到位」，**解决不了「解码跟不上」**。
  /// 这是两条独立的路，缺一条原画就还是卡。
  ///
  /// ## 为什么是 `mediacodec,auto-safe` 而不是光写 `auto-safe`（10-04 实测）
  ///
  /// 用户报「4K 掉帧、1080P 顺、夸克播同一片源没问题」。真机日志把根因钉死了：
  ///
  /// ```
  /// 第 6s：解码器=mediacodec-copy 解码丢帧=0 显示丢帧=14
  /// 第27s：解码器=mediacodec-copy 解码丢帧=0 显示丢帧=58
  /// ```
  ///
  /// `解码丢帧` 恒为 0（解码永远跟得上），而 `显示丢帧` 21 秒涨 44 帧
  /// （≈ 每秒丢 9%），同一段 `[中继]` 一条告警都没有 —— 瓶颈既不在解码、
  /// 也不在网络，而在**「拷回内存 + 上传纹理」这一段**。
  ///
  /// 为什么会有那一拷：mpv 的 `auto-safe` **只用白名单**，而
  /// `mediacodec` / `mediacodec-copy` **都不在白名单里**（白名单只有
  /// d3d11va / videotoolbox / vaapi / nvdec / drm / vulkan 这几族）。
  /// Android 上 `auto-safe` 于是落到 `mediacodec-copy`：MediaCodec 解到 CPU
  /// 内存，再 memcpy 进 mpv 的帧、再上传成纹理。4K 一帧 YUV 约 12 MB，
  /// 24fps 就是 ~290 MB/s 的 memcpy **再加**等量的上传，电视 SoC 撑不住
  /// 41ms 的帧预算。1080P 只有 1/4 像素，所以顺；夸克走 ExoPlayer +
  /// SurfaceView（解码器直接输出到 surface，一次拷贝都没有）所以也顺。
  ///
  /// 所以要把**直通**那一档显式点出来。两个前提都成立：
  ///
  /// 1. `mediacodec` 要求 `--vo=gpu` + `--gpu-context=android`（mpv 手册原话；
  ///    另一条 `--vo=mediacodec_embed` 我们不用）—— media_kit 在 Android 上
  ///    **恰好就是这两个值**：`android_video_controller/real.dart` 里
  ///    `vo: configuration.vo ?? 'gpu'`，并把 `gpu-context` 写死成 `android`，
  ///    配 `wid` 指向真实 Surface。**这条是上一轮误判过的地方**：Android 不是
  ///    render API（那条路确实只吃拷贝型硬解），是真窗口 vo。
  /// 2. 逗号列表**带自动回退**：手册里 `vaapi,auto` 的含义就是「先试 vaapi，
  ///    失败再走 auto 逻辑」。于是 `mediacodec,auto-safe` = 先试零拷贝，
  ///    配不上就退回今天这条拷贝路 —— **最坏情况等于没改**。
  ///
  /// ⛔ 别写成光秃秃的 `mediacodec`：那样失败只剩软解，4K 会直接不能看。
  ///
  /// ⚠️ 代价（手册明说）：`mediacodec` 是不安全档，它**强制 RGB 转换**、
  /// 非标准色彩空间的表现不明，10bit 会被降到 8bit。这台电视是 1080p SDR
  /// 面板，两条都不构成损失；哪天上了 HDR 屏，要回来重看这一条。
  static const String tvHwdec = 'mediacodec,auto-safe';

  // ---- 按设备取用 ----

  static int bufferSizeFor({required bool tv}) =>
      tv ? tvBufferSize : desktopBufferSize;

  static String readaheadSecsFor({required bool tv}) =>
      tv ? tvReadaheadSecs : desktopReadaheadSecs;

  static bool disableStreamCacheFor({required bool tv}) =>
      tv ? tvDisableStreamCache : desktopDisableStreamCache;

  /// 要下发的 `hwdec` 值；**桌面返回 `null` = 这一项根本不下发**。
  ///
  /// 桌面不动它有两个理由：开发机（M 系）软解绰绰有余，而且用户明确要求
  /// 「TV 走独立分支、桌面代码不动」。返回 `null` 而不是 `'no'` 是关键 ——
  /// 下发 `'no'` 也是**改了桌面行为**（把 mpv 的默认显式化，且挡住了将来
  /// 有人给桌面开硬解）。
  static String? hwdecFor({required bool tv}) => tv ? tvHwdec : null;

  /// 生效的解码器是否落在**拷贝档**。
  ///
  /// mpv 的 `hwdec-current` 在零拷贝直通上是 `mediacodec`，退回拷贝档是
  /// `mediacodec-copy`；其它平台还有 `vaapi-copy` / `d3d11va-copy` 同族值，
  /// 所以判据取「名字里带 copy」，而不是与某个具体值相等。
  ///
  /// ⚠️ 空串（解码器还没起来）**不算**拷贝档 —— 那不是「退回了拷贝」，
  /// 只是还没有读数。把空串算进来会让「起播那一瞬间的检查」误判成失败。
  static bool isCopyHwdec(String current) =>
      current.toLowerCase().contains('copy');

  /// 让 mpv **重新解析** `hwdec` 时先写入的过渡值。
  ///
  /// ## 为什么必须「改一次再改回来」
  ///
  /// mpv 只在 `hwdec` **发生变化**时才重建视频解码器；写入一个与当前完全
  /// 相同的字符串是**空操作**。所以「请重新解析一次」只能靠先写一个不同的
  /// 值、再写回目标值。
  ///
  /// ## 为什么过渡值不是 `no`
  ///
  /// `no` 同样能触发重建，但它把解码器拽到**软解** —— 4K 软解会直接卡死。
  /// `auto-safe` 依旧是硬解（只是拷贝档），重建那一瞬间的代价小得多。
  static const String hwdecKickTransient = 'auto-safe';

  /// 在 [Player] 创建后、`open()` 之前调用，设置 [PlayerConfiguration]
  /// 管不到的 mpv 属性。
  ///
  /// ## 为什么调用方可以 `unawaited`
  ///
  /// media_kit 的 [NativePlayer.setProperty] 是把命令**同步投进** isolate
  /// 的命令队列的 —— 投递顺序即执行顺序。本方法在播放器构造之后、`open()`
  /// 之前被调用，所以这几条 `setProperty` 一定排在 `loadfile` 前面，不需要
  /// 调用方 `await`。（[NativePlayer.setProperty] 内部还会等播放器初始化
  /// 完成再真正发送，顺序依旧保持。）
  static Future<void> apply(Player player, {required bool tv}) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;

    final disableStreamCache = disableStreamCacheFor(tv: tv);
    if (disableStreamCache) {
      await platform.setProperty('cache', 'no');
      await _confirmStreamCacheOff(platform);
    } else {
      // TV：显式写 `yes` 而不是「什么都不设」。media_kit 硬编码的就是 `yes`，
      // 但显式设一遍能把它带进诊断日志 —— 真机排查时「这一项到底是什么」
      // 是要第一眼确认的。
      await platform.setProperty('cache', 'yes');
    }

    // 同步模式**显式**设为默认值 `audio`（音频当主时钟）。
    //
    // 电视上的音画不同步，绝大多数不是同步算法选错了，而是**视频解码跟不上
    // 音频** —— 掉帧之后 mpv 为了追上主时钟会跳帧，观感上就是「嘴动了声音
    // 没动」。所以这里不去换算法，只把默认写下来，目的有两个：
    //   1. 它会出现在诊断日志里，真机排查时能直接排除这一项；
    //   2. 挡住将来有人改成 `display-resample` —— 那是给**固定刷新率的桌面
    //      显示器**用的，电视上播 24p 片源会有可见的抖动。
    await platform.setProperty('video-sync', 'audio');

    await platform.setProperty(
      'demuxer-readahead-secs',
      readaheadSecsFor(tv: tv),
    );

    // 硬件解码：**只有 TV 会拿到非 null**（见 [tvHwdec]）。桌面一个字节都不动。
    // ⚠️ 必须在 `open()` 之前设 —— 与上面几条同理（`setProperty` 是同步投进
    // isolate 的命令队列，投递顺序即执行顺序）。
    final hwdec = hwdecFor(tv: tv);
    if (hwdec != null) {
      await platform.setProperty('hwdec', hwdec);
    }

    // 当前这套策略写进诊断日志：真机上报「还是卡」时，第一件要确认的事就是
    // 「它到底跑在哪一套参数上」—— 而这个信息在手机上和电视上是不同的。
    diag.info(
      '缓冲',
      '策略=${tv ? 'TV' : '桌面'} '
          '缓存=${(bufferSizeFor(tv: tv) ~/ (1024 * 1024))}MB '
          '预读=${readaheadSecsFor(tv: tv)}s '
          'stream缓存=${disableStreamCache ? '关' : '开'} '
          'hwdec=${hwdec ?? '未下发(mpv 默认=软解)'} '
          'video-sync=audio',
    );
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
