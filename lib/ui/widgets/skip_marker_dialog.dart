import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/media_work.dart';
import '../../domain/services/work_skip_format.dart';
import '../providers/app_providers.dart';
import '../theme/app_theme.dart';

/// **手动指定片头 / 片尾的时间点**。
///
/// ## 为什么需要它
///
/// 自动学习要攒够几集样本才敢下结论，而且它对「用户拖一下」这件事的动机
/// 是**猜**的。猜错了没有报错，只有「它跳到一个莫名其妙的位置」或者
/// 「它学了好几集还是不跳」。这时用户唯一想要的就是**自己填一个数字**。
///
/// ## ⛔ 三个字段是「一整组」
///
/// 它们在进度文件里是 [WorkSkipEntry] 的手标组，LWW 是**按组**判胜负的。
/// 所以保存时三个值一起写（没填的保持原样），而「清除」是**三列一起清**
/// —— 只清一半的话，下一次同步会把剩下那半原样铺回来，界面上看起来是
/// 「清不干净」。
///
/// ## ⛔ 片尾填的是「距末尾多久」，不是绝对时间
///
/// 各集片长不同（正片 45 分钟、特辑 60 分钟），在第 1 集上量出来的
/// 「41:30」搬到第 2 集是错的；而「离结尾还有 90 秒」在两集上是同一件事。
/// 播放器用 `片长 - 偏移` 现算落点。
class SkipMarkerDialog extends ConsumerStatefulWidget {
  const SkipMarkerDialog({super.key, required this.work});

  final MediaWork work;

  /// 打开对话框。返回 `true` = 用户改了东西。
  static Future<bool> show(BuildContext context, MediaWork work) async {
    final saved = await showDialog<bool>(
      context: context,
      // 用户可能刚把三个时间敲完 —— 点外面误关掉要重敲一遍。
      barrierDismissible: false,
      builder: (_) => SkipMarkerDialog(work: work),
    );
    return saved ?? false;
  }

  @override
  ConsumerState<SkipMarkerDialog> createState() => _SkipMarkerDialogState();
}

class _SkipMarkerDialogState extends ConsumerState<SkipMarkerDialog> {
  late final TextEditingController _start;
  late final TextEditingController _end;
  late final TextEditingController _outro;

