import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/error/drive_error.dart';
import '../../domain/entities/auth_credential.dart';
import '../../domain/entities/capabilities.dart';
import '../../domain/entities/cloud_account.dart';
import '../../domain/entities/drive_provider.dart';
import 'app_providers.dart';

/// 授权状态快照 —— **多家网盘并存**。
///
/// ## 为什么是一张表而不是一个账号
///
/// 应用支持**同时**连接多家网盘：夸克和百度各有一份会话，媒体库把两家的
/// 条目混在一个库里（主键 `provider:fileId`，见 `MediaItem.id`）。
///
/// 曾经这里是单个 `account` + 一个「当前网盘」（`activeDriveProvider`），
/// 登录第二家会把第一家顶掉。那个模型下「两家都在线」是做不到的 ——
/// 而用户要的正是「两家都在线」。
///
/// ⛔ 所以这里**没有**「当前网盘」这个概念。任何需要网盘的地方都必须
///    拿到一个**明确的** [DriveProvider]：
///      * 播放 / 字幕 → 条目自己的 `MediaItem.provider`；
///      * 下载 → 每条任务的 `DownloadTask.provider`；
///      * 浏览 / 扫描 → 页面上选的那一家（见 `browseDriveProvider`）；
///      * 备份上传 → 挑一家 `Capabilities.canWrite` 的。
class AuthState {
  const AuthState({
    this.accounts = const {},
    this.errors = const {},
    this.busy = false,
    this.canPersist = true,
  });

  /// 已授权的网盘 → 账号。**这是唯一的真源。**
  ///
  /// ⛔ 空表 = 一家都没登录。判断「能不能进媒体库」看 [isAuthorized]，
  ///    而它是「表非空」，不是「某一家登录了」。
  final Map<DriveProvider, CloudAccount> accounts;

  /// 某家网盘最近一次的失败原因（恢复会话 / 授权）。
  ///
  /// ⛔ 按网盘分开记，不是一条全局 `error`：百度扫码失败不该让夸克的卡片
  ///    也显示「授权失败」。没失败过的网盘**不在表里**。
  final Map<DriveProvider, String> errors;

  /// 是否正在执行授权 / 登出。
  final bool busy;

  /// 凭证能否持久化。`false` 时 UI 要提示「本次会话有效，重启需重新登录」。
  final bool canPersist;

  /// **有任何一家**已授权。路由据此决定去媒体库还是去登录页。
  bool get isAuthorized => accounts.isNotEmpty;

  CloudAccount? accountFor(DriveProvider provider) => accounts[provider];

  String? errorFor(DriveProvider provider) => errors[provider];

  /// 有没有任何一家报过错。登录页 / 设置页拿它决定要不要显示汇总提示。
  bool get hasAnyError => errors.isNotEmpty;

  AuthState copyWith({
    Map<DriveProvider, CloudAccount>? accounts,
    Map<DriveProvider, String>? errors,
    bool? busy,
    bool? canPersist,
  }) {
    return AuthState(
      accounts: accounts ?? this.accounts,
      errors: errors ?? this.errors,
      busy: busy ?? this.busy,
      canPersist: canPersist ?? this.canPersist,
    );
  }
}

