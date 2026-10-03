import 'package:cloudcine/core/utils/subtitle_formats.dart';
import 'package:cloudcine/domain/entities/playback_preference.dart';
import 'package:cloudcine/domain/entities/subtitle_track.dart';
import 'package:flutter_test/flutter_test.dart';

/// 播放偏好的**跨集还原**规则。
///
/// 这些规则都不抛异常，做错了只表现为「记住的设置时灵时不灵」—— 用户最
/// 说不清、也最难查的一类问题。所以每一条都钉在测试里：
///   - 匹配分级写错 → 换集之后字幕变成外语，或者干脆没挂上；
///   - 兜底写松 → 硬套一条语言都不对的轨，比「没记住」更糟；
///   - JSON 容错写紧 → 一条坏记录让整部片打不开。
void main() {
  group('TrackPreference 匹配分级', () {
    test('轨道号相同是最强信号 —— 同一个文件重播走的就是它', () {
      const pref = TrackPreference(trackId: '3', language: 'chi', index: 2);
      // 同一个文件里轨道号能直接对上；此时**就算语言标记对不上**（发布组
      // 改过元数据、或者我们上一版解析得不一样）也该认这条 ——
      // 它才是「同一个物理轨」。
      expect(pref.scoreAgainst(const TrackPreference(trackId: '3')), 100);
    });

    test('语言 + 标题都相同，赢过「只有语言」', () {
      const pref = TrackPreference(language: 'chi', title: '国语');
      final both = pref.scoreAgainst(
        const TrackPreference(language: 'zho', title: '国语'),
      );
      final langOnly = pref.scoreAgainst(const TrackPreference(language: 'chi'));
      // 同一部剧里两条中文字幕（简体 / 繁体）的语言码常常一模一样，
      // 只有标题能分开它们。所以「标题也对上」必须比「只有语言对上」更强，
      // 否则换集会挑错那一条。
      expect(both, greaterThan(langOnly));
    });

    test('「只有语言」赢过「只有序号」—— 序号是最弱的兜底', () {
      const pref = TrackPreference(language: 'eng', index: 1);
      final byLang = pref.scoreAgainst(const TrackPreference(language: 'eng'));
      final byIndex = pref.scoreAgainst(const TrackPreference(index: 1));
      expect(byLang, greaterThan(byIndex));
      // 序号本身仍然算一个匹配（有些片源一条语言标记都不写），
      // 但必须**大于 0** 才会被采用。
      expect(byIndex, greaterThan(0));
    });

    test('语言、标题、序号全对不上 → 0 分（绝不硬套）', () {
      const pref = TrackPreference(language: 'eng', title: 'English', index: 0);
      // 这是整套规则里最重要的一条：匹配不上时**什么都不做**，
      // 让 mpv 用它的默认轨。硬套一条日语轨给一个选英语的用户，
      // 比「没记住」更让人困惑。
      expect(
        pref.scoreAgainst(
          const TrackPreference(language: 'jpn', title: '日本語', index: 3),
        ),
        0,
      );
    });

    test('语言别名归一：chi / zho / zh / zh-Hans 是同一种', () {
      // 同一部剧不同集的内嵌轨标记可能一个写 `chi`、一个写 `zho`
      // （不同 mkvmerge 版本 / 不同发布组）。不归一的话跨集继承会
      // **时灵时不灵**，而用户在某一集上明明记住过。
      expect(TrackPreference.normalizeLanguage('chi'), 'zh');
      expect(TrackPreference.normalizeLanguage('zho'), 'zh');
      expect(TrackPreference.normalizeLanguage('zh-Hans'), 'zh');
      expect(TrackPreference.normalizeLanguage('zh'), 'zh');
      expect(TrackPreference.normalizeLanguage('ENG'), 'en');
      expect(TrackPreference.normalizeLanguage('jpn'), 'ja');
      expect(TrackPreference.normalizeLanguage(''), isNull);
      expect(TrackPreference.normalizeLanguage('   '), isNull);
      expect(TrackPreference.normalizeLanguage(null), isNull);
    });

    test('标题比较不去空白就出错 —— 但绝不做「包含」匹配', () {
      const pref = TrackPreference(language: 'chi', title: ' 国语 ');
      // 前后空白要归一，否则同一部剧里一处带空格一处不带就匹配不上。
      expect(
        pref.scoreAgainst(const TrackPreference(language: 'chi', title: '国语')),
        greaterThan(60),
      );
      // ⚠️ `国语` 与 `国语（评论）` 是**两条不同的轨**。用包含关系会让它们
      // 互相匹配，用户切过去才发现切错了 —— 而且他只会以为是自己点错了。
      expect(
        const TrackPreference(language: 'chi', title: '国语')
            .scoreAgainst(const TrackPreference(language: 'chi', title: '国语（评论）')),
        60,
      );
    });
  });

  group('bestIndex（在候选里挑一条）', () {
    test('挑分数最高的那一条', () {
      const pref = TrackPreference(language: 'chi', title: '国语');
      final index = TrackPreference.bestIndex(pref, const [
        TrackPreference(language: 'eng', title: 'English'),
        TrackPreference(language: 'jpn', title: '日本語'),
        TrackPreference(language: 'zho', title: '国语'),
      ]);
      expect(index, 2);
    });

    test('一个都不匹配 → null（调用方据此退回「自动选第一条」）', () {
      const pref = TrackPreference(language: 'eng', title: 'English');
      expect(
        TrackPreference.bestIndex(pref, const [
          TrackPreference(language: 'jpn', title: '日本語'),
        ]),
        isNull,
      );
    });

    test('并列时取**先出现**的那一条', () {
      // 轨列表的顺序来自 mpv，是稳定的。取第一个让「同一部片每次还原到
      // 同一条轨」成立；取最后一个（`>=`）在真机上就是随机挑一条。
      const pref = TrackPreference(language: 'chi');
      expect(
        TrackPreference.bestIndex(pref, const [
          TrackPreference(language: 'zho', title: '简体'),
          TrackPreference(language: 'chi', title: '繁体'),
        ]),
        0,
      );
    });

    test('没有偏好 → null（不是 0）', () {
      // 返回 0 的话，所有「没记过」的片子都会被钉到**第一条**音轨上，
      // 而 mpv 自己的默认选择（通常是被标记为 default 的那条）就再也用不上了。
      expect(
        TrackPreference.bestIndex(null, const [TrackPreference(index: 0)]),
        isNull,
      );
    });
  });

  group('ofSubtitle（字幕轨 → 可匹配特征）', () {
    test('摊出 id / 语言 / 展示名 / 序号', () {
      const track = SubtitleTrack(
        id: 'embedded#2',
        origin: SubtitleOrigin.embedded,
        label: '简体中文',
        format: SubtitleFormat.srt,
        language: SubtitleLanguage(code: 'zh-Hans', label: '简体中文'),
        embeddedTrackId: 2,
      );
      final pref = TrackPreference.ofSubtitle(track, index: 1);
      expect(pref.trackId, 'embedded#2');
      expect(pref.language, 'zh-Hans');
      // 用 `displayLabel` 而不是 `label`：菜单上用户看到的就是前者，
      // 存它才能让「用户当时选的是哪一条」对得上。
      expect(pref.title, track.displayLabel);
      expect(pref.index, 1);
    });

    test('没有语言信息时 language 为空（不是空串）', () {
      const track = SubtitleTrack(
        id: 'cloud#abc',
        origin: SubtitleOrigin.cloudFile,
        label: 'xx.ass',
        format: SubtitleFormat.ass,
      );
      final pref = TrackPreference.ofSubtitle(track, index: 0);
      // 空串会在归一后变成 null，但存进 JSON 时是 `"language": ""` ——
      // 一个永远匹配不上任何东西的值。存 null 更诚实。
      expect(pref.language, isNull);
    });
  });

  group('PlaybackPreference JSON 往返', () {
    test('全字段往返', () {
      const pref = PlaybackPreference(
        qualityId: 'super',
        audio: TrackPreference(language: 'chi', title: '国语', index: 1),
        subtitle: TrackPreference(trackId: 'embedded#3', language: 'chi'),
        subtitlesEnabled: false,
        audioEffect: 'stereo',
      );
      expect(PlaybackPreference.fromJsonString(pref.toJsonString()), pref);
    });

    test('空对象往返 —— 「没记过」是一个合法状态', () {
      const pref = PlaybackPreference();
      final back = PlaybackPreference.fromJsonString(pref.toJsonString());
      expect(back, pref);
      expect(back!.isEmpty, isTrue);
    });

    test('缺 subtitlesEnabled 时按**开着**处理', () {
      // ⚠️ 判据必须是 `!= false`。写成 `== true` 的话，老库里那些没有这一位
      // 的记录会全部变成「字幕关着」—— 用户升级后发现**所有片**的字幕都没了，
      // 而且没有任何报错。
      final back = PlaybackPreference.fromJson(<String, Object?>{
        'qualityId': 'origin',
      });
      expect(back!.subtitlesEnabled, isTrue);
    });

    test('畸形输入 → null（当作没记过），而不是抛', () {
      // 抛出去的后果是播放页在 bootstrap 阶段直接失败，用户看到的是
      // 「这部片打不开」—— 为了一个本地库里的坏值付出这个代价不值得。
      expect(PlaybackPreference.fromJson(null), isNull);
      expect(PlaybackPreference.fromJson('not a map'), isNull);
      expect(PlaybackPreference.fromJson(42), isNull);
      expect(PlaybackPreference.fromJsonString('{'), isNull);
      expect(PlaybackPreference.fromJsonString(''), isNull);
      expect(PlaybackPreference.fromJsonString('   '), isNull);
      expect(PlaybackPreference.fromJsonString(null), isNull);
    });

    test('偏好里有一条坏轨道 → 只丢那一条，其余照常', () {
      final back = PlaybackPreference.fromJson(<String, Object?>{
        'qualityId': '4k',
        'audio': 'garbage',
        'subtitlesEnabled': false,
      });
      expect(back!.qualityId, '4k');
      expect(back.audio, isNull);
      expect(back.subtitlesEnabled, isFalse);
    });

    test('轨道特征里读不懂的项各自丢掉', () {
      final back = TrackPreference.fromJson(<String, Object?>{
        'trackId': 7,
        'index': '2',
        'title': '',
      });
      expect(back!.trackId, '7');
      expect(back.index, 2);
      expect(back.title, isNull);
      expect(back.language, isNull);
    });

    test('一个字段都没有的轨道 → null（不是「一条空轨」）', () {
      // 返回一条所有字段都为 null 的轨会让 `bestIndex` 拿到一个
      // 永远不会匹配的对象 —— 与「没记过」行为相同但更难排查。
      expect(TrackPreference.fromJson(<String, Object?>{}), isNull);
      expect(TrackPreference.fromJson(null), isNull);
    });
  });

  group('withX 的语义：**清得掉**，不是只改得动', () {
    test('withSubtitle(null) = 用户主动关掉字幕', () {
      // ⚠️ 这是整份设计里最容易写错的一处：`copyWith` 风格的 `??` 会把
      // null 当成「不改」，于是「关掉字幕」这个动作永远存不下来 ——
      // 用户下次打开又自动挂上一条。
      const pref = PlaybackPreference(
        subtitle: TrackPreference(language: 'chi'),
      );
      final off = pref.withSubtitle(null);
      expect(off.subtitle, isNull);
      expect(off.subtitlesEnabled, isFalse);
    });

    test('withSubtitle(track) 顺手把开关打开', () {
      const pref = PlaybackPreference(subtitlesEnabled: false);
      final on = pref.withSubtitle(const TrackPreference(language: 'chi'));
      expect(on.subtitle, isNotNull);
      expect(on.subtitlesEnabled, isTrue);
    });

    test('withQuality(null) 清掉画质（回到全局默认）', () {
      const pref = PlaybackPreference(qualityId: 'super');
      expect(pref.withQuality(null).qualityId, isNull);
    });

    test('改一项不动其它项', () {
      const pref = PlaybackPreference(
        qualityId: 'super',
        audio: TrackPreference(language: 'chi'),
        subtitlesEnabled: false,
        audioEffect: 'upmix',
      );
      final next = pref.withAudio(const TrackPreference(language: 'eng'));
      expect(next.qualityId, 'super');
      expect(next.subtitlesEnabled, isFalse);
      expect(next.audioEffect, 'upmix');
      expect(next.audio!.language, 'eng');
    });

    test('isEmpty 只看「有没有记过」，不看记的值是不是默认值', () {
      expect(const PlaybackPreference().isEmpty, isTrue);
      // 记着「字幕关着」是**记过**（用户主动关的），不是空的 ——
      // 把它当空的后果是这一条记录被当成没记过，字幕又自动挂上了。
      expect(const PlaybackPreference(subtitlesEnabled: false).isEmpty, isFalse);
      expect(const PlaybackPreference(qualityId: 'origin').isEmpty, isFalse);
      expect(
        const PlaybackPreference(audio: TrackPreference(index: 0)).isEmpty,
        isFalse,
      );
    });
  });
}
