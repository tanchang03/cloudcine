import 'package:flutter/foundation.dart';

/// 主窗口 → 播放窗口的「播这个」请求。
///
/// ## 为什么边界画在这里
///
/// 它**只带出画需要的东西**：直链、请求头、标题、起播位置，外加一个本地
/// 记录 id（只为回报进度用）。不带清晰度梯度、不带任何网盘凭证。
///
/// 这是刻意的，也是夸克网盘的做法：取链、鉴权、重试全部留在主窗口 ——
/// 那套逻辑的正确性只在主窗口验过（`QuarkAdapter` + 会话轮换 + 路由降级），
/// 播放窗口一旦也要自己取链，就得把这一整套复制一份，然后维护两个真相。
///
/// 反过来，播放窗口只做一件事：拿到一个能播的 URL 和它需要的请求头，出画。
/// 它甚至不知道「夸克」这个词。
///
/// ## 为什么请求头必须显式传
///
/// 夸克直链**缺 Cookie 一律 412**（见 `StreamTicket.headers` 的文档）。
/// 少了这一项的表现是「能取到链、一播就报错」，而错误信息里看不出是缺头。
@immutable
class PlayRequest {
  const PlayRequest({
    required this.url,
    required this.title,
    this.itemId = '',
    this.headers = const <String, String>{},
    this.qualityId,
    this.qualityLabel,
    this.startPosition = Duration.zero,
  });

  /// 直链地址（含签名查询串）
  final String url;

  /// 播放窗口标题栏/页头显示的片名
  final String title;

  /// 本地索引库里这一项的 id。
  ///
  /// **只为回报进度用**：播放窗口每 10 秒把位置报回主窗口，主窗口据此
  /// `markPlayed`。它不是凭证，只是我们自己的一个行号。
  ///
  /// 之所以进度要回主窗口落库而不是播放窗口自己写：数据库与仓储都装在主窗口，
  /// 播放窗口刻意不碰它们（见 `PlayerWindowApp` 的类文档）。
  ///
  /// 它同时是**能不能刷新直链的开关**：没有 id（自检视频、手输直链）就没法
  /// 让主窗口重新取链。
  final String itemId;

  /// 播放器必须携带的请求头
  final Map<String, String> headers;

  /// 当前档位的**机器可读标识**（`4k` / `super` 这类）。
  ///
  /// 与 [qualityLabel] 的区别：label 是给人看的（`4k(2160p)`），id 是给
  /// 服务端和自己看的。刷新直链时必须把 id 原样带回去 —— 只带 label 的话
  /// 主窗口只能退回「设置里的默认档位」，用户手选的档位会在一次刷新后
  /// **静默跳回默认**。
  final String? qualityId;

  /// 当前档位的人话标签（`4k(2160p)` 这类），仅用于显示
  final String? qualityLabel;

  /// 起播位置。切换清晰度后重建请求时用它续上，避免每次都从头开始。
  ///
  /// 刷新过期直链时也走这里：播放窗口把当前位置报上来，主窗口取到新链后
  /// 原样填回，于是刷新对用户表现为「卡一下接着播」而不是「从头开始」。
  final Duration startPosition;

  Map<String, Object?> toJson() => <String, Object?>{
        'url': url,
        'title': title,
        'itemId': itemId,
        'headers': headers,
        'qualityId': qualityId,
        'qualityLabel': qualityLabel,
        'startPositionMs': startPosition.inMilliseconds,
      };

  /// 从通道参数还原。**任何畸形输入都返回 null，不抛异常** ——
  /// 播放窗口拿到一个解不开的请求时，正确行为是安静地停在空舞台，
  /// 而不是崩掉一个刚起来的窗口。
  static PlayRequest? fromJson(Object? raw) {
    if (raw is! Map) return null;

    final url = raw['url'];
    if (url is! String || url.isEmpty) return null;

    final headers = <String, String>{};
    final rawHeaders = raw['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        final k = entry.key;
        final v = entry.value;
        if (k is String && v is String) headers[k] = v;
      }
    }

