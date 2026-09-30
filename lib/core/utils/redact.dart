/// 敏感信息脱敏。
///
/// 原则：**任何凭证都不允许以明文形式进入日志、异常消息、崩溃上报**。
/// 需要打印时统一走这里。
library;

/// 把密钥/令牌/凭据值脱敏成 `<长度:前4位…>`。
///
/// 保留长度与前 4 位，足够排查「是不是同一个值 / 有没有被截断」，
/// 又不足以还原原值。
///
/// ```dart
/// maskSecret('7aa52fb080f2d75a1035') // => '<20B:7aa5…>'
/// maskSecret('abc')                 // => '<3B>'
/// ```
String maskSecret(String? value) {
  if (value == null || value.isEmpty) return '<empty>';
  if (value.length <= 8) return '<${value.length}B>';
  return '<${value.length}B:${value.substring(0, 4)}…>';
}

/// 对 `Map` 里的所有值脱敏，保留键名。
Map<String, String> maskMapValues(Map<String, String> input) =>
    {for (final e in input.entries) e.key: maskSecret(e.value)};

/// 脱敏一个 `Cookie:` 头字符串。
///
/// 形如 `__pus=<20B:7aa5…>; __puus=<80B:dfbc…>`
String maskCookieHeader(String header) {
  if (header.isEmpty) return '<empty>';
  return header.split(';').map((seg) {
    final s = seg.trim();
    if (s.isEmpty) return '';
    final eq = s.indexOf('=');
    if (eq <= 0) return s;
    return '${s.substring(0, eq)}=${maskSecret(s.substring(eq + 1))}';
  }).where((s) => s.isNotEmpty).join('; ');
}

/// 只保留 URL 的协议与主机路径，丢弃查询串（签名参数在其中）。
String redactUrl(Object? url) {
  final s = url?.toString() ?? '';
  if (s.isEmpty) return '<empty>';
  final uri = Uri.tryParse(s);
  if (uri == null) return '<unparsable:${s.length}B>';
  return '${uri.scheme}://${uri.host}${uri.path}';
}

/// 兜底脱敏：把文本里 `key=value` 形式的敏感值换成 `<redacted>`。
///
/// 这是**最后一道防线**，不是主要手段 —— 调用方该做的是压根不把敏感值
/// 拼进消息（用 [maskSecret] / [maskCookieHeader] / [redactUrl]）。
/// 它存在只是因为「手滑把 Cookie 或直链签名打进日志」的代价太高：
/// 日志文件会留在用户磁盘上，还会被复制粘贴出来求助。
///
/// ```dart
/// scrubSecrets('Cookie: __puus=abc123; __pus=def')
/// // => 'Cookie: __puus=<redacted>; __pus=<redacted>'
/// ```
String scrubSecrets(String text) {
  if (text.isEmpty) return text;
  return text.replaceAllMapped(_secretAssignment, (m) => '${m[1]}=<redacted>');
}

/// 只匹配「已知的凭证字段名 + 等号 + 值」，避免误伤正常文案。
final RegExp _secretAssignment = RegExp(
  r'\b(__puus|__pus|__kp|__uid|access_token|refresh_token|token|sign|auth|'
  r'cookie|password|pwd|secret)\s*=\s*([^&\s;,"]+)',
  caseSensitive: false,
);
