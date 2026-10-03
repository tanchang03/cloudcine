/// mpv 字幕渲染开关 —— **两个播放器共用真源**（与 `PlayerBufferConfig` 同理），
/// 别只改一处。
///
/// ## 为什么必须是「让 mpv 画」
///
/// media_kit 的 `PlayerConfiguration.libass` **默认 `false`**，而它不是一个
/// 「关掉 ASS 特效」这么轻的开关 —— `real.dart` 里它一口气翻三个属性：
///
/// ```dart
/// 'sub-ass':                  configuration.libass ? 'yes' : 'no',
/// 'sub-visibility':           configuration.libass ? 'yes' : 'no',
/// 'secondary-sub-visibility': configuration.libass ? 'yes' : 'no',
/// ```
///
/// mpv 0.36 手册（`--sub-visibility`）原文：
///
/// > Can be used to disable display of subtitles, but still select and decode
/// > them.
///
/// 也就是说默认配置下 **mpv 根本不会把字幕画出来**，但轨道照选、照解码 ——
/// 所以症状是「`stream.track` 回报 `sid=1`、诊断日志一条错都没有、屏幕上什么
/// 都没有」。（另：`osd-level=0` 与它无关，手册写的是
/// 「OSD completely disabled (subtitles only)」，字幕恰恰是唯一保留项。）
///
/// 关掉 mpv 的渲染之后，字幕改由 Flutter 层画：`media_kit_video` 的 `Video`
/// 组件内部自带 `SubtitleView`，它读 `player.stream.subtitle` ——
/// **`List<String>`，纯文本**。文字字幕（srt/ass/vtt）能走通，
/// **位图字幕（PGS / VobSub / DVB）没有文字可提取，永远无路可走**。
///
/// ## 与夸克播放器的对照（2026-10-03 逆向 `/Applications/Quark.app` 7.3.5.1009）
///
/// 夸克是**在播放器内核里画字幕**，不交给外层 UI：
///
///   - `Libraries/libapolloffmpeg.dylib` 的构建串里明确写着
///     `--enable-decoder=pgssub --enable-demuxer=sup`（PGS 解码器）；
///   - `Libraries/libu3player.dylib` 里文字与图形是**两条独立渲染路径**：
///     `directRenderForText` / `directRenderForGraphic`、
///     `getGraphicSubtitleSourceVideoSize`，以及
///     「graphic subtitle video size fallback」—— 位图字幕拿不到自身尺寸时
///     回退用视频尺寸；文字那条走静态链进去的 libass（`ass_render.c`）。
///
/// 所以本开关就是把「谁来画字幕」对齐到夸克：**交给 mpv 画**。
///
/// ## 打开之后不会出现「双份字幕」
///
/// `media_kit_video` 的 `Video` 已经内置了这个判断
/// （`lib/src/video/video_texture.dart`）：
///
/// ```dart
/// if (videoViewParameters.subtitleViewConfiguration.visible &&
///     !(widget.controller.player.platform?.configuration.libass ?? false))
///   Positioned.fill(child: SubtitleView(...)),
/// ```
///
/// 即 `libass` 为真时**不再叠加** Flutter 层的 `SubtitleView`。两条路互斥，
/// 是 media_kit 自己设计好的，不需要我们额外处理。
///
/// ## 字体（macOS）
///
/// `Ass.framework` 走 CoreText 字体后端（里面有 `coretext`、没有
/// `fontconfig`），系统字体能正常枚举，文字字幕不会因为开 libass 掉字体。
/// 位图字幕本来就不依赖字体。
library;

/// mpv 字幕渲染配置。两个播放器（内置播放页 `PlaybackController` +
/// 独立播放窗口 `player_window_app.dart`）共用。
class PlayerSubtitleConfig {
  PlayerSubtitleConfig._();

  /// 是否让 mpv 自己渲染字幕，传给 `PlayerConfiguration.libass`。
  ///
  /// ⛔ **别改成 `false`**：`false` 会把 `sub-visibility` 一并设成 `no`，
  /// 结果是**所有**字幕（含文字字幕）都不显示，而且**不报任何错** ——
  /// 机理见本文件的 library 文档。
  static const bool useLibass = true;
}