    final rawTitle = raw['title'];
    final rawItemId = raw['itemId'];
    final rawQualityId = raw['qualityId'];
    final rawLabel = raw['qualityLabel'];
    final ms = raw['startPositionMs'];

    return PlayRequest(
      url: url,
      title: rawTitle is String ? rawTitle : '',
      itemId: rawItemId is String ? rawItemId : '',
      headers: headers,
      qualityId: rawQualityId is String && rawQualityId.isNotEmpty
          ? rawQualityId
          : null,
      qualityLabel: rawLabel is String ? rawLabel : null,
      startPosition: Duration(milliseconds: ms is int && ms > 0 ? ms : 0),
    );
  }

  /// 供日志使用的**脱敏**摘要。
  ///
  /// ⚠️ 绝不能把 [url] 或 [headers] 直接打进日志：直链带签名查询串，
  /// headers 里有 Cookie。诊断日志是给用户复制粘贴用的，不能成为泄露渠道。
  String describe() {
    final q = qualityLabel;
    return q == null ? title : '$title（$q）';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlayRequest &&
          other.url == url &&
          other.title == title &&
          other.itemId == itemId &&
          other.qualityId == qualityId &&
          other.qualityLabel == qualityLabel &&
          other.startPosition == startPosition &&
          mapEquals(other.headers, headers);

  @override
  int get hashCode => Object.hash(
        url,
        title,
        itemId,
        qualityId,
        qualityLabel,
        startPosition,
        Object.hashAllUnordered(
          headers.entries.map((e) => Object.hash(e.key, e.value)),
        ),
      );

  @override
  String toString() => 'PlayRequest(${describe()})';
}

/// 播放窗口 → 主窗口的进度回报。
///
/// 它存在的唯一理由：**「最近播放」不能因为换了播放方式就失效**。
///
/// 内置播放页那条路，进度落库是主窗口的 `PlaybackController.onPositionTick`
/// 在调 `markPlayed`；而独立窗口这条路播放发生在另一个引擎里，主窗口的控制器
/// 根本没被 `open()` 过，那个回调永远不会触发 —— 于是 `lastPlayedAt` 不更新，
/// 「最近播放」排序与已看标记都停在上一次用内置播放页的时候。
///
/// ⚠️ `markPlayed` 落的是**时间戳**，不是播放位置（见
/// `MediaRepository.markPlayed`：它只写 `lastPlayedAt`，库里目前没有存续播
/// 位置的字段）。所以 [position] / [duration] 现在是**随报告一起带上但还没被
/// 消费**的：`position` 用来驱动节流（见 [ProgressThrottle]），两个字段一起
/// 留着是为了将来真要存续播位置时不必再改一次协议。
@immutable
class PlaybackProgressReport {
  const PlaybackProgressReport({
    required this.itemId,
    required this.position,
    this.duration = Duration.zero,
  });

  final String itemId;
  final Duration position;
  final Duration duration;

  Map<String, Object?> toJson() => <String, Object?>{
        'itemId': itemId,
        'positionMs': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
      };

