/// 把 m3u8 **改写成全部走本地中继**的版本。
///
/// ## 为什么必须改写（2026-10-04 的故障根因）
///
/// 夸克转码档签出来的是 `media.m3u8`，里面的分片是**相对路径**：
///
/// ```
/// #EXTINF:2.000,
/// media-41a74c07…-0.ts?auth_key=…&token=…&mt=3&ct=…
/// ```
///
/// 如果直接把这份列表原样交给播放器，播放器会拿**列表自己的地址**当基准去拼
/// 分片地址。列表一旦来自中继，基准就变成 `127.0.0.1`，于是分片也指向
/// `127.0.0.1` —— 而那里并没有分片。
///
/// 绕开它的办法不是「放弃中继」，而是**改写列表**：把每一行地址换成中继上
/// 的一个入口（`index.m3u8?u=<上游地址的 base64url>`），播放器取分片时自然
/// 又回到中继，由中继带着 Cookie 直连上游。
///
/// ## 为什么非要走中继不可
///
/// 转码档是本机唯一一条**播放器直连 CDN** 的流。而本机 `http_proxy` 环境变量
/// 指向一个为命令行准备的代理，ffmpeg 读到它就改用 `httpproxy` 协议 —— 那个
/// 协议不在 mpv 的 protocol whitelist 里：
///
/// ```
/// ffmpeg: httpproxy: Protocol 'httpproxy' not on whitelist 'udp,rtp,tcp,…'!
/// lavf: avformat_open_input() failed
/// ```
///
/// 分片一个都取不到 →「切到 4K/1080 只有声音没画面、两秒就 EOF」。
/// 原画一直没事，因为**它本来就走 `127.0.0.1` 的中继**，而 ffmpeg 对回环
/// 地址不做代理。让转码档也回到回环上，是唯一同时解决「相对路径」与
/// 「代理劫持」两个问题的位置。
///
/// master 列表（`#EXT-X-STREAM-INF`）里的子列表地址同样落在普通 URL 行上，
/// 所以这份改写对两种列表都成立，不需要先分辨。
library;

import 'dart:convert';

/// 中继上「取上游某个地址」的查询参数名。
const String relayTargetQueryKey = 'u';

/// 中继上播放列表/分片的固定路径段（相对于 `/<token>/`）。
///
/// 名字带 `.m3u8` 是有意的：mpv / ffmpeg 会按扩展名挑解复用器，虽然它也能
/// 靠内容嗅探认出 `#EXTM3U`，但没必要让解析器去猜。
const String relayEntryPath = 'index.m3u8';

/// 把一个上游绝对地址编码成可以安全放进查询串的字符串。
///
/// 用 base64url 而不是百分号编码：上游地址里带 `{` `}`（夸克的
/// `x-oss-process=if_status_eq_404{…}`）、`%3D`、`&`，逐字符转义既啰嗦又容易
/// 漏；base64url 的字母表是 `A-Za-z0-9-_`，放进查询串不需要再转义。
String encodeRelayTarget(String url) =>
    base64Url.encode(utf8.encode(url)).replaceAll('=', '');

/// [encodeRelayTarget] 的逆运算。解不开返回 `null`（调用方回 400）。
String? decodeRelayTarget(String encoded) {
  final pad = encoded.length % 4;
  final padded = pad == 0 ? encoded : encoded + '=' * (4 - pad);
  try {
    return utf8.decode(base64Url.decode(padded));
  } catch (_) {
    return null;
  }
}

/// 把一份 m3u8 改写成走本地中继的版本。
///
/// [playlistUrl] 是**这份列表自己的上游地址** —— 相对路径必须按它解析成绝对
/// 地址，否则中继不知道该去哪儿取。
///
/// 返回改写后的正文与改写掉的行数（诊断用）。
///
/// 空行与 `#` 开头的行**原样保留**：`#EXT-X-KEY` / `#EXT-X-MAP` 这些标签
/// 一旦丢一条，播放器就会用错解码参数，而那种故障比「播不出来」更难查。
({String body, int entryCount}) rewriteHlsForRelay(
  String text, {
  required Uri playlistUrl,
}) {
  var count = 0;
  final out = <String>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) {
      out.add(line);
      continue;
    }
    final absolute = playlistUrl.resolve(line);
    out.add(
      '$relayEntryPath?$relayTargetQueryKey=${encodeRelayTarget(absolute.toString())}',
    );
    count++;
  }
  return (body: out.join('\n'), entryCount: count);
}
