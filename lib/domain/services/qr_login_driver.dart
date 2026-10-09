/// 扫码登录的**统一驱动**。
///
/// ## 为什么需要这一层
///
/// 夸克与百度的扫码链路形状差得很远，但页面上的**阶段**是同一套：
///
/// | 阶段 | 夸克 | 百度 |
/// |---|---|---|
/// | 出码 | 服务端给一个 `token`，本地拼 URL 再画成二维码 | 服务端**直接给一张二维码图片** |
/// | 轮询 | `data` 非空 = 有进展 | `channel_v.status`：`1` 已扫 / `0` 已确认 / `2` 已取消 |
/// | 换票 | `service_ticket` → `__pus`/`__puus` | `channel_v.v` + `u` → `BDUSS` |
///
/// 没有这一层的话，`AuthQrLoginPage` 里会出现一堆 `if (provider == baidu)` ——
/// 而那是「新增网盘零改动」这条架构红线最不该破的地方。
///
/// ## 边界
///
/// 驱动**只负责拿凭证**，不认识 UI、不认识 `AuthController`。页面拿到
/// [QrProgressConfirmed] 之后调 [QrLoginDriver.exchange]，得到
/// [AuthCredential]，再交给 `AuthController.authorize` 做**真实校验**
/// （那一步会真打一次账号接口）。
///
/// ⚠️ 驱动**持有会话状态**（token / sign / 待兑换的回执），所以它是
/// **有生命周期的**：页面在 `dispose` 时必须调 [QrLoginDriver.dispose]。
/// 它不能做成 Riverpod 的 `family` —— family 会缓存实例，第二次进页面
/// 拿到的还是上一次那个会话。
library;

import 'dart:typed_data';

import '../entities/auth_credential.dart';
import '../entities/drive_provider.dart';

/// 二维码的内容形态。
sealed class QrChallenge {
  const QrChallenge();
}

/// 二维码是**一段文本**，由本地渲染成图形（夸克）。
class QrChallengePayload extends QrChallenge {
  const QrChallengePayload(this.payload);

  /// 二维码里要装的 URL —— 手机扫了之后打开的「端内登录确认页」。
  final Uri payload;
}

/// 二维码是**一张服务端渲染好的图片**（百度）。
class QrChallengeImage extends QrChallenge {
  const QrChallengeImage(this.imageUrl);

  /// 图片地址。可能带鉴权要求，取字节要走 [QrLoginDriver.qrImageBytes]。
  final Uri imageUrl;
}

/// 一次轮询的结果。
sealed class QrProgress {
  const QrProgress();
}

/// 还没有事件。继续轮询 —— **这不是错误**。
///
/// ⚠️ 两家的长轮询都会在无事件时**挂住十几到几十秒**（百度实测约 30 秒），
/// 而 HTTP 层超时会走 `isNetworkFailure`。那种超时**必须**映射到这里，
/// 不能映射到 [QrProgressFailure] —— 否则页面的「连续失败 3 次就报错」
/// 会在用户还没来得及掏出手机时就触发。
class QrProgressIdle extends QrProgress {
  const QrProgressIdle();
}

/// 已扫码，**等用户在手机上点「确认登录」**。
///
/// 只有百度会走到这里。单独一个状态而不是并进 [QrProgressIdle]：界面上
/// 这两句话完全不同（「请用 App 扫码」vs「已在手机上确认」），合并会让
/// 用户以为没扫上，反复重扫。
class QrProgressScanned extends QrProgress {
  const QrProgressScanned();
}

/// 用户已确认，可以换凭证了。页面此时应进入「兑换中」并调
/// [QrLoginDriver.exchange]。
class QrProgressConfirmed extends QrProgress {
  const QrProgressConfirmed();
}

/// 用户在手机上点了取消。
class QrProgressCancelled extends QrProgress {
  const QrProgressCancelled();
}

/// 二维码失效（超时 / `sign` 不存在 / `token` 不存在）。需要重新取码。
class QrProgressExpired extends QrProgress {
  const QrProgressExpired(this.message);

  final String message;
}

/// 可重试的失败（网络抖一下、非 2xx、没见过的形状）。
///
/// ⚠️ 与 [QrProgressExpired] 分开：前者刷新二维码没用，后者重试往往就好。
/// 合成一个的话，用户在网络抖动时会被引导去反复刷新二维码 —— 而
/// 百度取码是**有次数限制的**（`errno=50000`）。
class QrProgressFailure extends QrProgress {
  const QrProgressFailure(this.message);

  final String message;
}

/// 扫码登录驱动。实现见 `data/auth/quark_qr_driver.dart` 与
/// `data/auth/baidu_qr_driver.dart`。
abstract class QrLoginDriver {
  QrLoginDriver({required this.provider});

  /// 这家驱动属于哪个网盘。
  final DriveProvider provider;

  /// 第 1 跳：开一次会话，返回二维码内容。
  Future<QrChallenge> start();

  /// 第 2 跳：轮询一次。
  ///
  /// ⚠️ **单飞由调用方保证**（页面里那个 `_polling` 标志）。本方法不做并发
  /// 保护 —— 「同一时刻只允许一次」是调度问题，放在页面里比藏在驱动里
  /// 更容易看清，也更好测。
  Future<QrProgress> poll();

  /// 第 3 跳：用 [poll] 报出的「已确认」换账号 Cookie，组装成凭证。
  ///
  /// 只在 [poll] 刚返回过 [QrProgressConfirmed] 之后调用。失败抛
  /// `QrLoginException` / `BaiduQrLoginException`，由页面接住转成文案。
  Future<AuthCredential> exchange();

  /// 图片型二维码的原始字节。文本型（夸克）返回 `null`。
  ///
  /// 返回 `null` 表示**取不到**，页面应显示「二维码加载失败，点击重试」，
  /// 而不是中断整个登录流程 —— 图片可能只是被 CDN 抖了一下。
  Future<Uint8List?> qrImageBytes() async => null;

  /// 诊断行，页面**原样展示**。
  ///
  /// 扫码链路至少三跳，任何一跳的字段改名都会让流程停在中间 ——
  /// 看不到回执就只能靠猜，所以这几行不是装饰。
  ///
  /// ## 两个模式
  ///
  ///   - `reveal: false`（默认）：**值必须已脱敏**（走 `maskSecret`）。
  ///     这是常态，用户随手截图求助时不会把凭据一起发出去。
  ///   - `reveal: true`：原值。只有用户主动点「显示原始值」才会走到 ——
  ///     排查「服务端回的 sign 到底长什么样」时非它不可。
  ///
  /// ⛔ 脱敏放在驱动里而不是页面里：让页面负责脱敏，等于把「谁脱敏」
  ///    变成一条口头约定，而漏掉的表现是**凭据出现在截图上**。
  Map<String, String> diagnostics({bool reveal = false});

  /// 释放会话状态。页面 `dispose` 时必须调。
  void dispose() {}
}
