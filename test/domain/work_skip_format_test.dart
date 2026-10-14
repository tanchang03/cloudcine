import 'package:flutter_test/flutter_test.dart';

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/work_skip_format.dart';

void main() {
  MediaWork work({
    int? introStartMs,
    int? introEndMs,
    int? outroOffsetMs,
    int? learnedIntroStartMs,
    int? learnedIntroEndMs,
    int? learnedOutroOffsetMs,
    int learnedSamples = 0,
  }) =>
      MediaWork(
        key: 'quark:g1',
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: '测试剧',
        introStartMs: introStartMs,
        introEndMs: introEndMs,
        outroOffsetMs: outroOffsetMs,
        learnedIntroStartMs: learnedIntroStartMs,
        learnedIntroEndMs: learnedIntroEndMs,
        learnedOutroOffsetMs: learnedOutroOffsetMs,
        learnedSamples: learnedSamples,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );

  group('WorkSkipFormat.line', () {
    test('什么都没标也没学过 → 整行不出现', () {
      // 「片头 —」这种空壳比什么都不显示更糟：用户会以为它学过了、
      // 只是没学出来，于是去看设置，而不是手动标一下。
      expect(WorkSkipFormat.line(work()), isNull);
      expect(WorkSkipFormat.hasAny(work()), isFalse);
    });

    test('半条手标（只标了起点）不算有片头结论', () {
      // 半个区间跳不了，写出来只会让人以为「它跳了但我没看见」。
      expect(WorkSkipFormat.introLine(work(introStartMs: 5000)), isNull);
    });

    test('手标片头写明起止时间点，并标出手标', () {
      expect(
        WorkSkipFormat.introLine(work(introStartMs: 0, introEndMs: 92000)),
        '片头 00:00–01:32（手标）',
      );
    });

    test('学出来的片头标成自动学习', () {
      expect(
        WorkSkipFormat.introLine(
          work(learnedIntroStartMs: 0, learnedIntroEndMs: 92000, learnedSamples: 4),
        ),
        '片头 00:00–01:32（自动学习）',
      );
    });

    test('⛔ 手标压过学习 —— 优先级链只有一条', () {
      // 链断了的后果是「我明明标过，界面却显示它自己猜的那个」。
      expect(
        WorkSkipFormat.introLine(
          work(
            introStartMs: 0,
            introEndMs: 60000,
            learnedIntroStartMs: 0,
            learnedIntroEndMs: 92000,
          ),
        ),
        '片头 00:00–01:00（手标）',
      );
    });

    test('片尾写「距末尾」的偏移，不折算成绝对时间', () {
      expect(
        WorkSkipFormat.outroLine(work(outroOffsetMs: 80000)),
        '片尾 距末尾 01:20（手标）',
      );
      expect(
        WorkSkipFormat.outroLine(work(learnedOutroOffsetMs: 80000)),
        '片尾 距末尾 01:20（自动学习）',
      );
    });

    test('片尾偏移为零不算数（0 秒的片尾跳过去毫无意义）', () {
      expect(WorkSkipFormat.outroLine(work(outroOffsetMs: 0)), isNull);
      expect(WorkSkipFormat.outroLine(work(learnedOutroOffsetMs: 0)), isNull);
    });

    test('片头片尾同时有值 → 用间隔号连成一行', () {
      expect(
        WorkSkipFormat.line(
          work(
            introStartMs: 0,
            introEndMs: 92000,
            learnedOutroOffsetMs: 80000,
          ),
        ),
        '片头 00:00–01:32（手标） · 片尾 距末尾 01:20（自动学习）',
      );
    });

    test('只有片尾时只显示片尾', () {
      expect(
        WorkSkipFormat.line(work(learnedOutroOffsetMs: 80000)),
        '片尾 距末尾 01:20（自动学习）',
      );
    });
  });

  group('WorkSkipFormat.clock / parseClock', () {
    test('超过一小时补出小时位', () {
      expect(WorkSkipFormat.clock(3723000), '1:02:03');
      expect(WorkSkipFormat.clock(92000), '01:32');
    });

    test('null / 负数一律当 0', () {
      expect(WorkSkipFormat.clock(null), '00:00');
      expect(WorkSkipFormat.clock(-1), '00:00');
    });

    test('四种写法都能解析（用户在输入框里不会先换算）', () {
      expect(WorkSkipFormat.parseClock('90'), 90000);
      expect(WorkSkipFormat.parseClock('1:30'), 90000);
      expect(WorkSkipFormat.parseClock('01:30'), 90000);
      expect(WorkSkipFormat.parseClock('1:02:03'), 3723000);
    });

    test('解析不了的返回 null（调用方据此提示，而不是记成 0）', () {
      expect(WorkSkipFormat.parseClock(''), isNull);
      expect(WorkSkipFormat.parseClock('abc'), isNull);
      expect(WorkSkipFormat.parseClock('1:2:3:4'), isNull);
      expect(WorkSkipFormat.parseClock('-5'), isNull);
    });

    test('clock 与 parseClock 往返一致', () {
      for (final ms in <int>[0, 1000, 92000, 3723000]) {
        expect(WorkSkipFormat.parseClock(WorkSkipFormat.clock(ms)), ms);
      }
    });
  });
}
