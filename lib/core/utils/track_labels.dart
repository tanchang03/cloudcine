import 'package:media_kit/media_kit.dart';

import 'format.dart';

/// 音轨 / 字幕轨的**展示文案**。
///
/// 单独一个文件而不是散在页面里，有两个理由：
///   1. 它是纯函数，能不开 widget 就测；
///   2. **两个播放器各有自己的键位表和菜单**（内置播放页 `player_page.dart`
///      与独立窗口 `player_window_app.dart`）。文案写在页面里，改一个就会
///      表现成「另一个地方没做」—— 这正是之前键位表踩过的坑。
///
/// ## 取值为什么都得判空
///
/// mpv 只在**探到**的时候才填这些字段。内嵌音轨常常只有 `language`，
/// 码率 / 声道 / 采样率要等解码器开始工作才补上，甚至永远不补。
/// 直接拼字符串会得到「AAC · null · null kbps」，比什么都不显示更难看。
class TrackLabels {
  const TrackLabels._();

  /// 音轨的主标题：`中文` / `英语` / `音轨 2`。
  static String audioTitle(AudioTrack track) {
    final lang = languageLabel(track.language);
    if (lang != null) return lang;
    final title = track.title?.trim();
    if (title != null && title.isNotEmpty) return title;
    return '音轨 ${track.id}';
  }

  /// 音轨的副标题：`AAC · 立体声 · 48 kHz · 320 kbps`。
  ///
  /// 每一段都只在有值时才拼进去，用「 · 」连接。
  static String audioDetail(AudioTrack track) {
    final parts = <String>[
      if (codecLabel(track.codec) case final c?) c,
      if (channelsLabel(track) case final ch?) ch,
      if (sampleRateLabel(track.samplerate) case final sr?) sr,
      if (bitrateLabel(track.bitrate) case final b?) b,
    ];
    return parts.join(' · ');
  }

  /// 字幕轨的标题：`中文` / `英语` / `字幕轨 3`。
  static String subtitleTitle(SubtitleTrack track) {
    final lang = languageLabel(track.language);
    if (lang != null) return lang;
    final title = track.title?.trim();
    if (title != null && title.isNotEmpty) return title;
    return '字幕轨 ${track.id}';
  }

  /// 字幕轨的副标题：`SRT · 默认轨`。
  ///
  /// 编码名走 [subtitleCodecLabel] 而不是 [codecLabel]：后者是给**音频**写的
  /// （`aac` → `AAC`），套到字幕上会把 mpv 的内部名原样大写输出 ——
  /// `hdmv_pgs_subtitle` 会变成 `HDMV_PGS_SUBTITLE`，比不显示更糟。
  ///
  /// 「强制字幕」（forced）**没有**出现在这里：media_kit 的 `SubtitleTrack`
  /// 不暴露这个标记（见 `_Track` 的字段表），猜是猜不出来的。
  static String subtitleDetail(SubtitleTrack track) {
    final parts = <String>[
      if (subtitleCodecLabel(track.codec) case final c?) c,
      if (track.isDefault == true) '默认轨',
    ];
    return parts.join(' · ');
  }

  /// 字幕编码名。mpv 给的是容器内部名（`subrip` / `ass` / `hdmv_pgs_subtitle`）。
  static String? subtitleCodecLabel(String? codec) {
    final c = codec?.trim().toLowerCase();
    if (c == null || c.isEmpty) return null;
    return switch (c) {
      'subrip' || 'srt' => 'SRT',
      'ass' || 'ssa' => 'ASS',
      'webvtt' || 'vtt' => 'VTT',
      'mov_text' || 'tx3g' => 'MOV 文本',
      'hdmv_pgs_subtitle' || 'pgs' => 'PGS 图形',
      'dvd_subtitle' || 'vobsub' => 'VobSub 图形',
      'dvb_subtitle' => 'DVB 图形',
      _ => c.toUpperCase(),
    };
  }

  /// mpv 的语言标记 → 中文名。
  ///
  /// ## 为什么不能直接用原始标记
  ///
  /// mpv 给的是 ISO 639-2/B（`chi` / `zho` / `jpn`）或 ISO 639-1（`zh` / `ja`），
  /// 还会给 `und`（undetermined）。直接显示 `chi` 用户看不懂，
  /// 而 `und` 显示出来更是纯粹的噪音。
  ///
  /// 认不出来就返回 `null` 而不是原样吐回去：让调用方退回「音轨 N」
  /// 这种不带错误承诺的兜底，比显示一串代码好。
  static String? languageLabel(String? tag) {
    final t = tag?.trim().toLowerCase();
    if (t == null || t.isEmpty || t == 'und') return null;
    return switch (t) {
      'chi' || 'zho' || 'zh' || 'chs' || 'zh-hans' || 'zh-cn' => '简体中文',
      'cht' || 'zh-hant' || 'zh-tw' || 'zh-hk' => '繁体中文',
      'eng' || 'en' => '英语',
      'jpn' || 'ja' => '日语',
      'kor' || 'ko' => '韩语',
      'fre' || 'fra' || 'fr' => '法语',
      'ger' || 'deu' || 'de' => '德语',
      'spa' || 'es' => '西班牙语',
      'rus' || 'ru' => '俄语',
      'ita' || 'it' => '意大利语',
      'por' || 'pt' => '葡萄牙语',
      'por-br' || 'pt-br' => '巴西葡萄牙语',
      'ara' || 'ar' => '阿拉伯语',
      'hin' || 'hi' => '印地语',
      'tha' || 'th' => '泰语',
      'vie' || 'vi' => '越南语',
      'nld' || 'dut' || 'nl' => '荷兰语',
      'pol' || 'pl' => '波兰语',
      'tur' || 'tr' => '土耳其语',
      'swe' || 'sv' => '瑞典语',
      'dan' || 'da' => '丹麦语',
      'nor' || 'nb' || 'no' => '挪威语',
      'fin' || 'fi' => '芬兰语',
      'ces' || 'cze' || 'cs' => '捷克语',
      'hun' || 'hu' => '匈牙利语',
      'ell' || 'gre' || 'el' => '希腊语',
      'heb' || 'he' => '希伯来语',
      'ind' || 'id' => '印尼语',
      'msa' || 'may' || 'ms' => '马来语',
      'yue' => '粤语',
      _ => null,
    };
  }

