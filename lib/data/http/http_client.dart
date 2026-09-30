/// HTTP 抽象。
///
/// 适配器不直接依赖 `dio`，而是依赖这个极小的接口。好处：
///   1. 单元测试可以注入假客户端，**完全不发网络请求**就能覆盖
///      分页、错误码映射、限流、直链解析等全部逻辑；
///   2. 将来换 HTTP 库（或给 Web 端换成 `package:http`）不影响适配器。
///
/// 关键约定：**非 2xx 不抛异常**，而是照常返回 [HttpResult]。
/// 因为网盘的业务错误信息（`code` / `message`）就在响应体里，
/// 抛异常会把这份关键信息丢掉。
library;

import 'dart:typed_data';

/// 一次 HTTP 调用的结果。
class HttpResult {
  const HttpResult({
    required this.statusCode,
    this.json,
    this.jsonList,
    this.rawBody = '',
    this.headers,
  });

  /// 请求在网络层就失败了（DNS / 超时 / 连接被拒），没有拿到任何响应。
  const HttpResult.networkFailure(this.rawBody)
      : statusCode = 0,
        json = null,
        jsonList = null,
        headers = null;

  final int statusCode;

  /// 解析后的 JSON 体。响应体是 JSON **对象**时非空。
  final Map<String, Object?>? json;

  /// 解析后的 JSON 体。响应体是 JSON **数组**时非空。
  ///
  /// 单独一个字段而不是把数组硬塞进 [json]：网盘那套接口一律返回对象，
  /// 塞进去会让所有既有调用方多一层「这到底是哪种形状」的判断。
  /// 但确实存在返回顶层数组的接口（LRCLIB 的 `/api/search`），
  /// 而那种响应体原本会被**整段丢掉** —— [json] 为 `null`，[rawBody] 又只留
  /// 400 字符，连事后排查都做不到。
  final List<Object?>? jsonList;

  /// 原始响应体（截断保存，仅用于错误排查）。
  final String rawBody;

  /// 响应头（含 `set-cookie`）。
  ///
  /// 用于扫码登录的「票据 → Cookie」兑换：服务端在 302 的 `Set-Cookie`
  /// 里下发账号 Cookie（`__pus` / `__puus`），**必须不跟重定向**才能拿到。
  /// dio 给的是 `Map<String, List<String>>`（同名头可能多条）。
  final Map<String, List<String>>? headers;

  /// 取某个响应头（大小写不敏感）。同名多条合并为逗号分隔。
  String? header(String name) {
    final h = headers;
    if (h == null) return null;
    final lower = name.toLowerCase();
    for (final entry in h.entries) {
      if (entry.key.toLowerCase() == lower) {
        return entry.value.join(', ');
      }
    }
    return null;
  }

  /// 取 `set-cookie` 全部原始行（大小写不敏感）。兑换 Cookie 时用。
  List<String> get setCookieLines {
    final h = headers;
    if (h == null) return const [];
    for (final entry in h.entries) {
      if (entry.key.toLowerCase() == 'set-cookie') return entry.value;
    }
    return const [];
  }

  bool get isNetworkFailure => statusCode == 0;

  bool get isSuccessStatus => statusCode >= 200 && statusCode < 300;

  bool get hasJson => json != null;

  /// 响应体是 JSON 数组，且至少有一项。
  bool get hasJsonList => jsonList != null && jsonList!.isNotEmpty;

  /// 顶层数组里的对象项。非数组、或项不是对象时返回空列表。
  List<Map<String, Object?>> get jsonListItems {
    final list = jsonList;
    if (list == null) return const [];
    return list.whereType<Map<String, Object?>>().toList();
  }

  /// 便捷取顶层字段（网盘的 `code` / `message` / `data` 都在顶层）。
  Object? operator [](String key) => json?[key];

  /// 取业务码。网盘通常用 `code`，也兼容 `errno` / `status`。
  int? get businessCode {
    final j = json;
    if (j == null) return null;
    for (final key in const ['code', 'errno', 'status', 'error_code']) {
      final v = j[key];
      if (v is int) return v;
      if (v is String) {
        final parsed = int.tryParse(v);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  /// 取业务消息。
  String? get businessMessage {
    final j = json;
    if (j == null) return null;
    for (final key in const ['message', 'error_info', 'errmsg', 'msg']) {
      final v = j[key];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  /// 取 `data` 字段。
  Object? get data => json?['data'];

  /// 取 `data` 为对象时。
  Map<String, Object?>? get dataMap {
    final d = data;
    return d is Map<String, Object?> ? d : null;
  }

  /// 取 `data` 为数组时。
  List<Object?>? get dataList {
    final d = data;
    return d is List<Object?> ? d : null;
  }

  /// 取 `data.list`（列目录 / 搜索的固定形状）。
  List<Map<String, Object?>> get dataListItems {
    final d = data;
    if (d is Map<String, Object?>) {
      final list = d['list'];
      if (list is List) {
        return list.whereType<Map<String, Object?>>().toList();
      }
    }
    if (d is List) {
      return d.whereType<Map<String, Object?>>().toList();
    }
    return const [];
  }

  /// `data.total`（分页总数）
  int? get dataTotal {
    final d = data;
    if (d is Map<String, Object?>) {
      final t = d['total'];
      if (t is int) return t;
      if (t is num) return t.toInt();
    }
    return null;
  }

  @override
  String toString() =>
      'HttpResult($statusCode, code=$businessCode, keys=${json?.keys.take(6).toList()})';
}

/// 最小 HTTP 客户端契约。
abstract class HttpClientLike {
  Future<HttpResult> get(
    String url, {
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
    /// 是否自动跟随 3xx。扫码登录兑换 Cookie 时必须 `false`，
    /// 否则 dio 跟完 302 落到首页，会丢掉位于 302 响应里的 `Set-Cookie`。
    bool followRedirects = true,
  });

  Future<HttpResult> post(
    String url, {
    Object? body,
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
  });

  /// 取**原始字节**。网络层失败返回 `null`。
  ///
  /// 与 [get] 的分工是刻意的：
  ///   - [get] 面向 JSON 接口 —— 会尝试解析 JSON，并把 `rawBody` **截断**到
  ///     400 字符（防巨大响应体进内存），够排查不够当数据用；
  ///   - 本方法面向「小文件的原始内容」，必须**一字节不动**地拿到。
  ///
  /// 为什么不能拿 [get] 的字符串再转回去：网盘上的 CUE 分轨表大量是 GBK。
  /// 一旦按 UTF-8（或 latin1）解成字符串，非法字节已被替换成 `�`，
  /// 原始字节就再也还原不出来了 —— 编码判定必须发生在拿到字节之后
  /// （见 `decodeCueBytes`）。
  Future<Uint8List?> getBytes(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  });

  /// 释放底层连接池
  void close();
}
