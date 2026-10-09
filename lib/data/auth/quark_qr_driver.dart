import 'dart:typed_data';

import '../../core/utils/redact.dart';
import '../../domain/entities/auth_credential.dart';
import '../../domain/entities/capabilities.dart';
import '../../domain/entities/drive_provider.dart';
import '../../domain/services/qr_login_driver.dart';
import 'quark_qr_login.dart';

/// 夸克的扫码登录驱动。
///
/// 把 [QuarkQrLoginClient] 的三跳（取 token → 轮询 → `service_ticket` 换 Cookie）
/// 包成 [QrLoginDriver] 那套统一阶段。
///
/// ## 与百度的两处形态差异（都在这一个文件里吃掉）
///
///   1. **二维码是文本**：服务端只给一个 `token`，URL 由
///      [QuarkQrLoginClient.buildQrUrl] 本地拼 —— 所以返回
///      [QrChallengePayload] 而不是图片。
///   2. **没有「已扫待确认」这一态**：夸克的轮询要么「还没人扫」
///      （`Query result is empty`），要么直接给确认回执，中间那一步
///      不在协议里。所以本驱动**永不**返回 [QrProgressScanned]。
class QuarkQrDriver extends QrLoginDriver {
  QuarkQrDriver({required QuarkQrLoginClient client})
      : _client = client,
        super(provider: DriveProvider.quark);

  final QuarkQrLoginClient _client;

  QrLoginSession? _session;

  /// 待兑换的 `service_ticket`。
  ///
  /// 存它而不是存整个 [QrPollConfirmed]：`payload` 里可能带着别的敏感字段，
  /// 留一份在这里等于把「不该留的东西」留到 `dispose` 为止。
  String? _ticket;

  /// 兑换回来的 Cookie 键名（**只存键，不存值**），给诊断区展示。
  List<String> _cookieKeys = const [];

  @override
  Future<QrChallenge> start() async {
    final session = await _client.start();
    _session = session;
    _ticket = null;
    _cookieKeys = const [];
    return QrChallengePayload(session.qrUrl);
  }

  @override
  Future<QrProgress> poll() async {
    final session = _session;
    if (session == null) {
      return const QrProgressExpired('会话已失效，请刷新二维码');
    }

    final QrPollOutcome outcome;
    try {
      outcome = await _client.poll(session);
    } on QrLoginException catch (e) {
      return QrProgressFailure(e.message);
    } catch (e) {
      return QrProgressFailure('轮询出错：$e');
    }

    switch (outcome) {
      case QrPollWaiting():
        return const QrProgressIdle();

      case QrPollConfirmed confirmed:
        // 客户端在这一跳里只负责**报出**回执，兑换放在 [exchange] ——
        // 页面要靠这个分界显示「正在兑换登录凭证…」。
        final members = confirmed.payload['members'];
        final ticket = members is Map ? members['service_ticket'] : null;
        if (ticket is! String || ticket.isEmpty) {
          // 回执里没有 ticket 是**服务端形状变了**，重试没用。
          return const QrProgressFailure(
            '服务端回执里没有 service_ticket，无法继续兑换',
          );
        }
        _ticket = ticket;
        return const QrProgressConfirmed();

      case QrPollExpired(: final message):
        return QrProgressExpired(
          message.isEmpty ? '二维码已失效' : message,
        );

      case QrPollError(: final message):
        return QrProgressFailure(message);
    }
  }

  @override
  Future<AuthCredential> exchange() async {
    final ticket = _ticket;
    if (ticket == null) {
      throw const QrLoginException('没有待兑换的回执，请重新扫码');
    }

    final result = await _client.exchangeServiceTicket(ticket);
    _cookieKeys = result.keys;

    return AuthCredential(
      provider: DriveProvider.quark,
      mode: AuthMode.qrCode,
      capturedAt: DateTime.now(),
      // 只落库「已知 + 必需」的 Cookie：兑换会顺带带回 `_UP_*` / `ctoken`
      // 等无关项，全写进安全存储是把无关凭据长期留在本机。
      cookies: filterQrCookiesForCredential(result.cookies),
    );
  }

  /// 夸克是文本型二维码，没有图片可下载。
  @override
  Future<Uint8List?> qrImageBytes() async => null;

  @override
  Map<String, String> diagnostics({bool reveal = false}) {
    final session = _session;
    return {
      if (session != null)
        'token': reveal ? session.token : maskSecret(session.token),
      if (session != null)
        'client_id': session.qrUrl.queryParameters['client_id'] ?? '-',
      if (_cookieKeys.isNotEmpty) 'cookie 键': _cookieKeys.join(', '),
    };
  }

  @override
  void dispose() {
    _session = null;
    _ticket = null;
    _cookieKeys = const [];
  }
}
