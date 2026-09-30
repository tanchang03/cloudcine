/// 网盘返回的原始节点（文件或目录）。
///
/// 这是适配器向领域层交付的**最小公共结构**：把三家网盘各自五花八门的
/// 字段（夸克 `dir`/`file_type`、阿里 `type`、百度 `isdir`）归一到这里。
class DriveEntry {
  const DriveEntry({
    required this.id,
    required this.name,
    required this.isDirectory,
    this.sizeBytes,
    this.mimeType,
    this.modifiedAt,
    this.parentId,
    this.path,
    this.durationMs,
  });

  /// 网盘侧节点 ID
  final String id;

  /// 节点名称（目录名或含扩展名的文件名）
  final String name;

  /// 是否目录。
  ///
  /// 夸克实测（2026-09-23）：`dir: true/false` 才是目录布尔位；
  /// `file_type` 是 `0=目录 / 1=文件`。适配器负责翻译成这里的布尔值。
  final bool isDirectory;

  /// 文件体积。目录通常为 `null` 或 0。
  final int? sizeBytes;

  final String? mimeType;
  final DateTime? modifiedAt;
  final String? parentId;

  /// 展示用路径（由扫描器按遍历栈拼出），如 `/音乐/华语/`
  final String? path;

  /// 音频时长（毫秒）。非音频、或网盘还没刮削出元数据时为 `null`。
  ///
  /// 夸克实测（2026-09-24）：列目录返回里带 `duration` 字段，**单位是秒**，
  /// 例如 `"duration": 186` → 3 分 06 秒。适配器负责换算成毫秒，
  /// 并且把 `0`（网盘没刮削到）也归一成 `null` —— 列表里显示 `00:00`
  /// 会让人以为是一首空文件，显示 `--:--` 才是诚实的「不知道」。
  final int? durationMs;

  bool get isFile => !isDirectory;

  /// 目录大小视为 0，避免上层把 `null` 当成「未知体积」而误判可播性。
  int? get fileSizeBytes => isDirectory ? 0 : sizeBytes;

  DriveEntry copyWith({String? path, String? parentId}) => DriveEntry(
        id: id,
        name: name,
        isDirectory: isDirectory,
        sizeBytes: sizeBytes,
        mimeType: mimeType,
        modifiedAt: modifiedAt,
        parentId: parentId ?? this.parentId,
        path: path ?? this.path,
      );

  @override
  String toString() =>
      'DriveEntry(${isDirectory ? "dir" : "file"}, $id, $name, ${sizeBytes ?? "-"}B)';
}

/// 一页目录列表结果。
class DrivePage {
  const DrivePage({
    required this.entries,
    this.nextPageToken,
    this.total,
  });

  const DrivePage.empty()
      : entries = const [],
        nextPageToken = null,
        total = null;

  final List<DriveEntry> entries;

  /// 下一页游标。为 `null` 表示当前目录已列完。
  final String? nextPageToken;

  /// 网盘声明的总条目数（可能为 `null`）
  final int? total;

  bool get isEmpty => entries.isEmpty;

  bool get hasMore => nextPageToken != null && nextPageToken!.isNotEmpty;

  Iterable<DriveEntry> get directories => entries.where((e) => e.isDirectory);

  Iterable<DriveEntry> get files => entries.where((e) => e.isFile);

  @override
  String toString() =>
      'DrivePage(${entries.length} 项, next=$nextPageToken, total=$total)';
}
