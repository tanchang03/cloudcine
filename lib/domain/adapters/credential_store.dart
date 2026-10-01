import '../entities/auth_credential.dart';
import '../entities/drive_provider.dart';

/// 凭证持久化契约。
///
/// 实现必须落在**系统级安全存储**：
///   - iOS / Android：Keychain / EncryptedSharedPreferences + Keystore
///   - Windows：DPAPI（`flutter_secure_storage` 已封装）
///   - Linux：libsecret
///   - macOS：**加密文件**（不是 Keychain —— 见 `SecureCredentialStore`：
///     本仓库走 ad-hoc 签名，身份每次重建都变，钥匙串条目的 ACL 永远对不上，
///     表现为「每次启动都弹钥匙串密码框」，已实测无解）
///   - Web：`flutter_secure_storage` 的 Web 实现**不是真安全存储**
///     （只有 localStorage + 弱混淆）。因此 Web 端定位为「浏览管理端」，
///     默认不持久化凭证，见技术方案 §平台能力矩阵。
///
/// **禁止**把凭证明文写进 SQLite、SharedPreferences、普通文件或日志。
abstract class CredentialStore {
  /// 保存（覆盖）某网盘的凭证。
  Future<void> save(AuthCredential credential);

  /// 读取某网盘的凭证。没有则返回 `null`。
  Future<AuthCredential?> load(DriveProvider provider);

  /// 清除某网盘的凭证。
  Future<void> clear(DriveProvider provider);

  /// 已保存凭证的网盘列表。
  Future<List<DriveProvider>> authorizedProviders();

  /// 是否支持持久化。Web 端返回 `false`，UI 据此提示「本次会话有效，
  /// 刷新页面需重新授权」。
  bool get supportsPersistence;
}
