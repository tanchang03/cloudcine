import 'capabilities.dart';
import 'drive_provider.dart';

/// 已授权的云盘账号。
///
/// 只承载**展示与状态**信息。真正的凭证（Cookie / token）不放在这里，
/// 由 `CredentialStore` 落在系统钥匙串（Keychain / Keystore）。
class CloudAccount {
  const CloudAccount({
    required this.provider,
    required this.authMode,
    required this.authorizedAt,
    this.userId,
    this.displayName,
    this.avatarUrl,
    this.expiresAt,
    this.storageUsedBytes,
    this.storageTotalBytes,
    this.memberLabel,
  });

  final DriveProvider provider;

  /// 本次会话是怎么拿到的（App 扫码 / 浏览器抓取 / 手动粘贴 / 官方 OAuth …）
  final AuthMode authMode;

  /// 授权发生时间
  final DateTime authorizedAt;

  final String? userId;

  /// 昵称或手机号掩码
  final String? displayName;
  final String? avatarUrl;

  /// 会话过期时间。`null` 表示不明确（Cookie 类通常如此）。
  final DateTime? expiresAt;

  final int? storageUsedBytes;
  final int? storageTotalBytes;

  /// 会员标识，如夸克的 `SUPER_VIP`。用于向用户解释「超限不是会员问题」。
  final String? memberLabel;

  /// 展示名：昵称 → 网盘名
  String get label {
    final n = displayName?.trim();
    if (n != null && n.isNotEmpty) return n;
    return provider.displayName;
  }

  bool get isExpired {
    final e = expiresAt;
    if (e == null) return false;
    return DateTime.now().isAfter(e);
  }

  bool get hasStorageInfo =>
      storageTotalBytes != null && storageTotalBytes! > 0;

  /// 已用空间占比（0.0 ~ 1.0）
  double? get storageRatio {
    if (!hasStorageInfo || storageUsedBytes == null) return null;
    return (storageUsedBytes! / storageTotalBytes!).clamp(0.0, 1.0);
  }

  CloudAccount copyWith({
    AuthMode? authMode,
    DateTime? authorizedAt,
    String? userId,
    String? displayName,
    String? avatarUrl,
    DateTime? expiresAt,
    int? storageUsedBytes,
    int? storageTotalBytes,
    String? memberLabel,
  }) {
    return CloudAccount(
      provider: provider,
      authMode: authMode ?? this.authMode,
      authorizedAt: authorizedAt ?? this.authorizedAt,
      userId: userId ?? this.userId,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      expiresAt: expiresAt ?? this.expiresAt,
      storageUsedBytes: storageUsedBytes ?? this.storageUsedBytes,
      storageTotalBytes: storageTotalBytes ?? this.storageTotalBytes,
      memberLabel: memberLabel ?? this.memberLabel,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CloudAccount &&
          other.provider == provider &&
          other.userId == userId &&
          other.authMode == authMode;

  @override
  int get hashCode => Object.hash(provider, userId, authMode);

  @override
  String toString() => 'CloudAccount(${provider.id}, ${authMode.id}, "$label")';
}
