/// 文件名与目录名的切分、比较工具。
///
/// 单独成文件是因为切分那几个被**三条互不相干的路径**共用：视频识别、
/// 图片识别、字幕匹配。塞进其中任何一个都会让另外两个反向依赖它。
library;

/// 自然序比较：名字里的**连续数字段按数值比**，其余按字符比。
///
/// ## 为什么不能用 `String.compareTo`
///
/// 目录列表里全是 `第2期` / `第10期` / `S01` / `S10` 这种名字，逐字符比较
/// 会把 `第10期` 排在 `第2期` **前面**（因为 `'1' < '2'`），而用户扫一眼
/// 目录时按的正是数字顺序。`自然序` 就是「人看着顺眼」的那个顺序。
///
/// ## 三条口径
///
///   - **大小写不敏感**：`a` 与 `A` 算同一个字符，否则大写会整批挤到前面；
///   - **前导零不影响数值**：`007` 与 `7` 数值相等，此时回落到逐字符比较，
///     保证「两个不同的名字」永远有确定顺序（排序稳定，不会每次刷新换位置）；
///   - **位数多的更大**：按字符串长度比而不是解析成 `int`，避免超长数字段
///     溢出 —— 文件名里的数字段长度是不受控的。
int naturalCompare(String a, String b) {
  final la = a.toLowerCase();
  final lb = b.toLowerCase();

  var i = 0;
  var j = 0;
  while (i < la.length && j < lb.length) {
    final ca = la.codeUnitAt(i);
    final cb = lb.codeUnitAt(j);
    final digitA = _isAsciiDigit(ca);
    final digitB = _isAsciiDigit(cb);

    if (digitA && digitB) {
      // 前导零：先各自跳过，`007` 与 `7` 才能比出「相等」而不是「位数不同」。
      var startA = i;
      var startB = j;
      while (startA < la.length && la.codeUnitAt(startA) == 0x30) {
        startA++;
      }
      while (startB < lb.length && lb.codeUnitAt(startB) == 0x30) {
        startB++;
      }
      var endA = startA;
      var endB = startB;
      while (endA < la.length && _isAsciiDigit(la.codeUnitAt(endA))) {
        endA++;
      }
      while (endB < lb.length && _isAsciiDigit(lb.codeUnitAt(endB))) {
        endB++;
      }

      final lenA = endA - startA;
      final lenB = endB - startB;
      if (lenA != lenB) return lenA - lenB;
      for (var k = 0; k < lenA; k++) {
        final d = la.codeUnitAt(startA + k) - lb.codeUnitAt(startB + k);
        if (d != 0) return d;
      }

      // 数值相同（`7` vs `007`）就往后看，不要在这里判等 —— 后面还有内容。
      i = endA;
      j = endB;
      continue;
    }

    if (ca != cb) return ca - cb;
    i++;
    j++;
  }

  final rest = (la.length - i) - (lb.length - j);
  if (rest != 0) return rest;

  // 小写后完全一样（`ABC` vs `abc`）：用原串定序，否则两个不同的名字会
  // 被排成「相等」，而 Dart 的 `List.sort` 不保证稳定 —— 列表每次重建
  // 都可能换位置，看起来像在乱跳。
  return a.compareTo(b);
}

bool _isAsciiDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

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
