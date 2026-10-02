import 'package:media_kit/media_kit.dart';

import '../../domain/services/intro_marker.dart';
import '../diagnostics/diag_log.dart';

/// 从正在播放的 mpv 里读容器章节，并认出片头。
///
/// ## 为什么放在 `core/utils/` 而不是 domain
///
/// 它要 `import package:media_kit`（为了 `NativePlayer.getProperty`），
/// 而 `domain/` 的规矩是**不碰插件**（见 `lib/domain/` 的目录约定）。
/// 「怎么读」留在这一层，「读出来的东西是什么意思」全部在
/// `domain/services/intro_marker.dart` 里 —— 两个播放器都只调这里，
/// 所以规则仍然只有一份。
///
/// ## 读取时机是**硬要求**：必须在容器解析完成之后
///
/// 实测（2026-10-02，真 libmpv）：`chapter-list` 在**打开文件之前**返回
/// `[]`，而「这个文件就是没有章节」返回的**也是** `[]`。两者在字符串上
/// 无法区分 —— 读早了会把「还没解析」当成「没有」，于是跳片头时灵时不灵，
/// 而且没有任何报错。
///
/// 所以本类**不做轮询、也不在 `open()` 之后立刻读**，而是由调用方在
/// 「`position` 已经大于 0」那一刻调一次（见 `PlaybackController` 里
/// `_probeChaptersOnce` 的调用点）。那时容器一定已经解完。
abstract final class MpvChapters {
  const MpvChapters._();

  /// 读一次章节清单。**任何失败都返回空列表，不抛异常**。
  ///
  /// 三种失败都归到「没有章节」：
  ///   - 平台不是 `NativePlayer`（理论上只有 web，本应用不涉及）；
  ///   - `getProperty` 抛异常（播放器已 dispose）；
  ///   - 读回来是空串 —— media_kit 的 `getProperty` **丢掉 mpv 的返回码**，
  ///     属性不存在时给的就是空串（同一个坑见 `PlayerBufferConfig`）。
  ///
  /// 为什么不该抛：章节读不出来只该让「跳片头」不生效，不该把播放搞挂。
  static Future<List<IntroChapter>> read(Player player) async {
    try {
      final platform = player.platform;
      if (platform is! NativePlayer) return const [];
      final raw = await platform.getProperty('chapter-list');
      if (raw.isEmpty) return const [];
      return MpvChapterList.parse(raw);
    } catch (e) {
      diag.debug('片头', '读章节清单失败（不影响播放）：$e');
      return const [];
    }
  }

  /// 读一次并直接给出片头区间。认不出来返回 `null`。
  ///
  /// [label] 只进诊断日志，用来对上「哪一集」—— 跳片头出问题时第一件要
  /// 确认的事就是「到底有没有读到章节」。
  static Future<IntroMarker?> detectIntro(
    Player player, {
    String label = '',
  }) async {
    final chapters = await read(player);
    if (chapters.isEmpty) {
      // 绝大多数网盘片源走到这里（压制时没写章节）。用 debug 而不是 info：
      // 它是常态，不该把诊断日志刷满。
      diag.debug('片头', '${_prefix(label)}没有章节标记');
      return null;
    }

    final marker = IntroMarkerDetector.detect(chapters);
    if (marker == null) {
      // 有章节但没认出片头。这条**必须**留痕（info 级）：用户报「怎么不跳
      // 片头」时，要能一眼看出是「章节名不匹配」还是「根本没读到章节」——
      // 两者的修法完全不同（前者改关键词表，后者查读取时机）。
      diag.info(
        '片头',
        '${_prefix(label)}有 ${chapters.length} 个章节但没认出片头：'
        '${chapters.map((c) => '"${c.title}"@${c.start.inSeconds}s').join(' ')}',
      );
      return null;
    }

    diag.info(
      '片头',
      '${_prefix(label)}认出片头 ${marker.start.inSeconds}s→'
      '${marker.end.inSeconds}s（${marker.length.inSeconds}s）',
    );
    return marker;
  }

  static String _prefix(String label) => label.isEmpty ? '' : '$label：';
}
