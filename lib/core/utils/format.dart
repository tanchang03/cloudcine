/// 展示层格式化工具。
///
/// 纯函数、无副作用，便于单元测试。
library;

/// 把字节数格式化成人类可读文本。
///
/// 采用 1024 进制。`null` / 负数返回「未知」，`0` 返回 `0 B`。
String formatBytes(int? bytes, {int fractionDigits = 1}) {
  if (bytes == null || bytes < 0) return '未知';
  if (bytes == 0) return '0 B';

  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 ? 0 : fractionDigits;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// 网盘容量的展示文案：`1.5 TB / 2.0 TB · 剩 512.0 GB`。
///
/// 三段都是用户真正要问的：**总共多少、用了多少、还剩多少**。只给前两段的话
/// 「还能不能传上去」得自己心算，而这正是这一行存在的理由。
///
/// ⚠️ 剩余量**夹在 0**：服务端给出的两份数字来自同一响应，但配额降档、会员
/// 到期这类时刻仍可能凑出 `used > total`。减出负数会让界面显示
/// 「剩 -3 GB」这种自相矛盾的话，用户会当成 bug 报上来。
///
/// [totalBytes] 非正数时返回**空串**而不是 `0 B / 0 B` —— 调用方据此整行不画
/// （见 `DriveStorageMeter`）。把「不知道」画成「0」会被读成「网盘满了」。
String formatStorageUsage(int usedBytes, int totalBytes) {
  if (totalBytes <= 0) return '';
  final used = usedBytes < 0 ? 0 : usedBytes;
  final remaining = totalBytes > used ? totalBytes - used : 0;
  return '${formatBytes(used)} / ${formatBytes(totalBytes)}'
      ' · 剩 ${formatBytes(remaining)}';
}

/// 把时长格式化成 `mm:ss` 或 `h:mm:ss`。
///
/// `null` 返回 `--:--`，与播放器占位一致。
///
/// ⚠️ **目前没有任何界面在用这个函数。** 页面与组件用的是
/// `ui/theme/app_theme.dart` 里的同名函数（分钟不补零、零值给 `--:--`），
/// 两者输出不一致 —— 改这里不会影响界面，改界面也不会走到这里。
/// 这个版本目前没有用例覆盖（`test/core/format_test.dart` 只覆盖本文件里
/// 的 `formatRelativeTime` / `formatDateTimeMinute`），别按它去推界面的显示。
String formatDuration(Duration? d) {
  if (d == null) return '--:--';
  final negative = d.isNegative;
  final total = d.inSeconds.abs();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  final text = h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  return negative ? '-$text' : text;
}

/// 把码率（**bps**）格式化成 `320 kbps` / `7.8 Mbps`。
///
/// 单位是 bps —— 这一点必须显式写在函数上。项目里同一个量出现过三种单位：
/// mpv 的 `demux-bitrate` 是 bps，夸克 `play/info` 的 `bitrate` 是 **kbps**，
/// 而界面上要显示 Mbps。单位错了不报错，只是数字差一千倍，所以宁可多写一句。
///
/// `null` / 非正数返回「未知」而不是 `0 Mbps` —— 后者会被读成「码率真的是 0」。
String formatBitrate(int? bps) {
  if (bps == null || bps <= 0) return '未知';
  if (bps < 1000000) return '${(bps / 1000).toStringAsFixed(0)} kbps';
  return '${(bps / 1000000).toStringAsFixed(1)} Mbps';
}

/// 大数字缩写：`1234` → `1.2k`
String formatCount(int n) {
  if (n < 1000) return '$n';
  if (n < 10000) return '${(n / 1000).toStringAsFixed(1)}k';
  if (n < 1000000) return '${(n / 1000).toStringAsFixed(0)}k';
  return '${(n / 1000000).toStringAsFixed(1)}M';
}

/// 扫描进度的百分比（0.0 ~ 1.0）。分母为 0 时返回 `null`。
double? ratio(int done, int total) {
  if (total <= 0) return null;
  final r = done / total;
  return r.clamp(0.0, 1.0);
}

/// 相对时间描述：`刚刚` / `3 分钟前` / `2 天前` / `2026-09-01`
String formatRelativeTime(DateTime time, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final diff = ref.difference(time);
  if (diff.isNegative) return '刚刚';
  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  final y = time.year.toString().padLeft(4, '0');
  final m = time.month.toString().padLeft(2, '0');
  final d = time.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// 精确到分钟的时刻：`2026-10-03 16:41`。
///
/// 与 [formatRelativeTime] 配套用：相对时间（`3 天前`）负责「扫一眼看新旧」，
/// 这一份负责回答「到底是哪一刻」—— 目录视图把它放在 tooltip 里，
/// 因为把完整时刻印进列表会让那一列宽到比文件名还长。
///
/// ⚠️ 不补时区、不做本地化：时间戳全部来自网盘（夸克给的是本地时区的
/// 字符串，解析后就是本机时间）。加一层 `toLocal()` 只会在别的时区上
/// 把同一个时刻显示成两个不同的值。
String formatDateTimeMinute(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${time.year.toString().padLeft(4, '0')}-${two(time.month)}-'
      '${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
}
