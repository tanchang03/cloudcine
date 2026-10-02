import 'package:cloudcine/domain/services/intro_marker.dart';
import 'package:flutter_test/flutter_test.dart';

/// 片头识别与跳过判定。
///
/// 这里的每一条断言都对应一个**用户看得见、但不报错**的后果：
///   - 认错 → 用户直接丢掉半集内容（不可逆）；
///   - 认不出来 → 功能静默失效，用户以为「这个功能没做」；
///   - 跳过判太松 → 用户把进度条拖回片头想看 OP，会被一次次推走。
void main() {
  group('MpvChapterList.parse（真 libmpv 量出来的格式）', () {
    // ⚠️ 这一串是**实测值**，不是编的：用产物里的 Mpv.framework（Python
    // ctypes 拉起，vo=null ao=null）打开一个带 3 章节的 mkv 读回来的原文。
    // 换版本重测后如果它变了，这里应当跟着变 —— 而不是反过来去改断言。
    const measured =
        '[{"title":"Opening","time":-0.023000},{"title":"Part A","time":9.977000},'
        '{"title":"Ending","time":39.977000}]';

    test('实测格式解析出三条，且负时间被夹到 0', () {
      final chapters = MpvChapterList.parse(measured);
      expect(chapters, hasLength(3));
      expect(chapters[0].title, 'Opening');
      // 首章实测是 -0.023s。不夹的话「片头起点」是个负数，
      // `position >= start` 会立刻成立 —— 结果一样，但落库与日志里
      // 会出现一个负的起点，排查时会以为算错了。
      expect(chapters[0].start, Duration.zero);
      expect(chapters[1].start, const Duration(milliseconds: 9977));
      expect(chapters[2].title, 'Ending');
    });

    test('没有章节时 mpv 给的是 `[]` —— 解析成空列表，不是一条空章节', () {
      expect(MpvChapterList.parse('[]'), isEmpty);
      expect(MpvChapterList.parse(''), isEmpty);
      expect(MpvChapterList.parse('   '), isEmpty);
    });

    test('畸形输入一律返回空列表，不抛', () {
      // 章节读不出来只该让「跳片头」不生效，不该把播放搞挂。
      expect(MpvChapterList.parse('不是 JSON'), isEmpty);
      expect(MpvChapterList.parse('[{"title":}'), isEmpty);
      expect(MpvChapterList.parse('{"title":"x"}'), isEmpty); // 不是数组
      expect(MpvChapterList.parse('[1,2,3]'), isEmpty);
    });

    test('缺 title 的章节保留（只是名字为空），缺 time 的丢掉', () {
      final chapters = MpvChapterList.parse('[{"time":5},{"title":"A"}]');
      expect(chapters, hasLength(1));
      expect(chapters.single.title, '');
      expect(chapters.single.start, const Duration(seconds: 5));
    });

    test('排版变了也能靠兜底正则认出 title/time 对', () {
      // 万一某个版本不再输出合法 JSON，这条路是唯一的退路。
      final chapters = MpvChapterList.parse(
        'chapter 0: title="Opening" time=0.000000, '
        'chapter 1: title="Main" time=90.000000',
      );
      expect(chapters, hasLength(2));
      expect(chapters[0].title, 'Opening');
      expect(chapters[1].start, const Duration(seconds: 90));
    });
  });

  group('IntroMarkerDetector.looksLikeIntro', () {
    test('中文关键词按包含匹配（中文没有词边界）', () {
      expect(IntroMarkerDetector.looksLikeIntro('片头'), isTrue);
      expect(IntroMarkerDetector.looksLikeIntro('片头曲'), isTrue);
      expect(IntroMarkerDetector.looksLikeIntro('[片头]'), isTrue);
      expect(IntroMarkerDetector.looksLikeIntro('开场'), isTrue);
    });

    test('英文关键词大小写不敏感', () {
      expect(IntroMarkerDetector.looksLikeIntro('Opening'), isTrue);
      expect(IntroMarkerDetector.looksLikeIntro('INTRO'), isTrue);
      expect(IntroMarkerDetector.looksLikeIntro('Opening Credits'), isTrue);
      expect(IntroMarkerDetector.looksLikeIntro('Main Title'), isTrue);
    });

    test('短英文词必须卡词边界 —— `op` 不能命中 `Operation`', () {
      // 与 `ova` 命中 `Nova.2023` 是同一个坑（见 `MediaCategoryGuesser`）。
      expect(IntroMarkerDetector.looksLikeIntro('Operation'), isFalse);
      expect(IntroMarkerDetector.looksLikeIntro('Reopen'), isFalse);
      expect(IntroMarkerDetector.looksLikeIntro('Chapter 01'), isFalse);
      // 但单独一个 OP 要认出来。
      expect(IntroMarkerDetector.looksLikeIntro('OP'), isTrue);
      expect(IntroMarkerDetector.looksLikeIntro('NCOP'), isTrue);
    });

    test('片尾词一律不认 —— 那是另一个功能', () {
      // 「跳片尾」的落点是下一集，与「跳片头」完全不同。混进来会让
      // 一集播到结尾时先跳到片尾结束，反而多等一段。
      expect(IntroMarkerDetector.looksLikeIntro('Ending'), isFalse);
      expect(IntroMarkerDetector.looksLikeIntro('片尾'), isFalse);
      expect(IntroMarkerDetector.looksLikeIntro('Preview'), isFalse);
      expect(IntroMarkerDetector.looksLikeIntro('预告'), isFalse);
      // 「前情提要」刻意不算片头：很多用户跳片头但要看前情提要。
      expect(IntroMarkerDetector.looksLikeIntro('前情提要'), isFalse);
    });

    test('空标题不认', () {
      expect(IntroMarkerDetector.looksLikeIntro(''), isFalse);
      expect(IntroMarkerDetector.looksLikeIntro('   '), isFalse);
    });
  });

  group('IntroMarkerDetector.detect', () {
    test('片头章节的终点取下一个章节的起点', () {
      final marker = IntroMarkerDetector.detect(const [
        IntroChapter(title: 'Opening', start: Duration.zero),
        IntroChapter(title: 'Part A', start: Duration(seconds: 95)),
        IntroChapter(title: 'Ending', start: Duration(minutes: 40)),
      ]);
      expect(marker, const IntroMarker(
        start: Duration.zero,
        end: Duration(seconds: 95),
      ));
    });

    test('片头不在 0 秒也认（冷开场之后的片头）', () {
      final marker = IntroMarkerDetector.detect(const [
        IntroChapter(title: 'Cold Open', start: Duration.zero),
        IntroChapter(title: '片头', start: Duration(minutes: 2)),
        IntroChapter(title: '正片', start: Duration(minutes: 3, seconds: 30)),
      ]);
      expect(marker!.start, const Duration(minutes: 2));
      expect(marker.end, const Duration(minutes: 3, seconds: 30));
    });

    test('片头是最后一个章节 → 认不出来（推不出终点）', () {
      // 拿片长当终点会跳掉后面**全部**内容，比不跳糟得多。
      expect(
        IntroMarkerDetector.detect(const [
          IntroChapter(title: 'Part A', start: Duration.zero),
          IntroChapter(title: 'Opening', start: Duration(minutes: 20)),
        ]),
        isNull,
      );
    });

    test('只有一个章节 → 认不出来', () {
      expect(
        IntroMarkerDetector.detect(const [
          IntroChapter(title: 'Opening', start: Duration.zero),
        ]),
        isNull,
      );
      expect(IntroMarkerDetector.detect(const []), isNull);
    });

    test('起点太晚（超过 15 分钟）不认 —— 那多半是正片被叫成了 Opening', () {
      // 跳过去会让用户丢掉半集内容，且不可逆。
      expect(
        IntroMarkerDetector.detect(const [
          IntroChapter(title: 'Chapter 01', start: Duration.zero),
          IntroChapter(title: 'Opening', start: Duration(minutes: 40)),
          IntroChapter(title: 'Chapter 03', start: Duration(minutes: 45)),
        ]),
        isNull,
      );
    });

    test('区间太短（<5 秒）不认 —— 跳过去只是让画面抖一下', () {
      expect(
        IntroMarkerDetector.detect(const [
          IntroChapter(title: 'Opening', start: Duration.zero),
          IntroChapter(title: 'Main', start: Duration(seconds: 3)),
        ]),
        isNull,
      );
    });

    test('区间太长（>10 分钟）不认 —— 那是把正片整段命名成了 Opening', () {
      expect(
        IntroMarkerDetector.detect(const [
          IntroChapter(title: 'Opening', start: Duration.zero),
          IntroChapter(title: 'Main', start: Duration(minutes: 30)),
        ]),
        isNull,
      );
    });

    test('多个候选取第一个', () {
      final marker = IntroMarkerDetector.detect(const [
        IntroChapter(title: 'Opening', start: Duration.zero),
        IntroChapter(title: 'Part A', start: Duration(seconds: 90)),
        IntroChapter(title: 'Opening 2', start: Duration(minutes: 20)),
        IntroChapter(title: 'Part B', start: Duration(minutes: 21)),
      ]);
      expect(marker!.start, Duration.zero);
      expect(marker.end, const Duration(seconds: 90));
    });

    test('完全没章节 → null（绝大多数网盘片源就是这样）', () {
      expect(IntroMarkerDetector.detect(const []), isNull);
    });
  });

  group('IntroMarker.fromMilliseconds（库里那一份）', () {
    test('正常的起终点能读出来', () {
      expect(
        IntroMarker.fromMilliseconds(10000, 95000),
        const IntroMarker(
          start: Duration(seconds: 10),
          end: Duration(seconds: 95),
        ),
      );
    });

    test('半条标记（只标了起点或只标了终点）当没有', () {
      // 半个区间没法跳 —— 认了它反而要在这里再判一次「终点呢」。
      expect(IntroMarker.fromMilliseconds(10000, null), isNull);
      expect(IntroMarker.fromMilliseconds(null, 95000), isNull);
    });

    test('反过来的区间当没有', () {
      expect(IntroMarker.fromMilliseconds(95000, 10000), isNull);
      expect(IntroMarker.fromMilliseconds(10000, 10000), isNull);
    });

    test('负数当没有', () {
      expect(IntroMarker.fromMilliseconds(-1, 95000), isNull);
    });
  });

  group('IntroSkip.shouldSkip', () {
    const marker = IntroMarker(
      start: Duration(seconds: 10),
      end: Duration(seconds: 100),
    );

    bool skip(
      Duration position, {
      bool skipped = false,
      IntroMarker? m = marker,
    }) =>
        IntroSkip.shouldSkip(position: position, marker: m, skipped: skipped);

    test('播放头进了区间 → 跳', () {
      expect(skip(const Duration(seconds: 10)), isTrue);
      expect(skip(const Duration(seconds: 50)), isTrue);
    });

    test('还没进区间 → 不跳', () {
      expect(skip(const Duration(seconds: 9)), isFalse);
      expect(skip(Duration.zero), isFalse);
    });

    test('已经走过区间末尾 → 不跳（跳过去等于原地不动）', () {
      expect(skip(const Duration(seconds: 100)), isFalse);
      expect(skip(const Duration(minutes: 20)), isFalse);
    });

    test('离末尾不到 1 秒 → 不跳（只是一次抖动）', () {
      expect(skip(const Duration(milliseconds: 99500)), isFalse);
      expect(skip(const Duration(seconds: 98)), isTrue);
    });

    test('本次播放已经跳过 → 再也不跳', () {
      // 这条是「跳一次」的全部实现。少了它，用户把进度条拖回片头想看 OP，
      // 会被每一次 position 回调推走一次 —— 画面疯狂往前窜。
      expect(skip(const Duration(seconds: 30), skipped: true), isFalse);
    });

    test('没有标记 / 标记不成立 → 不跳', () {
      expect(skip(const Duration(seconds: 30), m: null), isFalse);
      expect(
        skip(
          const Duration(seconds: 30),
          m: const IntroMarker(
            start: Duration(seconds: 100),
            end: Duration(seconds: 10),
          ),
        ),
        isFalse,
      );
    });

    test('位置为 0 / 负数 → 不跳（流还没解析完，position 不可信）', () {
      expect(skip(Duration.zero), isFalse);
      expect(skip(const Duration(seconds: -5)), isFalse);
    });
  });
}
