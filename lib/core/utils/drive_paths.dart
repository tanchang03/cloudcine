/// 网盘展示路径的归一化工具。
///
/// ## 为什么需要单独一套
///
/// 扫描器拼出来的路径（`ScanService._joinPath`）与用户/界面手里的路径形状不同：
///
/// | 来源 | 形状 |
/// |---|---|
/// | `MediaItem.dirPath`（扫描器写的） | `/电影/`、根是 `/` —— **一律带结尾斜杠** |
/// | 目录树内部 | `/电影`、根是 `/` —— **不带**结尾斜杠 |
/// | 用户从剪贴板粘进来的 | `/电影`、`电影`、`/电影/`、`\\电影` 都可能 |
///
/// 三者混在一起时，`/电影` 与 `/电影/` 会变成两个不同的键 —— 表现为目录树里
/// 出现两个同名目录、或者「按目录过滤」一条都查不到。所以**入库前必须过一道
/// 归一化**，而这道归一化只能有一份实现（放在 `core/` 里，谁都能用，
/// 也谁都改不动别人的层）。
///
/// 纯函数、无依赖，可直接单测。
library;

/// 根目录路径。归一化的**不动点**：`normalize('/') == '/'`。
const String driveRootPath = '/';

/// 归一化路径：统一分隔符、去掉重复段与结尾斜杠、补上前导斜杠。
///
/// ```dart
/// normalize('')                 // '/'
/// normalize('电影')             // '/电影'
/// normalize('/电影/科幻/')      // '/电影/科幻'
/// normalize('//电影//科幻//')   // '/电影/科幻'
/// normalize(r'\电影\科幻')      // '/电影/科幻'
/// ```
///
/// `.` 段被丢弃（相对路径的残留）；`..` **不处理** —— 网盘目录名里真的
/// 可以有 `..`，把它当上级会把两个不同目录并成一个。
String normalizeDrivePath(String raw) {
  final cleaned = raw.trim().replaceAll('\\', '/');
  if (cleaned.isEmpty) return driveRootPath;
  final parts =
      cleaned.split('/').where((p) => p.isNotEmpty && p != '.').toList();
  if (parts.isEmpty) return driveRootPath;
  return '/${parts.join('/')}';
}

/// 扫描器风格的路径：**带结尾斜杠**。根仍是单独的 `/`。
///
/// 用来和 `MediaItem.dirPath` 直接比较或做前缀匹配。
String drivePathWithTrailingSlash(String path) {
  final p = normalizeDrivePath(path);
  return p == driveRootPath ? driveRootPath : '$p/';
}

/// 拼一个子目录的展示路径：`<base>/<name>/`（**带结尾斜杠**）。
///
/// 这是扫描器与局部发现共同使用的口径 —— 它写出来的形状必须与
/// `MediaItem.dirPath` 完全一致（`/电影/流浪地球2 (2023)/`），
/// 否则目录视图按路径归并时，同一个目录会裂成两个键。
///
/// [base] 传什么都不影响结果（`/电影`、`/电影/`、`电影` 都归一成 `/电影`），
/// 因为内部先过一道 [normalizeDrivePath]。根目录拼出来是 `/name/`。
String drivePathJoin(String base, String name) {
  final b = normalizeDrivePath(base);
  if (b == driveRootPath) return '/$name/';
  return '$b/$name/';
}

/// 父目录路径。**根的父亲是它自己** —— 调用方据此判断「已经在最上层」，
/// 不需要额外判空。
String drivePathParent(String path) {
  final p = normalizeDrivePath(path);
  if (p == driveRootPath) return driveRootPath;
  final idx = p.lastIndexOf('/');
  return idx <= 0 ? driveRootPath : p.substring(0, idx);
}

/// 末段目录名。根返回 `/`。
String drivePathName(String path) {
  final p = normalizeDrivePath(path);
  if (p == driveRootPath) return driveRootPath;
  return p.substring(p.lastIndexOf('/') + 1);
}

/// 把归一化路径切成目录名列表。根返回空列表。
List<String> drivePathSegments(String path) {
  final p = normalizeDrivePath(path);
  if (p == driveRootPath) return const [];
  return p.split('/').where((s) => s.isNotEmpty).toList(growable: false);
}

/// [child] 是否在 [ancestor] 之下（**含它本身**）。
///
/// 前缀比较必须补上结尾斜杠再比：不补的话 `/电影2` 会被判成 `/电影` 的子目录，
/// 而「按目录筛文件」时那会让一个不相干的目录混进结果。
bool drivePathIsUnder(String child, String ancestor) {
  final c = normalizeDrivePath(child);
  final a = normalizeDrivePath(ancestor);
  if (a == driveRootPath) return true;
  if (c == a) return true;
  return c.startsWith('$a/');
}
