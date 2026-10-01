import 'dart:convert';

import '../../core/diagnostics/diag_log.dart';
import '../../domain/adapters/credential_store.dart';
import '../../domain/entities/auth_credential.dart';
import '../../domain/entities/capabilities.dart';
import '../../domain/entities/drive_provider.dart';
import 'secret_backend.dart';

/// 凭证存储。**绝不写进 SQLite、SharedPreferences 或日志。**
///
/// 具体落在哪一层由注入的 [SecretBackend] 决定，组合根用
/// [SecretBackend.forPlatform] 按平台挑：
///
/// | 平台 | 后端 | 落点 |
/// |---|---|---|
/// | macOS | [EncryptedFileSecretBackend] | 应用支持目录下的 `credentials.enc`（加密） |
/// | iOS / Android / Windows / Linux | [FlutterSecureStorageBackend] | Keychain / Keystore / DPAPI / libsecret |
///
/// ## 为什么 macOS 单独走一条路
///
/// **因为系统钥匙串在 ad-hoc 签名下必然弹框。**
///
/// 钥匙串条目的 ACL 只认「创建它的那一份代码签名」。本仓库刻意不落库任何
/// 签名身份（`CODE_SIGN_IDENTITY = "-"`、`DEVELOPMENT_TEAM` 为空，保证谁
/// clone 下来都能直接构建），于是走 ad-hoc 签名；而 ad-hoc 的身份就是
/// **cdhash**（`codesign -d -r- cloudcine.app` 可见），**每重新构建一次就变**。
/// 系统认定「换了个 app」→ ACL 对不上 → 每次启动都弹
/// 「请输入登录钥匙串密码」，点「始终允许」也只撑到下次构建。
///
/// ⛔ 试过并且**已经证伪**的两条路，都不要再走（完整实测数据见
/// `EncryptedFileSecretBackend` 的类文档）：
///
/// 1. 加 `keychain-access-groups` entitlement —— 只能由描述文件下发，
///    Xcode 构建直接失败（`"Runner" requires a provisioning profile.`），
///    而且 **ad-hoc 签名下会让 app 启动即崩**：taskgated 判定受限签名无效，
///    进程被 SIGKILL，报 `EXC_CRASH (SIGKILL (Code Signature Invalid))` /
///    `Taskgated Invalid Signature`，崩溃报告没有任何调用栈。
///    2026-10-01 就是因为这个 entitlement 让 Release 包完全起不来。
/// 2. 自建原生通道，建条目时写入「任何程序都可访问」的 ACL ——
///    **也不行**。打包成真正的 .app 复测过，重建后 `read` 仍返回
///    `-128 errSecUserCanceled` 且阻塞 3.2 秒（模态授权框）。
/// 3. 打开 `useDataProtectionKeyChain`（`flutter_secure_storage` 的默认值）——
///    它要求 `application-identifier` 或 `keychain-access-groups`，
///    同样是描述文件才能给的东西。结果是每次写入都抛
///    `PlatformException(Code: -34018, Message: A required entitlement isn't present.)`。
///
/// 真正能免弹框的只有「稳定签名身份」（Developer ID）——
/// 那要给这个播放器签上公司证书，本项目不做。
///
/// ## 写入失败不阻断登录
///
/// [save] 吞掉后端的异常（只记诊断日志）。理由是：落库失败不该让用户连
/// 本次会话都用不了 —— 大不了下次启动重新登录。反之若让它抛出，
/// `QuarkAdapter.authorize` 会在「已经校验通过」之后失败，报错还指向授权，
/// 排查成本高得多。
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({required SecretBackend backend}) : _backend = backend;

  final SecretBackend _backend;

  /// 键名前缀。加上它是因为后端是**整个用户共享**的命名空间
  /// （钥匙串如此，加密文件也刻意保持一致），直接叫 `quark` 会和别的用途撞。
  static const String _prefix = 'cloudcine.credential.';

  /// 已授权的网盘索引（一个 JSON 数组）。
  ///
  /// 单独存一份索引而不是遍历枚举所有 provider：后端的键空间里还有
  /// **别的用途**的键，逐个数前缀既慢又脆。
  static const String _indexKey = '${_prefix}providers';

  @override
  bool get supportsPersistence => _backend.isPersistent;

  @override
  Future<void> save(AuthCredential credential) async {
    final key = _keyFor(credential.provider);
    // 只存必要的字段，`extra` 里可能有设备指纹之类不该长期留的东西。
    final payload = jsonEncode({
      'mode': credential.mode.id,
      'capturedAt': credential.capturedAt.toIso8601String(),
      'cookies': credential.cookies,
      'tokens': credential.tokens,
    });

    try {
      await _backend.write(key, payload);
      await _addToIndex(credential.provider);
    } catch (e) {
      // 落库失败不阻断本次会话，理由见类文档。
      diag.error('凭证', '凭证写入失败（${credential.provider.id}），本次会话仍可用：$e');
      return;
    }

    diag.info(
      '凭证',
      '已保存 ${credential.provider.id} 的凭证'
      '（模式=${credential.mode.id}，Cookie 键=${credential.cookies.keys.toList()}）',
    );
  }

  @override
  Future<AuthCredential?> load(DriveProvider provider) async {
    final key = _keyFor(provider);
    String? raw;
    try {
      raw = await _backend.read(key);
    } catch (e) {
      // 读失败（文件损坏、密钥材料变了、系统安全存储拒绝）不该让应用起不来，
      // 只应让用户重新登录一次。
      diag.error('凭证', '读取凭证失败（${provider.id}）：$e');
      return null;
    }
    if (raw == null || raw.isEmpty) return null;

    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final mode = AuthMode.fromId('${map['mode']}') ?? AuthMode.qrCode;
      final capturedAt =
          DateTime.tryParse('${map['capturedAt']}') ?? DateTime.now();

      return AuthCredential(
        provider: provider,
        mode: mode,
        capturedAt: capturedAt,
        cookies: _stringMap(map['cookies']),
        tokens: _stringMap(map['tokens']),
      );
    } catch (e) {
      diag.error('凭证', '凭证反序列化失败（${provider.id}），按未授权处理：$e');
      return null;
    }
  }

  @override
  Future<void> clear(DriveProvider provider) async {
    try {
      await _backend.delete(_keyFor(provider));
      await _removeFromIndex(provider);
    } catch (e) {
      // 退出登录失败要让用户知道（否则会以为已经退干净了），
      // 但也不能把 UI 卡死在这里 —— 内存里的会话已经清掉了。
      diag.error('凭证', '清除凭证失败（${provider.id}）：$e');
      return;
    }
    diag.info('凭证', '已清除 ${provider.id} 的凭证');
  }

  @override
  Future<List<DriveProvider>> authorizedProviders() async {
    try {
      final raw = await _backend.read(_indexKey);
      if (raw == null || raw.isEmpty) return const [];
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .map((e) => DriveProvider.fromId('$e'))
          .whereType<DriveProvider>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static String _keyFor(DriveProvider provider) => '$_prefix${provider.id}';

  static Map<String, String> _stringMap(Object? raw) {
    if (raw is! Map) return const {};
    return {
      for (final e in raw.entries)
        if (e.value != null) '${e.key}': '${e.value}',
    };
  }

  Future<void> _addToIndex(DriveProvider provider) async {
    final current = await authorizedProviders();
    if (current.contains(provider)) return;
    final next = [...current.map((p) => p.id), provider.id];
    await _backend.write(_indexKey, jsonEncode(next));
  }

  Future<void> _removeFromIndex(DriveProvider provider) async {
    final current = await authorizedProviders();
    final next = current.where((p) => p != provider).map((p) => p.id).toList();
    await _backend.write(_indexKey, jsonEncode(next));
  }
}

/// 内存凭证存储。**测试与「不持久化」模式用**。
///
/// 它存在的第二个理由是 Web：`flutter_secure_storage` 的 Web 实现只有
/// localStorage + 弱混淆，**不是真安全存储**，所以那条路上会用这个实现。
class InMemoryCredentialStore implements CredentialStore {
  InMemoryCredentialStore();

  final Map<String, AuthCredential> _store = {};

  @override
  bool get supportsPersistence => false;

  @override
  Future<void> save(AuthCredential credential) async {
    _store[credential.provider.id] = credential;
  }

  @override
  Future<AuthCredential?> load(DriveProvider provider) async =>
      _store[provider.id];

  @override
  Future<void> clear(DriveProvider provider) async {
    _store.remove(provider.id);
  }

  @override
  Future<List<DriveProvider>> authorizedProviders() async =>
      _store.keys.map(DriveProvider.fromId).whereType<DriveProvider>().toList();
}
