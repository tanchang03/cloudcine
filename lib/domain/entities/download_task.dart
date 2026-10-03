/// 同时最多跑几个下载任务（用户没设过时的默认值）。
const int kDefaultDownloadConcurrency = 5;

/// 并发数的硬上界。
///
/// 见 `SettingKeys.downloadConcurrency`：每个下载任务内部已经用多连接分块
/// （`DriveDownloadService` 默认 8 条）占满带宽，**任务间**并发只是「同时
/// 下几个文件」。开太多会让网盘侧看到「同一账号短时间开了十几个大文件」，
/// 还会让每条连接都被降速。10 是实测还能保持稳定的上界。
const int kMaxDownloadConcurrency = 10;

/// 一个下载任务的状态。
///
/// ## 为什么「重启后未完成的」要落到 [paused] 而不是 [queued]
///
/// 进程被杀（关窗口 / 崩溃 / 系统重启）时正在下的那些任务，下次启动时
/// 如果直接回到 [queued]，表现就是**一开应用就开始闷头下载几十 GB** ——
/// 用户可能正连着手机热点，而这不是他这次打开应用想干的事。
/// 落到 [paused] 才是诚实的：「它还没下完，要不要继续由你说了算」。
enum DownloadStatus {
  /// 已入队，等着有空位。**这个状态不落盘就会丢**，所以它也写库。
  queued('排队中'),

  /// 正在下。
  downloading('下载中'),

  /// 用户暂停了，或者上次退出时还没下完。
  ///
  /// ⚠️ 它**不是**「失败了」：`.part` 还在磁盘上，点「继续」会带着
  /// `Range: bytes=<已下>-` 从断点接上，而不是从头再来。
  paused('已暂停'),

  /// 下完了。目标路径上的文件是完整的（体积校验过）。
  completed('已完成'),

  /// 失败了。原因在 `DownloadTask.error` 里。
  ///
  /// 失败与暂停在**操作上是同一个**（都是「点继续」），分开只是为了让用户
  /// 一眼看出「这条不是我自己停的，是出问题了」。
  failed('失败');

  const DownloadStatus(this.label);

  /// 给用户看的一两个字。
  final String label;

  bool get isRunning => this == DownloadStatus.downloading;

  /// 已经走到终点（成功或失败）。
  bool get isFinished =>
      this == DownloadStatus.completed || this == DownloadStatus.failed;

  /// 点了会不会真的开始占一个并发位。
  bool get isPending => this == DownloadStatus.queued;

  /// 「继续」对它有意义的那些状态。
  ///
  /// ⚠️ [failed] 也算 —— 失败之后唯一有意义的动作就是重试，而重试本来就
  /// 该带断点（已经下了一半的部分没有理由扔掉）。给它单独一个「重试」按钮
  /// 只是把同一件事换个名字。
  bool get canResume =>
      this == DownloadStatus.paused || this == DownloadStatus.failed;

  /// 「暂停」对它有意义的那些状态。
  bool get canPause =>
      this == DownloadStatus.downloading || this == DownloadStatus.queued;

  /// 从数据库里存的枚举名还原。
  ///
  /// 读不懂的值一律退回 [paused]（**不是** [queued]）：退回 queued 会让一个
  /// 未来版本写的未知状态在旧版本里**自动开始下载**；退回 paused 则只是
  /// 静静躺在那儿，用户点一下「继续」就好。两者代价差一个数量级。
  static DownloadStatus parse(String? raw) {
    for (final v in DownloadStatus.values) {
      if (v.name == raw) return v;
    }
    return DownloadStatus.paused;
  }
}

/// 一条下载记录。
///
/// ## 它是**记录**，不是「正在跑的任务」
///
/// 这个对象在数据库里躺着，也在内存队列里躺着，两边的形状完全一样 ——
/// 这样「界面显示的东西」与「重启后恢复的东西」永远是同一份数据，
/// 不会出现「界面上有这条、重启后没了」。
///
/// 「正在跑」这件事本身**不在这里**：它是 `DownloadQueue` 里那个
/// `Map<String, DriveDownloadControl>`（协作式暂停 / 取消的令牌），
/// 进程一死就没了，也不需要恢复。
class DownloadTask {
  const DownloadTask({
    required this.id,
    required this.provider,
    required this.fileId,
    required this.name,
    required this.savePath,
    required this.createdAt,
    required this.updatedAt,
    this.dirPath = '/',
    this.sizeBytes,
    this.receivedBytes = 0,
    this.status = DownloadStatus.queued,
    this.error,
  });

  /// 主键：`provider:fileId`。
  ///
  /// 取它的自然结果是**同一个文件天然去重**（见 `DownloadTasks` 的类文档）。
  static String idFor(String provider, String fileId) => '$provider:$fileId';

  final String id;

  /// 网盘标识（`DriveProvider.name`）。
  final String provider;

  /// 网盘侧文件 ID。
  final String fileId;

  /// 文件名（含扩展名）。
  final String name;

  /// 网盘上的目录路径（归一化，不带尾斜杠）。展示用。
  final String dirPath;

  /// 本地目标路径（绝对路径）。
  final String savePath;

  /// 文件总字节数。网盘没给时为 `null`。
  final int? sizeBytes;

  /// 已落盘字节数。**进度快照**，真源是磁盘上 `.part` 的长度。
  final int receivedBytes;

  final DownloadStatus status;

  /// 失败原因（面向用户的一句话）。
  final String? error;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// 断点续传用的临时文件路径。与 `DriveDownloadService` 的约定，
  /// **两处必须一致** —— 不一致的表现是「暂停后 .part 被当成垃圾留下，
  /// 而继续时又从 0 开始」，用户只看到「暂停过的文件白下了」。
  String get partPath => '$savePath.part';

  /// 完成比例（0..1）。总长未知时为 `null`。
  ///
  /// ⚠️ 总长未知时**返回 `null` 而不是 0**：进度条要的是「不确定态」，
  /// 拿 0 假装会画出一条永远不动的 0% 条。
  double? get fraction {
    final total = sizeBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0.0, 1.0);
  }

  bool get isActive => status.isRunning || status.isPending;

  DownloadTask copyWith({
    String? name,
    String? dirPath,
    String? savePath,
    int? sizeBytes,
    int? receivedBytes,
    DownloadStatus? status,
    String? error,
    bool clearError = false,
    DateTime? updatedAt,
  }) {
    return DownloadTask(
      id: id,
      provider: provider,
      fileId: fileId,
      name: name ?? this.name,
      dirPath: dirPath ?? this.dirPath,
      savePath: savePath ?? this.savePath,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      status: status ?? this.status,
      // `error` 是 nullable，用 `??` 就永远清不掉 —— 而「失败 → 重试成功」
      // 必须能把上一轮的原因抹掉，否则界面会挂着一条早就不成立的错误。
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  String toString() =>
      'DownloadTask($id, ${status.name}, $receivedBytes/$sizeBytes, $savePath)';
}
