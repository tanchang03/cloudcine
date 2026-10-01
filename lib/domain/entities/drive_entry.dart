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
    this.thumbnailUrl,
    this.previewImageUrl,
    this.videoWidth,
    this.videoHeight,
    this.faceAnchorX,
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

  /// 服务端生成的**小缩略图**地址（夸克：`thumbnail`，实测 178×100 WebP）。
  ///
  /// 目录级展示（文件列表里的小图）用它就够了。
  final String? thumbnailUrl;

  /// 服务端生成的**大预览图**地址（夸克：`preview_url`，实测 640×360 WebP）。
  ///
  /// 海报墙用它：一个格子约 172 逻辑像素宽，2x 屏需要 344px，
  /// 小缩略图那一档会明显发糊。
  ///
  /// ⚠️ 两者都**必须带 Cookie** 才能取到（实测裸链 401），而且夸克
  /// 每次响应会轮换 `__puus`，用旧值同样 401 —— 下载时必须走适配器
  /// 现取的请求头，不能把 Cookie 冻在地址里。
  final String? previewImageUrl;

  /// 网盘给出的**实测**视频宽度（像素）。夸克：`video_width`。
  ///
  /// 2026-10-01 实测：递归遍历 44 个目录、427 个视频，覆盖率 **100%**，
  /// 没有 0 值。比文件名里的 `2160p` 可靠 —— 那是发布组自己标的，会错、
  /// 会缺，而这是服务端读文件头得到的。
  ///
  /// 非视频、或服务端还没处理时为 `null`。
  final int? videoWidth;

  /// 网盘给出的**实测**视频高度（像素）。夸克：`video_height`。
  ///
  /// ⚠️ 归挡分辨率时**不要只看高度**：实测样本里宽银幕裁切占 40%
  /// （`3840x1632`、`1920x804`…），按高度会整体低估一档。
  /// 用 `VideoFormats.resolutionFromDimensions`，它按长边归挡。
  final int? videoHeight;

  /// 封面裁切用的**水平锚点**（归一化 0~1），来自夸克的人脸框
  /// `cover_face_boundary`。
  ///
  /// 2026-10-01 探针实测覆盖率 **56/60（93%）**。它是把 16:9 的视频帧裁成
  /// 竖版封面时唯一能锚住人物的依据 —— 按画面正中裁会在双人对谈镜头里
  /// 裁到两个人中间的空隙，既没主体也认不出片子。
  ///
  /// 是「**锚点**」（人物在画面里的水平位置）而不是「裁切偏移」：
  /// 具体偏移量取决于卡片比例，由 `FaceAnchor.alignmentX` 在渲染时换算，
  /// 这样换卡片比例不需要重新扫描。
  ///
  /// 没有可用人脸框时为 `null`，渲染时退回画面正中。
  final double? faceAnchorX;

  bool get isFile => !isDirectory;

  /// 目录大小视为 0，避免上层把 `null` 当成「未知体积」而误判可播性。
  int? get fileSizeBytes => isDirectory ? 0 : sizeBytes;

  /// 只用来补上「扫描器才知道的两个字段」（展示路径、父目录）。
  ///
  /// ⚠️ 它必须把**全部**字段原样带过去。漏掉一个的后果不是编译错误，
  /// 而是那个字段在「补路径」这一步之后静默变成 `null` ——
  /// 例如时长会显示成 `--:--`、缩略图会整片消失。
  DriveEntry copyWith({String? path, String? parentId}) => DriveEntry(
        id: id,
        name: name,
        isDirectory: isDirectory,
        sizeBytes: sizeBytes,
        mimeType: mimeType,
        modifiedAt: modifiedAt,
        parentId: parentId ?? this.parentId,
        path: path ?? this.path,
        durationMs: durationMs,
        thumbnailUrl: thumbnailUrl,
        previewImageUrl: previewImageUrl,
        videoWidth: videoWidth,
        videoHeight: videoHeight,
        faceAnchorX: faceAnchorX,
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
