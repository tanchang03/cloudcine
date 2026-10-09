import 'quality_option.dart';

/// 一次播放所需的直链票据。
///
/// 网盘的直链都是**带签名的临时 URL**，通常几十分钟就过期。因此票据不是
/// 长期数据，只在「准备播放」这一刻有效。播放中失效时由播放引擎捕获
/// `403` / `urlExpired` 后重新取链并 seek 回原位置。
class StreamTicket {
  const StreamTicket({
    required this.url,
    this.headers = const {},
    this.expiresAt,
    this.contentLength,
    this.supportsRange = true,
    this.contentType,
    this.qualities = const [],
    this.maxConnections,
  });

  /// 直链地址（含签名查询串，**不要打进日志**）
  final Uri url;

  /// 播放器必须携带的请求头。
  ///
  /// 夸克实测：缺少 `Cookie` 时直链返回 `412 Precondition Failed`；
  /// 任何带 Cookie 的组合都返回 `206 Partial Content`。
  final Map<String, String> headers;

  final DateTime? expiresAt;

  /// 服务端声明的体积，可用于与索引库比对、校正本地记录
  final int? contentLength;

  /// 是否支持 HTTP Range（决定能否 seek）
  final bool supportsRange;

  final String? contentType;

  /// 该文件可选的清晰度档位。
  ///
  /// **空列表是一个有意义的状态**：表示服务端没有提供转码梯度，此时
  /// 只有 [url] 这一条原画流可播。UI 据此隐藏「清晰度」入口，
  /// 而不是显示一个只有一项的下拉框。
  ///
  /// [url] 与 [qualities] 的关系：`url` 是**默认要播的那条**（原画优先），
  /// 它必然也出现在 `qualities` 里（如果服务端给了梯度）。
  final List<QualityOption> qualities;

  /// 这条流**最多**能承受的并发连接数；`null` = 没有额外约束，用消费方默认值。
  ///
  /// 存在的理由：网盘的「多连接加速」只在**每条连接各自限速**的通道上成立。
  /// 2026-10-09 对百度两条通道实测（同一账号、同一份 Cookie、同一份文件）：
  ///
  /// | 通道 | 1 条 | 2 条 | 4 条 | 8 条 |
  /// |---|---|---|---|---|
  /// | `origin=dlna`（视频） | 1.1 MB/s | 2.0 MB/s | 3.1 MB/s | 4.1 MB/s |
  /// | 不带 `origin`（文档） | **82 KB/s** | 76 KB/s ❌ | 73 KB/s ❌ | 68 KB/s ❌ 被掐断 |
  ///
  /// 后者的限速是**按账号**的：加连接数完全不加总吞吐，只会让每条连接
  /// 都慢到读超时、最后被服务端掐断（`Connection closed while receiving
  /// data`）—— 表现正是「下载卡在 0% 不动，几分钟后报一个看不懂的错」。
  ///
  /// 所以「这条通道该开几条连接」这件事只有**取链的适配器**知道，
  /// 它把它写在票据上；下载服务照做，不再自己拍一个全局默认值。
  final int? maxConnections;

  /// 实际要用的并发连接数：票据给了上限就用它，否则用 [fallback]。
  ///
  /// 收敛到一处，避免「判分块时用一个数、真开连接时用另一个数」。
  int connectionsFor(int fallback) {
    final m = maxConnections;
    if (m == null) return fallback;
    return m < 1 ? 1 : m;
  }

  /// 服务端是否提供了多档清晰度。
  bool get hasQualityChoice => qualities.length > 1;

  /// 按标识取档位。
  QualityOption? qualityById(String id) {
    for (final q in qualities) {
      if (q.id == id) return q;
    }
    return null;
  }