  /// 编码名。mpv 给的是小写短名（`aac` / `eac3` / `truehd`），
  /// 显示成常见写法（`AAC` / `E-AC-3` / `TrueHD`）。
  static String? codecLabel(String? codec) {
    final c = codec?.trim().toLowerCase();
    if (c == null || c.isEmpty) return null;
    return switch (c) {
      'aac' => 'AAC',
      'ac3' => 'Dolby Digital',
      'eac3' => 'Dolby Digital Plus',
      'truehd' => 'Dolby TrueHD',
      'dts' => 'DTS',
      'dts-hd' => 'DTS-HD',
      'mp3' => 'MP3',
      'flac' => 'FLAC',
      'opus' => 'Opus',
      'vorbis' => 'Vorbis',
      'pcm' => 'PCM',
      'alac' => 'ALAC',
      'wmav2' || 'wma' => 'WMA',
      _ => c.toUpperCase(),
    };
  }

  /// 声道：`立体声` / `5.1` / `单声道`。
  ///
  /// 优先用 [AudioTrack.channelscount]（整数），拿不到再用
  /// [AudioTrack.channels] 那个字符串（mpv 给的是 `stereo` / `5.1` 这种
  /// 布局名，能直接用）。
  static String? channelsLabel(AudioTrack track) {
    final n = track.channelscount;
    // ⚠️ `final count` 会连 `null` 一起匹配上（那样 `count` 仍是 `int?`），
    // 必须把类型写出来才会收窄成非空 —— 这也是为什么不能只写 `final count`。
    if (n case final int count when count > 0) {
      return switch (count) {
        1 => '单声道',
        2 => '立体声',
        6 => '5.1 声道',
        8 => '7.1 声道',
        _ => '$count 声道',
      };
    }
    final layout = track.channels?.trim();
    if (layout == null || layout.isEmpty) return null;
    return switch (layout.toLowerCase()) {
      'mono' => '单声道',
      'stereo' => '立体声',
      _ => layout,
    };
  }

  /// 采样率：`48 kHz`。低于 8000 的值不当采样率（那是别的东西填错了位置）。
  static String? sampleRateLabel(int? hz) {
    if (hz == null || hz < 8000) return null;
    final khz = hz / 1000;
    // 常见值都是整数 kHz（44.1 是唯一的例外），所以保留一位即可。
    final text = khz == khz.roundToDouble()
        ? khz.toStringAsFixed(0)
        : khz.toStringAsFixed(1);
    return '$text kHz';
  }

  /// 码率。`demux-bitrate` 的单位是 **bps**（实测：AAC 立体声常见值
  /// 128000 / 320000，DDP 常见 768000），所以这里除以 1000 得 kbps。
  static String? bitrateLabel(int? bps) {
    if (bps == null || bps <= 0) return null;
    return formatBitrate(bps);
  }

  /// 只保留**真实存在的轨道**，剔除 media_kit 硬塞进来的合成轨。
  ///
  /// ⚠️ `tracks.video` / `audio` / `subtitle` 的**前两条是合成轨**：media_kit
  /// 的 `real.dart` 里写死了 `[XxxTrack.auto(), XxxTrack.no()]`，它们的 `id`
  /// 是字符串 `'auto'` / `'no'`，**不是 mpv 的轨道号**。
  ///
  /// 把它们当真实轨道会踩两个坑：
  ///   1. `int.tryParse('auto')` → `null` → 报「这条字幕没有轨道号」；
  ///   2. 它们永远排在最前 —— 菜单里会出现两条「点了没反应」的选项，而自动
  ///      选字幕取「第一条」时**每次都会选中它们**。
  ///
  /// 实测症状：一个根本没有内嵌字幕的 mp4，`tracks.subtitle.length` 也是 2，
  /// 正好就是这两条合成轨。
  ///
  /// 用泛型 + [idOf] 而不是 `T extends _Track`：media_kit 的轨道基类 `_Track`
  /// 是**私有**的，外部没法拿它当类型约束，只能把「怎么取 id」传进来。
  ///
  /// `PlaybackController.realTracksOf` 与本函数是同一条规则，前者已改为委托
  /// 到这里 —— 别再拆成两份。
  static List<T> realTracks<T>(Iterable<T> tracks, String Function(T) idOf) =>
      [for (final t in tracks) if (int.tryParse(idOf(t)) != null) t];
}
