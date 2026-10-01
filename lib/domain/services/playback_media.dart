import 'package:media_kit/media_kit.dart';

/// 构造交给 mpv 的媒体对象。
///
/// ## 存在的唯一理由：`start` **每一次都必须显式给**
///
/// media_kit 把 `Media.start` 落成「在 mpv 的 `on_load` 钩子里设 `start` 属性」
/// （`media_kit-1.2.6/lib/src/player/native/player/real.dart`：`if (start != null)`
/// → `mpv_set_property_string(ctx, "start", …)`）。所以 `start == null` 不是
/// 「从头开始」，而是**什么都不设** —— 而上一次设过的值还留在 mpv 里。
///
/// ## 实测记录（用产物里的真 libmpv 跑出来的，不要凭读源码改这里）
///
/// 素材：`cc_a.mp4` 60 秒、`cc_b.mp4` 30 秒，`vo=null ao=null`，每步读
/// `filename` 与 `time-pos`：
///
/// ```
/// A) 设 start=20 → loadfile cc_a   → 文件=cc_a 位置=23.0s   （3 秒后，即从 20s 起播）
/// B) 不设 start  → loadfile cc_b   → 文件=cc_b 位置=23.0s   ← ⚠️ 也从 20s 起播！
/// C) 显式 start=0 → loadfile cc_a  → 文件=cc_a 位置=3.0s    （残留被清掉）
/// D) 不设 start  → loadfile cc_b   → 文件=cc_b 位置=3.0s
/// E) loadfile cc_a 后**立刻** seek 20 → 位置=3.0s           ← ⚠️ 这次 seek 被丢掉
/// ```
///
/// 同一组步骤换成 **HLS**（`ffmpeg -f hls` 生成的 a.m3u8 / b.m3u8，本地 HTTP
/// 提供，各步等 5 秒）→ `24.9s / 24.8s / 4.9s / 4.9s`，**四条结论完全一致**。
///
/// ⚠️ 这条对本项目是硬指标：夸克 `play/info` 签出来的就是 `media.m3u8`。
/// 所以「HLS 上 `start` 到底有没有用」是**实测过**的，不是从本地文件的结论
/// 外推过去的 —— 后者在这类问题上经常不成立。
///
/// 两条结论：
///
///   1. **`start` 有效，`open()` 之后的 `seek` 无效。** `Player.open()` 并**不等待**
///      文件加载完成（它只发 `loadlist`，再设 `playlist-pos`），紧跟着的 `seek`
///      落在解复用器就绪之前就被丢掉 —— 见 E 行。这正是本项目「续播点了没用、
///      每次都从头开始」的根因。
///   2. **`start` 会残留。** mpv 不会在文件加载完之后把它清掉，所以下一次
///      loadfile 若不重新设置，新文件会沿用上一个文件的位置 —— 见 B 行。
///      症状是「播过一部续播的片子之后，别的片子也从中途开始」，只在特定顺序下
///      复现，极难查。
///
/// 所以这里的 `startAt` 默认值刻意是 [Duration.zero] 而**不是 null**：
/// 「不续播」也要把 0 明确写进去。这是 [build] 不允许传 null 的唯一原因。
abstract final class PlaybackMedia {
  const PlaybackMedia._();

  /// [startAt] 语义与 `PlayRequest.startPosition` 一致：
  /// **给了值就原样使用，不给就是 0**（不是「不设」）。
  static Media build(
    String url, {
    Map<String, String> headers = const <String, String>{},
    Duration startAt = Duration.zero,
  }) =>
      Media(url, httpHeaders: headers, start: startAt);
}
