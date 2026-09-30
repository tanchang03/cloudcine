/// 一个可选的「清晰度」。
///
/// ## 为什么需要这个类型
///
/// 夸克播放器（以及几乎所有网盘播放器）的清晰度切换不是本地行为，而是
/// **服务端转码梯度**：同一个 fid，服务端准备了好几档不同码率的流，
/// 前端只是换一个 URL。`/1/clouddrive/batch/file/play/info` 的
/// `resolutions: "normal,low,high,super,2k,4k"` 就是这个梯度。
///
/// 因此本应用能提供的清晰度**完全取决于服务端返回了什么**：
///   - 服务端返回了转码梯度 → 逐档列出，用户可选；
///   - 只返回了原文件 → 列表里只有「原画」一项，UI 不显示切换入口。
///
/// 这个类型刻意**不假设**有哪些档位 —— 档位是服务端的事，硬编码一份
/// 梯度表只会在服务端调整时变成谎言。
class QualityOption {
  const QualityOption({
    required this.id,
    required this.label,
    this.detail,
    this.url,
    this.isOriginal = false,
    this.height,
    this.width,
    this.bitrate,
    this.estimatedBytes,
  });

  /// 服务端档位标识：`origin` / `high` / `normal` / `low` / `super` / `2k` / `4k`
  final String id;

  /// 展示名：`原画` / `1080P` / `720P` / `超清` / `流畅`
  final String label;

  /// 补充说明：`1920×1080 · 4.2 Mbps`
  final String? detail;

  /// 这一档的播放地址。`null` 表示服务端列出了档位但没给地址（不可选）。
  final Uri? url;

  /// 是否是原画（未经转码的原文件）。
  ///
  /// 原画这一档**永远优先**：转码流会丢细节，而本应用的定位是本地媒体库
  /// 播放器，用户要的就是原片。
  final bool isOriginal;

  final int? height;
  final int? width;

  /// 码率（bps）
  final int? bitrate;

  /// 预估体积（字节）。服务端给了才填。
  final int? estimatedBytes;

  /// 是否可选（有地址）。
  bool get isAvailable => url != null;

  /// 展示用副标题。
  String get displayDetail {
    if (detail != null && detail!.isNotEmpty) return detail!;
    final parts = <String>[
      if (width != null && height != null) '$width×$height',
      if (bitrate != null) '${(bitrate! / 1000000).toStringAsFixed(1)} Mbps',
    ];
    return parts.join(' · ');
  }

  @override
  String toString() => 'QualityOption($id, $label'
      '${isOriginal ? ", 原画" : ""}${isAvailable ? "" : ", 不可用"})';
}

/// 清晰度档位的**展示名**推断。
///
/// 服务端只给标识（`super` / `high`），展示名要我们自己定。放在这里而不是
/// 各适配器里，是为了让「夸克叫 super、阿里叫 FHD」这类差异收敛到一处，
/// 用户看到的文案始终一致。
class QualityLabels {
  const QualityLabels._();

  /// 标识 → 展示名。命中不了时回退到 [fallback]。
  static String labelFor(String id) {
    final key = id.toLowerCase().trim();
    const table = {
      'origin': '原画',
      'original': '原画',
      'source': '原画',
      'raw': '原画',
      '4k': '4K',
      '2160p': '2160P',
      '2k': '2K',
      '1440p': '1440P',
      'super': '超清 1080P',
      'fhd': '1080P',
      '1080p': '1080P',
      'high': '高清 720P',
      'hd': '720P',
      '720p': '720P',
      'normal': '标清 480P',
      'sd': '480P',
      '480p': '480P',
      'low': '流畅 360P',
      '360p': '360P',
      'auto': '自动',
    };
    return table[key] ?? fallback(id);
  }

  /// 认不出来的档位：**原样显示标识**而不是猜一个中文名。
  ///
  /// 猜错的代价是用户选了「高清 720P」结果拿到 480P 的流，比看到一个
  /// 陌生的 `h265_1080` 更糟 —— 后者至少是诚实的。
  static String fallback(String id) => id.trim().isEmpty ? '未知' : id.trim();

  /// 原画档位在服务端可能的标识。
  static const Set<String> originalIds = {
    'origin', 'original', 'source', 'raw', 'blue', 'blueray', 'bluray',
  };

  /// 判断某个标识是否代表原画。
  static bool isOriginal(String id) =>
      originalIds.contains(id.toLowerCase().trim());

  /// 原画的权重哨兵值。
  ///
  /// 必须**小于任何可能的 `-height`**。这里原本是 `-1000`，而 4K 的权重是
  /// `-2160` —— 数值更小反而排在前面，清晰度菜单第一项成了 4K 而不是原画。
  /// 原画没有「高度」可言（它就是源文件本身），只能用哨兵值表达「它最大」。
  static const int _originalWeight = -100000;

  /// 排序权重：**原画最前**，然后按清晰度降序。
  static int sortWeight(QualityOption q) {
    if (q.isOriginal) return _originalWeight;
    final h = q.height;
    if (h != null) return -h;
    // 没有高度信息时按标识里的数字排（`1080p` 这种）
    final m = RegExp(r'(\d{3,4})').firstMatch(q.id);
    if (m != null) return -(int.tryParse(m.group(1)!) ?? 0);
    return 0;
  }
}