/// 授权控制器：**同时**维护多家的会话。
///
/// 启动时用安全存储里的凭证恢复**所有**已保存过的网盘；某一家恢复失败
/// （凭证已失效）只清掉那一家，并给它记一条 [AuthState.errors] ——
/// 另一家的会话不受影响。
///
/// ## 为什么失败的只清一家
///
/// 百度的 `BDUSS` 过期是常态（百度会主动踢会话）。如果一次失败就把全部
/// 凭证清掉，用户会看到「夸克也掉线了」，而他只是百度过期了 ——
/// 那会让他以为应用坏了。
class AuthController extends AsyncNotifier<AuthState> {
  @override
  Future<AuthState> build() async {
    final store = ref.watch(credentialStoreProvider);
    final registry = ref.watch(adapterRegistryProvider);

    // ⛔ 只恢复**有凭证的**那些。`CredentialStore` 自己知道有哪些，
    //    不必挨个去问每一家适配器 —— 那是白花的网络往返（而且百度那边
    //    还会踩到风控）。
    final saved = await store.authorizedProviders();

    final accounts = <DriveProvider, CloudAccount>{};
    final errors = <DriveProvider, String>{};

    for (final provider in registry.providers) {
      if (!saved.contains(provider)) continue;
      final adapter = registry.adapterFor(provider);
      if (adapter == null) continue;
      try {
        final account = await adapter.restoreSession();
        if (account != null) accounts[provider] = account;
      } on DriveException catch (e) {
        // 凭证存在但服务端不认了：只清这一家，让用户重新扫一次即可。
        await adapter.signOut();
        errors[provider] = e.message;
      } catch (e) {
        errors[provider] = '恢复会话失败：$e';
      }
    }

    return AuthState(
      accounts: accounts,
      errors: errors,
      canPersist: store.supportsPersistence,
    );
  }

  void _emit(AuthState next) => state = AsyncData(next);

  AuthState get _current => state.valueOrNull ?? const AuthState();

  /// 用一份凭证完成授权。
  ///
  /// ## ⛔ 是**追加**，不是替换
  ///
  /// 凭证自带 [AuthCredential.provider]，所以这里只往 [AuthState.accounts]
  /// 里加一家 —— **不碰**其它已连接的网盘。登录百度不会把夸克顶掉。
  ///
  /// 成功返回 `null`，失败返回错误文案。
  Future<String?> authorize(AuthCredential credential) async {
    final provider = credential.provider;
    _emit(
      _current.copyWith(
        busy: true,
        errors: Map.of(_current.errors)..remove(provider),
      ),
    );

    try {
      final adapter = ref
          .read(adapterRegistryProvider)
          .requireAdapter(provider);
      final account = await adapter.authorize(credential);

      // ⚠️ 基于**最新**状态拼，不要用 await 之前那份快照：这次授权是一次
      //    网络往返，期间用户完全可能在侧栏把另一家登出 / 又登录了一家。
      final latest = _current;
      _emit(
        AuthState(
          accounts: Map.of(latest.accounts)..[provider] = account,
          errors: Map.of(latest.errors)..remove(provider),
          canPersist: ref.read(credentialStoreProvider).supportsPersistence,
        ),
      );
      return null;
    } on DriveException catch (e) {
      _emit(
        _current.copyWith(
          busy: false,
          errors: Map.of(_current.errors)..[provider] = e.message,
        ),
      );
      return e.message;
    } catch (e) {
      final message = '授权失败：$e';
      _emit(
        _current.copyWith(
          busy: false,
          errors: Map.of(_current.errors)..[provider] = message,
        ),
      );
      return message;
    }
  }

  /// 重新拉一次账号信息。
  ///
  /// [provider] 为空 = 所有已连接的网盘都刷一遍。
  ///
  /// ## 为什么需要它
  ///
  /// [AuthState.accounts] 里的**已用容量是一份快照** —— 它在授权/恢复会话
  /// 那一刻取到，之后用户传片、删片、清理空间都不会自己更新。文件夹页头
  /// 那条容量条要显示「还剩多少」，就必须有一条重新问一次的路径。
  ///
  /// ## 为什么失败时**不写 errors**
  ///
  /// 容量条是文件夹页上的**附属信息**，不是那一页的功能。为了一次容量刷新
  /// 失败把错误置上，侧栏与登录页会冒出「授权失败」—— 而会话其实好好的，
  /// 用户会跑去重新登录一次。所以这里只记诊断日志，界面保持原值。
  Future<void> refreshAccount({DriveProvider? provider}) async {
    final targets = provider != null
        ? <DriveProvider>[provider]
        : _current.accounts.keys.toList(growable: false);

    for (final p in targets) {
      if (!_current.accounts.containsKey(p)) continue;
      final adapter = ref.read(adapterRegistryProvider).adapterFor(p);
      if (adapter == null) continue;

      try {
        final account = await adapter.refreshAccount();
        if (account == null) continue;

        // ⚠️ 必须**重新取一次**最新状态，不能用 await 之前那份快照拼回去：
        //    这是一次网络往返，期间用户完全可能已经把这家登出了 ——
        //    拼旧快照会把刚清掉的会话又装回来，表现是「点了退出，账号却还在」，
        //    而且网越慢越容易撞上。
        final latest = _current;
        if (!latest.accounts.containsKey(p)) continue;
        _emit(
          latest.copyWith(accounts: Map.of(latest.accounts)..[p] = account),
        );
      } on DriveException catch (e) {
        diag.warn('会话', '刷新 ${p.displayName} 账号信息失败：${e.message}');
      } catch (e) {
        diag.warn('会话', '刷新 ${p.displayName} 账号信息失败：$e');
      }
    }
  }

