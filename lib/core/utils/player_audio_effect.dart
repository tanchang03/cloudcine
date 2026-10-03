import 'package:media_kit/media_kit.dart';

import '../diagnostics/diag_log.dart';

/// 播放器的「音效」—— 输出的声道 / 直通模式。
///
/// ## ⛔ 先说清楚它**不是**什么（这是这个文件最容易被改错的地方）
///
/// 「音效」与「音轨」是两件事，**别把两者合并**：
///
///   - **音轨**（audio track）是**片源自带的流**。一部 MKV 里可以同时封着
///     国语 / 粤语 / 英语几条音轨，能切几条完全由发布组决定 —— 换片源就换
///     一批。云影那边是 `player_page.dart` 的 `_AudioMenu`（菜单标题「音轨」），
///     数据来自 mpv 的 `stream.tracks`。
///   - **音效**（本文件）是**播放端对输出的处理方式**，与片源里封了什么无关。
///     同一部片子，谁都能选立体声或直通。
///
/// 夸克播放器自己也是这么分的：帮助中心里「多语言音轨」写在**「语言」**入口下，
/// 而「环绕音效」写在**「音效」**入口下，两者并列在播放器功能栏里。
///
/// ## ⛔ 为什么预设只有四个（而不是像夸克那样有 EQ / 人声增强 / 虚拟环绕）
///
/// 2026-10-03 实测：**当前依赖的 libmpv 里没有任何可用的音频 DSP 滤镜**，
/// 所以做不出来。证据（不是推测）：
///
///   - media_kit_libs_macos_video 1.1.4 内置 mpv 0.36.0 + FFmpeg 6.1；
///     它链接的 `Avfilter.framework` 是 `--disable-all` 的白名单构建，
///     用 `avfilter_get_by_name` 逐个数过，**整个库只注册了三个滤镜**：
///     `abuffer` / `abuffersink` / `equalizer`。
///   - `equalizer` 是唯一沾边的，但**用不了**：mpv 的 `lavfi` 包装要先插一个
///     `aresample` 做格式转换，而 `aresample` 不在白名单里 →
///     运行期报 `'aresample' filter not present, cannot convert formats.`
///     然后 `Disabling filter lavfi.00 because it has failed.`（音频照常播，
///     只是滤镜被丢掉 —— **不报错**，这正是它危险的地方）。
///   - `headphone` / `dynaudnorm` / `loudnorm` / `bass` / `treble` /
///     `extrastereo` / `surround` / `pan` 在 `avfilter_get_by_name` 上**全是 null**。
///   - `af set <名字>` 命令**不能**用来判断滤镜是否可用：它只做语法解析，
///     拿这些名字去 set 全都返回成功，真正跑起来才失败。
///     ⚠️ 排查时别再用 `af set` 的返回值当依据。
///
/// 想解锁 EQ 那一套，得换一份带音频滤镜的 Avfilter（与之前换 Avcodec 修 PGS
/// 同一个套路，见 `HOWTO.md` 的 macOS 章节）。**换之前这里不要加预设** ——
/// 加了的后果是「菜单点了没反应，日志里也没有一条错误」。
///
/// ## 能做的这些靠什么
///
/// 全部是 **mpv 自己的原生选项**（不经过 libavfilter），因此不受上面那条限制：
///   - `audio-channels`：输出的声道布局；
///   - `audio-spdif`：把压缩码流原样交给输出设备（HDMI 功放）。
///
/// 两者都在 mpv 0.36 上实测可设（`mpv_set_property_string` 返回成功）。
enum AudioEffectPreset {
  /// 跟随片源：只下混、不上混。**默认**。
  auto,

  /// 环绕上混：把立体声也铺到设备的全部扬声器。
  upmix,

  /// 强制立体声：多声道片源也下混成 2.0。
  stereo,

  /// 杜比 / DTS 直通：把码流原样送给 HDMI 功放，由功放解码。
  passthrough;

  /// 存进设置库的稳定字符串。**改它等于让老用户的设置失效** ——
  /// 所以用枚举名本身，不另起一套。
  String get value => name;
}

/// 「音效」预设 ↔ mpv 属性的唯一映射，以及把它应用到播放器上的入口。
///
/// 两个播放器（内置播放页 `player_page.dart` + 独立窗口
/// `player_window_app.dart`）**共用这一份**：独立窗口跑在另一个 Flutter 引擎里，
/// 两处各写一遍必然漂移 —— 而漂移的表现是「同一个预设，一个窗口有环绕、
/// 另一个没有」，用户根本不会想到这是两套代码。
abstract final class PlayerAudioEffect {
  const PlayerAudioEffect._();

  /// 设置库里的键名。见 `SettingKeys.playerAudioEffect`。
  static const String defaultPreset = 'auto';

  /// 全部预设，按菜单里的显示顺序。
  static const List<AudioEffectPreset> all = AudioEffectPreset.values;