  /// 畸形输入返回 null，不抛异常。**没有 itemId 就没有意义** ——
  /// 主窗口拿到它也不知道该更新哪一行。
  static PlaybackProgressReport? fromJson(Object? raw) {
    if (raw is! Map) return null;

    final itemId = raw['itemId'];
    if (itemId is! String || itemId.isEmpty) return null;

    final positionMs = raw['positionMs'];
    final durationMs = raw['durationMs'];

    return PlaybackProgressReport(
      itemId: itemId,
      position: Duration(
        milliseconds: positionMs is int && positionMs > 0 ? positionMs : 0,
      ),
      duration: Duration(
        milliseconds: durationMs is int && durationMs > 0 ? durationMs : 0,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackProgressReport &&
          other.itemId == itemId &&
          other.position == position &&
          other.duration == duration;

  @override
  int get hashCode => Object.hash(itemId, position, duration);

  @override
  String toString() =>
      'PlaybackProgressReport($itemId, ${position.inSeconds}s/${duration.inSeconds}s)';
}

/// 播放窗口 → 主窗口的「这条链失效了，再给我一条」请求。
///
/// 网盘的直链都是**带签名的临时 URL**，几十分钟就过期。过期后 mpv 在**下一次
/// 发起请求时**才会失败（seek 会重新发 Range 请求，所以最常见的表现是
/// 「播到一半拖进度条就报错」），而此时播放窗口手里只有一条死链 ——
/// 它自己没有重新取链的能力（没有凭证、也不该有）。
///
/// 所以这条回路的形状是：播放窗口报「我是谁、什么档位、播到哪了」，
/// 主窗口拿新链回来。
///
/// ⚠️ 刻意**不带 URL**：主窗口只需要知道「哪一项」，自己去重新取链。
/// 把旧链带回去只会让人忍不住去「复用」它。
@immutable
class TicketRefreshRequest {
  const TicketRefreshRequest({
    required this.itemId,
    this.qualityId,
    this.position = Duration.zero,
  });

  final String itemId;

  /// 当前档位标识，原样带回，保证刷新后还是同一档。
  final String? qualityId;

  /// 刷新发生时的播放位置。主窗口取到新链后把它填进
  /// [PlayRequest.startPosition]，刷新才不会把用户丢回片头。
  final Duration position;

  Map<String, Object?> toJson() => <String, Object?>{
        'itemId': itemId,
        'qualityId': qualityId,
        'positionMs': position.inMilliseconds,
      };

  /// 畸形输入返回 null。**没有 itemId 就刷不了**。
  static TicketRefreshRequest? fromJson(Object? raw) {
    if (raw is! Map) return null;

    final itemId = raw['itemId'];
    if (itemId is! String || itemId.isEmpty) return null;

    final qualityId = raw['qualityId'];
    final ms = raw['positionMs'];

    return TicketRefreshRequest(
      itemId: itemId,
      qualityId: qualityId is String && qualityId.isNotEmpty ? qualityId : null,
      position: Duration(milliseconds: ms is int && ms > 0 ? ms : 0),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TicketRefreshRequest &&
          other.itemId == itemId &&
          other.qualityId == qualityId &&
          other.position == position;

  @override
  int get hashCode => Object.hash(itemId, qualityId, position);

  @override
  String toString() =>
      'TicketRefreshRequest($itemId, ${qualityId ?? "-"}, ${position.inSeconds}s)';
}

/// 进度回报的节流器。
///
/// mpv 的 `position` 是每 ~100ms 一条的高频流，不能每条都跨引擎发一次 ——
/// 那会把方法通道变成每秒 10 次的噪音源，而续播位置只需要精确到秒。
///
/// 用「**整十秒边界**」当触发条件：天然节流，且不需要额外的计时器。
/// 与 `PlaybackController._maybeTickPosition` 是同一套办法 —— 两边各自
/// 独立实现是有意的：它们跨越了引擎边界，将来一边改节流粒度不该牵连另一边。
class ProgressThrottle {
  ProgressThrottle({this.intervalSeconds = 10});

  final int intervalSeconds;

  int _lastReportedSecond = -1;

  /// 喂一个位置；返回**需要上报**的位置，不需要上报时返回 null。
  Duration? accept(Duration position) {
    if (intervalSeconds <= 0) return null;
    final second = position.inSeconds;
    // 0 秒是「刚打开」，报上去只会把上次的进度覆盖成 0。
    if (second <= 0) return null;
    if (second % intervalSeconds != 0) return null;
    if (second == _lastReportedSecond) return null;
    _lastReportedSecond = second;
    return position;
  }

  /// 换片时重置。
  ///
  /// 不重置的话有个很难查的症状：新片恰好停在与上一部片**同一个**整十秒上时，
  /// 那一次回报会被当成重复而吞掉。
  void reset() => _lastReportedSecond = -1;
}

/// 「刷新直链」的重试闸。
///
/// 它防的是一个很容易写出来的死循环：
///
/// ```
/// mpv 报错 → 刷新直链 → 重开 → 还是报错 → 再刷新 → …
/// ```
///
/// 而**非时效性**的失败（文件损坏、编码不支持、网盘侧删了）刷新多少次都不会
/// 好 —— 那只会变成每几秒一次的取链请求 + 窗口反复重开。所以自动刷新必须
/// 有上限。
///
/// 光有上限还不够：一部长片里撞上两三次过期是正常的，用满之后整场都不能再
/// 刷新就太脆。所以要能**判定这次刷新是有效的**并清零。
///
/// 判定口径不能是「open 没抛异常」—— 失效的直链照样会被 mpv 接受，
/// 然后在解复用阶段才报错，那时 `open` 早就返回了。所以用两个条件同时成立：
///
///   1. 从刷新那一刻起，**时间**过去了至少 [healthyWindow]（期间没再报错）；
///   2. 位置**确实往前走了**至少 [healthyWindow]（不是停在原地反复重连）。
///
/// 条件 2 单看会有个假阳性：用户往后拖进度条会让位置一次性跳很远。
/// 条件 1 把这种跳变排除掉 —— 真出问题的话，mpv 在几秒内就会再报错。
class TicketRefreshGuard {
  TicketRefreshGuard({
    this.maxAttempts = 3,
    this.healthyWindow = const Duration(seconds: 30),
    this.minInterval = const Duration(seconds: 10),
  });

  /// 连续自动刷新的上限
  final int maxAttempts;

  /// 「这次刷新有效」所需的观察窗口
  final Duration healthyWindow;

  /// 两次**自动**刷新之间的最小间隔（去抖窗口）。
  ///
  /// ## 为什么必须有
  ///
  /// 一次 seek 失败不会只报一条 HTTP 403。ffmpeg 的 http 层带 reconnect
  /// 重试，mpv 又可能在 demux / cplayer 两层各报一次 —— 这些是**同一次故障
  /// 的回声**，间隔常在毫秒级。没有去抖的话，3 次自动刷新额度会被同一批错误
  /// 在几百毫秒内烧完，用户后面再遇到真的过期就一次额度都不剩了。
  ///
  /// ## 10 秒是怎么定的
  ///
  /// 刷新本身的往返是百毫秒级；ffmpeg 的 reconnect 退避在秒级。10 秒足够把
  /// 一次故障的全部回声收干净。而「刚刷完又立刻过期」基本不可能 ——
  /// 新链是刚签出来的，所以这个窗口不会挡住真正的第二次过期。
  final Duration minInterval;

  int _attempts = 0;
  Duration? _resumeAt;
  DateTime? _refreshedAt;

  /// 上一次**自动**刷新被批准的时刻。手动刷新走 [reset]，不记在这里。
  DateTime? _lastAutoAt;

  int get attempts => _attempts;

  bool get exhausted => _attempts >= maxAttempts;

  /// 申请一次自动刷新。
  ///
  /// 返回 true = 批准（已计数）；false = 拒绝，且**拒绝不消耗次数**。
  ///
  /// ⚠️ 返回 false 有**两种**原因，调用方必须分开对待：
  ///   - [exhausted] 为 true → 额度用满。该告诉用户「自动重试停了，可以手动」。
  ///   - [exhausted] 为 false → 只是还在 [minInterval] 冷却里。那是一次去抖，
  ///     **不该弹提示打扰用户** —— 一次故障的回声会连着弹好几条。
  ///
  /// [atPosition] 是刷新发生时的位置，[now] 是刷新时刻 —— 两者都用来在后面
  /// 判定这次刷新有没有用。**时钟由调用方注入**，否则这个判定只能靠 `sleep` 测。
  bool begin(Duration atPosition, {required DateTime now}) {
    if (exhausted) return false;
    final last = _lastAutoAt;
    if (last != null && now.difference(last) < minInterval) return false;
    _attempts++;
    _lastAutoAt = now;
    _resumeAt = atPosition;
    _refreshedAt = now;
    return true;
  }

  /// 喂当前播放位置与时刻。若这次刷新已被证明有效，清零并返回 true。
  ///
  /// 返回「是否刚刚清零」而不是新的计数，是为了让调用方只在真正恢复的那一次
  /// 打一行日志 —— 否则会跟着 position 流刷屏。
  bool observe(Duration position, {required DateTime now}) {
    final mark = _resumeAt;
    final at = _refreshedAt;
    if (mark == null || at == null) return false;
    if (now.difference(at) < healthyWindow) return false;
    if (position <= mark + healthyWindow) return false;

    _resumeAt = null;
    _refreshedAt = null;
    _lastAutoAt = null;
    _attempts = 0;
    return true;
  }

  /// 重置闸门。
  ///
  /// [now] 传了就把冷却窗口也一并重新起算；不传则**清掉**冷却。
  ///
  /// 两种调用场景要的东西正好相反，所以必须区分：
  ///   - **换片**（`_playRequest` / `_playRaw`）：`reset()`。新片是全新的流，
  ///     跟上一部片的冷却没有关系，清掉。
  ///   - **用户手动重新取链**：`reset(now: ...)`。手动刷新**照样会招来旧流
  ///     那批 403 回声**，不重新起冷却的话它们立刻就会把刚清空的额度烧掉。
  void reset({DateTime? now}) {
    _attempts = 0;
    _resumeAt = null;
    _refreshedAt = null;
    _lastAutoAt = now;
  }
}

// ---------------------------------------------------------------------------
// 从 mpv 日志里认出「直链过期」
// ---------------------------------------------------------------------------

/// ffmpeg 报 HTTP 状态码的格式串，形如 `HTTP error 403 Forbidden`。
///
/// **只认 4xx，不认 5xx**：4xx 是「这个请求不被接受」—— 签名过期（401/403）、
/// 缺 Cookie（夸克直链缺头会回 412）、资源被拒（404/410），这些「重新取一条链」
/// 都有救；5xx 是服务端自己出问题，重新取链解决不了，交给 mpv 自己的 reconnect
/// 更合适，硬刷只会白烧重试额度。
///
/// 这条格式串是从**产物里查出来的**（`Avformat.framework` 内有
/// `HTTP error %d %s`），不是猜的；同一个库里没有别的带状态码的报错措辞。
final RegExp _http4xxPattern = RegExp(r'http error 4\d\d', caseSensitive: false);

/// 判定一条 mpv 日志是不是「HTTP 4xx」。
///
/// ## 实测记录 —— 不要凭读源码的推断改这里
///
/// 下面这段是**跑出来的**。方法：用 Python ctypes 把产物里的 `Mpv.framework`
/// 拉起来（`DYLD_FRAMEWORK_PATH` 指向 app 的 Frameworks 目录），起一个「任何
/// 请求都回 403」的本地服务，让**真的** libmpv 去拉，打印它吐出的每一条日志。
///
/// ```
/// level='v'     prefix='ffmpeg'  text='Opening http://…'
/// level='warn'  prefix='ffmpeg'  text='http: HTTP error 403 Forbidden'
/// level='error' prefix='stream'  text='Failed to open http://… .'
/// level='v'     prefix='cplayer' text='Opening failed or was aborted: http://…'
/// ```
///
/// 三条结论，**每条都跟我最初读源码时的判断不一样**：
///
/// 1. **`HTTP error 403` 是 `warn` 级，不是 `error` 级。** 而
///    `mpv_request_log_messages` 的语义是「该级别**及以上严重**的消息才发」。
///    media_kit 默认请求 `error`，所以这条消息**根本不会被发到 Dart** ——
///    连它自己的前缀过滤都轮不到。这就是为什么 `PlayerWindowApp._ensurePlayer`
///    必须把 `PlayerConfiguration.logLevel` 抬到 `MPVLogLevel.warn`。
/// 2. 真正到达 `stream.error` 的是 `prefix='stream'` 的 `Failed to open <url>.`
///    —— prefix 是 `stream` 而**不是** `cplayer`（`cplayer` 那条是 `v` 级，
///    同样收不到）。而且它只在**打开阶段**失败时出现。
/// 3. 正文里带 `http: ` 前缀 —— mpv 把 av_log 的 context 名拼进了 text。
///
/// ### 场景二：流已建立、播放途中才 403（也就是最常见的那种）
///
/// 同一套方法，但第一个响应「声明完整长度、只给 64KB 就断线」，再 seek 到远处：
///
/// ```
/// level='warn'  prefix='ffmpeg'         text='http: HTTP error 403 Forbidden'
/// level='warn'  prefix='ffmpeg'         text='http: Will reconnect at 65536 in 0 second(s), error=Input/output error.'
/// level='error' prefix='ffmpeg'         text='http: Stream ends prematurely at 65536, should be 9799538'
/// level='error' prefix='ffmpeg'         text='Seek failed (to 8162141, size -78)'
/// level='error' prefix='ffmpeg/demuxer' text='mov,mp4,m4a,3gp,3g2,mj2: stream 0, offset …: partial file'
/// ```
///
/// **这个场景下 `stream.error` 一条都收不到。** 逐条对着 media_kit 的规则看：
/// `ffmpeg` 前缀要求 text 以 `tcp:` 开头，而它们要么以 `http:` 开头、要么以
/// `Seek` 开头；`ffmpeg/demuxer` 这个前缀根本不在白名单里。所以**唯一通路就是
/// 本函数 + 抬到 warn 的 `stream.log`** —— 这正是 `_ensurePlayer` 那行配置
/// 不能省的原因：少了它，用户实际会遇到的那种过期**一次都检测不到**。
///
/// 还有一条：一次 403 会**连出十几条**（ffmpeg 的 reconnect 退避是
/// 0s / 1s / 3s / 7s…，实测一次故障刷出 16 个请求）。这就是
/// [TicketRefreshGuard] 必须有冷却窗口的直接原因 —— 没有它，3 次自动刷新额度
/// 会在几秒内被同一批回声烧完。
///
/// ## 分工
///
/// 两条流各管一段，**刻意不重叠**：
///   - `stream.error` → `_onPlayerError`：管 `stream` 前缀的 `Failed to open`；
///   - `stream.log` → 本函数：管 `stream.error` **看不到**的 HTTP 4xx。
///
/// ## 为什么按内容匹配而不是按 prefix
///
/// 实测见到的 prefix 是 `ffmpeg`，但 mpv 给 ffmpeg 日志挂什么 prefix 取决于
/// av_log 的 context 名（也可能是 `http`）。状态码本身一定在正文里 ——
/// 按正文判，两种布局都命中。
bool isHttp4xxLog(String text) => _http4xxPattern.hasMatch(text);

/// URL 匹配：`http://` 或 `https://` 起，一直吃到空白字符。
///
/// `\S+` 会把结尾的句号一起吃掉 —— 换掉就好，见 [redactUrls] 里的补回。
final RegExp _urlPattern = RegExp(r'https?://\S+', caseSensitive: false);

/// 把文本里的直链抹掉，只留主机名。
///
/// ## 为什么必须有
///
/// mpv 的二级报错是 `Failed to open %s.`，那个 `%s` 是**完整 URL** —— 而夸克
/// 直链的签名就在查询串里。这条消息会一路走到 `diag.warn` 与「重新取链」的
/// 原因字段，也就是**落进诊断日志文件**。而诊断日志是给用户复制粘贴用的
/// （诊断页还专门做了「复制日志路径」按钮），绝不能成为签名泄露渠道。
///
/// 这与 `_openStream` 里「日志不打 url、请求头只打键名」是同一条规矩，
/// 区别只是那条报错**不是我们拼的**，只能事后抹。
///
/// 保留主机名是因为它有诊断价值（能看出是哪个 CDN 节点出的问题）；路径与
/// 查询串对排查没用、对泄露有用，所以一起抹掉。
String redactUrls(String message) {
  return message.replaceAllMapped(_urlPattern, (match) {
    final raw = match[0]!;
    final scheme =
        raw.toLowerCase().startsWith('http://') ? 'http://' : 'https://';
    // `\S+` 连结尾的句号都吃进来了。补回去，免得日志出现
    // 「…已抹去）」这种看起来像被截断的东西。
    final trailing = raw.endsWith('.') ? '.' : '';
    final host = Uri.tryParse(raw)?.host ?? '';
    if (host.isEmpty) return '$scheme（直链已抹去）$trailing';
    return '$scheme$host/…（直链签名已抹去）$trailing';
  });
}
