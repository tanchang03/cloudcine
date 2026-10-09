import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../domain/entities/auth_credential.dart';
import '../../domain/entities/drive_provider.dart';
import '../../domain/services/qr_login_driver.dart';
import '../providers/app_providers.dart';
import '../providers/auth_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/tv_affordance.dart';
import '../widgets/tv_text.dart';

/// 二维码那一块外框的 key（测试用来量边长）。
///
/// 需要一个 key 才能在不建立真实扫码会话的前提下断言尺寸 —— 这个框
/// **任何阶段都渲染**（loading 时里面是转圈、错误时是图标），所以测试不必
/// 造一个假的网络客户端就能量到它。
@visibleForTesting
const Key qrAreaKey = Key('qr-login-area');

/// 二维码外框的边长。
///
/// ## 为什么不能写死 208
///
/// 208 是「人坐在电脑前 40 厘米」的尺寸。TV 上用户得退到 **3 米**外才看得全
/// 整个画面，208 的码在那个距离上糊成一团 —— 而「扫不出来」和「码没生成」
/// 在用户眼里是同一件事，他只会反复点「刷新二维码」
/// （见 `docs/AndroidTV-遥控器体验评估.md` 的 P2-6）。TV 上按官方建议取 **320**。
///
/// ## 为什么要夹到可用宽度
///
/// 被父级裁掉一角的二维码**永远扫不出来**，而且看起来完全正常 ——
/// 所以宁可画得比目标值小，也不许溢出：窗口被拉窄时跟着缩。
double qrEdgeFor({required bool tv, required double availableWidth}) {
  final wanted = tv ? 320.0 : 208.0;
  if (!availableWidth.isFinite || availableWidth >= wanted) return wanted;
  return availableWidth < 0 ? 0 : availableWidth;
}

/// 扫码登录页（主登录入口）。
///
/// ## 页面不认识任何一家网盘
///
/// 整条链路是「取码 → 轮询 → 换凭证 → `authorize`」，而每家网盘在这三跳里的
/// 形状差异（二维码是文本还是图片、有没有「已扫待确认」这一态）**全部收敛到
/// [QrLoginDriver] 后面**。所以这个文件里没有一处 `if (provider == baidu)`。
///
/// 页面把每个阶段的回执与 Cookie 键原样展示出来，方便排查 —— 扫码链路
/// 至少三跳，任何一跳的字段改名都会让流程停在中间，看不到回执就只能靠猜。
class AuthQrLoginPage extends ConsumerStatefulWidget {
  const AuthQrLoginPage({super.key, this.provider = DriveProvider.quark});

  /// 要登录哪一家。默认夸克 —— 它是这个键出现之前的唯一选择。
  final DriveProvider provider;

  @override
  ConsumerState<AuthQrLoginPage> createState() => _AuthQrLoginPageState();
}

/// 页面阶段。
///
/// ⚠️ 与 [QrProgress] **不是**一一对应：这里是**界面**状态（多出
/// `loading` / `exchanging` / `loggedIn`），那边是**协议**状态。
/// 合成一个的话，「正在兑换」这个纯界面态就得塞进协议枚举里。
enum _QrPhase {
  /// 正在取码
  loading,

  /// 二维码已就绪，等待扫码
  waiting,

  /// 已扫码，等用户在手机上点确认（**只有百度会走到**）
  scanned,

  /// 服务端给了确认回执，即将兑换
  confirmed,

  /// 正在用回执兑换账号凭证
  exchanging,

  /// 兑换成功并已触发登录
  loggedIn,

  /// 码失效 / 用户取消
  expired,

  /// 出错
  error,
}

class _AuthQrLoginPageState extends ConsumerState<AuthQrLoginPage> {
  _QrPhase _phase = _QrPhase.loading;

  /// 当前会话的驱动。**每次 [_start] 都换一个新的** ——
  /// 驱动持有会话状态，复用会把上一张码的 token/sign 带进来。
  QrLoginDriver? _driver;

  QrChallenge? _challenge;

  /// 图片型二维码的字节（百度的码是服务端画好的图）。
  ///
  /// 取不到时保持 `null`，界面显示「点击重试」而**不**中断登录流程 ——
  /// 图片可能只是被 CDN 抖了一下，而码本身是好的。
  Uint8List? _qrImage;

