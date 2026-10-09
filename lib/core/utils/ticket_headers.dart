import 'dart:io';

/// 把票据上的请求头贴到一条请求上，并**保证重定向之后它们仍然生效**。
///
/// ## 为什么不能只 `headers.forEach(request.headers.set)`
///
/// `dart:io` 的 `HttpClient` **自动跟随重定向时会丢掉 `User-Agent`** ——
/// 换成客户端级的默认值（`Dart/x.y (dart:io)`），而 `Range` / `Referer`
/// 却会保留。对百度的 **`origin=dlna` 直链**是致命的：
///
/// > 2026-10-09 实测（真实账号 + 真实直链，`curl` 对照）：
/// > 第一跳 `d.pcs.baidu.com/file/<fid>?...&sign=...` 回 **302**，
/// > 落点是 CDN 主机 `*.baidupcs.com`；而**第二跳的 `sign` 是按
/// > `User-Agent` 签的** —— 同一个 URL：
/// >
/// > | 第二跳的 `User-Agent` | 结果 |
/// > |---|---|
/// > | `netdisk` | `206 Partial Content` |
/// > | `Dart/3.7 (dart:io)` | `403 {"error_code":31362,"error_msg":"sign error"}` |
/// > | `pan.baidu.com` / `Mozilla/5.0` | 同上 403 |
/// >
/// > 于是现象是「**直链过期了**」（下载层把 403 归成 `urlExpired`），
/// > 排查会一路往「重新取链」上走 —— 而真正的原因在重定向那一跳。
///
/// 所以这里顺手把 [HttpClient.userAgent] 也设成票据里那一个：**重定向那一跳
/// 用的是客户端级默认值**，只有这样才能把 UA 带过去（已实测有效）。
///
/// ⚠️ 2026-10-09 傍晚定稿：**视频又回到 `origin=dlna` 直链了** —— 实测那是
/// 唯一能跑满带宽的通道（1.4~2.9 MB/s vs 普通通道 ~80 KB/s），而它只服务
/// 视频。所以本函数对**视频播放与视频下载是必需的**，不是「无害的保险」；
/// 对文档走的那条无 `origin` 直链，第二跳既不挑 UA 也不看 `Cookie`，
/// 那时它才只是保险。完整分流表见 `BaiduAdapter._resolveOriginalViaPathString`。
///
/// ## ⚠️ 会改动传入的 [client]
///
/// 改的是它的默认 UA。因此调用方必须是「一次请求一个客户端」的那种
/// （两个调用点用的 `_directClient()` 正是如此）。客户端复用的话，
/// 这一改会污染后续所有请求。
///
/// ## ⚠️ `Cookie` 也会在重定向时丢 —— 但现在**无害**
///
/// 同一次实测里还看到：Dart 对 `Cookie` 走的是自己的罐子，手工 `set` 的
/// 那一份**同样不会带到第二跳**。
///
/// 对百度现在的两条链这都不成问题：
///   - **视频**（`origin=dlna`，直链自带 `vuk`）：第一跳**不需要 `Cookie`**
///     （实测裸 `netdisk` UA 就回 302），第二跳按 UA 签、也不看它；
///   - **文档**（无 `origin`，无 `vuk`）：只在**第一跳**需要 `Cookie`
///     （不带就 `403 31045 user not exists`），而第一跳是我们自己发的、
///     **不经过重定向**。
///
/// 夸克的直链本身就是最终 CDN 地址、不跳。
///
/// 但哪天真遇到「第二跳也要 Cookie」，就得改成 `followRedirects = false`
/// + 自己逐跳贴头 —— 现在不做。
void applyTicketHeaders(
  HttpClient client,
  HttpClientRequest request,
  Map<String, String> headers,
) {
  applyTicketUserAgent(client, headers);
  headers.forEach(request.headers.set);
}

/// 把票据里的 `User-Agent` 设到**客户端级**（[HttpClient.userAgent]）。
///
/// ## 什么时候要单独用这个
///
/// [applyTicketHeaders] 是「票据头 + 客户端 UA」的合体，正常调用方用它就够了。
/// 但如果某个调用方**出于自己的原因**要手工贴头（比如中继的分块取块要过滤
/// 掉 hop-by-hop 头），就必须**额外**调一次本函数 —— 光把 UA set 到
/// `request.headers` 是不够的，302 之后那一跳认的只有客户端级的值。
///
/// 把它单独抽出来就是为了这个：2026-10-09 那天，下载层和透传路径都调了
/// [applyTicketHeaders]，唯独中继的分块取块手工贴头时漏了 UA ⇒
/// 百度 dlna 直链每次取块都 `403 31362 sign error`，**18304 次全失败**、
/// 视频一播就 `Failed to open`。同一个不变量散在多处，就一定会有一处漏。
void applyTicketUserAgent(HttpClient client, Map<String, String> headers) {
  final userAgent = headers['User-Agent'] ?? headers['user-agent'];
  if (userAgent != null && userAgent.isNotEmpty) {
    client.userAgent = userAgent;
  }
}
