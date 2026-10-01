import 'dart:convert';
import 'dart:typed_data';

/// 媒体库备份清单（manifest）。
///
/// 每份备份包（`.ccbak`）内含一个 `manifest.json`，描述这份备份的
/// 来源设备、创建时间、版本号、包含的数据范围。
///
/// ## 跨机同步的判据
///
/// 同步逻辑基于 [createdAt] 时间戳做 Last-Write-Wins 合并：
/// 远程比本地新 → 拉取远程覆盖本地；本地比远程新 → 推送本地覆盖远程。
/// 这是最简单的策略，对「媒体库索引」这种数据来说足够 ——
/// 同一个人不会在两台机器上同时修改不同的作品元数据然后期望合并。
///
/// 「同时修改」的冲突用 [deviceId] 判定：同一设备先后备份不构成冲突，
/// 只是覆盖；不同设备且时间戳在 60 秒内才算冲突，交给用户选择。
class BackupManifest {
  BackupManifest({
    required this.deviceId,
    required this.deviceName,
    required this.createdAt,
    required this.schemaVersion,
    required this.fileNames,
    this.note,
  });

  /// 创建备份的设备唯一标识（用机器的 `IOPlatformUUID`）。
  final String deviceId;

  /// 创建备份的设备名称（用户可读，如「Tandy的MacBook Pro」）。
  final String deviceName;

  /// 备份创建时间（UTC）。
  final DateTime createdAt;

  /// 数据库 schema 版本号（与 `AppDatabase.schemaVersion` 对齐）。
  final int schemaVersion;

  /// 备份包内包含的文件名列表（`cloudcine.sqlite` / `posters/...`）。
  final List<String> fileNames;

  /// 用户备注（可选）。
  final String? note;

  /// 序列化为 JSON。
  Map<String, Object?> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'createdAt': createdAt.toIso8601String(),
        'schemaVersion': schemaVersion,
        'fileNames': fileNames,
        if (note != null) 'note': note,
      };

  /// 从 JSON 反序列化。
  factory BackupManifest.fromJson(Map<String, Object?> json) {
    return BackupManifest(
      deviceId: json['deviceId'] as String? ?? 'unknown',
      deviceName: json['deviceName'] as String? ?? '未知设备',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      schemaVersion: json['schemaVersion'] as int? ?? 1,
      fileNames: (json['fileNames'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      note: json['note'] as String?,
    );
  }

  /// 序列化为字节（用于写进备份包）。
  Uint8List toBytes() => Uint8List.fromList(
        utf8.encode(jsonEncode(toJson())),
      );

  /// 从字节反序列化。
  static BackupManifest fromBytes(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    return BackupManifest.fromJson(json);
  }

  /// 判断两份清单是否来自同一台设备。
  bool sameDevice(BackupManifest other) => deviceId == other.deviceId;

  /// 判断这份清单是否比 [other] 新。
  bool isNewerThan(BackupManifest other) =>
      createdAt.isAfter(other.createdAt);

  /// 判断两份清单是否构成「同时修改冲突」：
  /// 不同设备且时间戳差在 60 秒内。
  bool conflictsWith(BackupManifest other) {
    if (sameDevice(other)) return false;
    final diff = createdAt.difference(other.createdAt).abs();
    return diff.inSeconds < 60;
  }

  @override
  String toString() =>
      'BackupManifest(device=$deviceName, '
      'at=${createdAt.toIso8601String()}, '
      'schema=$schemaVersion, '
      'files=${fileNames.length})';
}
