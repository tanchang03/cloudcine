import '../entities/media_work.dart';

/// 作品简介页上「片头 / 片尾」那一行的**文案**。
///
/// ## 它回答的问题：到底跳到几秒？
///
/// 学习（或手标）出来的结论如果只显示成「已学到片头」，用户是没有办法判断
/// 它对不对的 —— 而判断不了就没法决定「要不要手动改一下」。
/// 所以这一行必须写**具体时间点**，并且说清**这个值是谁给的**：
///
/// ```text
/// 片头 00:00–01:32（手标） · 片尾 距末尾 01:20（自动学习）
/// ```
///
/// 两个括号里的词是这个功能诚实的代价：同一个位置有两种来源，而它们的
/// 可信度完全不同（一个是用户自己按下的，一个是机器从几次拖拽里猜的）。
/// 混在一起说「片头 01:32」的话，猜错了用户也不知道该怪谁。
///
/// ## ⛔ 片尾为什么写成「距末尾」而不是绝对时间
///
/// `media_works` 里存的就是**距末尾的偏移**（各集片长不同，绝对时间跨集
/// 不可比）。这一行照实写它，而不是拿某一集的片长去折算出一个假的绝对时间
/// —— 折算出来的那个数字在别的集上是错的，而它看起来却是对的。
///
/// ## 与 Android 端的关系
///
/// 电视上同一行由 `WorkDetailFormat.skipLine` 输出。两边的措辞不需要逐字
/// 一致（电视屏幕大、PC 信息密度高），但**「手标 > 学习」这条优先级链必须
/// 一致** —— 否则同一部作品在两台设备上显示的片头时间不一样，用户只会认为
/// 同步坏了。
class WorkSkipFormat {
  const WorkSkipFormat._();

  /// 片头那一半（含来源）；没有片头结论时返回 `null`。
  static String? introLine(MediaWork w) {
    final manual = w.introRange;
    if (manual != null) {
      return '片头 ${clock(manual.start.inMilliseconds)}–'
          '${clock(manual.end.inMilliseconds)}（手标）';
    }
    final learned = w.learnedIntroRange;
    if (learned != null) {
      return '片头 ${clock(learned.start.inMilliseconds)}–'
          '${clock(learned.end.inMilliseconds)}（自动学习）';
    }
    return null;
  }

  /// 片尾那一半（含来源）；没有片尾结论时返回 `null`。
  static String? outroLine(MediaWork w) {
    final manual = w.outroOffsetMs;
    if (manual != null && manual > 0) {
      return '片尾 距末尾 ${clock(manual)}（手标）';
    }
    final learned = w.learnedOutroOffsetMs;
    if (learned != null && learned > 0) {
      return '片尾 距末尾 ${clock(learned)}（自动学习）';
    }
    return null;
  }

  /// 整行；片头片尾都没有时返回 `null`（那一整行都不该出现，
  /// 而不是显示一个空的「片头 —」）。
  ///
  /// 只有一半时只显示那一半 —— 先学出片头、片尾还没攒够样本，
  /// 这时候写「片尾 未学会」是噪音。
  static String? line(MediaWork w) {
    final parts = <String>[
      if (introLine(w) case final s?) s,
      if (outroLine(w) case final s?) s,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// 有没有任何片头 / 片尾结论（手标或学习任一成立）。
  static bool hasAny(MediaWork w) => introLine(w) != null || outroLine(w) != null;

  /// `ms` → `mm:ss` / `h:mm:ss`。
  ///
  /// ⛔ 不复用 `core/utils/format.dart` 的 `formatDuration`：那份实现与
  ///    界面实际在用的不是同一个（它自己的注释里就写了「目前没有任何界面
  ///    在用」）。这里只服务这一行文案，规则只有一份。
  ///    `null` / 负数返回 `00:00`（这一行永远不该出现 `--:--`）。
  static String clock(int? ms) {
    final total = (ms == null || ms < 0) ? 0 : (ms ~/ 1000);
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  /// `mm:ss` / `h:mm:ss` → 毫秒。解析不了返回 `null`。
  ///
  /// 手动指定时间点的输入框吃的就是这个函数：
  /// 允许 `90`（纯秒）、`1:30`、`01:30`、`1:02:03` 四种写法 ——
  /// 用户脑子里的时间是「一分半」，让他先换算成 90 秒再输入是没道理的。
  static int? parseClock(String text) {
    final raw = text.trim();
    if (raw.isEmpty) return null;
    final parts = raw.split(':');
    if (parts.length > 3) return null;
    var total = 0;
    for (final p in parts) {
      final v = int.tryParse(p.trim());
      if (v == null || v < 0) return null;
      total = total * 60 + v;
    }
    return total * 1000;
  }
}