  String? _detail;
  bool _revealSecret = false;

  /// 兑换/登录阶段的错误文案。
  String? _loginError;

  Timer? _timer;

  /// 登录成功后的跳转定时器。
  ///
  /// 多家并存模型下路由**不再**把 `/auth*` 自动踢回 `/library`（否则已连
  /// 夸克的用户点不进百度的扫码页），所以登录成功后由本页**自己**跳回媒体库。
  /// 停留一会儿让用户看到「登录成功」再切走。
  Timer? _navTimer;
  DateTime? _startedAt;
  int _pollFailures = 0;

  /// 是否有一次轮询请求正在飞。
  ///
  /// `Timer.periodic` **不会等待**异步回调：网络慢于 [_pollInterval] 时，
  /// 上一次没回来下一次就又发出去了。两个请求同时挂着会出事 ——
  /// 后回来的那个如果带着 `confirmed`，会二次走 [_finishLogin]
  /// （同一张回执被兑换两次）；如果带着 `failure`，
  /// 会把已经成功的登录态**改回 error**，用户看到「失败」但其实已登录。
  bool _polling = false;

  /// 轮询间隔。太快会被风控，太慢用户会觉得卡 —— 2s 是折中。
  ///
  /// ⚠️ 百度的 `/channel/unicast` 是**长轮询**（无事件时挂约 30 秒），
  /// 所以「每 2 秒一次」实际是「上一跳回来后至少隔 2 秒再发下一跳」。
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
    _navTimer?.cancel();
    _driver?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    _timer?.cancel();
    _navTimer?.cancel();
    final previous = _driver;
    setState(() {
      _phase = _QrPhase.loading;
      _driver = null;
      _challenge = null;
      _qrImage = null;
      _detail = null;
      _loginError = null;
      _pollFailures = 0;
    });
    // 旧驱动在 setState 之后再释放：上面那几行读的是字段，先置空更安全。
    previous?.dispose();

    final driver = ref.read(qrLoginDriverFactoryProvider)(widget.provider);
    _driver = driver;

