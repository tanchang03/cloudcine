import 'package:cloudcine/domain/services/intro_marker.dart';
import 'package:cloudcine/domain/services/intro_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// 跳片头这条路上**状态转移**的回归。
///
/// 两个播放器（主窗口内置播放页、独立播放窗口）共用这一个状态机，而它们跑在
/// 不同的 Flutter 引擎里 —— 转移写错的表现是**静默**的：不报错、不崩，只是
/// 「跳片头时灵时不灵」。用户只会说「有时候跳有时候不跳」，而这是最难从反馈
/// 里定位的一类问题，所以每一条转移都要有断言。
void main() {
  const chapterIntro = IntroMarker(
    start: Duration.zero,
    end: Duration(seconds: 90),
  );
  const manualIntro = IntroMarker(
    start: Duration(seconds: 5),
    end: Duration(seconds: 95),
  );

  group('shouldProbe —— 什么时候去读文件章节', () {
    test('开播后 position 变成正数 → 读', () {
      final s = IntroSession();
      expect(s.shouldProbe(const Duration(milliseconds: 200)), isTrue);
    });

    test('position 还是 0 → 不读', () {
      // 这是整条路上最容易写错的一处。`open()` 只把 `loadfile` 投进命令
      // 队列就返回了，那一刻容器还没解析，`chapter-list` 恒为 `[]` ——
      // 而「还没解析完」与「这个文件就是没章节」在字符串上**无法区分**。
      // 在这里读，等于把「有章节的片子」也判成「没章节」，
      // 而且**永远不会重试**（`markProbed` 已经置位）。
      final s = IntroSession();
      expect(s.shouldProbe(Duration.zero), isFalse);
    });

    test('position 是负数 → 不读', () {
      // mpv 的 `time` 可以是负数（容器时间戳有偏移，实测首章 -0.023s）。
      final s = IntroSession();
      expect(s.shouldProbe(const Duration(milliseconds: -23)), isFalse);
    });

    test('已经读过 → 不再读', () {
      final s = IntroSession()..markProbed();
      expect(
        s.shouldProbe(const Duration(seconds: 30)),
        isFalse,
        reason: '位置流是每 ~100ms 一条的高频流。少了这个条件就是每秒十几次'
            '属性查询，而结果永远一样',
      );
    });

    test('设置里关掉了跳片头 → 连这一次查询都省掉', () {
      final s = IntroSession(enabled: false);
      expect(s.shouldProbe(const Duration(seconds: 30)), isFalse);
    });

    test('换流之后重新可以探测（漏了 reset 就会「只有第一集跳片头」）', () {
      final s = IntroSession()..markProbed();
      expect(s.shouldProbe(const Duration(seconds: 30)), isFalse);

      s.reset();
      expect(
        s.shouldProbe(const Duration(seconds: 1)),
        isTrue,
        reason: '不归零的话换集之后永远不再读章节 —— 而第一集恰好是最不需要'
            '跳的那一集（用户是从头开始看的），所以这个 bug 极难被发现',
      );
    });
  });

  group('marker —— 章节优先，手标兜底', () {
    test('两者都有 → 用文件章节', () {
      final s = IntroSession(manual: manualIntro)..setChapter(chapterIntro);
      expect(
        s.marker,
        chapterIntro,
        reason: '文件章节是压制者标的，与**这一集**的实际内容严格对应；'
            '手标是「这一部作品」级别的一次性标记，各集片长不同时会有偏差',
      );
      expect(s.fromChapters, isTrue);
    });

    test('只有章节 → 用章节', () {
      final s = IntroSession()..setChapter(chapterIntro);
      expect(s.marker, chapterIntro);
      expect(s.fromChapters, isTrue);
    });

    test('只有手标 → 用手标（绝大多数网盘片源就是这种）', () {
      final s = IntroSession(manual: manualIntro);
      expect(s.marker, manualIntro);
      expect(s.fromChapters, isFalse);
    });

    test('两者都没有 → null（这时这条规则完全空转，不误跳）', () {
      expect(IntroSession().marker, isNull);
    });

    test('章节探测没认出片头（null）→ 不覆盖手标', () {
      final s = IntroSession(manual: manualIntro)..setChapter(null);
      expect(
        s.marker,
        manualIntro,
        reason: '「有章节但没认出片头」是最常见的一种结果。用它把 marker '
            '置空，等于给「本来就靠手标在跳」的用户平白关掉了这个功能',
      );
    });
  });

  group('takeSkipTarget —— 该跳的时候跳，且只跳一次', () {
    test('播放头进了区间 → 返回区间终点', () {
      final s = IntroSession(manual: manualIntro);
      expect(s.takeSkipTarget(const Duration(seconds: 30)), manualIntro.end);
      expect(s.skipped, isTrue);
    });

    test('同一段里连问几次 → 只有第一次给目标', () {
      final s = IntroSession(manual: manualIntro);
      expect(s.takeSkipTarget(const Duration(seconds: 30)), manualIntro.end);
      // 位置流每 ~100ms 一条，`seek` 往返期间还会来好几条（都还在区间内）。
      // 不加这条闸，它们会各发一次 seek —— 表现是画面往前窜、进度条乱跳。
      expect(s.takeSkipTarget(const Duration(seconds: 31)), isNull);
      expect(s.takeSkipTarget(const Duration(seconds: 32)), isNull);
    });

    test('用户把进度条拖回片头想看 OP → 不会再被推走', () {
      final s = IntroSession(manual: manualIntro);
      expect(s.takeSkipTarget(const Duration(seconds: 30)), isNotNull);
      // 这是「跳一次」这个设计的**全部意义**：拖回去就是要看那一段，
      // 再推一次等于让进度条不听使唤。
      expect(s.takeSkipTarget(const Duration(seconds: 10)), isNull);
    });

    test('还没进区间 → 不跳', () {
      final s = IntroSession(manual: manualIntro);
      expect(s.takeSkipTarget(const Duration(seconds: 1)), isNull);
      expect(s.skipped, isFalse);
    });

    test('已经走过区间末尾 → 不跳（跳过去等于原地不动）', () {
      final s = IntroSession(manual: manualIntro);
      expect(s.takeSkipTarget(const Duration(seconds: 200)), isNull);
    });

    test('离末尾不到 1 秒 → 不跳（只是一次抖动）', () {
      final s = IntroSession(manual: manualIntro);
      expect(s.takeSkipTarget(manualIntro.end - const Duration(milliseconds: 200)), isNull);
    });

    test('位置为 0 / 负数 → 不跳（流还没解析完，position 不可信）', () {
      final s = IntroSession(manual: manualIntro);
      expect(s.takeSkipTarget(Duration.zero), isNull);
      expect(s.takeSkipTarget(const Duration(seconds: -5)), isNull);
    });

    test('设置里关掉了 → 一次都不跳', () {
      final s = IntroSession(manual: manualIntro, enabled: false);
      expect(s.takeSkipTarget(const Duration(seconds: 30)), isNull);
      expect(s.skipped, isFalse);
    });

    test('标记不成立（起终点反了）→ 不跳', () {
      const reversed = IntroMarker(
        start: Duration(seconds: 90),
        end: Duration(seconds: 10),
      );
      final s = IntroSession(manual: reversed);
      expect(
        s.takeSkipTarget(const Duration(seconds: 95)),
        isNull,
        reason: '反过来的区间不会报错，只会让「跳过片头」变成一次**向后跳**'
            '—— 用户看到画面突然倒回片头然后卡住，比不跳糟得多',
      );
    });
  });

  group('setManual —— 刚标完就应当生效', () {
    test('标记之后重新给一次机会', () {
      final s = IntroSession(manual: manualIntro);
      expect(s.takeSkipTarget(const Duration(seconds: 30)), isNotNull);
      expect(s.takeSkipTarget(const Duration(seconds: 30)), isNull);

      // 用户播到一半改了区间。不清 `skipped` 的话新区间在本次播放里
      // 一次都不会生效 —— 而他会以为标记没保存成功，于是再标一次。
      s.setManual(
        const IntroMarker(start: Duration(seconds: 10), end: Duration(seconds: 40)),
      );
      expect(s.skipped, isFalse);
      expect(s.takeSkipTarget(const Duration(seconds: 20)), isNotNull);
    });

    test('取消标记（传 null）→ 不再跳，但章节那一份照旧', () {
      final s = IntroSession(manual: manualIntro)..setChapter(chapterIntro);
      s.setManual(null);
      expect(s.manual, isNull);
      expect(s.marker, chapterIntro);
      expect(s.takeSkipTarget(const Duration(seconds: 30)), chapterIntro.end);
    });
  });

  group('reset / endStream —— 两种归零的范围不同', () {
    test('reset 连开关与手标一起换掉（换集时用）', () {
      final s = IntroSession(manual: manualIntro, enabled: true)
        ..setChapter(chapterIntro)
        ..markProbed();
      s.reset(manual: null, enabled: false);
      expect(s.manual, isNull);
      expect(s.marker, isNull);
      expect(s.enabled, isFalse);
      expect(s.shouldProbe(const Duration(seconds: 1)), isFalse);
    });

    test('endStream 保留开关与手标（退出播放时用）', () {
      final s = IntroSession(manual: manualIntro)
        ..setChapter(chapterIntro)
        ..markProbed();
      s.endStream();
      expect(s.marker, manualIntro, reason: '章节那份属于上一条流，要清');
      expect(s.enabled, isTrue);
      expect(
        s.shouldProbe(const Duration(seconds: 1)),
        isTrue,
        reason: '清掉「已探测」标志，下一次播放要重新读章节',
      );
    });
  });
}