  /// 「刚才那一下为什么没生效」。
  ///
  /// 这个对话框里**没有**一种失败会弹系统提示，而静默失败特别多：
  /// 时间格式不对、终点早于起点、解析出来是 0。所以这一行必须有。
  String? _hint;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // 手标那一半用现有值预填；学习出来的**不预填** ——
    // 那是机器猜的，预填进「手动指定」的输入框等于把猜测说成用户的选择。
    _start = TextEditingController(
      text: widget.work.introStartMs == null
          ? ''
          : WorkSkipFormat.clock(widget.work.introStartMs),
    );
    _end = TextEditingController(
      text: widget.work.introEndMs == null
          ? ''
          : WorkSkipFormat.clock(widget.work.introEndMs),
    );
    _outro = TextEditingController(
      text: widget.work.outroOffsetMs == null
          ? ''
          : WorkSkipFormat.clock(widget.work.outroOffsetMs),
    );
  }

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    _outro.dispose();
    super.dispose();
  }

  /// 读一个输入框。`null` = 没填（**不改这一项**）；
  /// 填了却解析不了 → 抛 [_BadTime]（调用方据此提示，绝不记成 0）。
  int? _read(TextEditingController c, String label) {
    final raw = c.text.trim();
    if (raw.isEmpty) return null;
    final ms = WorkSkipFormat.parseClock(raw);
    if (ms == null) throw _BadTime('「$raw」不是时间 —— 写成 1:30 或 90（秒）');
    if (ms <= 0) throw _BadTime('$label 不能是 0');
    return ms;
  }

  Future<void> _save() async {
    int? startMs;
    int? endMs;
    int? outroMs;
    try {
      startMs = _read(_start, '片头起点');
      endMs = _read(_end, '片头终点');
      outroMs = _read(_outro, '片尾偏移');
    } on _BadTime catch (e) {
      setState(() => _hint = e.message);
      return;
    }
    if (startMs != null && endMs != null && endMs <= startMs) {
      setState(() => _hint = '片头终点必须晚于起点（现在是反的）');
      return;
    }

    setState(() => _saving = true);
    final repo = ref.read(mediaRepositoryProvider);
    final key = widget.work.key;
    // ⛔ 没填的字段**不调用**对应方法：手标是一整组，「传空 = 不改」。
    //    调一次 `setWorkIntroStart(key, 0)` 会把用户原来标好的起点抹掉。
    if (startMs != null) await repo.setWorkIntroStart(key, startMs);
    if (endMs != null) await repo.setWorkIntroEnd(key, endMs);
    if (outroMs != null) await repo.setWorkOutroOffset(key, outroMs);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _clearManual() async {
    setState(() => _saving = true);
    // 三列一起清。学习那一组**不动** —— 用户可能只是想回到「让它自己学」。
    await ref.read(mediaRepositoryProvider).clearWorkIntroRange(widget.work.key);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _clearLearned() async {
    setState(() => _saving = true);
    await ref.read(mediaRepositoryProvider).clearLearnedSkip(widget.work.key);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.work;
    final learned = WorkSkipFormat.hasAny(w) && w.introRange == null && w.outroOffsetMs == null;

    return Dialog(
      backgroundColor: AppTheme.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppTheme.line, width: 0.5),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 10, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.fast_forward_rounded,
                      size: 18,
                      color: AppTheme.accent,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '片头 / 片尾',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.text,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '对整部「${w.title}」生效（每一集共用）',
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 当前生效的结论。写的就是播放器真的会跳的那个位置，
                    // 用户改之前必须先知道现在是什么。
                    _currentLine(w),
                    const SizedBox(height: 14),
                    _field(_start, '片头起点', '留空 = 不改'),
                    const SizedBox(height: 9),
                    _field(_end, '片头终点', '留空 = 不改'),
                    const SizedBox(height: 9),
                    _field(_outro, '片尾（距末尾）', '留空 = 不改'),
                    const SizedBox(height: 8),
                    Text(
                      '时间写成 1:30 或 90 都行。片尾填的是「离结束还有多久」，'
                      '不是绝对时间 —— 各集片长不一样，填绝对时间会在别的集上跳错。',
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.6,
                        color: AppTheme.dim,
                      ),
                    ),
                    if (_hint != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        _hint!,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppTheme.warn,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 11, 18, 12),
              child: Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (_saving)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else ...[
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('取消'),
                    ),
                    if (learned)
                      TextButton(
                        onPressed: _clearLearned,
                        child: const Text('清除自动学习的结论'),
                      ),
                    if (w.hasManualSkip)
                      TextButton(
                        onPressed: _clearManual,
                        child: const Text('清除手标'),
                      ),
                    FilledButton(
                      onPressed: _save,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.accent,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      child: const Text('保存'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 当前生效的结论（手标 > 学习，与播放器同一条优先级链）。
  Widget _currentLine(MediaWork w) {
    final line = WorkSkipFormat.line(w);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: AppTheme.line, width: 0.5),
      ),
      child: Text(
        line ?? '还没有片头 / 片尾结论 —— 可以手动指定，或看几集让它自己学',
        style: const TextStyle(fontSize: 12, height: 1.5, color: AppTheme.text),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, String hint) {
    return Row(
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: AppTheme.muted),
          ),
        ),
        Expanded(
          child: TextField(
            controller: c,
            style: const TextStyle(fontSize: 12.5, color: AppTheme.text),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: const BorderSide(color: AppTheme.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: const BorderSide(color: AppTheme.line),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        const Text(
          'mm:ss',
          style: TextStyle(fontSize: 11, color: AppTheme.dim),
        ),
      ],
    );
  }
}

/// 输入框里的时间解析不了。只在对话框内部用 —— 它要携带
/// 「哪一句提示」这个信息，用异常比用返回值好读。
class _BadTime implements Exception {
  const _BadTime(this.message);

  final String message;
}