    try {
      final challenge = await driver.start();
      if (!mounted || !identical(driver, _driver)) return;
      setState(() {
        _challenge = challenge;
        _phase = _QrPhase.waiting;
        _startedAt = DateTime.now();
      });
      if (challenge is QrChallengeImage) {
        unawaited(_loadQrImage());
      }
      _beginPolling();
    } catch (e) {
      if (!mounted || !identical(driver, _driver)) return;
      setState(() {
        _phase = _QrPhase.error;
        _detail = _messageOf(e);
      });
    }
  }

  /// 取图片型二维码的字节。
  ///
  /// 失败**不改变阶段** —— 码本身是好的，只是图没下来。
  Future<void> _loadQrImage() async {
    final driver = _driver;
    if (driver == null) return;
    try {
      final bytes = await driver.qrImageBytes();
      if (!mounted || !identical(driver, _driver)) return;
      if (bytes == null) return;
      setState(() => _qrImage = bytes);
    } catch (_) {
      // 静默：界面会继续显示「点击重试」，用户点一下即可。
    }
  }

  void _beginPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(_pollInterval, (_) => _pollOnce());
  }

  /// 轮询是否还该继续。
  ///
  /// `scanned`（已扫待确认）**必须继续轮**，否则百度那条链路会停在
  /// 「已在手机上确认」而永远等不到确认回执。
  bool get _pollingActive =>
      _phase == _QrPhase.waiting || _phase == _QrPhase.scanned;

  Future<void> _pollOnce() async {
    // 单飞：上一次还没回来就跳过这一拍，绝不并发。
    if (_polling) return;

    final driver = _driver;
    if (driver == null || !_pollingActive) return;

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
    QrProgress progress;
    try {
      progress = await driver.poll();
    } catch (e) {
      // `poll` 自己抛异常（而不是返回 `QrProgressFailure`）时必须也走
      // 「连续失败」计数，否则页面会一直空转、永远不给用户任何反馈。
      progress = QrProgressFailure(_messageOf(e));
    } finally {
      _polling = false;
    }

    if (!mounted) return;

    // 结果回来时状态可能已经变了：用户点了刷新（换了驱动）、已经判超时、
    // 或已经在走兑换。陈旧的响应一律丢弃 —— 尤其不能让它把
    // `loggedIn` / `exchanging` 覆盖成 error。
    if (!identical(driver, _driver) || !_pollingActive) return;

    switch (progress) {
      case QrProgressIdle():
        _pollFailures = 0;
        // 正常态什么都不改 —— 每 2 秒 setState 会让二维码无谓重建。
        break;

      case QrProgressScanned():
        _pollFailures = 0;
        setState(() {
          _phase = _QrPhase.scanned;
          _detail = null;
        });

      case QrProgressConfirmed():
        _timer?.cancel();
        setState(() {
          _phase = _QrPhase.confirmed;
          _detail = null;
        });
        _finishLogin(driver);

      case QrProgressCancelled():
        _timer?.cancel();
        setState(() {
          _phase = _QrPhase.expired;
          _detail = '已在手机上取消登录，请重新扫码';
        });

      case QrProgressExpired(:final message):
        _timer?.cancel();
        setState(() {
          _phase = _QrPhase.expired;
          _detail = message.isEmpty ? '二维码已失效' : message;
        });

      case QrProgressFailure(:final message):
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

  /// 扫码确认后：换账号凭证 → 触发真实登录。
  Future<void> _finishLogin(QrLoginDriver driver) async {
    if (!mounted) return;
    setState(() => _phase = _QrPhase.exchanging);

    AuthCredential credential;
    try {
      credential = await driver.exchange();
    } catch (e) {
      if (!mounted || !identical(driver, _driver)) return;
      setState(() {
        _phase = _QrPhase.error;
        _loginError = _messageOf(e);
      });
      return;
    }
    if (!mounted || !identical(driver, _driver)) return;

    // `authorize` 会真打一次账号接口校验，并把「当前网盘」切到这家。
    final error =
        await ref.read(authControllerProvider.notifier).authorize(credential);
    if (!mounted) return;
    if (error == null) {
      setState(() {
        _phase = _QrPhase.loggedIn;
        _loginError = null;
      });
      // 登录成功：回到媒体库。多家并存模型下路由**不再**自动把 `/auth*`
      // 踢回 `/library`（授权页必须可达，才能添加第二家网盘），所以这里
      // 显式跳转。停留 900ms 让用户看到「登录成功」再切走。
      _navTimer?.cancel();
      _navTimer = Timer(const Duration(milliseconds: 900), () {
        if (mounted) context.go('/library');
      });
    } else {
      setState(() {
        _phase = _QrPhase.error;
        _loginError = error;
      });
    }
  }

  /// 把任意异常变成一句用户能读的话。
  ///
  /// 两家的登录异常都覆写了 `toString()` 让它返回消息本身，所以 `'$e'`
  /// 就够了 —— 不必在这里 `switch` 异常类型（那会把网盘名字带进页面）。
  static String _messageOf(Object e) => '$e';

  @override
  Widget build(BuildContext context) {
    // 过扫描边距**只加在顶栏上**，整页不加 —— 理由见下面那处 `Padding`。
    final safe = AppTheme.safeAreaInsets(context);
    final app = widget.provider.shortName;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              // ⛔ 只给顶栏加，**整页不加**。这一页的主角是那个 320 的二维码，
              // 它必须一进来就**完整可见**（缺一角的码永远扫不出来，而且看起来
              // 完全正常）。整页套一层过扫描边距会平白多出 54px 滚动量，
              // 把二维码推出首屏 —— 那是比「返回键被切一角」严重得多的回归。
              //
              // 而顶栏确实需要：那个返回键在 x=10、y=8，正好落进过扫描带里。
              // `/auth/qr` 与 `/work`、`/diagnostics` 一样在 `StatefulShellRoute`
              // 之外，拿不到 `AppShell` 那层内边距（见 `AppTheme.safeAreaInsets`）。
              padding: EdgeInsets.fromLTRB(
                10 + safe.left,
                8 + safe.top,
                14 + safe.right,
                0,
              ),
              child: Row(
                children: [
                  TvIconLabel(
                    label: '返回',
                    child: IconButton(
                      onPressed: () => context.pop(),
                      iconSize: 18,
                      tooltip: '返回',
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
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
                        Text(
                          '用$app App 扫码即可登录，全程不接触账号密码',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
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
    return LayoutBuilder(
      builder: (context, constraints) => _qrBox(
        qrEdgeFor(
          tv: AppTheme.isTvLayout(context),
          availableWidth: constraints.maxWidth,
        ),
      ),
    );
  }

  Widget _qrBox(double size) {
    return Container(
      key: qrAreaKey,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppTheme.panel2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.line, width: 0.5),
      ),
      alignment: Alignment.center,
      child: switch (_phase) {
        // 二维码在「等待 / 已扫 / 已确认 / 已失效」四个阶段都画出来 ——
        // 失效后仍显示，用户能对着它看出「这是刚才那张码」。
        _QrPhase.waiting ||
        _QrPhase.scanned ||
        _QrPhase.confirmed ||
        _QrPhase.expired =>
          _buildQrContent(size),
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

  Widget _buildQrContent(double size) {
    final challenge = _challenge;
    if (challenge == null) {
      return const Icon(Icons.hourglass_empty, color: AppTheme.dim);
    }

    return switch (challenge) {
      // 夸克：服务端只给 token，URL 本地拼，所以二维码本地画。
      QrChallengePayload(:final payload) => ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: QrImageView(
            // 二维码必须深色模块 + 浅色底才扫得出来，别跟主题走。
            data: payload.toString(),
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

      // 百度：二维码是**服务端画好的图片**（`sign` 在服务端，本地拼不出来）。
      QrChallengeImage() => _buildQrImage(size),
    };
  }

  Widget _buildQrImage(double size) {
    final bytes = _qrImage;
    if (bytes == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.image_not_supported_outlined, color: AppTheme.dim),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _loadQrImage,
            child: const Text('二维码加载失败，点击重试'),
          ),
        ],
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      // 百度给的图自带白底与静默区，别再垫一层背景 —— 垫了会多一圈边，
      // 扫起来反而更容易失败。
      child: Image.memory(
        bytes,
        width: size - 24,
        height: size - 24,
        fit: BoxFit.contain,
        // 关掉平滑：二维码缩放时插值会糊掉模块边缘。
        filterQuality: FilterQuality.none,
        gaplessPlayback: true,
      ),
    );
  }

  Widget _buildStatus() {
    final app = widget.provider.shortName;
    final (text, color) = switch (_phase) {
      _QrPhase.loading => ('正在获取二维码…', AppTheme.muted),
      _QrPhase.waiting => ('用$app App 扫码确认', AppTheme.text),
      _QrPhase.scanned => ('已扫码，请在手机上点「确认登录」', AppTheme.accent),
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
            '回执不完整，无法继续兑换（通常是扫码端未真正确认）。',
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
    final rows = _driver?.diagnostics(reveal: _revealSecret) ??
        const <String, String>{};
    if (rows.isEmpty) return const SizedBox.shrink();

    final challenge = _challenge;

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
          // ⚠️ 值在驱动那一侧脱敏（除非用户点了「显示原始值」）。这里只是
          // 照抄展示 —— 脱敏放在页面里会让「谁负责脱敏」变成一条口头约定，
          // 而漏掉的表现是**凭据出现在用户随手发的截图上**。
          for (final entry in rows.entries) _kv(entry.key, entry.value),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _revealSecret = !_revealSecret),
              icon: Icon(
                _revealSecret ? Icons.visibility_off : Icons.visibility,
                size: 14,
              ),
              label: Text(_revealSecret ? '隐藏原始值' : '显示原始值'),
            ),
          ),
          if (_revealSecret)
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                '原始值只用于排查，请勿外传。',
                style: TextStyle(fontSize: 11, color: AppTheme.dim),
              ),
            ),
          // 「复制二维码内容」对两家都有用，但复制的东西不同：
          // 夸克是那段 URL（可以贴进别的地方自己画码），百度是图片地址。
          if (challenge is QrChallengePayload)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _copy(challenge.payload.toString()),
                icon: const Icon(Icons.copy, size: 14),
                label: const Text('复制二维码内容'),
              ),
            )
          else if (challenge is QrChallengeImage)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _copy(challenge.imageUrl.toString()),
                icon: const Icon(Icons.copy, size: 14),
                label: const Text('复制二维码图片地址'),
              ),
            ),
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
              child: TvSelectableText(
                value,
                style: const TextStyle(fontSize: 11.5, color: AppTheme.text),
              ),
            ),
          ],
        ),
      );

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制')),
    );
  }
}
