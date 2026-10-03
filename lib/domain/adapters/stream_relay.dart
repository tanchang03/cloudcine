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
  });

  /// 累计从网盘拉到的字节数。
  final int downloadedBytes;

  /// 当前缓存里持有的字节数。
  final int cachedBytes;

  /// 正在拉取的并发数。
  final int activeWorkers;

  final int upstreamFailures;
  final int upstreamRequests;

  /// 失败率。没发过请求时是 0 —— 「没试过」不等于「都失败了」。
  double get failureRate =>
      upstreamRequests == 0 ? 0 : upstreamFailures / upstreamRequests;

  /// 下载进度（0..1）。`contentLength` 为 0 时返回 null。
  double? progressOf(int contentLength) {
    if (contentLength <= 0) return null;
    return (downloadedBytes / contentLength).clamp(0.0, 1.0);
  }
}

/// 这条流适不适合走本地中继。
///
/// ## 为什么 HLS 要排除
///
/// 转码档签出来的是 `media.m3u8`：它**本来就是分片并发下发**的，中继帮不上
/// 忙；更要命的是 m3u8 里的分片地址是**相对路径**，而 mpv 会把「m3u8 的
/// URL」当成基准去拼 —— 一旦走中继，基准变成 `127.0.0.1`，拼出来的分片
/// 地址全部指向我们自己的服务，而那里根本没有 m3u8 的内容。
///
/// 表现是「开了中继之后转码档反而播不了」，而原画照常 —— 一个极易被误判成
/// 「中继在某些文件上有 bug」的现象。
bool isRelayableUrl(Uri url) {
  if (url.scheme != 'http' && url.scheme != 'https') return false;
  final text = url.toString().toLowerCase();
  return !text.contains('.m3u8');
}

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
  Future<RelayEndpoint?> open(StreamTicket ticket, {String? label});

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
