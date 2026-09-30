/// Cookie 文本解析。
///
/// 两条链路都依赖它：
///   1. **浏览器抓取** —— 从 WebView 的 `CookieManager` 或 `document.cookie`
///      拿到 `k=v; k=v` 形式的字符串；
///   2. **手动粘贴** —— 用户从开发者工具复制，格式五花八门（见下）。
///
/// 因此提供两个入口：严格的 [parseCookieHeader] 与宽容的 [parseCookieLooseText]。
library;

/// 解析标准 `Cookie` 头：`k1=v1; k2=v2`。
///
/// 也容忍换行分隔（用户从 Network 面板复制时常带换行）。
///
/// 规则：
///   - 按**第一个** `=` 切分，因此值里的 `=`（base64 padding）不会被破坏；
///   - 值两侧的成对双引号会被剥掉；
///   - 空键、无 `=` 的片段直接跳过。
///
/// 注意：值的合法字符集不含 `;`，所以按 `;` 切分是安全的。
Map<String, String> parseCookieHeader(String raw) {
  final out = <String, String>{};
  if (raw.trim().isEmpty) return out;

  for (final segment in raw.split(RegExp(r'[;\n\r]+'))) {
    final s = segment.trim();
    if (s.isEmpty) continue;
    final eq = s.indexOf('=');
    if (eq <= 0) continue;
    final key = s.substring(0, eq).trim();
    if (key.isEmpty) continue;
    var value = s.substring(eq + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    out[key] = value;
  }
  return out;
}

/// 宽容解析：在 [parseCookieHeader] 基础上额外支持 `k: v` 形式。
///
/// 用户手动粘贴时常见这几种写法：
/// ```
/// __pus=7aa5...; __puus=dfbc...
/// __pus: 7aa5...
/// __puus: dfbc...
/// ```
/// 只有**当整行不含 `=`** 时才按冒号切分，避免把 base64 / JWT 值里的
/// `:` 误当成键值分隔符。
Map<String, String> parseCookieLooseText(String raw) {
  final out = <String, String>{};
  if (raw.trim().isEmpty) return out;

  // 先按标准规则吃一遍（能覆盖 `;` 分隔与换行分隔的 `k=v`）
  out.addAll(parseCookieHeader(raw));

  // 再逐行处理 `k: v` 形式
  for (final line in raw.split(RegExp(r'[\n\r]+'))) {
    final s = line.trim().replaceAll(RegExp(r'[;,]+$'), '');
    if (s.isEmpty) continue;
    if (s.contains('=')) continue; // 已由上面处理
    final colon = s.indexOf(':');
    if (colon <= 0) continue;
    final key = s.substring(0, colon).trim();
    final value = s.substring(colon + 1).trim();
    if (key.isEmpty || value.isEmpty) continue;
    out[key] = value;
  }
  return out;
}

/// 组装成 `Cookie:` 头的值。
///
/// 按 [preferredOrder] 指定的键顺序输出（把关键的会话键放前面，
/// 便于日志排查时一眼看到），其余键按插入顺序追加。
String buildCookieHeader(
  Map<String, String> cookies, {
  List<String> preferredOrder = const [],
}) {
  if (cookies.isEmpty) return '';
  final emitted = <String>{};
  final parts = <String>[];

  for (final key in preferredOrder) {
    final v = cookies[key];
    if (v != null && v.isNotEmpty) {
      parts.add('$key=$v');
      emitted.add(key);
    }
  }
  for (final e in cookies.entries) {
    if (emitted.contains(e.key) || e.value.isEmpty) continue;
    parts.add('${e.key}=${e.value}');
  }
  return parts.join('; ');
}
