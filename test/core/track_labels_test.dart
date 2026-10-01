import 'package:cloudcine/core/utils/track_labels.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

/// 音轨 / 字幕轨的展示文案。
///
/// ## 为什么这些用例值得写
///
/// 媒体元数据这一层**没有任何一处会报错**：字段缺失就是 `null`，拼坏了也只是
/// 显示成「AAC · null · null kbps」这种难看的字符串。所以「显示对了」这种事
/// 只能靠断言钉住，靠人眼是看不出来的 —— 尤其是「某个字段刚好没值」的分支，
/// 真机上要碰巧遇到那种文件才会露出来。
void main() {
  AudioTrack audio({
    String id = '1',
    String? title,
    String? language,
    String? codec,
    int? channelscount,
    String? channels,
    int? samplerate,
    int? bitrate,
  }) =>
      AudioTrack(
        id,
        title,
        language,
        codec: codec,
        channelscount: channelscount,
        channels: channels,
        samplerate: samplerate,
        bitrate: bitrate,
      );

  group('语言标记', () {
    test('mpv 的 ISO 639-2/B 要翻成中文', () {
      expect(TrackLabels.languageLabel('chi'), '简体中文');
      expect(TrackLabels.languageLabel('zho'), '简体中文');
      expect(TrackLabels.languageLabel('jpn'), '日语');
      expect(TrackLabels.languageLabel('eng'), '英语');
    });

    test('`und` 返回 null —— 它不是「未知语言」，是「没有标语言」', () {
      expect(
        TrackLabels.languageLabel('und'),
        isNull,
        reason: 'mpv 用 und 表示 undetermined。原样显示出来用户看不懂，'
            '而当成一种语言显示成「未知」又是凭空捏造 —— 应当退回「音轨 N」',
      );
    });

    test('认不出来的标记返回 null，而不是把代码原样吐给用户', () {
      expect(TrackLabels.languageLabel('qqq'), isNull);
      expect(TrackLabels.languageLabel(null), isNull);
      expect(TrackLabels.languageLabel('  '), isNull);
    });
  });

  group('音轨标题', () {
    test('有语言就用语言', () {
      expect(TrackLabels.audioTitle(audio(language: 'chi')), '简体中文');
    });

    test('没语言但有标题就用标题', () {
      expect(
        TrackLabels.audioTitle(audio(title: '  Commentary  ')),
        'Commentary',
        reason: '标题要 trim —— mpv 给的常常带前后空格',
      );
    });

    test('都没有就退回「音轨 N」，不显示 null', () {
      expect(TrackLabels.audioTitle(audio(id: '3')), '音轨 3');
    });
  });

  group('音轨副标题', () {
    test('四个字段齐全时按 编码 · 声道 · 采样率 · 码率 排', () {
      expect(
        TrackLabels.audioDetail(
          audio(
            codec: 'eac3',
            channelscount: 6,
            samplerate: 48000,
            bitrate: 768000,
          ),
        ),
        'Dolby Digital Plus · 5.1 声道 · 48 kHz · 768 kbps',
      );
    });

    test('缺哪个就少哪一段 —— 中间不能留下空的分隔符', () {
      expect(
        TrackLabels.audioDetail(audio(codec: 'aac', channelscount: 2)),
        'AAC · 立体声',
        reason: '缺字段时若先拼成定长四段再 join，会得到「AAC · 立体声 ·  · 」'
            '这种带连续分隔符的字符串',
      );
    });

    test('什么都没有时是空串 —— 调用方据此不建副标题那一行', () {
      expect(
        TrackLabels.audioDetail(audio()),
        '',
        reason: '空串是「不要副标题」的信号。返回「未知 · 未知」会让每一项'
            '看起来都像是有信息，其实一条都没有',
      );
    });

    test('码率是 bps，不是 kbps', () {
      expect(
        TrackLabels.audioDetail(audio(bitrate: 320000)),
        '320 kbps',
        reason: 'mpv 的 demux-bitrate 单位是 bps。按 kbps 处理会显示成 '
            '「320000 kbps」，差一千倍且不报错',
      );
    });

    test('超过 1 Mbps 换成 Mbps', () {
      expect(TrackLabels.audioDetail(audio(bitrate: 1500000)), '1.5 Mbps');
    });
  });

  group('声道', () {
    test('按整数声道数给出惯例说法', () {
      expect(TrackLabels.channelsLabel(audio(channelscount: 1)), '单声道');
      expect(TrackLabels.channelsLabel(audio(channelscount: 2)), '立体声');
      expect(TrackLabels.channelsLabel(audio(channelscount: 6)), '5.1 声道');
      expect(TrackLabels.channelsLabel(audio(channelscount: 8)), '7.1 声道');
      expect(TrackLabels.channelsLabel(audio(channelscount: 4)), '4 声道');
    });

    test('没有整数声道数时退回 mpv 给的布局名', () {
      expect(TrackLabels.channelsLabel(audio(channels: 'stereo')), '立体声');
      expect(TrackLabels.channelsLabel(audio(channels: 'mono')), '单声道');
    });

    test('两者都没有时返回 null', () {
      expect(TrackLabels.channelsLabel(audio()), isNull);
    });
  });

  group('采样率', () {
    test('44.1 kHz 保留一位，48 kHz 不显示小数点', () {
      expect(TrackLabels.sampleRateLabel(48000), '48 kHz');
      expect(TrackLabels.sampleRateLabel(44100), '44.1 kHz');
    });

    test('明显不是采样率的值直接丢掉', () {
      expect(
        TrackLabels.sampleRateLabel(0),
        isNull,
        reason: '0 与负数都不是采样率，显示成「0 kHz」是纯粹的噪音',
      );
      expect(TrackLabels.sampleRateLabel(60), isNull);
      expect(TrackLabels.sampleRateLabel(null), isNull);
    });
  });

  group('字幕标题', () {
    test('有语言用语言，都没有退回「字幕轨 N」', () {
      expect(
        TrackLabels.subtitleTitle(const SubtitleTrack('2', null, null)),
        '字幕轨 2',
      );
    });

    test('有语言时用语言', () {
      expect(
        TrackLabels.subtitleTitle(
          const SubtitleTrack('1', '简体中文', 'chi'),
        ),
        '简体中文',
      );
    });
  });

  group('字幕副标题', () {
    SubtitleTrack sub({String? codec, bool? isDefault}) =>
        SubtitleTrack('1', null, null, codec: codec, isDefault: isDefault);

    test('mpv 的内部编码名要翻成人话', () {
      expect(TrackLabels.subtitleCodecLabel('subrip'), 'SRT');
      expect(TrackLabels.subtitleCodecLabel('ass'), 'ASS');
      expect(TrackLabels.subtitleCodecLabel('webvtt'), 'VTT');
      expect(TrackLabels.subtitleCodecLabel('mov_text'), 'MOV 文本');
      expect(TrackLabels.subtitleCodecLabel('hdmv_pgs_subtitle'), 'PGS 图形');
      expect(TrackLabels.subtitleCodecLabel('dvd_subtitle'), 'VobSub 图形');
    });

    test('认不出来的编码大写显示，不是原样吐下划线名', () {
      // `hdmv_pgs_subtitle` 那类内部名如果落到这个分支就会很难看，
      // 所以上面每一条常见值都必须显式映射。
      expect(TrackLabels.subtitleCodecLabel('xyz'), 'XYZ');
    });

    test('编码与「默认轨」用 · 连接', () {
      expect(TrackLabels.subtitleDetail(sub(codec: 'subrip')), 'SRT');
      expect(TrackLabels.subtitleDetail(sub(codec: 'ass', isDefault: true)), 'ASS · 默认轨');
      expect(TrackLabels.subtitleDetail(sub(isDefault: true)), '默认轨');
    });

    test('什么都没有时给空串 —— 空串不建副标题那一行，不是「未知」', () {
      expect(TrackLabels.subtitleDetail(sub()), '');
      expect(TrackLabels.subtitleCodecLabel(null), isNull);
      expect(TrackLabels.subtitleCodecLabel('  '), isNull);
    });

    test('「强制字幕」不在这里 —— media_kit 根本没暴露那个标记', () {
      // 这条是**反面断言**：提醒后来者不要凭 mpv 的 `forced` 去猜。
      // `SubtitleTrack` 的字段表里没有它，猜出来的值只会在真机上显示成错的。
      expect(TrackLabels.subtitleDetail(sub(codec: 'subrip')), isNot(contains('强制')));
    });
  });

  group('realTracks · 剔除 media_kit 的合成轨', () {
    const auto = AudioTrack('auto', null, null);
    const no = AudioTrack('no', null, null);
    const first = AudioTrack('1', null, null);

    test('`auto` 与 `no` 不算真实轨道', () {
      expect(
        TrackLabels.realTracks(<AudioTrack>[auto, no, first], (t) => t.id),
        [first],
        reason: 'media_kit 在 tracks.audio / video / subtitle 里各硬塞了两条'
            '合成轨（id 是字符串 auto / no，不是 mpv 轨道号）。把它们放进菜单'
            '就是两条「点了没反应」的选项，而它们还永远排在最前',
      );
    });

    test('全是合成轨时得到空列表 —— 而不是「有一条」', () {
      expect(
        TrackLabels.realTracks(<AudioTrack>[auto, no], (t) => t.id),
        isEmpty,
        reason: '实测：一个没有内嵌字幕的 mp4，tracks.subtitle.length 也是 2。'
            '不剔除的话菜单会凭空多出两条',
      );
    });
  });
}
