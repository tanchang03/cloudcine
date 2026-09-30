/// 文件名切分工具。
///
/// 单独成文件是因为它被**三条互不相干的路径**共用：视频识别、图片识别、
/// 字幕匹配。塞进其中任何一个都会让另外两个反向依赖它。
library;

/// 取小写扩展名（不含点）。
///
/// 用**最后一个点**切分：`The.Wandering.Earth.II.2023.mkv` 的扩展名是 `mkv`。
///
/// 三种返回 `null` 的情况都是刻意的：
///   - 没有点（`README`）；
///   - 点在最前（`.gitignore` —— 那是隐藏文件名，不是扩展名）；
///   - 点在最后（`file.`）。
String? extensionOf(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0 || dot == fileName.length - 1) return null;
  return fileName.substring(dot + 1).toLowerCase();
}

/// 去掉扩展名。
String baseNameOf(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0) return fileName;
  return fileName.substring(0, dot);
}

/// 把 `Set<String>` 的扩展名集合做成判据，避免每处都写 `contains`。
bool hasExtension(String fileName, Set<String> extensions) {
  final ext = extensionOf(fileName);
  return ext != null && extensions.contains(ext);
}
