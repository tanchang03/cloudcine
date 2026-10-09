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
  final userAgent = headers['User-Agent'] ?? headers['user-agent'];
  if (userAgent != null && userAgent.isNotEmpty) {
    client.userAgent = userAgent;
  }
  headers.forEach(request.headers.set);
}
