import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/utils/redact.dart';
import '../../data/auth/quark_qr_login.dart';
import '../../domain/entities/auth_credential.dart';
import '../../domain/entities/capabilities.dart';
import '../../domain/entities/drive_provider.dart';
import '../providers/app_providers.dart';
import '../providers/auth_providers.dart';
import '../theme/app_theme.dart';

/// 扫码登录页（主登录入口）。
///
/// 整条链路：取 token → 生成二维码 → 轮询（`uop.quark.cn`，无鉴权无签名）
/// → 用 `service_ticket` 兑换 `pan.quark.cn` 的 `__pus`/`__puus` Cookie
/// → 组装 `AuthCredential(AuthMode.qrCode)` 调 `authController.authorize`
/// 完成**真实登录**（`authorize` 会真打一次 `account/info` 校验）。
///
/// 页面把每个阶段的服务端回执与 Cookie 键原样展示出来，方便排查 ——
/// 扫码链路有四跳，任何一跳的字段改名都会让流程停在中间，看不到回执
/// 就只能靠猜。
class AuthQrLoginPage extends ConsumerStatefulWidget {
  const AuthQrLoginPage({super.key});

  @override
  ConsumerState<AuthQrLoginPage> createState() => _AuthQrLoginPageState();
}

/// 页面阶段。
enum _QrPhase {
  /// 正在取 token
  loading,

  /// 二维码已就绪，等待扫码
  waiting,

  /// 服务端给了确认回执
  confirmed,

  /// 正在用票据兑换账号 Cookie
  exchanging,

  /// 兑换成功并已触发登录
  loggedIn,

  /// token 失效 / 超时
  expired,

  /// 出错
  error,
}

class _AuthQrLoginPageState extends ConsumerState<AuthQrLoginPage> {
  _QrPhase _phase = _QrPhase.loading;
  QrLoginSession? _session;
  QrPollConfirmed? _confirmed;
  String? _detail;
  bool _revealToken = false;

  /// 兑换成功后拿到的账号 Cookie 键（**只存键名，不存值**）。
  List<String> _cookieKeys = const [];

  /// 兑换/登录阶段的错误文案。
  String? _loginError;

  Timer? _timer;
  DateTime? _startedAt;
  int _pollFailures = 0;

  /// 是否有一次轮询请求正在飞。
  ///
  /// `Timer.periodic` **不会等待**异步回调：网络慢于 [_pollInterval] 时，
  /// 上一次没回来下一次就又发出去了。两个请求同时挂着会出事 ——
  /// 后回来的那个如果带着 `QrPollConfirmed`，会二次走 [_finishLogin]
  /// （同一张 `service_ticket` 被兑换两次）；如果带着 `QrPollError`，
  /// 会把已经成功的登录态**改回 error**，用户看到「失败」但其实已登录。
  bool _polling = false;

  /// 轮询间隔。太快会被风控，太慢用户会觉得卡 —— 2s 是折中。
  static const Duration _pollInterval = Duration(seconds: 2);

  /// 二维码有效期兜底。服务端没告诉我们 TTL，超时就提示刷新。
  static const Duration _sessionTtl = Duration(minutes: 5);

  /// 连续轮询失败上限。单次失败**不该**终止流程 —— 网络抖一下很常见。
  static const int _maxPollFailures = 3;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    _timer?.cancel();
    setState(() {
      _phase = _QrPhase.loading;
      _session = null;
      _confirmed = null;
      _detail = null;
      _pollFailures = 0;
    });

