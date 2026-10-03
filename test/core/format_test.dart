import 'package:cloudcine/core/utils/format.dart';
import 'package:flutter_test/flutter_test.dart';

/// 展示层的两个时间格式化函数。
///
/// 它们是一对：相对时间（`3 天前`）负责「扫一眼看新旧」，完整时刻
/// （`2026-10-03 16:41`）负责回答「到底是哪一刻」。目录视图把前者印在
/// 「修改时间」那一列里、后者放在 tooltip 里 —— 补零写漏了不会报错，
/// 只会显示成 `2026-1-2 3:4` 这种一眼看出不齐的样子。
void main() {
  group('formatDateTimeMinute', () {
    test('月 / 日 / 时 / 分都补零到两位', () {
      expect(
        formatDateTimeMinute(DateTime(2026, 1, 2, 3, 4)),
        '2026-01-02 03:04',
      );
    });

    test('已经是两位的不变，且不含秒', () {
      expect(
        formatDateTimeMinute(DateTime(2026, 10, 30, 16, 41, 59)),
        '2026-10-30 16:41',
        reason: '秒被丢掉是刻意的：这一列/tooltip 只需要分钟级精度，'
            '带上秒会让宽度多出 3 个字符',
      );
    });
  });

  group('formatStorageUsage', () {
    const gb = 1024 * 1024 * 1024;

    test('三段齐全：已用 / 总量 / 剩余', () {
      expect(
        formatStorageUsage(1536 * gb, 2048 * gb),
        '1.5 TB / 2.0 TB · 剩 512.0 GB',
      );
    });

    test('剩余量夹在 0，不出现「剩 -3 GB」', () {
      expect(formatStorageUsage(2050 * gb, 2048 * gb),
          '2.0 TB / 2.0 TB · 剩 0 B',
          reason: '配额刚降档时两份数字可能自相矛盾。显示负数的剩余空间'
              '会被当成 bug 报上来，而这里其实什么也做不了。');
    });

    test('总量未知返回空串，而不是「0 B / 0 B」', () {
      expect(formatStorageUsage(0, 0), '');
      expect(formatStorageUsage(100, -1), '',
          reason: '调用方（容量条）靠空串决定整行不画。画成 0 会被读成'
              '「网盘满了」，那是完全相反的意思。');
    });
  });

  group('formatRelativeTime', () {
    final now = DateTime(2026, 10, 3, 12, 0);

    test('按档位给出相对描述', () {
      expect(formatRelativeTime(now, now: now), '刚刚');
      expect(formatRelativeTime(DateTime(2026, 10, 3, 11, 50), now: now), '10 分钟前');
      expect(formatRelativeTime(DateTime(2026, 10, 3, 8, 0), now: now), '4 小时前');
      expect(formatRelativeTime(DateTime(2026, 9, 30, 12, 0), now: now), '3 天前');
    });

    test('超过 30 天退回完整日期', () {
      expect(formatRelativeTime(DateTime(2026, 9, 1, 9, 0), now: now), '2026-09-01',
          reason: '「33 天前」这种说法已经帮不上忙了，给日期更直接');
    });

    test('未来时间说「刚刚」，不说「-5 分钟前」', () {
      expect(formatRelativeTime(DateTime(2026, 10, 3, 12, 5), now: now), '刚刚',
          reason: '网盘时间戳与本地时钟差几分钟很常见，'
              '负数的时间描述会被读成「这个功能坏了」');
    });
  });
}
