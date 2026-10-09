/// 杜比视界（DV）探测的**取字节**与**缓存**两层。
///
/// 纯解析在 `core/utils/dolby_vision.dart`（那边不碰网络）。这里补上它缺的
/// 两件事：把「文件头部前 N 字节」取回来，以及「同一部片子只探一次」。
///
/// ## 为什么必须自己发 Range 请求，而不是走 `HttpClientLike.getBytes`
///
/// `getBytes` 会把**整个响应体**读进内存。网盘直链正常支持 Range，但
/// **服务端忽略 Range 回 200 是真实存在的**（下载那条路就专门为它写过
/// 「回 200 必须从 0 重写」的兜底）。一旦发生，`getBytes` 会把一部 4K 片源
/// （本项目那条样本是 7.5 GB）整个读进内存 —— 直接 OOM。
///
/// 所以这里**边收边数**：够了就主动断开，绝不按 `Content-Length` 收。
///
/// ## 为什么 256 KiB 够
///
/// DV 的映射记录在**文件很靠前**的位置（实测本项目那条 4K DV 片源在偏移
/// 439 字节处），而 Matroska 的 `Tracks` 也一定排在第一个 `Cluster` 之前。
/// 取多了只是白下载；取太少会在**某些文件**上静默探不到。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/dolby_vision.dart';
import '../../core/utils/ticket_headers.dart';

/// 取「文件头部前 [maxBytes] 字节」的能力。
///
/// 做成可注入的函数类型，是为了让单测**不碰真网络**就能覆盖
/// 「探到了 / 没探到 / 取字节失败」三条路。
typedef HeadBytesFetcher = Future<Uint8List?> Function(
  Uri url,
  Map<String, String> headers,
  int maxBytes,
);

/// 默认取字节实现：`dart:io` + Range + **硬上限**。
///
/// ⚠️ `findProxy = DIRECT` 不能省。本机的 `http_proxy` 是给命令行工具准备的，
/// `dart:io` 的 `HttpClient` 默认会读它 —— 少了这一句，探测请求会被代理掉，
/// 表现是「所有片源都探不到 DV」，而且是**静默**的（`null` 与「不是 DV」
/// 在接口上无法区分）。本地中继为同一个理由做过同一件事，两处口径要一致。
Future<Uint8List?> fetchHeadBytesDirect(
  Uri url,
  Map<String, String> headers,
  int maxBytes,
) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);
  client.findProxy = (Uri _) => 'DIRECT';

  try {
    final request = await client.getUrl(url);
    headers.forEach(request.headers.set);
    // ⛔⛔ 光把票据头 set 到 `request.headers` **不够**：直链回 302 时
    //      `dart:io` 会把 `User-Agent` 换成客户端级默认值
    //      （`Dart/x.y (dart:io)`），而百度 `origin=dlna` 直链**第二跳的
    //      `sign` 正是按 UA 签的** ⇒ 探测拿到 `403 31362 sign error`，
    //      按「不是 DV」处理返回 `null`。而 `null` 与「不是 DV」在接口上
    //      无法区分 ⇒ **DV P5 片源不换内核、画面偏绿**，且日志里一条错误
    //      都没有（2026-10-09 与中继分块取块是同一类漏洞）。
    //      只有设到**客户端级**才能熬过重定向 —— 见 [applyTicketUserAgent]。
    applyTicketUserAgent(client, headers);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${maxBytes - 1}');
    // 与取链那条路一致：不要压缩。带 gzip 拿到的不是文件的原始字节，
    // 而 EBML / ISO BMFF 的魔数判据是逐字节的。
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');

    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      diag.warn('DV', '探头部字节：上游回 ${response.statusCode}，按「不是 DV」处理');
      return null;
    }

    // ⚠️ 这里**故意不看** `Content-Length`。服务端忽略 Range 时它报的是整个
    // 文件的长度（几 GB），照着它收就是 OOM；而它也可能压根不报。
    // 唯一可信的是「已经收到多少」。
    final builder = BytesBuilder(copy: false);
    final completer = Completer<Uint8List?>();
    late StreamSubscription<List<int>> sub;
    sub = response.listen(
      (chunk) {
        builder.add(chunk);
        if (builder.length >= maxBytes) {
          // 收够了就断 —— 剩下的字节对我们毫无用处。
          unawaited(sub.cancel());
          if (!completer.isCompleted) {
            completer.complete(_take(builder, maxBytes));
          }
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(_take(builder, maxBytes));
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.complete(null);
      },
      cancelOnError: true,
    );
    return await completer.future;
  } catch (e) {
    diag.warn('DV', '探头部字节失败（按「不是 DV」处理）：$e');
    return null;
  } finally {
    // `force: true`：连接可能正卡在中途（上面主动 cancel 的那条），
    // 不强制关会等 keep-alive 超时，白白拖慢开播。
    client.close(force: true);
  }
}

