import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../domain/adapters/credential_store.dart';
import '../../domain/entities/auth_credential.dart';
import '../../domain/entities/capabilities.dart';
import '../../domain/entities/drive_provider.dart';

/// 基于系统钥匙串的凭证存储。
///
/// 落在 Keychain（macOS/iOS）/ Keystore（Android）/ DPAPI（Windows）——
/// **绝不写进 SQLite、SharedPreferences 或普通文件**。
///
/// ## macOS 上的钥匙串选择
///
/// `useDataProtectionKeyChain` 必须为 **true**。
/// 这使用应用专属的 Data Protection Keychain，不需要每次弹框授权。
///
/// 早期版本曾设为 false（走旧版 login.keychain），但沙箱 + ad-hoc 签名下
/// 每次启动都会弹「访问钥匙串」密码框——因为旧版钥匙串是系统共享的，
/// macOS 按代码签名授权，ad-hoc 签名每次编译都变，「始终允许」记不住。
///
/// 设为 true 需要同时在两份 .entitlements 里声明 `keychain-access-groups`
/// 权限，否则会报 `-34018`（`errSecMissingEntitlement`）。
///
/// 另一个是 `first_unlock` 可访问性：用户还没解锁过机器时后台任务不该
/// 拿到凭证，但**解锁后**必须能读 —— `first_unlock` 正好是这个语义。
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              mOptions: MacOsOptions(
                // ⚠️ 见类文档：true 用应用专属 Data Protection Keychain，
                // 配合 keychain-access-groups entitlement，不再每次弹框。
                useDataProtectionKeyChain: true,
              ),
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );

  final FlutterSecureStorage _storage;

  /// 键名前缀。加上它是因为钥匙串是**整个用户共享**的命名空间，
  /// 直接叫 `quark` 会和别的应用撞。
  static const String _prefix = 'cloudcine.credential.';

  /// 已授权的网盘索引（一个 JSON 数组）。
  ///
  /// 单独存一份索引而不是遍历枚举所有 provider：钥匙串的 `readAll` 会把
  /// **本应用全部**的键读出来（包括别的用途），逐个数 key 前缀既慢又脆。
  static const String _indexKey = '${_prefix}providers';

  @override
  bool get supportsPersistence => true;

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
    await _storage.write(key: key, value: payload);
    await _addToIndex(credential.provider);
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
      raw = await _storage.read(key: key);
    } catch (e) {
      // 钥匙串读失败（签名变更、权限被拒）不该让应用起不来，
      // 只应让用户重新登录一次。
      diag.error('凭证', '读取钥匙串失败（${provider.id}）：$e');
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
    await _storage.delete(key: _keyFor(provider));
    await _removeFromIndex(provider);
    diag.info('凭证', '已清除 ${provider.id} 的凭证');
  }

  @override
  Future<List<DriveProvider>> authorizedProviders() async {
    try {
      final raw = await _storage.read(key: _indexKey);
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
    await _storage.write(key: _indexKey, value: jsonEncode(next));
  }

  Future<void> _removeFromIndex(DriveProvider provider) async {
    final current = await authorizedProviders();
    final next = current.where((p) => p != provider).map((p) => p.id).toList();
    await _storage.write(key: _indexKey, value: jsonEncode(next));
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
