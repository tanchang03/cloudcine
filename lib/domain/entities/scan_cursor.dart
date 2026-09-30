import 'drive_provider.dart';

/// BFS 队列中的一个待扫目录。
///
/// 必须可序列化：扫描可能被用户中断或 App 被杀，续扫时要能原样恢复队列，
/// 否则要么重扫全盘（浪费配额），要么漏掉目录。
class PendingDir {
  const PendingDir({
    required this.id,
    required this.path,
    this.depth = 0,
  });

  /// 网盘侧目录 ID
  final String id;

  /// 展示用路径，如 `/音乐/华语/`
  final String path;

  /// 相对扫描根目录的深度，用于执行 [ScanPolicy.maxDepth]
  final int depth;

  factory PendingDir.fromJson(Map<String, Object?> json) => PendingDir(
        id: json['id'] as String? ?? '',
        path: json['path'] as String? ?? '/',
        depth: (json['depth'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toJson() => {'id': id, 'path': path, 'depth': depth};

  PendingDir copyWith({String? id, String? path, int? depth}) => PendingDir(
        id: id ?? this.id,
        path: path ?? this.path,
        depth: depth ?? this.depth,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PendingDir && other.id == id && other.path == path && other.depth == depth;

  @override
  int get hashCode => Object.hash(id, path, depth);

  @override
  String toString() => 'PendingDir($id, $path, d$depth)';
}

/// 扫描阶段
enum ScanStage {
  /// 从未扫描过
  idle,

  /// 正在扫描
  running,

  /// 用户主动暂停，可续扫
  paused,

  /// 已扫完
  completed,

  /// 因错误中断，可续扫
  failed;

  bool get canResume => this == ScanStage.paused || this == ScanStage.failed;
  bool get isTerminal => this == ScanStage.completed;
}

/// 断点续扫游标。
///
/// 这是「遍历搜索所有网盘音乐文件」这个需求的核心持久化状态。
/// 设计要点：
///   - 队列与当前分页游标都落库，任何时刻中断都能原地续上；
///   - 计数（目录数 / 文件数 / 曲目数 / 体积）随游标一起持久化，
///     这样即使中途退出，UI 也能立刻展示「上次扫到哪了」。
class ScanCursor {
  const ScanCursor({
    required this.provider,
    required this.rootId,
    required this.updatedAt,
    this.rootPath = '/',
    this.pendingDirs = const [],
    this.currentDir,
    this.currentPageToken,
    this.stage = ScanStage.idle,
    this.scannedDirs = 0,
    this.scannedFiles = 0,
    this.foundTracks = 0,
    this.totalBytes = 0,
    this.failedDirs = 0,
    this.lastError,
  });

  /// 全新游标：队列里只有根目录。
  factory ScanCursor.fresh({
    required DriveProvider provider,
    required String rootId,
    String rootPath = '/',
    DateTime? now,
  }) {
    final ts = now ?? DateTime.now();
    return ScanCursor(
      provider: provider,
      rootId: rootId,
      rootPath: rootPath,
      updatedAt: ts,
      pendingDirs: [PendingDir(id: rootId, path: rootPath, depth: 0)],
      stage: ScanStage.idle,
    );
  }

  final DriveProvider provider;

  /// 扫描根目录 ID（夸克取 `0` 表示根）
  final String rootId;
  final String rootPath;

  /// BFS 待扫队列。**队首即下一个要扫的目录**，持久化后顺序不变。
  final List<PendingDir> pendingDirs;

  /// 当前正在扫描的目录（分页未取完时非空）
  final PendingDir? currentDir;

  /// 当前目录的下一页游标。非空表示该目录还没列完。
  final String? currentPageToken;

  final ScanStage stage;

  /// 已完整列过的目录数
  final int scannedDirs;

  /// 已枚举过的文件数（含非音频）
  final int scannedFiles;

  /// 已识别出的音频曲目数
  final int foundTracks;

  /// 已识别出的音频曲目总体积
  final int totalBytes;

  /// 因权限/超时等原因跳过的目录数
  final int failedDirs;

  /// 最近一次失败原因（面向用户的中文描述）
  final String? lastError;

  final DateTime updatedAt;

  /// 队列里还有没有活
  bool get hasPendingWork =>
      currentDir != null || pendingDirs.isNotEmpty;

  /// 是否已扫完
  bool get isComplete => stage == ScanStage.completed;

  /// 已发现的曲目总体积（人类可读由 UI 层格式化）
  int get averageTrackBytes =>
      foundTracks <= 0 ? 0 : (totalBytes / foundTracks).round();

  ScanCursor copyWith({
    String? rootId,
    String? rootPath,
    List<PendingDir>? pendingDirs,
    PendingDir? currentDir,
    bool clearCurrentDir = false,
    String? currentPageToken,
    bool clearPageToken = false,
    ScanStage? stage,
    int? scannedDirs,
    int? scannedFiles,
    int? foundTracks,
    int? totalBytes,
    int? failedDirs,
    String? lastError,
    bool clearLastError = false,
    DateTime? updatedAt,
  }) {
    return ScanCursor(
      provider: provider,
      rootId: rootId ?? this.rootId,
      rootPath: rootPath ?? this.rootPath,
      pendingDirs: pendingDirs ?? this.pendingDirs,
      currentDir: clearCurrentDir ? null : (currentDir ?? this.currentDir),
      currentPageToken:
          clearPageToken ? null : (currentPageToken ?? this.currentPageToken),
      stage: stage ?? this.stage,
      scannedDirs: scannedDirs ?? this.scannedDirs,
      scannedFiles: scannedFiles ?? this.scannedFiles,
      foundTracks: foundTracks ?? this.foundTracks,
      totalBytes: totalBytes ?? this.totalBytes,
      failedDirs: failedDirs ?? this.failedDirs,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 从队首取出一个目录开始扫；队列为空时返回 `null`。
  ///
  /// 注意：取出**最后一个**目录时队列虽然空了，但该目录尚未扫描、可能
  /// 还会产出子目录，因此 [stage] 仍是 [ScanStage.running]。真正的完成
  /// 判定由 [markCompleted] 显式完成，或在空队列上再次 [dequeue] 兜底。
  ScanCursor dequeue(DateTime now) {
    if (pendingDirs.isEmpty) {
      return markCompleted(now);
    }
    final head = pendingDirs.first;
    return copyWith(
      pendingDirs: pendingDirs.sublist(1),
      currentDir: head,
      clearPageToken: true,
      stage: ScanStage.running,
      clearLastError: true,
      updatedAt: now,
    );
  }

  /// 显式标记扫描完成，清空当前目录与分页游标。
  ///
  /// 扫描器在 `!hasPendingWork` 时调用。
  ScanCursor markCompleted(DateTime now) => copyWith(
        clearCurrentDir: true,
        clearPageToken: true,
        stage: ScanStage.completed,
        updatedAt: now,
      );

  /// 标记为暂停（用户主动），保留队列以便续扫。
  ScanCursor pause(DateTime now) => copyWith(
        stage: ScanStage.paused,
        updatedAt: now,
      );

  /// 标记为失败，保留队列与错误信息以便续扫。
  ScanCursor fail(String reason, DateTime now) => copyWith(
        stage: ScanStage.failed,
        lastError: reason,
        updatedAt: now,
      );

  /// 把一个子目录压入队尾。
  ScanCursor enqueue(PendingDir dir, DateTime now) => copyWith(
        pendingDirs: [...pendingDirs, dir],
        updatedAt: now,
      );

  /// 入队，但队列里已有同 ID 时跳过。
  ///
  /// 网盘里同一个目录可能通过多条路径被引用（软链接、收藏夹），
  /// 不去重会导致同一目录被反复扫描 —— 既浪费接口配额，也让计数虚高。
  /// 续扫时 `visited` 集合会丢失，这个方法就是那层兜底。
  ScanCursor enqueueIfAbsent(PendingDir dir, DateTime now) {
    if (dir.id.isEmpty) return this;
    if (currentDir?.id == dir.id) return this;
    for (final d in pendingDirs) {
      if (d.id == dir.id) return this;
    }
    return enqueue(dir, now);
  }

  /// 累计计数（不改变阶段）。
  ScanCursor addCounts({
    int dirs = 0,
    int files = 0,
    int tracks = 0,
    int bytes = 0,
    int failures = 0,
    DateTime? now,
  }) =>
      copyWith(
        scannedDirs: scannedDirs + dirs,
        scannedFiles: scannedFiles + files,
        foundTracks: foundTracks + tracks,
        totalBytes: totalBytes + bytes,
        failedDirs: failedDirs + failures,
        updatedAt: now ?? updatedAt,
      );

  @override
  String toString() => 'ScanCursor(${provider.id}, ${stage.name}, '
      '待扫 ${pendingDirs.length}, 已扫目录 $scannedDirs, 曲目 $foundTracks)';
}