Uint8List _take(BytesBuilder builder, int maxBytes) {
  final bytes = builder.takeBytes();
  if (bytes.length <= maxBytes) return bytes;
  return Uint8List.sublistView(bytes, 0, maxBytes);
}

/// 探一次杜比视界，并把结果缓存住。
///
/// ## 为什么要缓存
///
/// 「开播前探一次」在**每次换集 / 换清晰度**都会发生，而换的是同一份文件的
/// 另一条签名地址 —— 内容没变，答案也不会变。不缓存的话每次开播都多一次
/// 256 KiB 的往返，用户感受得到（尤其「下一集」连播时）。
///
/// ⚠️ 缓存键必须由**调用方**给（通常是 `fileId`），**不能拿 URL 当键**：
/// 网盘直链是带签名的临时地址，同一部片子每次取链都不一样 ——
/// 用 URL 当键等于永远不命中。
class DolbyVisionProbe {
  DolbyVisionProbe({HeadBytesFetcher? fetch, this.maxBytes = 256 * 1024})
      : _fetch = fetch ?? fetchHeadBytesDirect;

  final HeadBytesFetcher _fetch;

  /// 取多少头部字节去判。见库文档「为什么 256 KiB 够」。
  final int maxBytes;

  final Map<String, DolbyVisionInfo?> _cache = <String, DolbyVisionInfo?>{};

  /// 探 [key] 对应的片源。
  ///
  /// 返回 `null` 的两种含义（**调用方都不该当错误处理**，见
  /// `detectDolbyVision`）：这片源确实不是 DV，或者需要的元素不在取到的那
  /// 一段字节里（截断 / `moov` 后置）。两者无法区分，所以调用方的正确反应是
  /// 「按非 DV 处理」—— 也就是**维持现有行为**，而不是回退到别的内核。
  Future<DolbyVisionInfo?> probe({
    required String key,
    required Uri url,
    required Map<String, String> headers,
  }) async {
    if (_cache.containsKey(key)) return _cache[key];

    final bytes = await _fetch(url, headers, maxBytes);
    if (bytes == null || bytes.isEmpty) {
      // ⚠️ **不缓存失败**。网络抖一下就把这部片子永久钉成「不是 DV」，
      // 而它下一次很可能就探到了 —— 那会变成「同一部片子时好时坏」这种
      // 最难查的症状。失败与「确实不是 DV」必须区别对待。
      diag.warn('DV', '片源探测：$key 取字节失败，本次按非 DV 处理（不缓存）');
      return null;
    }

    final info = detectDolbyVision(bytes);
    _cache[key] = info;
    diag.info(
      'DV',
      '片源探测：$key → ${info?.toString() ?? '不是杜比视界'}'
          '（头部 ${bytes.length} 字节）',
    );
    return info;
  }

  /// 只查缓存，不发请求。没探过返回 `null`。
  DolbyVisionInfo? cached(String key) => _cache[key];

  /// 同一部片子重刮 / 换源后要重探时用。
  void forget(String key) => _cache.remove(key);

  void clear() => _cache.clear();
}
