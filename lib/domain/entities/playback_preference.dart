import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'subtitle_track.dart';

/// 一条轨道（音轨 / 字幕）的**可匹配特征**。
///
/// ## 为什么不能只存「轨道号」
///
/// 内嵌轨的 id 是 mpv 给这一条**流**编的号（`aid` / `sid`），它只在
/// **同一个文件**里稳定。而播放偏好要能跨集继承（用户给第 1 集选了粤语，
/// 第 2 集打开也该是粤语），那时 id 几乎必然对不上 —— 第 2 集里
/// 「第 1 条音轨」可能才是粤语。
///
/// 所以存的是**一组特征**，还原时按可靠性分级匹配：
///
///   1. [trackId] 完全相同 —— 同一个文件重播，最可靠；
///   2. [language] + [title] 都相同 —— 跨集时最可靠的组合；
///   3. 只有 [language] 相同 —— 发布组给同一条轨的标题在不同集里可能不同；
///   4. 只有 [index] 相同 —— 「还是第 N 条」，最后的兜底。
///
/// 四级都不中就当没存过，退回「自动选第一条」。**绝不硬套一条语言都对不上
/// 的轨** —— 那比没记住更糟：用户看到的是「换集之后字幕变成外语了」，
/// 而他什么都没做。
@immutable
class TrackPreference {
  const TrackPreference({this.trackId, this.language, this.title, this.index});

  /// 原始的轨道号（内嵌轨是 mpv 的 `aid` / `sid` 字符串）。
  ///
  /// 网盘 / 在线字幕没有这个概念，为 `null`。
  final String? trackId;

  /// 语言标记（`chi` / `zho` / `eng`…），原样存，比较时归一。
  final String? language;

  /// 轨的显示名（`国语` / `评论音轨` / 字幕文件名）。
  ///
  /// 用显示名而不是文件名：它是菜单上用户看到的那一行，也是「用户当时
  /// 到底选了哪条」最贴近的记录。
  final String? title;

  /// 在**真实轨列表**里的序号（0 基，合成轨已剔除）。
  ///
  /// 兜底用。为什么必须有它：有些片源一条语言标记都不写（全是 `null`），
  /// 那时前三级全部失效，只剩「用户选的是第 2 条」这条信息可用。
  final int? index;

  /// 从字幕轨构造。见 [PlaybackController] 的自动选择。
  static TrackPreference ofSubtitle(SubtitleTrack track, {required int index}) =>
      TrackPreference(
        trackId: track.id,
        language: track.languageCode.isEmpty ? null : track.languageCode,
        title: track.displayLabel,
        index: index,
      );

  /// 与一条候选的匹配分。**0 表示不匹配。**
  ///
  /// 分数只用来排序，具体数值不重要，重要的是**级与级之间不能交叉**：
  /// 任意一个「高一级的匹配」都必须赢过任意一个「低一级的匹配」。
  int scoreAgainst(TrackPreference candidate) {
    final id = trackId;
    if (id != null && id.isNotEmpty && id == candidate.trackId) return 100;

    final lang = normalizeLanguage(language);
    final sameLang = lang != null && lang == normalizeLanguage(candidate.language);

    final t = _normalizeTitle(title);
    final sameTitle = t != null && t == _normalizeTitle(candidate.title);

    if (sameLang && sameTitle) return 80;
    if (sameLang) return 60;
    if (index != null && index == candidate.index) return 40;
    return 0;
  }

