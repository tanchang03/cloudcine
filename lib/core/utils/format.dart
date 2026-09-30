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

/// 把时长格式化成 `mm:ss` 或 `h:mm:ss`。
///
/// `null` 返回 `--:--`，与播放器占位一致。
///
/// ⚠️ **目前没有任何界面在用这个函数。** 页面与组件用的是
/// `ui/theme/app_theme.dart` 里的同名函数（分钟不补零、零值给 `--:--`），
/// 两者输出不一致 —— 改这里不会影响界面，改界面也不会走到这里。
/// 这个版本只被 `test/core/format_test.dart` 覆盖着，别按它去推界面的显示。
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
