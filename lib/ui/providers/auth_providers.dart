import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/error/drive_error.dart';
import '../../domain/entities/auth_credential.dart';
import '../../domain/entities/cloud_account.dart';
import '../../domain/entities/drive_provider.dart';
import 'app_providers.dart';

/// 授权状态快照。
class AuthState {
  const AuthState({
    this.account,
    this.error,
    this.busy = false,
    this.canPersist = true,
  });

  /// 已授权的账号，`null` 表示尚未授权
  final CloudAccount? account;

  /// 最近一次失败原因，面向用户
  final String? error;

  /// 是否正在执行授权/登出
  final bool busy;

  /// 凭证能否持久化。`false` 时 UI 要提示「本次会话有效，重启需重新登录」。
  final bool canPersist;

  bool get isAuthorized => account != null;

  AuthState copyWith({
    CloudAccount? account,
    String? error,
    bool clearAccount = false,
    bool clearError = false,
    bool? busy,
    bool? canPersist,
  }) {
    return AuthState(
      account: clearAccount ? null : (account ?? this.account),
      error: clearError ? null : (error ?? this.error),
      busy: busy ?? this.busy,
      canPersist: canPersist ?? this.canPersist,
    );
  }
}

/// 授权控制器。
///
/// 启动时用安全存储里的凭证恢复会话；恢复失败（凭证已失效）会**清掉本地凭证**
/// 并回到未授权状态，而不是每次启动都弹一次同样的错误 —— 后者会让用户
/// 以为应用坏了，实际只需要重新扫一次码。
class AuthController extends AsyncNotifier<AuthState> {
  @override
  Future<AuthState> build() async {
    final store = ref.watch(credentialStoreProvider);
    final adapter =
        ref.watch(adapterRegistryProvider).adapterFor(DriveProvider.quark);
    if (adapter == null) {
      return const AuthState(error: '夸克网盘适配器未注册');
    }

    try {
      final account = await adapter.restoreSession();
      return AuthState(
        account: account,
        canPersist: store.supportsPersistence,
      );
    } on DriveException catch (e) {
      // 凭证存在但服务端不认了：清掉，让用户重新登录一次即可。
      await adapter.signOut();
      return AuthState(error: e.message, canPersist: store.supportsPersistence);
    } catch (e) {
      return AuthState(
        error: '恢复会话失败：$e',
        canPersist: store.supportsPersistence,
      );
    }
  }

  void _emit(AuthState next) => state = AsyncData(next);

  AuthState get _current => state.valueOrNull ?? const AuthState();

  /// 用一份凭证完成授权。成功返回 `null`，失败返回错误文案。
  Future<String?> authorize(AuthCredential credential) async {
    _emit(_current.copyWith(busy: true, clearError: true));

    try {
      final adapter = ref
          .read(adapterRegistryProvider)
          .requireAdapter(credential.provider);
      final account = await adapter.authorize(credential);

      _emit(
        AuthState(
          account: account,
          canPersist: ref.read(credentialStoreProvider).supportsPersistence,
        ),
      );
      return null;
    } on DriveException catch (e) {
      _emit(_current.copyWith(busy: false, error: e.message));
      return e.message;
    } catch (e) {
      final message = '授权失败：$e';
      _emit(_current.copyWith(busy: false, error: message));
      return message;
    }
  }

  /// 重新拉一次账号信息。
  ///
  /// ## 为什么需要它
  ///
  /// [AuthState.account] 里的**已用容量是一份快照** —— 它在授权/恢复会话那一刻
  /// 取到，之后用户传片、删片、清理空间都不会自己更新。文件夹页头那条容量条
  /// 要显示「还剩多少」，就必须有一条重新问一次的路径。
  ///
  /// ## 为什么失败时**不写 error**
  ///
  /// 容量条是文件夹页上的**附属信息**，不是那一页的功能。为了一次容量刷新
  /// 失败把 `AuthState.error` 置上，侧栏与登录页会冒出「授权失败」—— 而会话
  /// 其实好好的，用户会跑去重新登录一次。所以这里只记诊断日志，界面保持原值。
  ///
  /// 未授权时直接返回：这一条只服务于「已经在用」的账号。
  Future<void> refreshAccount() async {
    if (!_current.isAuthorized) return;
    final adapter =
        ref.read(adapterRegistryProvider).adapterFor(DriveProvider.quark);
    if (adapter == null) return;

    try {
      final account = await adapter.refreshAccount();
      if (account == null) return;

      // ⚠️ 必须**重新取一次**最新状态，不能用 await 之前那份快照拼回去：
      // 这是一次网络往返，期间用户完全可能已经点了「退出登录」——
      // 拼旧快照会把刚清掉的会话又装回来，表现是「点了退出，账号却还在」，
      // 而且网越慢越容易撞上。
      final latest = _current;
      if (!latest.isAuthorized) return;
      _emit(latest.copyWith(account: account));
    } on DriveException catch (e) {
      diag.warn('会话', '刷新账号信息失败：${e.message}');
    } catch (e) {
      diag.warn('会话', '刷新账号信息失败：$e');
    }
  }

  /// 登出并清除本地凭证。
  Future<void> signOut() async {
    _emit(_current.copyWith(busy: true, clearError: true));
    try {
      await ref
          .read(adapterRegistryProvider)
          .adapterFor(DriveProvider.quark)
          ?.signOut();
    } finally {
      _emit(const AuthState());
    }
  }
}

final authControllerProvider =
    AsyncNotifierProvider<AuthController, AuthState>(AuthController.new);
