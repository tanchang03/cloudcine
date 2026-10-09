import 'dart:typed_data';

import '../../core/utils/redact.dart';
import '../../domain/entities/auth_credential.dart';
import '../../domain/entities/capabilities.dart';
import '../../domain/entities/drive_provider.dart';
import '../../domain/services/qr_login_driver.dart';
import 'baidu_qr_login.dart';

/// 百度的扫码登录驱动。
///
/// 把 [BaiduQrLoginClient] 的三跳（取二维码 → `unicast` 长轮询 → 换 BDUSS）
/// 包成 [QrLoginDriver] 那套统一阶段。
///
/// ## 与夸克的两处形态差异（都在这一个文件里吃掉）
///
///   1. **二维码是服务端渲染好的图片**：所以返回 [QrChallengeImage]，
///      页面走 [qrImageBytes] 取字节再 `Image.memory` 画出来 ——
///      本地拼不出这张图（`sign` 在服务端）。
///   2. **有「已扫待确认」这一态**（`channel_v.status == "1"`）：夸克没有，
///      所以页面必须处理 [QrProgressScanned] 这个分支。
///
/// ## ⛔ 长轮询的超时**不是失败**
///
/// `/channel/unicast` 无事件时会挂约 30 秒。`BaiduQrLoginClient.poll` 已经把
/// 网络层超时映射成 [BaiduQrWaiting]，本驱动照抄成 [QrProgressIdle] ——
/// 绝不能落到 [QrProgressFailure]，否则页面的「连续失败 3 次就报错」会在
/// 用户还没掏出手机时就触发（而百度取码是有次数限制的）。
class BaiduQrDriver extends QrLoginDriver {
  BaiduQrDriver({required BaiduQrLoginClient client})
      : _client = client,
        super(provider: DriveProvider.baidu);

  final BaiduQrLoginClient _client;

  BaiduQrSession? _session;

  /// 待兑换的确认回执（`channel_v.v` + `u`）。
  BaiduQrConfirmed? _confirmed;

  /// 兑换回来的 Cookie 键名（**只存键，不存值**），给诊断区展示。
  List<String> _cookieKeys = const [];

  /// 二维码图片字节的缓存。
  ///
  /// ⚠️ 必须缓存：页面每 2 秒轮询一次都会重建 widget 树，不缓存的话
  /// 每次重建都可能重新下载一遍图片 —— 那是每秒半次无用请求，而且
  /// 会让二维码在重建时闪一下。
  Uint8List? _qrImage;

  @override
  Future<QrChallenge> start() async {
    final session = await _client.start();
    _session = session;
    _confirmed = null;
    _cookieKeys = const [];
    _qrImage = null;
    return QrChallengeImage(session.imgUrl);
  }

  @override
  Future<QrProgress> poll() async {
    final session = _session;
    if (session == null) {
      return const QrProgressExpired('会话已失效，请刷新二维码');
    }

    final BaiduQrPollOutcome outcome;
    try {
      outcome = await _client.poll(session);
    } on BaiduQrLoginException catch (e) {
      return QrProgressFailure(e.message);
    } catch (e) {
      return QrProgressFailure('轮询出错：$e');
    }

    switch (outcome) {
      case BaiduQrWaiting():
        return const QrProgressIdle();

      case BaiduQrScanned():
        return const QrProgressScanned();

      case BaiduQrConfirmed confirmed:
        // 兑换放在 [exchange]：页面要靠这个分界显示「正在兑换登录凭证…」。
        _confirmed = confirmed;
        return const QrProgressConfirmed();

      case BaiduQrCancelled():
        return const QrProgressCancelled();

      case BaiduQrExpired(: final message):
        return QrProgressExpired(
          message.isEmpty ? '二维码已失效' : message,
        );

      case BaiduQrError(: final message):
        return QrProgressFailure(message);
    }
  }

  @override
  Future<AuthCredential> exchange() async {
    final confirmed = _confirmed;
    if (confirmed == null) {
      throw const BaiduQrLoginException('没有待兑换的回执，请重新扫码');
    }

    final result = await _client.exchange(confirmed);
    _cookieKeys = result.keys;

    return AuthCredential(
      provider: DriveProvider.baidu,
      mode: AuthMode.qrCode,
      capturedAt: DateTime.now(),
      // 换票会顺带带回 `BAIDUID` / `H_PS_*` / `ZFY` 等与网盘无关的 Cookie，
      // 落库只留已知 + 必需项。
      //
      // ⚠️ 但**落地网盘域**那一跳收到的（`PANWEB` / `PANPSC` …）必须放行：
      // 它们不在固定名单里，丢掉的后果与「没做落地」完全相同 ——
      // 网盘侧不认会话，`/api/account/uinfo` 回 `-6`。
      cookies: filterBaiduCookiesForCredential(
        result.cookies,
        extraNames: result.panCookieNames,
      ),
    );
  }

  @override
  Future<Uint8List?> qrImageBytes() async {
    final cached = _qrImage;
    if (cached != null) return cached;

    final session = _session;
    if (session == null) return null;

    final bytes = await _client.fetchQrImage(session);
    // ⚠️ 只缓存成功的结果。把 `null` 也缓存下来会让一次 CDN 抖动
    // 变成「二维码永远加载不出来，只能刷新整页」。
    if (bytes != null) _qrImage = bytes;
    return bytes;
  }

  @override
  Map<String, String> diagnostics({bool reveal = false}) {
    final session = _session;
    final confirmed = _confirmed;
    return {
      if (session != null)
        'sign': reveal ? session.sign : maskSecret(session.sign),
      if (session != null) 'gid': session.gid,
      if (session != null) 'imgurl': session.imgUrl.toString(),
      if (confirmed != null)
        '已确认': reveal ? 'v=${confirmed.v}' : '是（v=${maskSecret(confirmed.v)}）',
      if (_cookieKeys.isNotEmpty) 'cookie 键': _cookieKeys.join(', '),
    };
  }

  @override
  void dispose() {
    _session = null;
    _confirmed = null;
    _cookieKeys = const [];
    _qrImage = null;
  }
}
