import '../../core/utils/cookie_parser.dart';
import '../../core/utils/redact.dart';
import 'capabilities.dart';
import 'drive_provider.dart';

/// 一次授权拿到的凭证。
///
/// 这是**敏感数据**：只应存在于内存与系统钥匙串中，禁止写入普通文件、
/// 日志、异常消息。需要展示或打印时走 [redacted]。
class AuthCredential {
  const AuthCredential({
    required this.provider,
    required this.mode,
    required this.capturedAt,
    this.cookies = const {},
    this.tokens = const {},
    this.extra = const {},
  });

  /// 从 `Cookie:` 头字符串构造（浏览器抓取与手动粘贴共用）。
  factory AuthCredential.fromCookieString({
    required DriveProvider provider,
    required AuthMode mode,
    required String cookieString,
    DateTime? capturedAt,
  }) {
    return AuthCredential(
      provider: provider,
      mode: mode,
      capturedAt: capturedAt ?? DateTime.now(),
      cookies: parseCookieLooseText(cookieString),
    );
  }

  final DriveProvider provider;

  /// 凭证来源方式
  final AuthMode mode;

  final DateTime capturedAt;

  /// Cookie 名 → 值。夸克的关键键：`__pus` / `__puus`。
  final Map<String, String> cookies;

  /// OAuth 类凭证（access_token / refresh_token）
  final Map<String, String> tokens;

  /// 其他附加信息（设备标识、用户 ID 等）
  final Map<String, String> extra;

  bool get isEmpty => cookies.isEmpty && tokens.isEmpty;

  bool get isNotEmpty => !isEmpty;

  /// 组装 `Cookie:` 头的值。
  ///
  /// 夸克的会话键排在最前，方便排查。
  String get cookieHeader => buildCookieHeader(
        cookies,
        preferredOrder: const ['__pus', '__puus', '__kp', '__uid'],
      );

  /// 是否含某个 Cookie 键（值非空）
  bool hasCookie(String name) {
    final v = cookies[name];
    return v != null && v.isNotEmpty;
  }

  /// 是否含某个 token 键（值非空）
  bool hasToken(String name) {
    final v = tokens[name];
    return v != null && v.isNotEmpty;
  }

  /// 脱敏快照，可安全打日志。
  Map<String, Object?> get redacted => {
        'provider': provider.id,
        'mode': mode.id,
        'capturedAt': capturedAt.toIso8601String(),
        'cookies': maskMapValues(cookies),
        'tokens': maskMapValues(tokens),
        'extra': maskMapValues(extra),
      };

  AuthCredential copyWith({
    AuthMode? mode,
    DateTime? capturedAt,
    Map<String, String>? cookies,
    Map<String, String>? tokens,
    Map<String, String>? extra,
  }) {
    return AuthCredential(
      provider: provider,
      mode: mode ?? this.mode,
      capturedAt: capturedAt ?? this.capturedAt,
      cookies: cookies ?? this.cookies,
      tokens: tokens ?? this.tokens,
      extra: extra ?? this.extra,
    );
  }

  /// 判断两条凭证是否指向同一会话（只比对凭证内容，不比对时间）。
  ///
  /// 用于避免「重复授权」时无谓地覆盖钥匙串。
  bool isSameSessionAs(AuthCredential other) {
    if (provider != other.provider) return false;
    if (cookies.length != other.cookies.length) return false;
    for (final e in cookies.entries) {
      if (other.cookies[e.key] != e.value) return false;
    }
    if (tokens.length != other.tokens.length) return false;
    for (final e in tokens.entries) {
      if (other.tokens[e.key] != e.value) return false;
    }
    return true;
  }

  /// 是否已超过指定年龄（用于提示用户凭证可能过期）。
  bool isOlderThan(Duration age, {DateTime? now}) =>
      (now ?? DateTime.now()).difference(capturedAt) > age;

  @override
  String toString() =>
      'AuthCredential(${provider.id}, ${mode.id}, ${maskCookieHeader(cookieHeader)})';
}