  /// 在候选里挑最匹配的一个，返回它的下标。**一个都不匹配时返回 `null`。**
  ///
  /// 并列时取**先出现的**那个（用 `>` 而不是 `>=`）：轨列表的顺序来自 mpv，
  /// 稳定的顺序 + 稳定的取法 = 同一部片每次还原到同一条轨。
  static int? bestIndex(
    TrackPreference? preference,
    List<TrackPreference> candidates,
  ) {
    if (preference == null) return null;
    var bestScore = 0;
    int? best;
    for (var i = 0; i < candidates.length; i++) {
      final score = preference.scoreAgainst(candidates[i]);
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    return best;
  }

  /// 把语言标记归一到主码。
  ///
  /// ## 为什么必须归一
  ///
  /// 同一部剧不同集的内嵌轨标记可能一个写 `chi`、一个写 `zho`（不同
  /// mkvmerge 版本 / 不同发布组），甚至同一集里音轨写 `zho`、字幕写 `chi`。
  /// 不归一的话「跨集继承」会**时灵时不灵** —— 这是最难查的一类问题，
  /// 因为用户在某一集上明明记住过。
  ///
  /// `chs` / `cht` 一并归到 `zh`：跨集匹配时「都是中文」就够了，
  /// 简繁之别交给 [title] 那一级去分（同一集里两条中文字幕的标题必然不同）。
  static String? normalizeLanguage(String? tag) {
    final t = tag?.trim().toLowerCase();
    if (t == null || t.isEmpty) return null;
    const alias = <String, String>{
      'chi': 'zh', 'zho': 'zh', 'zh': 'zh', 'chs': 'zh', 'cht': 'zh',
      'zh-hans': 'zh', 'zh-hant': 'zh', 'zh-cn': 'zh', 'zh-tw': 'zh',
      'cmn': 'zh',
      'eng': 'en', 'en': 'en', 'en-us': 'en', 'en-gb': 'en',
      'jpn': 'ja', 'ja': 'ja',
      'kor': 'ko', 'ko': 'ko',
      'fra': 'fr', 'fre': 'fr', 'fr': 'fr',
      'deu': 'de', 'ger': 'de', 'de': 'de',
      'spa': 'es', 'es': 'es',
      'rus': 'ru', 'ru': 'ru',
    };
    return alias[t] ?? t;
  }

  /// 标题比较前的归一：去空白、小写。
  ///
  /// **不做「包含」判断**：`国语` 与 `国语（评论）` 是两条不同的轨，
  /// 用包含关系会让它们互相匹配，用户切过去才发现切错了。
  static String? _normalizeTitle(String? raw) {
    final t = raw?.trim().toLowerCase();
    if (t == null || t.isEmpty) return null;
    return t;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        if (trackId != null) 'trackId': trackId,
        if (language != null) 'language': language,
        if (title != null) 'title': title,
        if (index != null) 'index': index,
      };

  /// 从 JSON 还原。**读不懂就当没有**（返回 `null`）而不是抛 ——
  /// 这是用户能手动改的本地库，为一个畸形值把播放拦下来不值得。
  static TrackPreference? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = _str(raw['trackId']);
    final language = _str(raw['language']);
    final title = _str(raw['title']);
    final index = _int(raw['index']);
    if (id == null && language == null && title == null && index == null) {
      return null;
    }
    return TrackPreference(
      trackId: id,
      language: language,
      title: title,
      index: index,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TrackPreference &&
      other.trackId == trackId &&
      other.language == language &&
      other.title == title &&
      other.index == index;

  @override
  int get hashCode => Object.hash(trackId, language, title, index);

  @override
  String toString() =>
      'TrackPreference(id=$trackId, lang=$language, title=$title, idx=$index)';
}

/// 一部影片（严格说是**一个媒体项**）的播放偏好。
///
/// ## 记住的是哪几项，以及为什么
///
///   - [qualityId] —— 画质档位。夸克各档是同一个 fid 的不同转码，档位 id
///     在整部剧里一致，所以跨集继承是直接可用的；
///   - [audio] / [subtitle] —— 音轨与字幕，存**特征**不存 id（见
///     [TrackPreference] 的类文档）；
///   - [subtitlesEnabled] —— 字幕开关。**「关掉」也是一个要记住的选择**：
///     不记的话，用户在一部片里关了字幕，下次打开又被自动挂上一条；
///   - [audioEffect] —— 音效预设。
///
/// ## 刻意不记的两项
///
/// **音量与倍速**不在这里。它们描述的是这台设备 / 这个人的观看习惯，
/// 与「播哪一部片」无关 —— 半夜把音量调小，不该只对一部片生效。
/// 它们继续走 `SettingKeys.playerVolume` / `playerRate` 这两个全局键。
@immutable
class PlaybackPreference {
  const PlaybackPreference({
    this.qualityId,
    this.audio,
    this.subtitle,
    this.subtitlesEnabled = true,
    this.audioEffect,
  });

  /// 画质档位 id（`origin` / `super` / `4k`…）。`null` = 没记过，用全局默认。
  final String? qualityId;

  /// 音轨偏好。`null` = 没记过，交给 mpv 自己选。
  final TrackPreference? audio;

  /// 字幕偏好。`null` 且 [subtitlesEnabled] 为 true = 没记过，自动选第一条。
  final TrackPreference? subtitle;

  /// 用户是否开着字幕。
  ///
  /// ⚠️ 与 [subtitle] **不是一回事**：`subtitle == null && !subtitlesEnabled`
  /// 表示「用户主动关掉了字幕」，而 `subtitle == null && subtitlesEnabled`
  /// 表示「没记过，按自动选」。少了这一个布尔，两种状态就没法区分，
  /// 用户关掉字幕的行为会在下次播放时被自动选择覆盖掉。
  final bool subtitlesEnabled;

  /// 音效预设（`AudioEffectPreset.value`）。`null` = 没在这部片上改过，
  /// 用全局默认。
  final String? audioEffect;

  /// 一个字都没记过。
  bool get isEmpty =>
      qualityId == null &&
      audio == null &&
      subtitle == null &&
      audioEffect == null &&
      subtitlesEnabled;

  /// 改画质。传 `null` 表示**清掉**这一项（回到全局默认）。
  PlaybackPreference withQuality(String? id) => PlaybackPreference(
        qualityId: id,
        audio: audio,
        subtitle: subtitle,
        subtitlesEnabled: subtitlesEnabled,
        audioEffect: audioEffect,
      );

  PlaybackPreference withAudio(TrackPreference? value) => PlaybackPreference(
        qualityId: qualityId,
        audio: value,
        subtitle: subtitle,
        subtitlesEnabled: subtitlesEnabled,
        audioEffect: audioEffect,
      );

  /// 改字幕。
  ///
  /// [enabled] 不传时按「选了某条就是开着、传 null 就是关着」推断 ——
  /// 这是两个调用点的真实语义（`selectSubtitle(track)` 与
  /// `selectSubtitle(null)`），写出来省得每处都重复一遍。
  PlaybackPreference withSubtitle(TrackPreference? value, {bool? enabled}) =>
      PlaybackPreference(
        qualityId: qualityId,
        audio: audio,
        subtitle: value,
        subtitlesEnabled: enabled ?? (value != null),
        audioEffect: audioEffect,
      );

  PlaybackPreference withSubtitlesEnabled(bool enabled) => PlaybackPreference(
        qualityId: qualityId,
        audio: audio,
        subtitle: subtitle,
        subtitlesEnabled: enabled,
        audioEffect: audioEffect,
      );

  PlaybackPreference withAudioEffect(String? value) => PlaybackPreference(
        qualityId: qualityId,
        audio: audio,
        subtitle: subtitle,
        subtitlesEnabled: subtitlesEnabled,
        audioEffect: value,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'qualityId': qualityId,
        'audio': audio?.toJson(),
        'subtitle': subtitle?.toJson(),
        'subtitlesEnabled': subtitlesEnabled,
        'audioEffect': audioEffect,
      };

  String toJsonString() => jsonEncode(toJson());

  /// 从 JSON 还原。**读不懂就返回 `null`**（当作「没记过」）。
  ///
  /// 不抛异常的代价是「一个坏值静默失效」，但那条路本来就是「退回默认」——
  /// 而抛出去会让播放页在 bootstrap 阶段直接失败，用户看到的是「这部片打不开」。
  /// 两害相权，退回默认明显更好。
  static PlaybackPreference? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return PlaybackPreference(
      qualityId: _str(raw['qualityId']),
      audio: TrackPreference.fromJson(raw['audio']),
      subtitle: TrackPreference.fromJson(raw['subtitle']),
      // 缺失即 `true`：与「没记过时按自动选」这条缺省行为一致。
      // ⚠️ 写成 `== true` 的话，老库里的记录会全部变成「字幕关着」。
      subtitlesEnabled: raw['subtitlesEnabled'] != false,
      audioEffect: _str(raw['audioEffect']),
    );
  }

  /// 从库里读出来的字符串还原。畸形 / 空串都返回 `null`。
  static PlaybackPreference? fromJsonString(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PlaybackPreference &&
      other.qualityId == qualityId &&
      other.audio == audio &&
      other.subtitle == subtitle &&
      other.subtitlesEnabled == subtitlesEnabled &&
      other.audioEffect == audioEffect;

  @override
  int get hashCode =>
      Object.hash(qualityId, audio, subtitle, subtitlesEnabled, audioEffect);

  @override
  String toString() => 'PlaybackPreference(quality=$qualityId, audio=$audio, '
      'subtitle=$subtitle, subtitles=$subtitlesEnabled, effect=$audioEffect)';
}

String? _str(Object? raw) {
  if (raw == null) return null;
  final s = '$raw'.trim();
  return s.isEmpty ? null : s;
}

int? _int(Object? raw) {
  if (raw is int) return raw;
  if (raw == null) return null;
  return int.tryParse('$raw');
}
