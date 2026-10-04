import '../entities/stream_ticket.dart';

/// 一次代理会话暴露给播放器的**本地**入口。
class RelayEndpoint {
  const RelayEndpoint({
    required this.uri,
    required this.token,
    required this.contentLength,
  });

  /// 本地地址：`http://127.0.0.1:<port>/<token>`。
  ///
  /// ⚠️ **只监听 loopback**：代理不带鉴权，token 只是防误撞。绑到
  /// `0.0.0.0` 等于把带签名的网盘直链开放给同一局域网里的任何人。
  final Uri uri;

  /// 会话标识，用于 [StreamRelay.close]。
  final String token;

  /// 源流的总字节数（代理已经确认过它支持 Range 才可能建会话）。
  final int contentLength;

  @override
  String toString() =>
      'RelayEndpoint(${uri.host}:${uri.port}, ${(contentLength / 1048576).round()} MiB)';
}

/// 代理的实时统计。**全部是真实计数，不是估算。**
class RelayStats {
  const RelayStats({
    required this.downloadedBytes,
    required this.cachedBytes,
    required this.activeWorkers,
    required this.upstreamFailures,
    required this.upstreamRequests,
    required this.upstreamConnects,
  });

  /// 累计从网盘拉到的字节数。
  final int downloadedBytes;

  /// 当前缓存里持有的字节数。
  final int cachedBytes;

  /// 正在拉取的并发数。
  final int activeWorkers;

  final int upstreamFailures;
  final int upstreamRequests;

  /// **新建上游连接**的次数（不是并发数，是累计开过多少条连接）。
  ///
  /// 这是判断「连接复用到底有没有生效」的唯一客观指标：
  /// 复用正常时它应当**远小于** [upstreamRequests]（理想情况等于 worker 数，
  /// 一块接一块复用同一条 TCP/TLS）；若两者量级接近，说明每块都在重连 ——
  /// 每 2 MiB 一次 TLS 握手，净吞吐被握手间隙切成锯齿，高码率原画必卡。
  final int upstreamConnects;

  /// 失败率。没发过请求时是 0 —— 「没试过」不等于「都失败了」。
  double get failureRate =>
      upstreamRequests == 0 ? 0 : upstreamFailures / upstreamRequests;

  /// 下载进度（0..1）。`contentLength` 为 0 时返回 null。
  double? progressOf(int contentLength) {
    if (contentLength <= 0) return null;
    return (downloadedBytes / contentLength).clamp(0.0, 1.0);
  }
}

/// 这条地址是不是 HLS（`media.m3u8`）。
///
/// 转码档签出来的就是它。它与原画的直链是**两套东西**：原画是一条带签名的
/// 字节流，HLS 是一份播放列表 + 一堆分片。中继对这两者用两条不同的服务路径
/// （见 `LocalStreamRelay` 里的 `_serve` 与 `_serveHls`）。
bool isHlsUrl(Uri url) => url.toString().toLowerCase().contains('.m3u8');

/// 这条流适不适合走本地中继。
///
/// ## ⚠️ 2026-10-04：HLS **也要**走中继了，这里从「排除 m3u8」改成「都放行」
///
/// 以前这里把 `.m3u8` 排除掉，理由是「分片是相对路径，走中继之后基准变成
/// `127.0.0.1`，拼出来的分片地址全指向我们自己」。那个理由本身没错，
/// **但绕开它的办法是改写列表**（见 `rewriteHlsForRelay`），而不是放弃中继。
///
/// 放弃中继的代价在那天变成了致命伤。夸克把转码档从**签名直链**换成了
/// `media.m3u8`，于是转码档第一次成了「不经中继、播放器直连 CDN」的流 ——
/// 而本机 `http_proxy` 环境变量指向一个为命令行准备的代理，ffmpeg 一读到它
/// 就改用 `httpproxy` 协议，那个协议不在 mpv 的 protocol whitelist 里：
///
/// ```
/// ffmpeg: httpproxy: Protocol 'httpproxy' not on whitelist 'udp,rtp,tcp,…'!
/// lavf: avformat_open_input() failed
/// ```
///
/// 分片一个都取不到，表现是「切到 4K/1080 只有声音没画面、两秒就 EOF」。
/// 原画一直没事，正因为**它走的是 `127.0.0.1` 的中继** —— ffmpeg 对回环地址
/// 不做代理。所以让转码档也回到回环上，是唯一能同时解决「相对路径」与
/// 「代理劫持」两个问题的位置。
///
/// 中继侧对 HLS 是**原样转发**：不做并发预取（上游本来就是分片并发下发的），
/// 只把「上游地址」换成 `127.0.0.1` 的入口。
bool isRelayableUrl(Uri url) => url.scheme == 'http' || url.scheme == 'https';

