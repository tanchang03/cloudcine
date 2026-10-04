import 'package:media_kit/media_kit.dart';

import '../../domain/services/intro_marker.dart';
import '../diagnostics/diag_log.dart';

/// 从 mpv 里读容器章节。**只有 `MediaKitPlaybackEngine` 会调它**。
///
/// ## 为什么放在 `core/utils/` 而不是 domain
///
/// 它要 `import package:media_kit`（为了 `NativePlayer.getProperty`），
/// 而 `domain/` 的规矩是**不碰插件**（见 `lib/domain/` 的目录约定）。
/// 「怎么读」留在这一层；「读出来的东西是什么意思」（认片头）在
/// `domain/services/intro_marker.dart` 里 —— 两个内核共用那一份判定。
///
/// ## ⚠️ 别从这里直接认片头
///
/// 这里曾经有一个 `detectIntro(player)` 的便捷方法，两个播放器都调它。
/// 迁移到「两个内核按需路由」之后它变成了**第二个人口**：fvp 那边根本没有
/// `Player`，走它只能拿到空章节，而症状是「DV 片源上跳片头静默失效」。
/// 所以判定收口到契约（`PlaybackEngine.chapters` →
/// [IntroMarkerDetector.detectAndLog]），本类只剩「怎么读」。
///
/// ## 读取时机是**硬要求**：必须在容器解析完成之后
///
/// 实测（2026-10-02，真 libmpv）：`chapter-list` 在**打开文件之前**返回
/// `[]`，而「这个文件就是没有章节」返回的**也是** `[]`。两者在字符串上
/// 无法区分 —— 读早了会把「还没解析」当成「没有」，于是跳片头时灵时不灵，
/// 而且没有任何报错。
///
/// 所以本类**不做轮询、也不在 `open()` 之后立刻读**，而是由调用方在
/// 「`position` 已经大于 0」那一刻调一次（见 `PlaybackController` /
/// `player_window_app.dart` 里片头探测的调用点）。那时容器一定已经解完。
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

}
