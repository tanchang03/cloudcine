/// HLS 播放列表（`media.m3u8`）的**摘要**。
///
/// ## 为什么需要它
///
/// 夸克的转码档签出来的就是 `media.m3u8`。当它「播两三秒就 EOF」时，
/// 排查上最要紧的一个二选一是：
///
///   1. **播放列表本身就短**（服务端只给了几秒，或给的是预览档）；
///   2. 播放列表是完整的，是**播放器**没跟上（分片取不到、解码失败…）。
///
/// 这两条路的修法完全不同，而它们在我们这一层**看不出区别** ——
/// 用户的观感都是「只有声音没画面、几秒就跳下一集」。
/// 把 `#EXTINF` 的秒数加起来、数一下有几个分片，就能一眼分开：
/// 合计时长只有 6 秒 = 情况 1；合计时长 6000 秒 = 情况 2。
///
/// 只做**纯文本解析**，不发请求、不依赖 mpv —— 这样它能被单测直接喂字符串。
library;

/// 播放列表摘要。字段都是「看一眼就能定性」的那种。
class HlsPlaylistSummary {
  const HlsPlaylistSummary({
    required this.isMaster,
    required this.segmentCount,
    required this.totalDuration,
    required this.hasEndList,
  });

  /// 是不是 **master playlist**（`#EXT-X-STREAM-INF`）。
  ///
  /// 这条要紧是因为 master 里**没有** `#EXTINF`：它的 `segmentCount` 必然是 0，
  /// 而真正的分片列表在它指向的子播放列表里。分不清这一点的话，
  /// 「0 个分片」会被误读成「服务端给了个空列表」。
  final bool isMaster;

  /// `#EXTINF` 的条数（master 下恒为 0）。
  final int segmentCount;

  /// 所有 `#EXTINF` 秒数之和（master 下恒为 [Duration.zero]）。
  final Duration totalDuration;

  /// 有没有 `#EXT-X-ENDLIST` —— 有才是**点播**（VOD），没有是直播/事件流。
  ///
  /// ⚠️ 没有它时播放器**不会**在读完现有分片后报 EOF，而是等新分片；
  /// 所以「没有 ENDLIST 却很快 EOF」是另一种故障，别和上面那个混起来。
  final bool hasEndList;

  /// 供日志用的一行摘要。
  String describe() {
    if (isMaster) {
      return 'master 播放列表（分片列表在子列表里，本条不含 #EXTINF）'
          '${hasEndList ? '，带 ENDLIST' : ''}';
    }
    return '分片 $segmentCount 个，合计时长 ${totalDuration.inSeconds}s'
        '，${hasEndList ? '点播（有 ENDLIST）' : '⚠️ 没有 ENDLIST（会被当成直播）'}';
  }

  @override
  String toString() => 'HlsPlaylistSummary(${describe()})';
}

/// 取播放列表里**第一条分片地址**（`#EXTINF` 后面那一行）。
///
/// 只做纯文本提取，**不**解析相对路径 —— 调用方拿它去 `Uri.resolve`。
/// 找不到（空列表 / 全是注释行）返回 `null`。
///
/// ## 为什么需要它
///
/// `media.m3u8` 本身能取到（HTTP 200）**不等于分片能取到**：转码档的鉴权
/// 在分片那一层（`auth_key` 就挂在分片 URL 上），「m3u8 下得来、分片全 404」
/// 是完全可能的组合 —— 而它的观感正是「有声音没画面、几秒就 EOF」。
/// 所以诊断必须把分片也探一次，否则那条二选一永远只能靠猜。
///
/// master 列表下第一条非注释行是**子播放列表**的地址，探它同样有信息量
/// （能看出子列表取不取得到），所以这里不特意区分。
String? firstSegmentUri(String text) {
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    return line;
  }
  return null;
}

/// 解析一段 m3u8 文本。**不认识的行一律忽略**，绝不抛异常。
///
/// 宽容是有意的：这份解析只服务于诊断，一份畸形列表不该让诊断本身失败 ——
/// 那等于在最需要证据的时候把证据也弄丢了。
HlsPlaylistSummary summarizeHlsPlaylist(String text) {
  var isMaster = false;
  var hasEndList = false;
  var count = 0;
  var micros = 0;

  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#EXT-X-STREAM-INF')) {
      isMaster = true;
      continue;
    }
    if (line.startsWith('#EXT-X-ENDLIST')) {
      hasEndList = true;
      continue;
    }
    if (!line.startsWith('#EXTINF')) continue;

    count++;
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    // `#EXTINF:6.006,` —— 逗号后面是标题，可能带中文，先切逗号再解析数字。
    var value = line.substring(colon + 1);
    final comma = value.indexOf(',');
    if (comma >= 0) value = value.substring(0, comma);
    final seconds = double.tryParse(value.trim());
    if (seconds == null || seconds.isNaN || seconds <= 0) continue;
    micros += (seconds * Duration.microsecondsPerSecond).round();
  }

  return HlsPlaylistSummary(
    isMaster: isMaster,
    segmentCount: count,
    totalDuration: Duration(microseconds: micros),
    hasEndList: hasEndList,
  );
}