/// 把网盘直链**中继**成本地 HTTP 流。
///
/// ## 为什么需要它
///
/// 夸克原画的直链是**一条**源站连接，顺序读。网盘对单连接普遍有吞吐上限，
/// 于是 4K 原画（平均 13 Mbps、峰值 40 Mbps 以上）在一条 TCP 上永远追不上
/// 播放 —— 症状就是「缓冲看着不少，却每隔几十秒卡一下」。
/// 而夸克自己的播放器播同一个文件不卡，因为它不是单连接顺序读。
///
/// 本接口做的事就是补上那一段：起一个 loopback 服务，用**多个并发连接**
/// 按块预取源流、缓存在本地，mpv 从 `127.0.0.1` 读。单连接的吞吐上限被
/// N 倍绕过，seek 也能命中已缓存的块。
///
/// ## 为什么返回可空
///
/// [open] 返回 `null` 表示「这条路走不通，请直接播原链接」。走不通的情况
/// 包括：源流不支持 Range、长度未知、本地端口绑不上。**这些都不是错误** ——
/// 直连至少还能播，所以调用方拿到 null 时必须照常 `open` 原地址，
/// 而不是给用户弹一个「播放失败」。
abstract class StreamRelay {
  /// 为 [ticket] 建一条本地中继。**返回 null 表示不可用**（调用方回退直连）。
  ///
  /// [startOffset] 是**播放器即将从哪个字节开始读**（续播点换算成字节）。
  /// 中继据此把预取窗口放到那儿，而不是永远从文件头开始 —— 换清晰度 /
  /// 换集时续播点常在中后段，从 0 预取的那几百 MiB 全是白下的，而播放器
  /// 真正要的那一块还得现拉。给 0 就是「从文件头开始」，是默认行为。
  ///
  /// ⚠️ 它只是一个**提示**，不是契约：换算用「时长比例 × 文件大小」近似，
  /// 对 VBR 片源会有偏差。中继把它当成预取窗口的起点，播放器随后的真实
  /// Range 请求会立刻把窗口拉正，所以偏了只多下一点、不会播错。
  Future<RelayEndpoint?> open(
    StreamTicket ticket, {
    String? label,
    int startOffset = 0,
  });

  /// 某条会话的实时统计。会话已关闭返回 null。
  RelayStats? statsOf(String token);

  /// 当前会话数。`0` 表示此刻没有任何流在走中继。
  int get sessionCount;

  /// 全部会话的**汇总**统计。没有会话时返回 `null`。
  ///
  /// 诊断页靠它回答「中继到底在不在干活」。实测加速效果时这是唯一客观的
  /// 指标 —— 没有它就只能凭手感说「好像快了点」。
  RelayStats? get aggregateStats;

  /// 当前会话的来源标签（已脱敏），供诊断显示。
  List<String> get sessionLabels;

  /// 当前会话的源长度（字节）。没有会话时返回 `null`。
  int? get primaryContentLength;

  /// 关闭一条会话并释放它的缓存。重复调用无害。
  Future<void> close(String token);

  /// 关掉整个代理（含监听端口与全部会话）。
  Future<void> dispose();
}

/// 等 [token] 这条会话**预取到足够开播的数据**（或超时）。返回是否达标。
///
/// ## 它解决什么
///
/// 换清晰度 / 换集时，新会话刚建出来时缓存是空的。如果紧接着就 `open()`，
/// 播放器的第一次 Range 请求要等**一次完整的上游往返 + 一个块的下载**才拿到
/// 数据 —— 这段时间画面是停的，用户看到的就是「切一下就卡一下」。
///
/// 把这段等待**提前到 `open()` 之前**，代价就消失了：这期间**旧流还在播**，
/// 用户什么都不缺；等新会话备好了再切，播放器的第一个请求直接命中缓存。
///
/// ## 为什么是「轮询 statsOf」而不是加一个回调
///
/// 加回调要在 [StreamRelay] 上多一个成员，所有实现都得跟着改；而这里只需要
/// 一个**有上界**的就绪判断。用现成的 [StreamRelay.statsOf] 轮询既够用，
/// 又让这条逻辑对任何实现都成立 —— 拿不到统计（返回 null）就当没备好，
/// 由 [timeout] 兜底。
///
/// ## 参数
///
/// [minBytes] 是「备好」的门槛。默认 1 MiB：够覆盖一次首读与连接建立，
/// 又不至于在慢网下拖太久 —— 真正的量由 [timeout] 封顶。
Future<bool> warmUpRelay(
  StreamRelay relay,
  String token, {
  int minBytes = 1 << 20,
  Duration timeout = const Duration(milliseconds: 700),
  Duration pollInterval = const Duration(milliseconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final stats = relay.statsOf(token);
    // 会话没了（被关掉 / 建不起来）：不再等，交给调用方照常开流。
    if (stats == null) return false;
    if (stats.downloadedBytes >= minBytes) return true;
    if (!DateTime.now().isBefore(deadline)) return false;
    await Future<void>.delayed(pollInterval);
  }
}
