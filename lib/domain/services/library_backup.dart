import 'dart:convert';
import 'dart:typed_data';

/// 媒体库备份清单（manifest）。
///
/// 每份备份包（`.ccbak`）内含一个 `manifest.json`，描述这份备份的
/// 来源设备、创建时间、版本号、包含的数据范围。
///
/// ## 跨机同步的判据
///
/// 同步逻辑基于 [effectiveModifiedAt] 做 Last-Write-Wins 合并：
/// 远程比本地新 → 拉取远程覆盖本地；本地比远程新 → 推送本地覆盖远程。
/// 这是最简单的策略，对「媒体库索引」这种数据来说足够 ——
/// 同一个人不会在两台机器上同时修改不同的作品元数据然后期望合并。
///
/// ## ⚠️ 为什么「谁新」不能用 [createdAt]
///
/// [createdAt] 是**这份备份文件生成的时间**，也就是「现在」。拿它比大小，
/// 本机在任何时刻都必然比远程新 —— 于是同步永远只会上传，
/// 而**新机器一同步就会把网盘上的好备份覆盖成空库**。
///
/// 真正的判据是 [libraryModifiedAt]：**这台机器的媒体库最后一次内容变更
/// 的时间**。空库没有这个时间，此时 [effectiveModifiedAt] 退化成 epoch，
/// 远程自然赢下比较 —— 这正是新机器该有的行为（拉取，而不是覆盖）。
class BackupManifest {
  BackupManifest({
    required this.deviceId,
    required this.deviceName,
    required this.createdAt,
    required this.schemaVersion,
    required this.fileNames,
    this.libraryModifiedAt,
    this.note,
  });

  /// 创建备份的设备唯一标识（用机器的 `IOPlatformUUID`）。
  final String deviceId;

  /// 创建备份的设备名称（用户可读，如「Tandy的MacBook Pro」）。
  final String deviceName;

  /// 备份**文件**的创建时间（UTC）。只用于展示「这份备份是什么时候做的」。
  final DateTime createdAt;

  /// 本地媒体库**最后一次内容变更**的时间（UTC）。同步的 LWW 判据。
  ///
  /// 空库为 `null`。老版本备份里没有这个字段，读取时退化成 [createdAt]。
  final DateTime? libraryModifiedAt;

  /// 数据库 schema 版本号（与 `AppDatabase.schemaVersion` 对齐）。
  final int schemaVersion;

  /// 备份包内包含的文件名列表（`cloudcine.sqlite` / `posters/...`）。
  final List<String> fileNames;

  /// 用户备注（可选）。
  final String? note;

  /// 同步比较用的时间：优先 [libraryModifiedAt]，缺失时退回 [createdAt]。
  ///
  /// ⚠️ 退化成 [createdAt] 只对**老备份**发生（字段是后加的）。
  /// 那种备份没有更好的信息可用，用它至少能让「明显更晚做的备份」赢。
  DateTime get effectiveModifiedAt => libraryModifiedAt ?? createdAt;

  /// 这份备份是否记录了**库内容**（即导出时库里确实有东西）。
  ///
  /// 空库导出时 [libraryModifiedAt] 为 `null`。同步两侧都要看这个标志：
  ///   - 本地没有内容 → 让远程赢（新机器的正路）；
  ///   - 远程没有内容 → **绝不拿它覆盖本地**，否则会用一个空库
  ///     把本地攒好的媒体库清掉。
  bool get hasLibraryContent => libraryModifiedAt != null;

  /// 序列化为 JSON。
  Map<String, Object?> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'createdAt': createdAt.toIso8601String(),
        if (libraryModifiedAt != null)
          'libraryModifiedAt': libraryModifiedAt!.toIso8601String(),
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
      libraryModifiedAt:
          DateTime.tryParse(json['libraryModifiedAt'] as String? ?? ''),
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
  ///
  /// ⚠️ 比的是 [effectiveModifiedAt]（库内容变更时间），**不是**
  /// [createdAt]（备份文件生成时间）—— 理由见类文档。
  bool isNewerThan(BackupManifest other) =>
      effectiveModifiedAt.isAfter(other.effectiveModifiedAt);

  /// 判断两份清单是否构成「同时修改冲突」：
  /// 不同设备且库内容变更时间差在 60 秒内。
  bool conflictsWith(BackupManifest other) {
    if (sameDevice(other)) return false;
    final diff = effectiveModifiedAt
        .difference(other.effectiveModifiedAt)
        .abs();
    return diff.inSeconds < 60;
  }

  @override
  String toString() =>
      'BackupManifest(device=$deviceName, '
      'at=${createdAt.toIso8601String()}, '
      'schema=$schemaVersion, '
      'files=${fileNames.length})';
}
