import 'package:cloudcine/core/utils/subtitle_formats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SubtitleFormats.isSubtitleFile', () {
    test('认得文本与位图字幕', () {
      for (final name in [
        'a.srt',
        'a.ass',
        'a.ssa',
        'a.vtt',
        'a.webvtt',
        'a.sub',
        'a.idx',
        'a.smi',
        'a.ttml',
        'a.sup',
        'a.pgs',
        'a.mks',
      ]) {
        expect(SubtitleFormats.isSubtitleFile(name), isTrue, reason: name);
      }
    });

    test('txt 不算字幕', () {
      // txt 在网盘里更多是说明文档，收进来会让每部片子多几个假字幕
      expect(SubtitleFormats.isSubtitleFile('readme.txt'), isFalse);
      expect(SubtitleFormats.isSubtitleFile('movie.mkv'), isFalse);
    });
  });

  group('SubtitleFormats.formatOf', () {
    test('扩展名 → 格式', () {
      expect(SubtitleFormats.formatOf('a.srt'), SubtitleFormat.srt);
      expect(SubtitleFormats.formatOf('a.ass'), SubtitleFormat.ass);
      expect(SubtitleFormats.formatOf('a.idx'), SubtitleFormat.vobSub);
      expect(SubtitleFormats.formatOf('a.sup'), SubtitleFormat.pgs);
      expect(SubtitleFormats.formatOf('a.dfxp'), SubtitleFormat.ttml);
      expect(SubtitleFormats.formatOf('a.unknown'), SubtitleFormat.other);
    });

    test('文本 / 位图 / 富文本的区分', () {
      expect(SubtitleFormat.srt.isText, isTrue);
      expect(SubtitleFormat.ass.isRichText, isTrue);
      // 位图字幕改不了字号描边，UI 上的样式设置对它无效
      expect(SubtitleFormat.pgs.isText, isFalse);
      expect(SubtitleFormat.vobSub.isText, isFalse);
    });
  });

  group('SubtitleFormats.languageFromName', () {
    test('简繁必须分得开（cht 不能被 ch 抢走）', () {
      expect(SubtitleFormats.languageFromName('Movie.chs.srt')?.code, 'zh-Hans');
      expect(SubtitleFormats.languageFromName('Movie.cht.srt')?.code, 'zh-Hant');
      expect(SubtitleFormats.languageFromName('Movie.ch.srt')?.code, 'zh');
    });

    test('中文标记的多种写法', () {
      expect(SubtitleFormats.languageFromName('Movie.简体.srt')?.code, 'zh-Hans');
      expect(SubtitleFormats.languageFromName('Movie.简.srt')?.code, 'zh-Hans');
      expect(SubtitleFormats.languageFromName('Movie.繁体.srt')?.code, 'zh-Hant');
      expect(SubtitleFormats.languageFromName('Movie.中字.srt')?.code, 'zh');
      expect(SubtitleFormats.languageFromName('Movie.中英.srt')?.code, 'zh-en');
      expect(SubtitleFormats.languageFromName('Movie.双语.srt')?.code, 'zh-en');
    });

    test('其他语言', () {
      expect(SubtitleFormats.languageFromName('Movie.eng.srt')?.code, 'en');
      expect(SubtitleFormats.languageFromName('Movie.英文.srt')?.code, 'en');
      expect(SubtitleFormats.languageFromName('Movie.jpn.srt')?.code, 'ja');
      expect(SubtitleFormats.languageFromName('Movie.kor.srt')?.code, 'ko');
    });

    test('语言在倒数第二段也能认出来', () {
      // 真实命名里语言经常不在最后一段
      expect(
        SubtitleFormats.languageFromName('Movie.2023.1080p.BluRay.chs.ass')?.code,
        'zh-Hans',
      );
      expect(
        SubtitleFormats.languageFromName('Movie.chs.2023.srt')?.code,
        'zh-Hans',
      );
    });

    test('认不出来返回 null，不乱猜', () {
      expect(SubtitleFormats.languageFromName('Movie.2023.srt'), isNull);
      expect(SubtitleFormats.languageFromName('Movie.1080p.srt'), isNull);
    });

    test('短标记不做子串匹配（chen 不能被 ch 命中）', () {
      expect(SubtitleFormats.languageFromName('Movie.chen.srt'), isNull);
    });
  });

  group('SubtitleFormats.isForced / isSdh', () {
    test('强制字幕', () {
      expect(SubtitleFormats.isForced('Movie.chs.forced.srt'), isTrue);
      expect(SubtitleFormats.isForced('Movie.强制.srt'), isTrue);
      expect(SubtitleFormats.isForced('Movie.chs.srt'), isFalse);
    });

    test('听障字幕', () {
      expect(SubtitleFormats.isSdh('Movie.sdh.srt'), isTrue);
      expect(SubtitleFormats.isSdh('Movie.听障.srt'), isTrue);
      expect(SubtitleFormats.isSdh('Movie.chs.srt'), isFalse);
    });
  });

  group('SubtitleFormats.stripSubtitleTags', () {
    test('去掉语言段', () {
      final stripped = SubtitleFormats.stripSubtitleTags('Movie.2023.chs.ass');
      expect(stripped.contains('chs'), isFalse);
    });

    test('**保留**分辨率等技术标记', () {
      // 同一个目录里经常同时有 1080p 与 2160p 两个版本，
      // 把技术标记也剥掉会让一个字幕同时匹配到两部片子
      final stripped = SubtitleFormats.stripSubtitleTags('Movie.2023.1080p.chs.ass');
      expect(stripped.contains('1080p'), isTrue);
      expect(stripped.contains('2023'), isTrue);
    });

    test('去掉 forced / sdh 这类属性词', () {
      final stripped = SubtitleFormats.stripSubtitleTags('Movie.forced.sdh.srt');
      expect(stripped.contains('forced'), isFalse);
      expect(stripped.contains('sdh'), isFalse);
    });
  });
}
