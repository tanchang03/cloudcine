import 'package:flutter/material.dart';

import '../../core/utils/format.dart';
import '../../domain/entities/cloud_account.dart';
import '../theme/app_theme.dart';

/// 容量条的告警档位。
///
/// 做成枚举而不是直接给颜色：**档位是语义、颜色是皮肤**。测试要钉的是
/// 「用到 95% 要变红」，而不是「那天的红是 `0xFFFF6B6B`」—— 后者改一次主题
/// 就要改一遍测试，前者不会。
enum StorageLevel {
  /// 还宽裕
  normal,

  /// 该考虑清理了
  warn,

  /// 快满了（传不上去就是这一档）
  danger,
}

/// 网盘容量条 —— 文件夹页头下面那一行：`▓▓▓░░░░  1.5 TB / 2.0 TB · 剩 512 GB`。
///
/// ## 为什么放在文件夹视图
///
/// 「还剩多少空间」是**在网盘上放东西**时才要问的问题，而文件夹视图正是那个
/// 「网盘上现在是怎么放的」的视图：翻到某一层发现想传的片子传不上去时，
/// 答案就在同一屏里，不用跑去设置页翻账号信息。
///
/// ## 数据是**快照**，所以要有一条刷新路径
///
/// [CloudAccount.storageUsedBytes] 取自授权/恢复会话那一刻，之后用户传片删片
/// 都不会自己变。刷新由 `FolderPage` 负责（进页面拉一次 + 页头「刷新」按需拉），
/// 这个组件只管画。
///
/// ## 拿不到容量时**整行不画**
///
/// 不画「未知」，也不画成 `0 B / 0 B`：后者会被读成「网盘满了」，与事实正好
/// 相反。这条判据收在组件里而不是让调用方各自判断 —— 调用方有两处
/// （页面与测试），漏一处就会出现一行莫名其妙的零。
class DriveStorageMeter extends StatelessWidget {
  const DriveStorageMeter({super.key, required this.account});

  /// 当前账号。`null`（未登录）或没有容量信息时整行不画。
  final CloudAccount? account;

  /// 用到这个比例就换成警示色。
  static const double warnRatio = 0.85;

  /// 用到这个比例就换成危险色 —— 这时候「传不上去」已经近在眼前。
  static const double dangerRatio = 0.95;

  /// 进度条填充块的 Key。测试靠它读颜色与宽度。
  static const Key fillKey = Key('storage-meter-fill');

  /// 进度条尺寸。刻意做小：它是**背景信息**，不该跟列表抢注意力。
  static const double barWidth = 96;
  static const double barHeight = 6;

  /// 占比 → 档位。判据是 `>=`（刚好 85% 就算警示）。
  static StorageLevel levelFor(double ratio) {
    if (ratio >= dangerRatio) return StorageLevel.danger;
    if (ratio >= warnRatio) return StorageLevel.warn;
    return StorageLevel.normal;
  }

  static Color colorFor(StorageLevel level) => switch (level) {
        StorageLevel.normal => AppTheme.accent,
        StorageLevel.warn => AppTheme.warn,
        StorageLevel.danger => AppTheme.danger,
      };

  @override
  Widget build(BuildContext context) {
    final acc = account;
    if (acc == null || !acc.hasStorageInfo) return const SizedBox.shrink();

    final used = acc.storageUsedBytes ?? 0;
    final total = acc.storageTotalBytes!;
    final text = formatStorageUsage(used, total);
    // 总量非正数时 `formatStorageUsage` 给空串（见它的文档）。
    if (text.isEmpty) return const SizedBox.shrink();

    final ratio = acc.storageRatio ?? 0;
    final color = colorFor(levelFor(ratio));

    return Padding(
      // 左边距与 `PageHeader` 对齐（22），否则这一行会比标题突出去一块。
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 10),
      child: Tooltip(
        // 悬停给**精确字节与百分比**：`1.5 TB` 这种四舍五入后的数字看不出
        // 「还差 3 GB 就满」。电视上没有 hover，所以关键信息必须在正文里
        // 已经说完 —— tooltip 只是补充。
        message: '已用 ${formatBytes(used, fractionDigits: 2)}'
            ' / 共 ${formatBytes(total, fractionDigits: 2)}'
            '（${(ratio * 100).toStringAsFixed(1)}%）',
        child: Row(
          children: [
            const Icon(Icons.cloud_outlined, size: 13, color: AppTheme.dim),
            const SizedBox(width: 6),
            _Bar(ratio: ratio, color: color),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: AppTheme.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.ratio, required this.color});

  final double ratio;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final w = ratio.isFinite ? ratio.clamp(0.0, 1.0).toDouble() : 0.0;
    const radius = BorderRadius.all(Radius.circular(DriveStorageMeter.barHeight / 2));

    return Container(
      width: DriveStorageMeter.barWidth,
      height: DriveStorageMeter.barHeight,
      decoration: const BoxDecoration(
        color: AppTheme.panel3,
        borderRadius: radius,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: w,
          child: Container(
            key: DriveStorageMeter.fillKey,
            decoration: BoxDecoration(color: color, borderRadius: radius),
          ),
        ),
      ),
    );
  }
}
