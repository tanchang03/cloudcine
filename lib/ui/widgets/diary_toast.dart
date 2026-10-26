import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/diary_provider.dart';
import '../theme/app_theme.dart';

/// 刚刚自动记入的那一条，用于顶部非模态提示条（设计文档 §8.5）。
///
/// 由同步调度在「本轮捕种到了新达标的作品」时写入；媒体库页/日记页读它弹条。
/// 它是**一次性**的 —— 用户忽略或 5 秒后自动清空，不进任何持久存储。
class DiaryToastData {
  const DiaryToastData({required this.id, required this.title});
  final String id;
  final String title;
}

/// 全局 holder：当前「刚记入」的那条（可空）。
final diaryToastProvider = StateProvider<DiaryToastData?>((_) => null);

/// 顶部非模态提示条：「《X》已记入观影日记 [去评分] [撤销]」。
///
/// 非模态：不打断播放、不挡内容，5 秒后自动消失（设计文档 §8.5）。
/// 「去评分」跳到日记详情；「撤销」把这条移出日记（写墓碑）。
class DiaryRecordedToast extends ConsumerStatefulWidget {
  const DiaryRecordedToast({super.key});

  @override
  ConsumerState<DiaryRecordedToast> createState() => _DiaryRecordedToastState();
}

class _DiaryRecordedToastState extends ConsumerState<DiaryRecordedToast> {
  @override
  void initState() {
    super.initState();
    // 挂载后若已有待显示条目，起 5 秒自动消失计时。
    WidgetsBinding.instance.addPostFrameCallback((_) => _arm());
  }

  void _arm() {
    final data = ref.read(diaryToastProvider);
    if (data == null) return;
    Future<void>.delayed(const Duration(seconds: 5), () {
      if (mounted && ref.read(diaryToastProvider)?.id == data.id) {
        ref.read(diaryToastProvider.notifier).state = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(diaryToastProvider);
    if (data == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.panel2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.line),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_rounded, color: AppTheme.ok, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '《${data.title}》已记入观影日记',
              style: const TextStyle(color: AppTheme.text, fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () {
              ref.read(diaryToastProvider.notifier).state = null;
              context.push('/diary/detail?id=${Uri.encodeComponent(data.id)}');
            },
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.accent,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('去评分', style: TextStyle(fontSize: 13)),
          ),
          TextButton(
            onPressed: () {
              ref.read(diaryNotifierProvider.notifier).remove(data.id);
              ref.read(diaryToastProvider.notifier).state = null;
            },
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.muted,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('撤销', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