  /// 登出并清除本地凭证。
  ///
  /// [provider] 为空 = **全部**登出（设置页那个「退出登录」）。
  /// 给了具体一家 = 只登出那一家的（侧栏每一行各自的退出按钮）。
  ///
  /// ⛔ 只登出一家时**绝不碰**另一家的凭证：用户在夸克与百度之间来回切
  ///    时，不该每切一次就要重扫一次码。
  Future<void> signOut({DriveProvider? provider}) async {
    final targets = provider != null
        ? <DriveProvider>[provider]
        : _current.accounts.keys.toList(growable: false);
    if (targets.isEmpty) return;

    _emit(_current.copyWith(busy: true));
    try {
      for (final p in targets) {
        await ref.read(adapterRegistryProvider).adapterFor(p)?.signOut();
      }
    } finally {
      // 用 `finally`：即使某一家登出时抛了，本地状态也必须跟着清掉 ——
      // 留着的话界面显示「已登录」，而凭证其实已经删了。
      _emit(
        AuthState(
          accounts: Map.of(_current.accounts)
            ..removeWhere((k, _) => targets.contains(k)),
          errors: Map.of(_current.errors)
            ..removeWhere((k, _) => targets.contains(k)),
          canPersist: _current.canPersist,
        ),
      );
    }
  }
}

final authControllerProvider =
    AsyncNotifierProvider<AuthController, AuthState>(AuthController.new);

/// **已连接**的网盘（有账号的那些），顺序 = 适配器注册顺序。
///
/// 侧栏、浏览选择器、扫描选择器都用它列候选 —— 未登录的网盘不在这里，
/// 因为「选一家没登录的网盘」只会得到一串未授权错误。
final connectedDrivesProvider = Provider<List<DriveProvider>>((ref) {
  final registry = ref.watch(adapterRegistryProvider);
  final accounts =
      ref.watch(authControllerProvider).valueOrNull?.accounts ?? const {};
  return [
    for (final provider in registry.providers)
      if (accounts.containsKey(provider)) provider,
  ];
});

/// 某一家网盘的账号（同步读）。未登录时为 `null`。
///
/// 侧栏每一行、文件夹页头的容量条都读它 —— 传进哪一家就拿哪一家的，
/// 不存在「拿错一家」的可能。
final accountForProviderProvider =
    Provider.family<CloudAccount?, DriveProvider>(
  (ref, provider) =>
      ref.watch(authControllerProvider).valueOrNull?.accounts[provider],
);

/// 可选的网盘：**已注册适配器且支持扫码登录**的那些。
///
/// 判据走 `capabilities.authModes`，不在这里列枚举名 —— 以后某家网盘
/// 改成只支持手动粘贴凭证时，登录页会自动不再展示它的扫码入口。
///
/// ⚠️ 它列的是**可以连的**，与 [connectedDrivesProvider]（**已经连上的**）
///    是两回事：登录页要把两者对照着显示（「已连接 / 去连接」）。
final selectableDrivesProvider = Provider<List<DriveProvider>>((ref) {
  final registry = ref.watch(adapterRegistryProvider);
  return [
    for (final provider in registry.providers)
      if (registry
              .adapterFor(provider)
              ?.capabilities
              .authModes
              .contains(AuthMode.qrCode) ??
          false)
        provider,
  ];
});