    try {
      final session = await ref.read(qrLoginClientProvider).start();
      if (!mounted) return;
      setState(() {
        _session = session;
        _phase = _QrPhase.waiting;
        _startedAt = DateTime.now();
      });
      _beginPolling();
    } on QrLoginException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _QrPhase.error;
        _detail = e.message;
      });
    }
  }

  void _beginPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(_pollInterval, (_) => _pollOnce());
  }

  Future<void> _pollOnce() async {
    // 单飞：上一次还没回来就跳过这一拍，绝不并发。
    if (_polling) return;

    final session = _session;
    if (session == null || _phase != _QrPhase.waiting) return;

    final started = _startedAt;
    if (started != null && DateTime.now().difference(started) > _sessionTtl) {
      _timer?.cancel();
      setState(() {
        _phase = _QrPhase.expired;
        _detail = '二维码已超时，请刷新后重试';
      });
      return;
    }

    _polling = true;
    QrPollOutcome outcome;
    try {
      outcome = await ref.read(qrLoginClientProvider).poll(session);
    } on QrLoginException catch (e) {
      outcome = QrPollError(message: e.message);
    } catch (e) {
      // `poll` 自己抛异常（而不是返回 `QrPollError`）时必须也走「连续失败」
      // 计数，否则页面会一直空转、永远不给用户任何反馈。
      outcome = QrPollError(message: '轮询出错：$e');
    } finally {
      _polling = false;
    }

    if (!mounted) return;

    // 结果回来时状态可能已经变了：用户点了刷新（换了会话）、已经判超时、
    // 或已经在走兑换。陈旧的响应一律丢弃 —— 尤其不能让它把
    // `loggedIn` / `exchanging` 覆盖成 error。
    if (!identical(session, _session) || _phase != _QrPhase.waiting) return;

    switch (outcome) {
      case QrPollWaiting():
        _pollFailures = 0;
        // 正常态什么都不改 —— 每 2 秒 setState 会让二维码无谓重建。
        break;

      // 用显式模式绑定而不是依赖 switch 对 scrutinee 的类型提升 ——
      // `outcome` 是多分支赋值的非 final 局部，提升不保证生效。
      case QrPollConfirmed confirmed:
        _timer?.cancel();
        setState(() {
          _phase = _QrPhase.confirmed;
          _confirmed = confirmed;
          _detail = null;
        });
        _finishLogin(confirmed);

      case QrPollExpired(: final message):
        _timer?.cancel();
        setState(() {
          _phase = _QrPhase.expired;
          _detail = message.isEmpty ? '二维码已失效' : message;
        });

      case QrPollError(: final message):
        _pollFailures++;
        if (_pollFailures >= _maxPollFailures) {
          _timer?.cancel();
          setState(() {
            _phase = _QrPhase.error;
            _detail = message;
          });
        } else {
          setState(() => _detail = '$message（第 $_pollFailures 次，继续重试）');
        }
    }
  }

  /// 扫码确认后：取 `service_ticket` → 兑换账号 Cookie → 触发真实登录。
  Future<void> _finishLogin(QrPollConfirmed outcome) async {
    // 1. 从回执里取 service_ticket。
    final members = outcome.payload['members'];
    final ticket = members is Map ? members['service_ticket'] : null;
    if (ticket is! String || ticket.isEmpty) {
      if (!mounted) return;
      setState(() {
        _detail = '服务端回执里没有 service_ticket，无法继续兑换';
      });
      return;
    }

    if (!mounted) return;
    setState(() => _phase = _QrPhase.exchanging);

    // 2. 兑换票据 → 账号 Cookie。
    final cookies = await _exchange(ticket);
    if (cookies == null) return; // 已 setState 报错

    // 3. 组装凭证并触发登录。
    //
    // 只落库「已知 + 必需」的 Cookie（`filterQrCookiesForCredential`）：
    // 兑换会顺带带回 `_UP_*` / `ctoken` 等无关项，全写进安全存储是
    // 把无关凭据长期留在本机。
    final credential = AuthCredential(
      provider: DriveProvider.quark,
      mode: AuthMode.qrCode,
      capturedAt: DateTime.now(),
      cookies: filterQrCookiesForCredential(cookies.cookies),
    );
    final error =
        await ref.read(authControllerProvider.notifier).authorize(credential);
    if (!mounted) return;
    if (error == null) {
      setState(() {
        _phase = _QrPhase.loggedIn;
        _cookieKeys = cookies.keys;
        _loginError = null;
      });
    } else {
      setState(() {
        _phase = _QrPhase.error;
        _cookieKeys = cookies.keys;
        _loginError = error;
      });
    }
  }

  /// 兑换票据；失败时在页面上给出错误并返回 `null`。
  Future<QrLoginCookies?> _exchange(String ticket) async {
    try {
      final result =
          await ref.read(qrLoginClientProvider).exchangeServiceTicket(ticket);
      if (!mounted) return null;
      setState(() => _cookieKeys = result.keys);
      return result;
    } on QrLoginException catch (e) {
      if (!mounted) return null;
      setState(() {
        _phase = _QrPhase.error;
        _loginError = e.message;
      });
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 14, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => context.pop(),
                    iconSize: 18,
                    tooltip: '返回',
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _phase == _QrPhase.loading ? null : _start,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('刷新二维码'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      children: [
                        const Text(
                          '用夸克 App 扫码即可登录，全程不接触账号密码',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.6,
                            color: AppTheme.muted,
                          ),
                        ),
                        const SizedBox(height: 18),
                        _buildQrArea(),
                        const SizedBox(height: 18),
                        _buildStatus(),
                        const SizedBox(height: 20),
                        _buildDiagnostics(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQrArea() {
    const size = 208.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppTheme.panel2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.line, width: 0.5),
      ),
      alignment: Alignment.center,
      child: switch (_phase) {
        _QrPhase.waiting ||
        _QrPhase.confirmed ||
        _QrPhase.expired =>
          _session == null
              ? const Icon(Icons.hourglass_empty, color: AppTheme.dim)
              : ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: QrImageView(
                    // 二维码必须深色模块 + 浅色底才扫得出来，别跟主题走。
                    data: _session!.qrUrl.toString(),
                    version: QrVersions.auto,
                    size: size - 24,
                    backgroundColor: Colors.white,
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Colors.black,
                    ),
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Colors.black,
                    ),
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                  ),
                ),
        _QrPhase.loading || _QrPhase.exchanging => const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        _QrPhase.loggedIn => const Icon(
            Icons.check_circle_outline,
            size: 34,
            color: AppTheme.ok,
          ),
        _QrPhase.error => const Icon(
            Icons.wifi_off,
            size: 34,
            color: AppTheme.danger,
          ),
      },
    );
  }

  Widget _buildStatus() {
    final (text, color) = switch (_phase) {
      _QrPhase.loading => ('正在获取二维码…', AppTheme.muted),
      _QrPhase.waiting => ('用夸克 App 扫码确认', AppTheme.text),
      _QrPhase.confirmed => ('已拿到服务端回执', AppTheme.ok),
      _QrPhase.exchanging => ('正在兑换登录凭证…', AppTheme.text),
      _QrPhase.loggedIn => ('登录成功', AppTheme.ok),
      _QrPhase.expired => ('二维码已失效', AppTheme.warn),
      _QrPhase.error => ('出错了', AppTheme.danger),
    };

    return Column(
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: color,
          ),
        ),
        if (_detail != null) ...[
          const SizedBox(height: 8),
          Text(
            _detail!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              height: 1.6,
              color: AppTheme.muted,
            ),
          ),
        ],
        if (_loginError != null && _phase == _QrPhase.error) ...[
          const SizedBox(height: 8),
          Text(
            _loginError!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              height: 1.6,
              color: AppTheme.danger,
            ),
          ),
        ],
        if (_phase == _QrPhase.loggedIn) ...[
          const SizedBox(height: 10),
          const Text(
            '下次启动会自动恢复登录态。若发现播放异常，'
            '请在「诊断日志」里排查。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.7,
              color: AppTheme.ok,
            ),
          ),
        ],
        if (_phase == _QrPhase.confirmed) ...[
          const SizedBox(height: 10),
          const Text(
            '回执不含 service_ticket，无法继续兑换'
            '（通常是扫码端未真正确认）。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.7,
              color: AppTheme.warn,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDiagnostics() {
    final session = _session;
    final confirmed = _confirmed;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.line, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '调试信息',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppTheme.muted,
            ),
          ),
          const SizedBox(height: 10),
          if (session != null) ...[
            _kv('token', _revealToken ? session.token : maskSecret(session.token)),
            _kv('client_id', session.qrUrl.queryParameters['client_id'] ?? '-'),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _revealToken = !_revealToken),
                icon: Icon(
                  _revealToken ? Icons.visibility_off : Icons.visibility,
                  size: 14,
                ),
                label: Text(_revealToken ? '隐藏' : '显示原始值'),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _copy(session.qrUrl.toString()),
                icon: const Icon(Icons.copy, size: 14),
                label: const Text('复制二维码内容'),
              ),
            ),
          ],
          if (confirmed != null) ...[
            const Divider(height: 20, color: AppTheme.line),
            const Text(
              '服务端回执',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppTheme.muted,
              ),
            ),
            const SizedBox(height: 8),
            _kv('status', '${confirmed.status}'),
            _kv('payload 键', confirmed.payloadKeys.join(', ')),
            const SizedBox(height: 8),
            _MonoBlock(text: _safeEncode(confirmed.payload)),
          ],
          if (_cookieKeys.isNotEmpty) ...[
            const Divider(height: 20, color: AppTheme.line),
            const Text(
              '兑换到的账号 Cookie 键',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppTheme.muted,
              ),
            ),
            const SizedBox(height: 8),
            _kv('cookie 键', _cookieKeys.join(', ')),
          ],
        ],
      ),
    );
  }

  Widget _kv(String key, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 74,
              child: Text(
                key,
                style: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(fontSize: 11.5, color: AppTheme.text),
              ),
            ),
          ],
        ),
      );

  /// 把 payload 编成 JSON 展示。
  ///
  /// 编码失败时给占位而不是抛异常 —— 服务端可能返回 Dart 侧无法序列化的结构。
  static String _safeEncode(Map<String, Object?> payload) {
    try {
      return const JsonEncoder.withIndent('  ').convert(payload);
    } catch (_) {
      return '<无法序列化：${payload.keys.toList()}>';
    }
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制二维码内容')),
    );
  }
}

class _MonoBlock extends StatelessWidget {
  const _MonoBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.panel2,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(text, style: AppTheme.mono),
    );
  }
}