  /// 从设置库读出来的字符串还原。**任何读不懂的值都退回默认**，
  /// 不抛异常：设置库是用户能手动改的（也能被旧版本写坏），
  /// 为一个字符串把播放器拦在启动之前不值得。
  static AudioEffectPreset parse(String? raw) {
    if (raw == null) return AudioEffectPreset.auto;
    for (final p in all) {
      if (p.value == raw) return p;
    }
    return AudioEffectPreset.auto;
  }

  /// 菜单上的名字。
  static String label(AudioEffectPreset p) => switch (p) {
        AudioEffectPreset.auto => '跟随片源',
        AudioEffectPreset.upmix => '环绕上混',
        AudioEffectPreset.stereo => '立体声',
        AudioEffectPreset.passthrough => '杜比 / DTS 直通',
      };

  /// 菜单上的第二行说明 —— 每一项都要说清「什么时候它才有区别」。
  ///
  /// 不写清的话，「立体声」与「跟随片源」在笔记本上是**完全一样**的
  /// （`auto-safe` 本来就下混到设备声道数），用户会以为功能坏了。
  static String detail(AudioEffectPreset p) => switch (p) {
        AudioEffectPreset.auto => '按输出设备的能力自动下混',
        AudioEffectPreset.upmix => '立体声也铺满所有扬声器（需设备支持多声道）',
        AudioEffectPreset.stereo => '强制 2.0，多声道片源也下混',
        AudioEffectPreset.passthrough => '原码送 HDMI 功放解码（需功放支持）',
      };

  /// 预设对应的 mpv 属性。**纯函数，没有副作用** —— 所以能直接单测。
  ///
  /// 每一项都写全（不是只写变化的那一个）：切换预设时若只写一半，
  /// 从「直通」切回「跟随片源」会留下 `audio-spdif` 的旧值，
  /// 表现是「切回来了但还是没声音」——因为码流仍然被原样送出去了。
  static Map<String, String> mpvProperties(AudioEffectPreset p) => switch (p) {
        AudioEffectPreset.auto => const <String, String>{
            'audio-channels': 'auto-safe',
            'audio-spdif': 'no',
          },
        AudioEffectPreset.upmix => const <String, String>{
            'audio-channels': 'auto',
            'audio-spdif': 'no',
          },
        AudioEffectPreset.stereo => const <String, String>{
            'audio-channels': 'stereo',
            'audio-spdif': 'no',
          },
        AudioEffectPreset.passthrough => const <String, String>{
            // 直通时声道布局交给功放：这里给 `auto-safe` 只是为了别留下
            // 上一个预设的 `stereo`（那会让 mpv 先把 5.1 下混成 2.0 再送出去，
            // 功放收到的就已经不是原码了 —— 直通等于白开）。
            'audio-channels': 'auto-safe',
            'audio-spdif': 'ac3,eac3,dts,truehd,dts-hd',
          },
      };

  /// 把预设应用到播放器上。
  ///
  /// ## 为什么失败要**自己读回确认**
  ///
  /// media_kit 的 `setProperty` 把 mpv 的返回码丢掉了（见
  /// `PlayerBufferConfig._confirmStreamCacheOff` 的文档）。属性名写错、
  /// 或 mpv 不接受运行期改这个选项时，失败是**完全静默**的 ——
  /// 表现就是「菜单上打了勾，声音一点没变」，而日志里查不到原因。
  ///
  /// 所以这里设完把 `audio-channels` 读回来比对，不一致就记一条 warn。
  /// **只记日志、不抛异常**：音效没生效不该让播放本身挂掉。
  static Future<void> apply(Player player, AudioEffectPreset preset) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;

    final props = mpvProperties(preset);
    try {
      for (final entry in props.entries) {
        await platform.setProperty(entry.key, entry.value);
      }
    } catch (e) {
      // 播放器已 dispose 之类：不影响播放，静默。
      diag.debug('音效', '设置音效属性失败：$e');
      return;
    }
    await _confirmChannels(platform, preset, props['audio-channels']!);
  }

  /// 读回 `audio-channels`，确认真的生效了。
  static Future<void> _confirmChannels(
    NativePlayer platform,
    AudioEffectPreset preset,
    String expected,
  ) async {
    try {
      final actual = await platform.getProperty('audio-channels');
      if (actual.isEmpty) {
        diag.debug('音效', '读不到 audio-channels，无法确认「${label(preset)}」是否生效');
      } else if (actual != expected) {
        diag.warn(
          '音效',
          '「${label(preset)}」没设上：audio-channels=$actual（期望 $expected）',
        );
      } else {
        diag.info('音效', '已切到「${label(preset)}」（audio-channels=$actual）');
      }
    } catch (e) {
      diag.debug('音效', '确认 audio-channels 失败：$e');
    }
  }
}