  /// 换一条流（清晰度切换）。地址与体积一起换，避免新旧信息混在一起。
  ///
  /// 请求头与过期时间沿用原票据：夸克各档位流走同一个 CDN、同一套签名参数。
  ///
  /// ## ⚠️ 体积**不沿用旧值**：拿不到就留 `null`
  ///
  /// 这里原来写的是 `quality.estimatedBytes ?? contentLength` —— 服务端没给
  /// 这一档体积时**沿用上一条流的**。而换档时上一条流是**原画**，体积就是原
  /// 文件大小，于是「原画 17.09 GiB 的块布局」被套到「4.38 GiB 的 4K 转码流」
  /// 上：本地中继按错的总长切块、发越界的 `Range`，上游回 `416`，表现是
  /// **切到 4K 就黑屏**（有声音没画面，或直接报错）。
  ///
  /// 留 `null` 才是诚实的。下游看到「长度未知」会**跳过本地中继、直连播放** ——
  /// 少一点加速，但至少能播（见 `PlaybackController._prepareSource`）。
  StreamTicket withQuality(QualityOption quality) {
    final url = quality.url;
    if (url == null) return this;
    return StreamTicket(
      url: url,
      headers: headers,
      expiresAt: expiresAt,
      contentLength: quality.estimatedBytes,
      supportsRange: supportsRange,
      contentType: contentType,
      qualities: qualities,
      // 换档不换通道：并发上限是**通道**的属性，与档位无关。
      maxConnections: maxConnections,
    );
  }

  /// 决定「当前应该用哪一档」。
  ///
  /// 优先级：调用方给的默认档 → 原画 → 第一个可用档 → 第一档。
  ///
  /// **原画优先**是刻意的：转码流会丢细节，而本应用的用户把片子放在网盘上
  /// 就是想要原片质量。只有用户显式选了别的档位才用别的。
  ///
  /// 返回 `null` 表示服务端没给转码梯度（[qualities] 为空），此时 [url]
  /// 就是唯一可播的那条。
  ///
  /// 放在实体上而不是播放控制器里：**独立播放窗口那条路也要用同一套规则**
  /// （主窗口取到票据后要据此决定把哪一档的地址发给播放窗口）。判定规则只能
  /// 有一处 —— 两处各写一份的话，内置播放页和独立窗口选的档位迟早会不一样。
  String? pickActiveQualityId([String? preferred]) {
    if (qualities.isEmpty) return null;

    if (preferred != null && preferred.isNotEmpty) {
      final q = qualityById(preferred);
      if (q != null && q.isAvailable) return q.id;
    }
    for (final q in qualities) {
      if (q.isOriginal && q.isAvailable) return q.id;
    }
    for (final q in qualities) {
      if (q.isAvailable) return q.id;
    }
    return qualities.first.id;
  }

  /// 是否已过期。
  ///
  /// 提前 [earlyMargin] 判定，避免「刚取到就过期」导致播放中途断流。
  bool get isExpired => isExpiredAt(DateTime.now());

  /// 距离过期的剩余时间。未知返回 `null`。
  Duration? get remaining => remainingAt(DateTime.now());

  /// 在指定时刻是否已过期。
  ///
  /// 与 [isExpired] 的区别是**时钟可注入** —— 票据缓存与播放引擎的
  /// 续链判定都必须能在单元测试里精确控制时间，否则只能靠 `sleep` 测。
  bool isExpiredAt(DateTime now) {
    final e = expiresAt;
    if (e == null) return false;
    return now.isAfter(e.subtract(earlyMargin));
  }

  /// 在指定时刻距离过期还有多久。未知返回 `null`。
  Duration? remainingAt(DateTime now) {
    final e = expiresAt;
    if (e == null) return null;
    final d = e.difference(now);
    return d.isNegative ? Duration.zero : d;
  }

  /// 提前判定过期的安全余量
  static const Duration earlyMargin = Duration(seconds: 30);

  bool get needsHeaders => headers.isNotEmpty;

  /// 脱敏后的地址，仅保留协议与主机路径，可安全打日志。
  String get redactedUrl => '${url.scheme}://${url.host}${url.path}';

  @override
  String toString() => 'StreamTicket($redactedUrl, '
      'headers=${headers.keys.join(",")}, expires=$expiresAt, '
      'len=$contentLength, range=$supportsRange, '
      'conns=${maxConnections ?? "-"}, '
      'qualities=${qualities.length})';
}
